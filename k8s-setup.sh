#!/bin/bash

# k8s-setup.sh
# This script orchestrates the setup of a 3-node Kubernetes cluster
# by distributing and executing the 'setup.sh' script on each node.

# Exit on any error
set -e
# Echo commands
set -x

# --- 1. Pre-flight Checks ---
echo "==== [1/5] Pre-flight Checks ===="

# Check for required files
if [ ! -f .env ] || [ ! -f setup.sh ]; then
  echo "Error: .env and/or setup.sh file not found."
  echo "Please ensure both files are in the current directory."
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

# --- 2. Define Nodes and Copy Files ---
echo -e "\n==== [2/5] Copying setup files to all nodes ===="

# Define node arrays for easier iteration
ALL_NODES_IP=($NODE00_IP $NODE01_IP $NODE02_IP)
ALL_NODES_USER=($NODE00_USER $NODE01_USER $NODE02_USER)
ALL_NODES_PASS=($NODE00_PASSWORD $NODE01_PASSWORD $NODE02_PASSWORD)
WORKER_NODES_IP=($NODE01_IP $NODE02_IP)
WORKER_NODES_USER=($NODE01_USER $NODE02_USER)
WORKER_NODES_PASS=($NODE01_PASSWORD $NODE02_PASSWORD)

# SSH options to avoid host key checking
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Copy .env and setup.sh to each node
for i in ${!ALL_NODES_IP[@]}; do
  IP=${ALL_NODES_IP[$i]}
  USER=${ALL_NODES_USER[$i]}
  PASS=${ALL_NODES_PASS[$i]}
  HOSTNAME_VAR="NODE0$(($i))_HOSTNAME"
  HOSTNAME=${!HOSTNAME_VAR}

  echo "--- Copying files to ${HOSTNAME} (${IP}) ---"
  sshpass -p "$PASS" scp $SSH_OPTS .env setup.sh ${USER}@${IP}:~/
  echo "✅ Files copied to ${HOSTNAME}."
done

# --- 3. Execute Control-Plane Setup ---
echo -e "\n==== [3/5] Executing setup on Control-Plane node (${NODE00_HOSTNAME}) ===="
# We run this in the foreground to ensure it completes and the join token is available
# before the workers try to join.
sshpass -p "$NODE00_PASSWORD" ssh $SSH_OPTS ${NODE00_USER}@${NODE00_IP} "bash ~/setup.sh"
echo "✅ Control-Plane setup finished."


# --- 4. Execute Worker Node Setup ---
echo -e "\n==== [4/5] Executing setup on Worker nodes in parallel ===="
pids=()
for i in ${!WORKER_NODES_IP[@]};
 do
  IP=${WORKER_NODES_IP[$i]}
  USER=${WORKER_NODES_USER[$i]}
  PASS=${WORKER_NODES_PASS[$i]}
  HOSTNAME_VAR="NODE0$(($i+1))_HOSTNAME"
  HOSTNAME=${!HOSTNAME_VAR}

  echo "--- Starting setup on ${HOSTNAME} (${IP}) in the background ---"
  sshpass -p "$PASS" ssh $SSH_OPTS ${USER}@${IP} "bash ~/setup.sh" &
  pids+=($!)
  echo "✅ Setup initiated for ${HOSTNAME} with PID ${pids[-1]}.
"
done

# Wait for all background worker setups to complete
echo "--- Waiting for worker nodes to finish setup... ---"
for pid in "${pids[@]}"; do
  if wait $pid; then
    echo "Process $pid completed successfully."
  else
    echo "Process $pid failed."
    # Depending on desired behavior, you might want to exit here
    # exit 1
  fi
done
echo "✅ All worker nodes have finished setup."


# --- 5. Final Verification ---
echo -e "\n==== [5/5] Verifying cluster status ===="
echo "--- Waiting 60 seconds for nodes to become Ready..."
sleep 60

sshpass -p "$NODE00_PASSWORD" ssh $SSH_OPTS ${NODE00_USER}@${NODE00_IP} << EOF
  echo "--- Cluster Node Status ---"
  kubectl get nodes -o wide
  echo "-------------------------"
EOF

echo -e "\n🎉 Cluster setup script finished. Please check the output above for the status of your nodes."
