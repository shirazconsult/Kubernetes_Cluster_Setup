#!/usr/bin/env bash

set -eu

ETCD_VERSION="v3.5.21"
CRICTL_VERSION="v1.31.1"
HELM_VERSION=""  # Latest
KUBECTX_VERSION="v0.9.5"

VM_NODES=()
ARCH=

install-helm(){
  echo "###########################################"
  echo "Installing HELM"
  echo "###########################################"

  sudo apt-get install curl gpg apt-transport-https --yes
  curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
  sudo apt-get update
  sudo apt-get install helm
}

install-etcdctl(){
  echo "###########################################"
  echo "Installing ETCDCTL"
  echo "###########################################"

  ETCD_VERSION="v3.5.15"
  echo "Downloading etcdctl $ETCD_VERSION..."
  wget -q https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-$ARCH.tar.gz
  tar xzvf etcd-$ETCD_VERSION-linux-$ARCH.tar.gz --strip-components=1 -C /tmp etcd-$ETCD_VERSION-linux-$ARCH/etcdctl
  sudo mv /tmp/etcdctl /usr/local/bin/
  rm -f etcd-$ETCD_VERSION-linux-$ARCH.tar.gz
}

install-crictl(){
  echo "###########################################"
  echo "Installing CRICTL"
  echo "###########################################"

  CRICTL_VERSION="v1.31.1"
  echo "Downloading crictl $CRICTL_VERSION..."
  wget -q https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-$ARCH.tar.gz
  sudo tar zxvf crictl-$CRICTL_VERSION-linux-$ARCH.tar.gz -C /usr/local/bin
  rm -f crictl-$CRICTL_VERSION-linux-$ARCH.tar.gz
}

install-kubectx-and-kubens(){
  echo "###########################################"
  echo "Installing kubectx and kubens"
  echo "###########################################"

  echo "--- Downloading kubectx ${KUBECTX_VERSION}"

  # 2. Download and Install kubectx
  curl -L "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubectx_${KUBECTX_VERSION}_linux_${ARCH}.tar.gz" | tar xz
  sudo mv kubectx /usr/local/bin/
  sudo chmod +x /usr/local/bin/kubectx

  echo "--- Downloading kubens ${KUBECTX_VERSION}"

  # 3. Download and Install kubens
  curl -L "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubens_${KUBECTX_VERSION}_linux_${ARCH}.tar.gz" | tar xz
  sudo mv kubens /usr/local/bin/
  sudo chmod +x /usr/local/bin/kubens

  # 4. Clean up
  rm -f kubectx_${KUBECTX_VERSION}_linux_${ARCH}.tar.gz
  rm -f kubens_${KUBECTX_VERSION}_linux_${ARCH}.tar.gz
}

install-extra-tools() {
  echo "###########################################"
  echo "Installing additional tools"
  echo "###########################################"

  ARCH=$(dpkg --print-architecture)

  install-crictl
  install-etcdctl
  install-helm
  install-kubectx-and-kubens
}

usage(){
  echo "Usage: "
  echo "$0 --nodes <comma separated list of the names of the virtual machines/nodes"
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--nodes)
        IFS=',' read -r -a VM_NODES <<< "$2"
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
  if [[ ${#VM_NODES[@]} -eq 0 ]]; then
    echo "Error: You must provide at least one node name using '--nodes'."
    usage
  fi
}

main() {
  parse_args "$@"

  for node in "${VM_NODES[@]}"; do
    # ROLE: REMOTE WORKER
    # If the script is currently running ON the target VM node
    if [ $(hostname) == "${node}" ]; then
      install-extra-tools
      continue
    fi

    # ROLE: LOCAL ORCHESTRATOR
    # If we got here, we are NOT on the node yet.
    # We need to send the script there and execute it.
    echo "Transfering the install scritp to $node"
    multipass transfer $0 ${node}:/home/ubuntu/

    # We call the script on the remote node with the -n flag
    # This remote execution will trigger the 'IF' block above on the remote side.
    multipass exec "${node}" -- /home/ubuntu/$0 -n ${node}
  done
}

main "$@"