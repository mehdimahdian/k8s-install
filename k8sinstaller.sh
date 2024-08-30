#!/bin/bash

# Kubernetes Installation Script for Ubuntu 24.04
# This script automates the installation of Kubernetes master and worker nodes on Ubuntu 24.04.
# AUTHER: Mohammad Mahdi Mahdian

# ANSI color codes for colored output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# Initialize status tracking variables
STATUS_PREREQUISITES="Not Run"
STATUS_SWAP="Not Run"
STATUS_SYSCTL="Not Run"
STATUS_CONTAINERD="Not Run"
STATUS_KUBERNETES="Not Run"
STATUS_NETWORK="Skipped"
STATUS_MASTER="Skipped"
STATUS_WORKER="Skipped"

# Function to check for root privileges
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use sudo.${RESET}"
    exit 1
  fi
}

# Function to update system and install prerequisites
install_prerequisites() {
  echo "Updating system and installing prerequisites..."
  apt update && apt upgrade -y
  apt install -y apt-transport-https ca-certificates curl
  if [ $? -eq 0 ]; then
    STATUS_PREREQUISITES="Success"
  else
    STATUS_PREREQUISITES="Failure"
  fi
}

# Function to disable swap
disable_swap() {
  echo "Disabling swap..."
  swapoff -a
  sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
  if [ $? -eq 0 ]; then
    STATUS_SWAP="Success"
  else
    STATUS_SWAP="Failure"
  fi
}

# Function to configure sysctl parameters
configure_sysctl() {
  echo "Configuring sysctl parameters..."
  cat <<EOF | tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

  cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

  sysctl --system
  if [ $? -eq 0 ]; then
    STATUS_SYSCTL="Success"
  else
    STATUS_SYSCTL="Failure"
  fi
}

# Function to install containerd
install_containerd() {
  echo "Installing containerd..."
  apt update
  apt install -y containerd

  # Configure containerd
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd
  if [ $? -eq 0 ]; then
    STATUS_CONTAINERD="Success"
  else
    STATUS_CONTAINERD="Failure"
  fi
}

# Function to install Kubernetes components
install_kubernetes() {
  echo "Installing Kubernetes components..."
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
  apt update
  apt install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  if [ $? -eq 0 ]; then
    STATUS_KUBERNETES="Success"
  else
    STATUS_KUBERNETES="Failure"
  fi
}

# Function to configure networking with user input
configure_networking() {
  read -p "Enter the IP address and CIDR notation (e.g., 192.168.1.10/24, leave blank to keep current settings): " ip_cidr

  if [[ -n "$ip_cidr" ]]; then
    # Split IP address and subnet mask
    IFS='/' read -r ip_address cidr <<< "$ip_cidr"

    # Set default gateway to the first IP in the provided subnet
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip_address"
    gateway="${i1}.${i2}.${i3}.1"
    read -p "Enter the gateway IP address [default: $gateway]: " user_gateway
    gateway=${user_gateway:-$gateway}

    # Set default DNS servers to 1.1.1.1 and 8.8.8.8
    read -p "Enter the DNS server IP addresses [default: 1.1.1.1,8.8.8.8]: " dns_servers
    dns_servers=${dns_servers:-"1.1.1.1,8.8.8.8"}

    # Configure network interface settings
    echo "Configuring network settings..."
    network_interface=$(ip -o -4 route show to default | awk '{print $5}')

    cat <<EOF | tee /etc/netplan/99-kubernetes.yaml
network:
  version: 2
  ethernets:
    $network_interface:
      dhcp4: no
      addresses:
        - $ip_address/$cidr
      gateway4: $gateway
      nameservers:
        addresses:
          - ${dns_servers//,/ }
EOF

    netplan apply
    if [ $? -eq 0 ]; then
      STATUS_NETWORK="Success"
      echo "Networking configuration updated with static settings."
    else
      STATUS_NETWORK="Failure"
    fi
  else
    echo "Skipping network configuration; DHCP settings remain unchanged."
  fi

  read -p "Enter the hostname for this machine (e.g., k8s-master): " hostname
  read -p "Enter the domain name (optional, press Enter if none): " domain_name

  # Set the full hostname and FQDN
  if [ -n "$domain_name" ]; then
    fqdn="${hostname}.${domain_name}"
  else
    fqdn="${hostname}"
  fi

  echo "Setting hostname to ${hostname} and FQDN to ${fqdn}..."
  hostnamectl set-hostname $fqdn

  # Update /etc/hosts
  if [[ -n "$ip_address" ]]; then
    echo "Updating /etc/hosts..."
    if grep -q "$ip_address" /etc/hosts; then
      echo "IP address already exists in /etc/hosts. Updating entry..."
      sed -i "/$ip_address/c\\$ip_address $fqdn $hostname" /etc/hosts
    else
      echo "$ip_address $fqdn $hostname" | tee -a /etc/hosts
    fi
  fi
}

# Function to initialize Kubernetes master node
initialize_master() {
  read -p "Enter the Pod Network CIDR (e.g., 192.168.0.0/16): " pod_cidr
  echo "Initializing the Kubernetes master node..."
  kubeadm init --pod-network-cidr=$pod_cidr

  # Set up kubeconfig for the current user
  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  # Deploy Calico or another CNI plugin (adjust URL if needed)
  echo "Deploying Calico network plugin..."
  kubectl apply -f https://docs.projectcalico.org/v3.25/manifests/calico.yaml

  if [ $? -eq 0 ]; then
    STATUS_MASTER="Success"
  else
    STATUS_MASTER="Failure"
  fi

  # Display join command for worker nodes
  kubeadm token create --print-join-command
}

# Function to join worker node to master
join_worker() {
  read -p "Enter the Kubernetes master IP address (e.g., 192.168.1.100): " master_ip
  read -p "Enter the join token: " join_token
  read -p "Enter the discovery token CA cert hash: " ca_cert_hash

  echo "Joining the worker node to the Kubernetes cluster..."
  kubeadm join $master_ip:6443 --token $join_token --discovery-token-ca-cert-hash sha256:$ca_cert_hash

  if [ $? -eq 0 ]; then
    STATUS_WORKER="Success"
  else
    STATUS_WORKER="Failure"
  fi
}

# Function to display the summary status
display_summary() {
  echo -e "\n${YELLOW}Summary of Installation:${RESET}"
  echo -e "Prerequisites Installation: ${STATUS_PREREQUISITES}"
  echo -e "Swap Disabled: ${STATUS_SWAP}"
  echo -e "Sysctl Configuration: ${STATUS_SYSCTL}"
  echo -e "Containerd Installation: ${STATUS_CONTAINERD}"
  echo -e "Kubernetes Installation: ${STATUS_KUBERNETES}"
  echo -e "Network Configuration: ${STATUS_NETWORK}"
  echo -e "Master Node Initialization: ${STATUS_MASTER}"
  echo -e "Worker Node Join: ${STATUS_WORKER}"
}

# Main script execution
main() {
  check_root
  install_prerequisites
  disable_swap
  configure_sysctl
  install_containerd
  install_kubernetes

  # Configure networking with user input
  configure_networking

  echo "Select the type of node you want to set up:"
  echo "1. Master Node"
  echo "2. Worker Node"
  read -p "Enter your choice (1 or 2): " node_type

  case $node_type in
    1)
      initialize_master
      ;;
    2)
      join_worker
      ;;
    *)
      echo -e "${RED}Invalid choice. Please run the script again and select 1 or 2.${RESET}"
      exit 1
      ;;
  esac

  # Display installation summary
  display_summary
  echo -e "${GREEN}Kubernetes setup completed!${RESET}"
}

# Run the main function
main
