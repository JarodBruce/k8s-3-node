#!/bin/bash

# Exit on error
set -e

# Load environment variables
if [ -f .env ]; then
  export $(cat .env | sed 's/#.*//g' | xargs)
fi

# Get hostname
HOSTNAME=$(hostname)

# Common setup for all nodes
setup_common() {
  echo "Running common setup..."

  # Disable swap
  echo "Disabling swap..."
  sudo swapoff -a
  sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

  # Clean up any old repository files to ensure idempotency before running apt-get update
  if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
    echo "Removing old Kubernetes repository file..."
    sudo rm /etc/apt/sources.list.d/kubernetes.list
  fi

  # 1. Install required packages
  sudo apt-get update
  # Install sshpass for password-based scp automation
  sudo apt-get install -y apt-transport-https ca-certificates curl sshpass ntp

  echo "Waiting for NTP to synchronize..."
  for i in {1..24}; do # Retry for up to 2 minutes (24 * 5s)
    if timedatectl status | grep -q 'NTP synchronized: yes'; then
      echo "NTP synchronized successfully."
      break
    fi
    echo "Waiting for NTP sync... (Attempt $i/24)"
    sleep 5
  done
  # タイムアウトした場合でも、現在のステータスを表示して続行する
  if ! timedatectl status | grep -q 'NTP synchronized: yes'; then
    echo "Warning: NTP sync may not have completed within 2 minutes. Showing status and continuing..."
    timedatectl status
  fi

  # 2. Install containerd
  sudo mkdir -p /etc/apt/keyrings
  # Clean up old docker gpg key to ensure idempotency
  sudo rm -f /etc/apt/keyrings/docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y containerd.io

  # 3. Configure containerd
  sudo mkdir -p /etc/containerd
  sudo containerd config default | sudo tee /etc/containerd/config.toml
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd

  # 4. Install Kubernetes components
  echo "Installing Kubernetes components..."
  sudo apt-get install -y apt-transport-https ca-certificates curl gpg

  # Add Kubernetes APT repository
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR_VERSION}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt-get update
  # Install the latest available versions for the specified minor version
  sudo apt-get install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl

  # 5. Enable kernel modules and sysctl
  sudo modprobe overlay
  sudo modprobe br_netfilter
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
  sudo sysctl --system
}

# Control Plane setup
setup_control_plane() {
  echo "Setting up Control Plane..."

  # 1. Initialize Kubernetes cluster
  sudo kubeadm init --pod-network-cidr=$POD_CIDR --apiserver-advertise-address=$NODE00_IP --cri-socket=unix:///var/run/containerd/containerd.sock

  # 2. Configure kubectl for the user
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  # 3. Install Calico CNI
  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

  # 4. Generate join command
  kubeadm token create --print-join-command | tee /tmp/kubeadm_join_command.sh
}

# Worker Node setup
setup_worker_node() {
  echo "Setting up Worker Node..."

  # 1. Copy join command from control plane with retry logic
  echo "Attempting to copy join command from control plane node (will retry for up to 5 minutes)..."

  JOIN_COMMAND_COPIED=false
  for i in {1..30}; do # Retry 30 times (30 * 10s = 300s = 5 minutes)
    # Try to copy the file, redirecting output to null to avoid clutter
    if sshpass -p "$NODE00_PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${NODE00_IP}:/tmp/kubeadm_join_command.sh /tmp/kubeadm_join_command.sh &> /dev/null; then
      echo "Join command copied successfully."
      JOIN_COMMAND_COPIED=true
      break
    fi
    echo "Failed to copy join command. Retrying in 10 seconds... (Attempt $i/30)"
    sleep 10
  done

  if [ "$JOIN_COMMAND_COPIED" = false ]; then
    echo "Error: Could not copy join command from control plane after 5 minutes. Exiting."
    exit 1
  fi

  # 2. Join the cluster
  sudo bash -c "$(cat /tmp/kubeadm_join_command.sh) --v=5"
}

# Main logic
if [ "$HOSTNAME" == "$NODE00_HOSTNAME" ]; then
  setup_common
  setup_control_plane
elif [ "$HOSTNAME" == "$NODE01_HOSTNAME" ] || [ "$HOSTNAME" == "$NODE02_HOSTNAME" ]; then
  setup_common
  setup_worker_node
else
  echo "Hostname not recognized. Exiting."
  exit 1
fi

echo "Setup complete for $HOSTNAME."