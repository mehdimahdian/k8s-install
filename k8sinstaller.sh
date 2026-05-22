#!/usr/bin/env bash
# Kubernetes Installation Script for Ubuntu 24.04
# Author: Mohammad Mahdi Mahdian

set -euo pipefail

# ── Configurable versions ──────────────────────────────────────────────────────
# Update these to pin a specific release.
K8S_VERSION="1.31"        # major.minor — selects the pkgs.k8s.io channel
CALICO_VERSION="v3.29.0"  # https://github.com/projectcalico/calico/releases

# ── Colors ────────────────────────────────────────────────────────────────────
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# ── Status tracking ───────────────────────────────────────────────────────────
STATUS_PREREQUISITES="Not Run"
STATUS_SWAP="Not Run"
STATUS_SYSCTL="Not Run"
STATUS_CONTAINERD="Not Run"
STATUS_KUBERNETES="Not Run"
STATUS_NETWORK="Skipped"
STATUS_MASTER="Skipped"
STATUS_WORKER="Skipped"

# ── Helpers ───────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automates Kubernetes ${K8S_VERSION} installation on Ubuntu 24.04 LTS.
Configures either a master (control-plane) or worker node.

Options:
  -h, --help    Show this help message and exit

Requirements:
  - Ubuntu 24.04 LTS (64-bit)
  - Root / sudo privileges
  - Master node: 2 CPUs, 2 GB RAM minimum
  - Worker node:  1 CPU,  1 GB RAM minimum

Installed components:
  - containerd (container runtime)
  - kubelet, kubeadm, kubectl ${K8S_VERSION}
  - Calico CNI ${CALICO_VERSION} (master node only)
EOF
}

display_summary() {
  echo -e "\n${YELLOW}━━━  Installation Summary  ━━━${RESET}"
  printf "  %-34s %s\n" "Prerequisites:"         "$STATUS_PREREQUISITES"
  printf "  %-34s %s\n" "Swap disabled:"          "$STATUS_SWAP"
  printf "  %-34s %s\n" "Kernel modules / sysctl:" "$STATUS_SYSCTL"
  printf "  %-34s %s\n" "containerd:"             "$STATUS_CONTAINERD"
  printf "  %-34s %s\n" "Kubernetes components:"  "$STATUS_KUBERNETES"
  printf "  %-34s %s\n" "Network configuration:"  "$STATUS_NETWORK"
  printf "  %-34s %s\n" "Master node init:"       "$STATUS_MASTER"
  printf "  %-34s %s\n" "Worker node join:"       "$STATUS_WORKER"
  echo
}

# ERR trap: print context and summary, then let set -e exit the script.
on_error() {
  echo -e "\n${RED}Error: installation failed (script line ${1}).${RESET}" >&2
  display_summary
}
trap 'on_error ${LINENO}' ERR

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}This script must be run as root. Use: sudo bash $0${RESET}" >&2
    exit 1
  fi
}

check_ubuntu_version() {
  if ! grep -qi 'Ubuntu 24\.04' /etc/os-release 2>/dev/null; then
    echo -e "${YELLOW}Warning: this script targets Ubuntu 24.04; other versions are untested.${RESET}"
  fi
}

# Returns 0 if $1 is a valid dotted-quad IP address, 1 otherwise.
validate_ip() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for octet in "${parts[@]}"; do
    (( octet <= 255 )) || return 1
  done
}

# Returns 0 if $1 is a valid CIDR block (x.x.x.x/0-32), 1 otherwise.
validate_cidr() {
  local input="$1"
  [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  validate_ip "${input%%/*}"
}

# ── Installation steps ────────────────────────────────────────────────────────

install_prerequisites() {
  echo "Updating system and installing prerequisites..."
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y apt-transport-https ca-certificates curl gpg
  STATUS_PREREQUISITES="Success"
}

disable_swap() {
  echo "Disabling swap..."
  swapoff -a
  # Comment out any active swap entries in /etc/fstab
  sed -i '/\bswap\b/{ /^[[:space:]]*#/!s/^/# / }' /etc/fstab
  STATUS_SWAP="Success"
}

configure_sysctl() {
  echo "Loading kernel modules and applying sysctl settings..."

  # Load modules immediately (also persisted for reboots via modules-load.d)
  modprobe overlay
  modprobe br_netfilter

  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

  cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sysctl --system
  STATUS_SYSCTL="Success"
}

install_containerd() {
  echo "Installing containerd..."
  apt-get install -y containerd

  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  # kubeadm requires the systemd cgroup driver
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl restart containerd
  systemctl enable containerd
  STATUS_CONTAINERD="Success"
}

install_kubernetes() {
  echo "Installing Kubernetes ${K8S_VERSION} (kubelet, kubeadm, kubectl)..."

  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  chmod 644 /etc/apt/sources.list.d/kubernetes.list

  apt-get update -y
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  STATUS_KUBERNETES="Success"
}

# ── Networking (split into two focused functions) ─────────────────────────────

configure_network_ip() {
  local ip_cidr ip_address cidr gateway dns_servers dns_yaml network_interface

  read -rp "Enter IP address and CIDR (e.g. 192.168.1.10/24) [leave blank to keep DHCP]: " ip_cidr
  [[ -z "$ip_cidr" ]] && return 0

  until validate_cidr "$ip_cidr"; do
    echo -e "${RED}Invalid format. Expected x.x.x.x/prefix (e.g. 192.168.1.10/24).${RESET}"
    read -rp "Enter IP address and CIDR: " ip_cidr
    [[ -z "$ip_cidr" ]] && return 0
  done

  ip_address="${ip_cidr%%/*}"
  cidr="${ip_cidr##*/}"

  # Default gateway: replace last octet with 1
  IFS='.' read -r o1 o2 o3 _ <<< "$ip_address"
  local default_gw="${o1}.${o2}.${o3}.1"
  read -rp "Enter gateway IP [default: ${default_gw}]: " gateway
  gateway="${gateway:-$default_gw}"
  until validate_ip "$gateway"; do
    echo -e "${RED}Invalid gateway IP.${RESET}"
    read -rp "Enter gateway IP [default: ${default_gw}]: " gateway
    gateway="${gateway:-$default_gw}"
  done

  read -rp "Enter DNS servers, comma-separated [default: 1.1.1.1,8.8.8.8]: " dns_servers
  dns_servers="${dns_servers:-1.1.1.1,8.8.8.8}"
  # Build a valid YAML inline sequence: "1.1.1.1,8.8.8.8" → "[1.1.1.1, 8.8.8.8]"
  dns_yaml="[${dns_servers//,/, }]"

  network_interface=$(ip -o -4 route show to default | awk '{print $5; exit}')

  echo "Applying static IP configuration on interface ${network_interface}..."
  cat >/etc/netplan/99-kubernetes.yaml <<EOF
network:
  version: 2
  ethernets:
    ${network_interface}:
      dhcp4: false
      addresses:
        - ${ip_address}/${cidr}
      routes:
        - to: default
          via: ${gateway}
      nameservers:
        addresses: ${dns_yaml}
EOF

  netplan apply
  STATUS_NETWORK="Success"
  echo "Static network configuration applied."
}

configure_hostname() {
  local hostname domain_name fqdn current_ip

  read -rp "Enter hostname for this machine (e.g. k8s-master): " hostname
  while [[ -z "$hostname" ]]; do
    echo -e "${RED}Hostname cannot be empty.${RESET}"
    read -rp "Enter hostname: " hostname
  done

  read -rp "Enter domain name (optional, press Enter to skip): " domain_name
  if [[ -n "$domain_name" ]]; then
    fqdn="${hostname}.${domain_name}"
  else
    fqdn="$hostname"
  fi

  hostnamectl set-hostname "$fqdn"

  # Update /etc/hosts with the current primary IP
  current_ip=$(ip -o -4 route get 1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

  if [[ -n "$current_ip" ]] && validate_ip "$current_ip"; then
    if grep -q "$current_ip" /etc/hosts; then
      sed -i "/${current_ip}/c\\${current_ip} ${fqdn} ${hostname}" /etc/hosts
    else
      printf '%s\t%s %s\n' "$current_ip" "$fqdn" "$hostname" >>/etc/hosts
    fi
  fi

  echo "Hostname set to: ${fqdn}"
}

# ── Node setup ────────────────────────────────────────────────────────────────

initialize_master() {
  local pod_cidr

  read -rp "Enter Pod Network CIDR [default: 192.168.0.0/16]: " pod_cidr
  pod_cidr="${pod_cidr:-192.168.0.0/16}"
  until validate_cidr "$pod_cidr"; do
    echo -e "${RED}Invalid CIDR. Expected x.x.x.x/prefix (e.g. 192.168.0.0/16).${RESET}"
    read -rp "Enter Pod Network CIDR: " pod_cidr
  done

  echo "Initializing Kubernetes control-plane..."
  kubeadm init --pod-network-cidr="${pod_cidr}"

  mkdir -p "$HOME/.kube"
  cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  echo "Deploying Calico ${CALICO_VERSION} CNI..."
  kubectl apply -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

  STATUS_MASTER="Success"
  echo -e "\n${GREEN}Control-plane is ready.${RESET}"
  echo "Worker node join command:"
  kubeadm token create --print-join-command
}

join_worker() {
  local master_ip join_token ca_cert_hash

  read -rp "Enter master node IP address: " master_ip
  until validate_ip "$master_ip"; do
    echo -e "${RED}Invalid IP address.${RESET}"
    read -rp "Enter master node IP address: " master_ip
  done

  read -rp "Enter join token: " join_token
  read -rp "Enter discovery-token CA cert hash (without 'sha256:'): " ca_cert_hash

  echo "Joining cluster at ${master_ip}:6443..."
  kubeadm join "${master_ip}:6443" \
    --token "${join_token}" \
    --discovery-token-ca-cert-hash "sha256:${ca_cert_hash}"

  STATUS_WORKER="Success"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      *) echo -e "${RED}Unknown option: ${arg}${RESET}" >&2; usage; exit 1 ;;
    esac
  done

  check_root
  check_ubuntu_version

  install_prerequisites
  disable_swap
  configure_sysctl
  install_containerd
  install_kubernetes
  configure_network_ip
  configure_hostname

  echo
  echo "Select node type to configure:"
  echo "  1) Master (control-plane)"
  echo "  2) Worker"
  read -rp "Choice [1/2]: " node_type

  case "$node_type" in
    1) initialize_master ;;
    2) join_worker ;;
    *)
      echo -e "${RED}Invalid choice. Run the script again and enter 1 or 2.${RESET}" >&2
      exit 1
      ;;
  esac

  display_summary
  echo -e "${GREEN}Kubernetes setup complete!${RESET}"
}

main "$@"
