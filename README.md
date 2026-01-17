# Kubernetes_Cluster_Setup
The purpose of this project is to quickly launch two or more VM nodes and setup a Kubernetes 
Cluster locally on a Linux or Mac OS, just by running a command line script with a few arguments.
The VMs are launched using the **Multipass**.

**Multipass** is a lightweight, cross-platform utility that quickly launches and manages Ubuntu 
virtual machines (VMs) on Windows, macOS, and Linux. It simplifies local cloud development by 
providing a straightforward command-line interface to spawn fresh Ubuntu environments for development 
and testing. For further details regarding Multipass, please refer to this [URL](https://canonical.com/multipass).

The project consists of three files. One yaml file and two bash scripts. 

### cloud-init.yaml 
This is the init file used by _Multipass_ to do custom intialization of the VMs. This init file
insturcts the multipass to:
1. Disable memory swap: We disable memory swap when setting up a Kubernetes cluster because **kubelet** (the primary 
node agent) requires this to function predictably and reliably. Kubernetes is designed to manage resource limits 
strictly, and swap memory interferes with this mechanism.
2. Ensuring the two essential kernel modules, `overlay` and `br_netfilter`, are loaded automatically every time the system starts.
  * The _overlay_ module enables the **OverlayFS** file system. The OverlayFS is the most common and recommended storage driver 
    for container runtimes like _Docker_ and _Containerd_. By ensuring this module is loaded at boot, you guarantee 
    the container runtime can operate correctly.
  * The _br_netfilter_ module is critical for Kubernetes networking. This module enables ${iptables}$ rules to properly 
    handle network traffic flowing through ${Linux network bridges}$. This module is necessary for the mandatory 
    ${sysctl}$ settings (`net.bridge.bridge-nf-call-iptables`) that allow Kubernetes to function. Without it, service 
    routing will fail.
3. Enable two essential kernel features—${IP}$ forwarding and ${iptables}$ processing over network bridges—that are 
   mandatory for Kubernetes networking to function correctly.
   * `net.ipv4.ip_forward = 1`: This tells the Linux kernel to act as a router, allowing network packets to be 
     forwarded between different interfaces. This is absolutely necessary for traffic to flow from the host network 
     into the Pod network and between Pods on different nodes."
   * `net.bridge.bridge-nf-call-iptables = 1`: This instructs the kernel to process IPv4 traffic passing over a 
     network bridge (like the one created by *CNI plugins*) through the _iptables_ chains. This allows the Kubernetes 
     component *kube-proxy* to use _iptables_ rules to properly route and load balance traffic destined for ClusterIP 
     and _NodePort_ services.
   * `net.bridge.bridge-nf-call-ip6tables = 1`: This is the IPv6 equivalent of the IPv4 setting, ensuring IPv6 traffic 
     is also processed by the firewall rules if IPv6 is used in the cluster.
4. Adds the `ubuntu` user to the VM nodes. The Cluster will be set up on these nodes using this user.

### launch_vm.sh
This script is the main bash script for setting up the cluster. It basically perform three tasks:
1. Launch the VMs by running `multipass launch`. The VMs are initially set up having 2Gb memory, 2 CPU core and 20Gb 
   hard disk which are recommended by the Kubernetes documentation. 
2. Transfers the `setup-k8s-cluster.sh` script to the VM nodes and executes it on each. See below.
3. Sets up the kube-config file on both the master and the worker nodes.
3. Make the worker nodes to join the kubernetes master (_controlplane_) node.
This script can be run as:
```shell
launch_vm.sh --nodes master_node,worker_node0,worker_node1
```
in which the first parameter is the name of the master node and the subsequent parameters are the names of the worker
nodes. You can specify arbitrary number of worker nodes.

There are other optional arguments to the `launch_vm.sh`. Running the `launch_vm.sh --help` will print all the parameters
that can be used with the script.
```bash
> /launch_vm.sh --help
Usage: launch_vm.sh [OPTIONS]

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
  launch_vm.sh --version v1.31  --nodes kmaster,knode0,knode1
  launch_vm.sh --nodes kmaster,knode0,knode1
  launch_vm.sh --nodes kmaster,knode0,knode1 -c 1 -d 1G --mem 500M
  launch_vm.sh -h
```

### setup-k8s-cluster.sh
This script is transfered to the VM nodes and run on each node using _multipass_ command. It perform the following tasks: 
1. Installs *kubelet*,  *kubeadm* and *kubectl*.
2. Installs *containerd*.
3. Initializes the Cluster by running the `kubeadm init` on the master node.
4. Installs the *Calico* on the master node. Calico is a widely used *Container Network Interface (CNI) plugin* for 
   Kubernetes that provides high-performance network connectivity and advanced network policy enforcement between 
   containers and nodes.For further details regarding _Calico_, please go to [Calico](https://www.tigera.io/project-calico/).
This script is not meant to be invoked manually.

## Installing additional tools
After setting up the k8s cluster you can install additional tools on the nodes by invoking:
```bash
./install-additional-tools.sh --nodes kmaster,knode0,knode1
```
At the moment this script installs the following tools:
* etcdctl version v3.5.21
* crictl version v1.31.1
* helm latest version
* kubectx version v0.9.5
* kubens version v0.9.5

When you install another version of kubernetes than the default (v1.34), you need to make sure that the versions of
the additional tools gets updated too.


