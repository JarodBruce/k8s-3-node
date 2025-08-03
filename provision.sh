#!/bin/bash

# Exit on any error
set -e

# --- 1. Initial Setup and Pre-checks ---
echo "==== [1/6] Initial Setup and Pre-checks ===="

# Check for .env file
if [ ! -f .env ]; then
  echo "Error: .env file not found. Please create it from env.template."
  exit 1
fi

# Load environment variables
source .env
echo "✅ .env file loaded."

# Check for sshpass
if ! command -v sshpass &> /dev/null; then
  echo "Error: sshpass is not installed. Please install it to continue."
  echo "e.g., sudo apt-get update && sudo apt-get install -y sshpass"
  exit 1
fi
echo "✅ sshpass is available."

# Define node arrays for easier iteration
ALL_NODES_IP=($NODE00_IP $NODE01_IP $NODE02_IP)
ALL_NODES_USER=($NODE00_USER $NODE01_USER $NODE02_USER)
ALL_NODES_PASS=($NODE00_PASSWORD $NODE01_PASSWORD $NODE02_PASSWORD)
WORKER_NODES_IP=($NODE01_IP $NODE02_IP)
WORKER_NODES_USER=($NODE01_USER $NODE02_USER)
WORKER_NODES_PASS=($NODE01_PASSWORD $NODE02_PASSWORD)

# SSH options to avoid host key checking
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# --- 2. Common Node Preparation ---
echo -e "\n==== [2/6] Preparing all nodes (this may take a while) ===="

for i in ${!ALL_NODES_IP[@]}; do
  IP=${ALL_NODES_IP[$i]}
  USER=${ALL_NODES_USER[$i]}
  PASS=${ALL_NODES_PASS[$i]}
  HOSTNAME_VAR="NODE0$(($i))_HOSTNAME"
  HOSTNAME=${!HOSTNAME_VAR}

  echo "--- Preparing node ${HOSTNAME} (${IP}) ---"

  sshpass -p "$PASS" ssh $SSH_OPTS ${USER}@${IP} << EOF
    set -e # Exit on error within the SSH session
    
    echo "🔑 Configuring passwordless sudo for user ${USER}..."
    echo "${PASS}" | sudo -S sh -c "echo '${USER} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/010_${USER}-nopasswd && chmod 440 /etc/sudoers.d/010_${USER}-nopasswd"

    echo "🔑 Setting hostname..."
    sudo hostnamectl set-hostname ${HOSTNAME}

    echo "🔧 Disabling swap..."
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab

    echo "🔧 Configuring kernel modules..."
    cat <<EOT | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOT
    sudo modprobe overlay
    sudo modprobe br_netfilter

    echo "🔧 Applying sysctl params for Kubernetes..."
    cat <<EOT | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOT
    sudo sysctl --system

    echo "📦 Installing containerd..."
    sudo apt-get update -qq >/dev/null
    sudo apt-get install -y -qq containerd >/dev/null
    sudo mkdir -p /etc/containerd
    sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd

    echo "📦 Installing Kubernetes components (kubeadm, kubelet, kubectl)..."
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl >/dev/null
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR_VERSION}/deb/Release.key" | sudo gpg --batch --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    sudo apt-get update -qq >/dev/null
    sudo apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
    sudo apt-mark hold kubelet kubeadm kubectl

    echo "📦 Installing sshpass..."
    sudo apt-get install -y -qq sshpass >/dev/null
    
    echo "✅ Node ${HOSTNAME} preparation complete."
EOF
  echo "--- Finished preparation for node ${HOSTNAME} (${IP}) ---"
done

# --- 3. Control-Plane Setup ---
echo -e "\n==== [3/6] Setting up Control-Plane node (${NODE00_HOSTNAME}) ===="
sshpass -p "$NODE00_PASSWORD" ssh $SSH_OPTS ${NODE00_USER}@${NODE00_IP} << EOF
  set -e
  echo "🚀 Initializing Kubernetes cluster with kubeadm..."
  sudo kubeadm init --pod-network-cidr=${POD_CIDR} --apiserver-advertise-address=${NODE00_IP}

  echo "🏠 Configuring kubectl for user ${NODE00_USER}..."
  mkdir -p \$HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
  sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config

  echo "🌐 Applying Calico network add-on..."
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

  echo "🔑 Generating join command..."
  sudo kubeadm token create --print-join-command > /tmp/join-command.txt
  echo "✅ Control-Plane setup complete."
EOF

# --- 4. Worker Node Setup (Deploying listener script) ---
echo -e "\n==== [4/6] Deploying join-listener scripts to worker nodes ===="

# This is the script that will wait for the join command and execute it
WAIT_AND_JOIN_SCRIPT='
#!/bin/bash
set -e
echo "[$(date)] Waiting for /tmp/join-command.txt..."
while [ ! -f /tmp/join-command.txt ]; do
  sleep 5
done
echo "[$(date)] Found join command. Joining cluster..."
sudo bash /tmp/join-command.txt
echo "[$(date)] Successfully joined cluster. Cleaning up..."
rm /tmp/join-command.txt
rm /tmp/wait-and-join.sh
echo "[$(date)] Cleanup complete."
'

for i in ${!WORKER_NODES_IP[@]}; do
  IP=${WORKER_NODES_IP[$i]}
  USER=${WORKER_NODES_USER[$i]}
  PASS=${WORKER_NODES_PASS[$i]}
  HOSTNAME_VAR="NODE0$(($i+1))_HOSTNAME"
  HOSTNAME=${!HOSTNAME_VAR}

  echo "--- Deploying to ${HOSTNAME} (${IP}) ---"
  # Use ssh to write the script content to a file on the remote host
  sshpass -p "$PASS" ssh $SSH_OPTS ${USER}@${IP} "echo '${WAIT_AND_JOIN_SCRIPT}' > /tmp/wait-and-join.sh && chmod +x /tmp/wait-and-join.sh"
  # Execute the script in the background using nohup
  sshpass -p "$PASS" ssh $SSH_OPTS ${USER}@${IP} "nohup /tmp/wait-and-join.sh > /tmp/join-log.txt 2>&1 &"
  echo "✅ Listener deployed to ${HOSTNAME}."
done

# --- 5. Triggering Worker Node Join ---
echo -e "\n==== [5/6] Triggering worker nodes to join the cluster ===="
echo "--- Waiting 10 seconds before sending join command to ensure listeners are ready..."
sleep 10

for i in ${!WORKER_NODES_IP[@]}; do
  IP=${WORKER_NODES_IP[$i]}
  USER=${WORKER_NODES_USER[$i]}
  PASS=${WORKER_NODES_PASS[$i]}
  HOSTNAME_VAR="NODE0$(($i+1))_HOSTNAME"
  HOSTNAME=${!HOSTNAME_VAR}

  echo "--- Sending join command to ${HOSTNAME} (${IP}) ---"
  # Use the control-plane node to scp the join command to the worker nodes
  sshpass -p "$NODE00_PASSWORD" ssh $SSH_OPTS ${NODE00_USER}@${NODE00_IP} << EOF
    set -e
    sshpass -p "${PASS}" scp $SSH_OPTS /tmp/join-command.txt ${USER}@${IP}:/tmp/
EOF
  echo "✅ Join command sent to ${HOSTNAME}."
done

# --- 6. Final Verification ---
echo -e "\n==== [6/6] Verifying cluster status ===="
echo "--- Waiting 60 seconds for nodes to become Ready..."
sleep 60

sshpass -p "$NODE00_PASSWORD" ssh $SSH_OPTS ${NODE00_USER}@${NODE00_IP} << EOF
  echo "--- Cluster Node Status ---"
  kubectl get nodes -o wide
  echo "-------------------------"
EOF

echo -e "\n🎉 Cluster setup script finished. Please check the output above for the status of your nodes."
