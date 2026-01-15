#!/usr/bin/env bash

# Define global variables with default values
K8S_VERSION=""
IS_MASTER=false
DEFAULT_POD_CIDR='10.244.0.0/16'

install-kubes(){
  echo "###########################################"
  echo "Installing kubelet, kubeadm and kubectl"
  echo "###########################################" && sleep 1

  sudo apt-get update
  # apt-transport-https may be a dummy package; if so, you can skip that package
  sudo apt-get install -y apt-transport-https ca-certificates curl gpg

  # If the directory `/etc/apt/keyrings` does not exist, it should be created before the curl command, read the note below.
  # sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/"$K8S_VERSION"/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  # This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | \
       sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt-get update
  sudo apt-get install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl

  # Optional
  sudo systemctl enable --now kubelet

  echo '--------------------'
  kubeadm version
}

install-containerd(){
    echo "###########################################"
    echo "Installing containerd"
    echo "###########################################" && sleep 1

  # sysctl params required by setup, params persist across reboots
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

  # Apply sysctl params without reboot
  sudo sysctl --system

  echo "---------------- "
  echo "IMPORTANT: Check if net.ipv4.ip_forward is set to 1 !"
  sysctl net.ipv4.ip_forward
  echo "---------------- "

  sudo apt update
  sudo apt install -y containerd

  echo "Creating the config file for containerd -> /etc/containerd/config.toml" && sleep 0.5
  sudo mkdir -p /etc/containerd
  containerd config default | sed  's/SystemdCgroup = false/SystemdCgroup = true/' | sed 's/registry.k8s.io\/pause:3.8/registry.k8s.io\/pause:3.10.1/' | sudo tee /etc/containerd/config.toml > /dev/null
  echo "----------------"
  grep -q "SystemdCgroup = true" /etc/containerd/config.toml && echo "SystemdCgroup set to true for containerd" || echo "Failed to set systemd as cgroup driver for containerd!"
  echo "----------------"

  echo "Starting containerd ..." && sleep 0.5
  sudo systemctl restart containerd
  sudo systemctl status containerd
}

install-calico(){
  echo "###########################################"
  echo "Installing Calico network plugin: Explicit CR Creation"
  echo "###########################################"

  POD_CIDR="${DEFAULT_POD_CIDR}"
  OPERATOR_URL="https://docs.tigera.io/archive/v3.25/manifests/tigera-operator.yaml"
  CR_URL="https://docs.tigera.io/archive/v3.25/manifests/custom-resources.yaml"

  # 1. Create CRDs and Operator Deployment (avoids CRD annotation bug)
  echo "Creating Calico Operator CRDs and Deployment..."
  kubectl create -f "$OPERATOR_URL"

  # 2. WAIT for the operator Deployment to be ready
  echo "Waiting for tigera-operator Deployment to be available..."
  # We still need this to ensure the operator pod is running
  kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=300s

  # 3. EXPLICITLY CREATE the default Installation CR
  # This creates the target 'installation.operator.tigera.io/default' resource.
  echo "Explicitly creating the Installation Custom Resource..."
  kubectl create -f "$CR_URL"

  # 4. CRITICAL WAIT: Wait for the Installation Custom Resource to exist
  # This is still necessary to wait for the API server to fully register the CR.
  echo "Waiting for Installation Custom Resource to be fully created..."
  kubectl wait --for=jsonpath='{.metadata.name}'="default" installation.operator.tigera.io/default --timeout=60s

  # 5. PATCH the Installation resource with the correct CIDR
  echo "Patching Installation resource with Pod CIDR: $POD_CIDR"
  kubectl patch installation.operator.tigera.io default --type merge -p "{\"spec\":{\"calicoNetwork\":{\"ipPools\":[{\"cidr\":\"$POD_CIDR\",\"encapsulation\":\"IPIP\",\"natOutgoing\":\"Enabled\",\"nodeSelector\":\"all()\"}]}}}"

  echo "Calico installation fully configured."
}

init-kubeadm(){
  echo "###########################################"
  echo "Initializing kubeadm on the controlplane node"
  echo "###########################################" && sleep 1

  local master_ip=$(hostname -I | awk '{print $1}')

  echo "The Pod network will be set to $DEFAULT_POD_CIDR" && sleep 0.5
  sudo kubeadm init --apiserver-advertise-address "$master_ip" --pod-network-cidr "$DEFAULT_POD_CIDR" --upload-certs

  echo "------" && echo "Copying kube config file to the home directory" && sleep 0.5
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  echo "------" && echo "IMPORTANT: Now make the worker nodes to join the network by applying the 'kubeadm join' instructions above." && sleep 0.5
  echo "Run the following command on each worker nodes as root in order to join the cluster:"
  printf "sudo %s\n" "$(sudo kubeadm token create --print-join-command)" | sudo tee /home/ubuntu/join-command.txt
}

# ----------------------------------------------------------------------
# Description: Parses command-line options -v <version> and -m (master flag).
# ----------------------------------------------------------------------
parse_args() {
    # OPTSTRING: List of valid options.
    # 'v:' means -v requires an argument.
    # 'm' means -m is a simple flag (no argument).
    local OPTSTRING="v:m"

    # Reset OPTIND in case getopts has been used previously in the shell
    OPTIND=1

    # Loop through the arguments using getopts
    while getopts "$OPTSTRING" opt; do
        case "$opt" in
            v)
                K8S_VERSION="$OPTARG"
                ;;
            m)
                IS_MASTER=true
                ;;
            \?)
                # Handle invalid options
                echo "Error: Invalid option -$OPTARG" >&2
                exit 1
                ;;
            :)
                # Handle missing arguments
                echo "Error: Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done

    # Shift positional parameters so $1, $2, etc. refer to non-option arguments
    # (Not strictly needed here as we have no positional arguments, but good practice)
    shift $((OPTIND - 1))
}


# ----------------------------------------------------------------------
# Function: main
# Description: Main execution logic of the script.
# ----------------------------------------------------------------------
main() {
    # 1. Invoke the argument parsing function, passing all command line arguments
    parse_args "$@"

    echo "--- Script Parameters ---"
    echo "Kubernetes Version: ${K8S_VERSION:-'Not Set'}"
    echo "Is Master Node:     $IS_MASTER"

    if [ -z "$K8S_VERSION" ]; then
        echo ""
        echo "ERROR: -v <version> is a required parameter." >&2
        exit 1
    fi

    install-kubes
    install-containerd

    if $IS_MASTER; then
        echo "ACTION: Initializing Kubernetes Master with version $K8S_VERSION..."
        init-kubeadm
        install-calico
    else
        echo "ACTION: Joining Worker Node with required version $K8S_VERSION..."
        echo "IMPORTANT: Run the join command printed on the master node as root"
    fi
}

# Execute the main function, passing all script arguments
main "$@"
