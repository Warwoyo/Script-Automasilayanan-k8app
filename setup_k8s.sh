#!/usr/bin/env bash
# setup_k8s.sh — Installer Docker + cri-dockerd + Kubernetes + Calico + Metrics + Dashboard
# Usage:
#   sudo bash setup_k8s.sh master   --master-ip xxxxx --pod-cidr 192.168.0.0/16 
#   sudo bash setup_k8s.sh worker   --master-ip xxxxx --token xxxx --hash sha256:xxxx

set -euo pipefail

ROLE="$1"; shift

# default values
POD_CIDR="192.168.0.0/16"
INSTALL_METRICS=false
INSTALL_DASH=false

# parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --master-ip) MASTER_IP="$2"; shift 2;;
    --pod-cidr) POD_CIDR="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --hash) HASH="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "${MASTER_IP:-}" ]]; then
  echo "ERROR: --master-ip wajib diisi"; exit 1
fi

# pastikan root
if [[ $EUID -ne 0 ]]; then
  echo "Jalankan dengan sudo"; exit 1
fi

# 1) common setup: apt, dependencies, Docker, cri-dockerd, k8s repo, sysctl, swap
function setup_common() {
  apt update -y
  apt install -y git wget curl socat gnupg lsb-release apt-transport-https ca-certificates

  # Docker repo & install
  wget -qO- https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/docker.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list
  apt update -y && apt install -y docker-ce

  # cri-dockerd
  VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest \
        |grep tag_name|cut -d\" -f4|sed 's/^v//')
  wget -q "https://github.com/Mirantis/cri-dockerd/releases/download/v${VER}/cri-dockerd-${VER}.amd64.tgz"
  tar xzvf cri-dockerd-${VER}.amd64.tgz
  mv cri-dockerd/cri-dockerd /usr/local/bin/
  wget -q \
    https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service \
    https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
  mv cri-docker.* /etc/systemd/system/
  sed -i 's#/usr/bin/cri-dockerd#/usr/local/bin/cri-dockerd#' /etc/systemd/system/cri-docker.service
  systemctl daemon-reload
  systemctl enable --now cri-docker.service cri-docker.socket

  # Kubernetes repo & install
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list
  apt update -y
  apt install -y kubelet kubeadm kubectl
  apt-mark hold docker-ce kubelet kubeadm kubectl

  # sysctl & modules
  cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  modprobe overlay && modprobe br_netfilter
  cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system

  # disable swap
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
}

# 2) master-only: init + Calico
function init_master() {
  kubeadm init \
    --apiserver-advertise-address="${MASTER_IP}" \
    --cri-socket unix:///var/run/cri-dockerd.sock \
    --pod-network-cidr="${POD_CIDR}"

  mkdir -p $HOME/.kube
  cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  # allow pods di master (fix CoreDNS Pending)
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

  # install Calico
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
}

# 3) worker-only: join
function join_worker() {
  if [[ -z "${TOKEN:-}" || -z "${HASH:-}" ]]; then
    echo "ERROR: --token dan --hash wajib untuk worker"; exit 1
  fi
  kubeadm join "${MASTER_IP}:6443" \
    --cri-socket unix:///var/run/cri-dockerd.sock \
    --token "${TOKEN}" \
    --discovery-token-ca-cert-hash "${HASH}"
}

# 4) optional: metrics-server
function install_metrics() {
  git clone https://github.com/mialeevs/kubernetes_installation_docker.git
  cd kubernetes_installation_docker
  kubectl apply -f metrics-server.yaml
  cd ..
  rm -rf kubernetes_installation_docker
}

# 5) optional: dashboard via Helm
function install_dashboard() {
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x get_helm.sh && ./get_helm.sh && rm get_helm.sh

  helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
  helm repo update

  helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    --create-namespace --namespace kubernetes-dashboard

  kubectl expose deployment kubernetes-dashboard-kong \
    --name k8s-dash-svc --type NodePort --port 443 --target-port 8443 \
    -n kubernetes-dashboard
}

### MAIN
setup_common

if [[ "$ROLE" == "master" ]]; then
  init_master
  install_metrics
  install_dashboard
  echo "=== Master setup selesai ==="
  echo "Gunakan 'kubeadm token create --print-join-command' untuk dapatkan perintah join."
elif [[ "$ROLE" == "worker" ]]; then
  join_worker
  echo "=== Worker berhasil join cluster ==="
else
  echo "Role harus 'master' atau 'worker'"; exit 1
fi

# Generating a Token for Login: Create a service account and generate a token:

# vim k8s-dash.yaml

# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: widhi
#   namespace: kube-system
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRoleBinding
# metadata:
#   name: widhi-admin
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: ClusterRole
#   name: cluster-admin
# subjects:
# - kind: ServiceAccount
#   name: widhi
#   namespace: kube-system

# kubectl apply -f k8s-dash.yaml



NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}') ab -n 10000 -c 100 http://10.96.28.215