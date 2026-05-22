# Kubernetes Installation Script for Ubuntu 24.04

A Bash script that automates Kubernetes installation on Ubuntu 24.04 LTS, supporting both master (control-plane) and worker node setup.

## Features

- Installs and configures **containerd** with the systemd cgroup driver required by kubeadm
- Adds the official **pkgs.k8s.io** repository with proper GPG key handling
- Installs **kubelet**, **kubeadm**, and **kubectl** (version-pinned via `apt-mark hold`)
- Loads required kernel modules (`overlay`, `br_netfilter`) and applies sysctl settings
- Disables swap permanently (runtime + `/etc/fstab`)
- Optionally configures a **static IP** via netplan
- Sets hostname and updates `/etc/hosts`
- Deploys **Calico CNI** on the master node and prints the worker join command
- Validates all user input (IPs, CIDRs)
- Shows a colour-coded installation summary on completion or failure

## Requirements

| | Master node | Worker node |
|---|---|---|
| OS | Ubuntu 24.04 LTS (64-bit) | Ubuntu 24.04 LTS (64-bit) |
| CPUs | 2 minimum | 1 minimum |
| RAM | 2 GB minimum | 1 GB minimum |
| Privileges | root / sudo | root / sudo |

## Usage

```bash
git clone https://github.com/mehdimahdian/k8s-install.git
cd k8s-install
chmod +x k8sinstaller.sh
sudo bash k8sinstaller.sh
```

Run with `--help` to see version info and requirements without executing anything:

```bash
sudo bash k8sinstaller.sh --help
```

### What the script does (in order)

1. Updates the system and installs prerequisites
2. Disables swap
3. Loads `overlay` and `br_netfilter` kernel modules; applies sysctl settings
4. Installs and configures containerd
5. Installs kubelet, kubeadm, and kubectl from `pkgs.k8s.io`
6. Prompts for optional static IP / netplan configuration
7. Prompts for hostname
8. Asks whether to set up a **master** or **worker** node

### Master node

The script runs `kubeadm init`, sets up `~/.kube/config`, deploys Calico, and prints the `kubeadm join` command you'll need on each worker.

### Worker node

The script prompts for the master IP, join token, and CA cert hash, then runs `kubeadm join`.

## Pinning versions

Edit the variables at the top of `k8sinstaller.sh` before running:

```bash
K8S_VERSION="1.31"        # major.minor — selects the pkgs.k8s.io channel
CALICO_VERSION="v3.29.0"  # full tag from github.com/projectcalico/calico/releases
```

## License

MIT — see [LICENSE](LICENSE).
