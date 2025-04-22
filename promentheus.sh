#!/bin/bash

set -e

echo "Memulai setup monitoring Kubernetes dengan Prometheus dan Grafana..."

# Update dan instal dependensi dasar
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y curl wget git jq software-properties-common

# Instal Kubernetes CLI (kubectl)
echo "Menginstal kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Instal Helm
echo "Menginstal Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Clone repo dan masuk ke direktori
echo "Meng-clone repository..."
git clone https://github.com/Widhi-yahya/kubernetes_installation_docker.git
cd kubernetes_installation_docker

# Terapkan Metrics Server
echo "Menginstal Metrics Server..."
kubectl apply -f metrics-server.yaml

# Verifikasi Metrics Server
echo "Verifikasi Metrics Server..."
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -A

# Setup Prometheus dan Grafana
echo "Menginstal Prometheus dan Grafana menggunakan Helm..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring || true

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin \
  --set grafana.service.type=NodePort

# Verifikasi instalasi Prometheus dan Grafana
echo "Verifikasi instalasi Prometheus dan Grafana..."
kubectl get pods -n monitoring
kubectl get svc -n monitoring

# Dapatkan NodePort untuk Grafana
echo "Mendapatkan NodePort untuk Grafana..."
GRAFANA_PORT=$(kubectl get svc -n monitoring prometheus-grafana -o jsonpath='{.spec.ports[0].nodePort}')
echo "Akses Grafana di http://<your-node-ip>:${GRAFANA_PORT}"
echo "Username: admin"
echo "Password: admin"

# Tambahkan konfigurasi monitoring aplikasi Node.js (opsional)
echo "Contoh konfigurasi ServiceMonitor untuk aplikasi Node.js..."
cat <<EOF > login-app-monitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: login-app-monitor
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: login-app
  endpoints:
  - port: http  # Pastikan ini sesuai dengan nama port service Anda
    interval: 15s
    path: /metrics
  namespaceSelector:
    matchNames:
    - default  # Namespace tempat aplikasi Anda berjalan
EOF

kubectl apply -f login-app-monitor.yaml

# Selesai
echo "Setup selesai. Anda sekarang dapat mengakses Grafana dan memonitor cluster Kubernetes Anda."