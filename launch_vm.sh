#!/usr/bin/env bash

set -eu

VM_NODES=
MEM='2G'
DISK='20G'
CPU=2
K8S_VERSION="v1.34"
MASTER_NODE=  # will be set later

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

This script automates the setup of a Kubernetes cluster on Multipass nodes.

Options:
  -v, --version <ver>    Specify Kubernetes version (e.g. v1.31). Default is v1.34.
  -n, --nodes <list>     Specify the name of the nodes as a comma separated list. The first one will be the "master" kubernetes node.
  -m, --mem              Specify the desired memory of each node (e.g. 1G). Default is 2G
  -c, --cpu              Specify the number of cpu cores for each node. Default is 2.
  -d, --disk             Specify the size of the hard disk for each node (e.g. 5G). Default is 20G.
  -h, --help             Display this help message and exit

All the arguments except the --nodes one are optional.
Examples:
  $(basename "$0") --version v1.31  --nodes kmaster,knode0,knode1
  $(basename "$0") --nodes kmaster,knode0,knode1
  $(basename "$0") --nodes kmaster,knode0,knode1 -c 1 -d 1G --mem 500M
  $(basename "$0") -h

EOF
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--version)
        K8S_VERSION="$2"
        shift 2
        ;;
      -n|--nodes)
        IFS=',' read -r -a VM_NODES <<< "$2"
        shift 2
        ;;
      -m|--mem)
        MEM="$2"
        shift 2
        ;;
      -c|--cpu)
        CPU="$2"
        shift 2
        ;;
      -d|--disk)
        DISK="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Invalid argument: $1"
        usage
        ;;
    esac
  done

  # Check if the mandatory pararemters are set
  if [[ -z ${VM_NODES+x} || ${#VM_NODES[@]} -eq 0 ]]; then
    echo "Error: You must provide at least one node name using '--nodes'."
    usage
  fi
}

transfer_kubeconfig_to_workers(){
    local worker_node=$1

    # transfer the admin.conf to local machine first
    multipass transfer ${MASTER_NODE}:/home/ubuntu/.kube/config admin.conf

    echo "Transfering and setting up the ~/.kube/config on $worker_node"
    multipass exec $worker_node -- bash -c "mkdir -p /home/ubuntu/.kube"
    multipass transfer ./admin.conf ${worker_node}:/home/ubuntu/.kube/config
    multipass exec $worker_node -- bash -c "sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config"
}

setup_nodes(){
  for node in "${VM_NODES[@]}"; do
    multipass launch --name ${node} --cpus ${CPU} --memory ${MEM} --disk ${DISK} --cloud-init ./cloud-init.yaml

    # Transfer the setup-script script to the node
    multipass transfer ./setup-k8s-cluster.sh ${node}:/home/ubuntu/

    # Execute the setup script based on the role
    if [ "${node}" == "${MASTER_NODE}" ]; then
      echo "Executing Master setup script on ${node}..."
      multipass exec "${node}" -- /home/ubuntu/setup-k8s-cluster.sh -v "${K8S_VERSION}" -m
      multipass transfer ${MASTER_NODE}:/home/ubuntu/join-command.txt .
    else
      echo "Executing Worker setup script on ${node}..."
      # The worker script must be resilient and wait for the master's join command
      multipass exec "${node}" -- /home/ubuntu/setup-k8s-cluster.sh -v "${K8S_VERSION}"
      transfer_kubeconfig_to_workers "${node}"
    fi

    multipass exec ${node} -- bash -c "echo \"alias k='kubectl'\" >> ~/.bash_aliases"
    echo "---"
  done
}

join_workers(){
  if [ ! -f ./join-command.txt ]; then
    echo "ERROR: Failed to retrieve join-command.txt from Master. Please run the join command manually on each worker node"
    exit 1
  fi
  JOIN_COMMAND=$(cat ./join-command.txt)
  echo "ACTION: Making worker nodes join the cluster..."
  for node in "${VM_NODES[@]}"; do
    if [ "${node}" != "${MASTER_NODE}" ]; then
      echo "Joining worker: ${node}..."
      multipass exec "${node}" -- /bin/bash -c "${JOIN_COMMAND}"
      echo "Worker ${node} join command executed."
    fi
  done
  # Cleanup the temporary file once all workers are processed
  rm ./join-command.txt
  echo "--- Cluster setup complete! ---"
}

main() {
  parse_args "$@"

  MASTER_NODE="${VM_NODES[0]}" # Capture the master node name
  setup_nodes
  join_workers
}

main "$@"