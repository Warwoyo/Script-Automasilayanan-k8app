#!/bin/bash

# Pastikan Anda menjalankan skrip ini dengan hak akses root atau sudo
if [ "$EUID" -ne 0 ]; then
  echo "Mohon jalankan sebagai root atau gunakan sudo."
  exit
fi

echo "Memulai instalasi dan konfigurasi Kubernetes Autoscaling..."

# Instalasi dependencies yang diperlukan
echo "Memastikan dependencies terinstal..."
apt update && apt install -y curl apt-transport-https

# Tambahkan repository Kubernetes
echo "Menambahkan repository Kubernetes..."
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

# Update package dan instal kubectl
echo "Menginstal kubectl..."
apt update && apt install -y kubectl

# Memastikan cluster Kubernetes sudah berjalan
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo "Kubernetes cluster tidak terdeteksi. Pastikan cluster sudah diinisialisasi."
    exit 1
fi

# Mengaktifkan Metrics Server (dibutuhkan untuk Horizontal Pod Autoscaler)
echo "Menginstal Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Tunggu Metrics Server untuk siap
echo "Menunggu Metrics Server siap..."
kubectl wait --for=condition=Available --timeout=300s deployment/metrics-server -n kube-system

# Contoh Deployment aplikasi
echo "Membuat deployment contoh (nginx)..."
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --target-port=80

# Mengatur Horizontal Pod Autoscaler
echo "Mengatur Horizontal Pod Autoscaler..."
kubectl autoscale deployment nginx --cpu-percent=50 --min=1 --max=10

echo "Selesai! Deployment 'nginx' telah di-autoscale. Anda dapat memeriksa status dengan perintah berikut:"
echo "kubectl get hpa"