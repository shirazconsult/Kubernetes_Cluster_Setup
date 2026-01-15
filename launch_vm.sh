#!/usr/bin/env bash

vm_nodes=("$@")
MASTER_NODE="${vm_nodes[0]}" # Capture the master node name
mem='2G'
disk='20G'
cpu=2

[[ $# -eq 0 ]] && echo "Please specify the master node followed by the worker nodes" && exit

for node in "${vm_nodes[@]}"; do
  echo "Setting up ${node} vm..."
  multipass launch --name ${node} --cpus ${cpu} --memory ${mem} --disk ${disk} --cloud-init ./cloud-init.yaml

  # Transfer the necessary script
  multipass transfer ./setup-k8s-cluster.sh ${node}:/home/ubuntu/

  # Execute the setup script based on the role
  if [ "${node}" == "${MASTER_NODE}" ]; then
    echo "Executing Master setup script on ${node}..."
    multipass exec "${node}" -- /home/ubuntu/setup-k8s-cluster.sh -v v1.34 -m
    multipass transfer ${MASTER_NODE}:/home/ubuntu/join-command.txt .
  else
    echo "Executing Worker setup script on ${node}..."
    # The worker script must be resilient and wait for the master's join command
    multipass exec "${node}" -- /home/ubuntu/setup-k8s-cluster.sh -v v1.34
  fi
  echo "---"
done

if [ ! -f ./join-command.txt ]; then
  echo "ERROR: Failed to retrieve join-command.txt from Master. Please run the join command manually on each worker node"
  exit 1
fi
JOIN_COMMAND=$(cat ./join-command.txt)
echo "ACTION: Making worker nodes join the cluster..."
for node in "${vm_nodes[@]}"; do
  if [ "${node}" != "${MASTER_NODE}" ]; then
    echo "Joining worker: ${node}..."
    multipass exec "${node}" -- /bin/bash -c "${JOIN_COMMAND}"
    echo "Worker ${node} join command executed."
  fi
done
# Cleanup the temporary file once all workers are processed
rm ./join-command.txt
echo "--- Cluster setup complete! ---"

