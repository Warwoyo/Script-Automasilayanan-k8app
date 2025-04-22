#!/usr/bin/env bash
# deploy_load_balancer.sh - Script untuk setup Load Balancing Login Web App
# Usage:
#   sudo bash deploy_load_balancer.sh

set -euo pipefail

REPO_URL="https://github.com/Widhi-yahya/kubernetes_installation_docker.git"
BASE_DIR="$HOME/kubernetes_installation_docker"
K8S_DIR="$BASE_DIR/k8s-login-app"

function log {
  echo -e "\e[1;34m[INFO]\e[0m $*"
}

function setup_ingress_controller() {
  log "Membuat namespace untuk ingress-nginx"
  kubectl create namespace ingress-nginx || true

  log "Menambahkan helm repository untuk ingress-nginx"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update

  log "Menginstal ingress-nginx dengan Helm"
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30081
}

function deploy_web_deployment() {
  log "Deploy konfigurasi web deployment untuk load balancing"
  cat > "$K8S_DIR/k8s/web-deployment-lb.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: login-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: login-app
  template:
    metadata:
      labels:
        app: login-app
    spec:
      containers:
      - name: login-app
        image: login-app:latest
        imagePullPolicy: Never
        ports:
        - containerPort: 3000
        env:
        - name: DB_HOST
          value: mysql
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_USER
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_PASSWORD
        - name: DB_NAME
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_DATABASE
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
EOF
  kubectl apply -f "$K8S_DIR/k8s/web-deployment-lb.yaml"
}

function deploy_ingress_resource() {
  log "Deploy konfigurasi ingress untuk aplikasi"
  cat > "$K8S_DIR/k8s/login-app-ingress.yaml" << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: login-app-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: login-app
            port:
              number: 80
EOF
  kubectl apply -f "$K8S_DIR/k8s/login-app-ingress.yaml"
}

function deploy_web_service() {
  log "Deploy konfigurasi service untuk web app"
  cat > "$K8S_DIR/k8s/web-service-lb.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: login-app
spec:
  selector:
    app: login-app
  ports:
  - port: 80
    targetPort: 3000
EOF
  kubectl apply -f "$K8S_DIR/k8s/web-service-lb.yaml"
}

function test_load_balancer() {
  log "Menguji load balancer"
  for i in {1..10}; do
    curl -s http://<your-node-ip>:30081/server-info | jq .
    sleep 1
  done
}

function add_server_identification() {
  log "Menambahkan server info ke server.js"
  cat > "$K8S_DIR/app/server-patch.js" << 'EOF'
const os = require('os');
const serverInfo = {
  hostname: os.hostname(),
  podName: process.env.POD_NAME || 'unknown',
  nodeName: process.env.NODE_NAME || 'unknown'
};

app.get('/server-info', (req, res) => {
  res.json(serverInfo);
});

app.use((req, res, next) => {
  res.setHeader('X-Served-By', serverInfo.podName);
  next();
});
EOF

cat "$K8S_DIR/app/server-patch.js" >> "$K8S_DIR/app/server.js"

}


function rebuild_docker_image_and_apply(){
    log "Build ulang image login-app"
    cd "$K8S_DIR/app"
    cat server-patch.js >> server.js
    docker build -t login-app:latest .
    kubectl apply -f k8s/web-deployment-lb.yaml
    # docker save login-app:latest > login-app.tar

# Jika butuh, transfer ke node worker
# scp login-app.tar user@worker-node:/home/user/
# ssh user@worker-node 'docker load < /home/user/login-app.tar'

}

# MAIN
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Harus dijalankan sebagai root (sudo)"
  exit 1
fi

log "=== Mulai setup load balancing untuk Login Web App ==="

deploy_web_deployment
add_server_identification
rebuild_docker_image_and_apply
deploy_ingress_resource
deploy_web_service

kubectl annotate ingress login-app-ingress nginx.ingress.kubernetes.io/affinity="cookie"
kubectl annotate ingress login-app-ingress nginx.ingress.kubernetes.io/session-cookie-name="SERVERID"

log "=== Setup selesai. Silakan akses aplikasi melalui Ingress ==="1