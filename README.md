# Kubernetes Installation Script for Ubuntu 24.04

This repository contains a Bash script that automates the installation of Kubernetes on Ubuntu 24.04. The script supports setting up both master and worker nodes with customizable options, including specifying the pod network CIDR.

## Features

- Automated setup for Kubernetes master and worker nodes.
- Installs prerequisites, configures container runtime, and sets up Kubernetes components.
- Disables swap and configures necessary kernel parameters.
- Prompts the user to enter the pod network CIDR during master node setup.
- Automatically installs the Calico network plugin for Kubernetes.
- Provides a `kubeadm join` command for adding worker nodes.

## Requirements

- Ubuntu 24.04 LTS (64-bit) on all nodes.
- User with `sudo` privileges.
- Minimum hardware requirements:
  - Master Node: 2 CPUs, 2GB RAM.
  - Worker Node: 1 CPU, 1GB RAM.

## Usage

### Clone the Repository & Run

```bash
git clone https://github.com/mehdimahdian/k8s-install.git
cd k8s-install
chmod +x k8sinstaller.sh
sudo bash k8sinstaller.sh
