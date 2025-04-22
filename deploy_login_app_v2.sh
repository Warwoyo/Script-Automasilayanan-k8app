#!/usr/bin/env bash
# deploy_login_app.sh — deploy Login Web App + MySQL ke K8s, self‑contained
# Usage:
#   sudo bash deploy_login_app.sh master
#   sudo bash deploy_login_app.sh worker

set -euo pipefail

ROLE="${1:-}"
REPO_URL="https://github.com/Widhi-yahya/kubernetes_installation_docker.git"
BASE_DIR="$HOME/kubernetes_installation_docker"
APP_SUBDIR="$BASE_DIR/k8s-login-app/app"
K8S_DIR="$BASE_DIR/k8s-login-app"
IMAGE_NAME="login-app:latest"

function log {
  echo -e "\e[1;34m[INFO]\e[0m $*"
}

function cleanup() {
  log "Cleanup K8s resources (ignore error kalau belum ada)"
  kubectl delete deployment login-app mysql        --ignore-not-found
  kubectl delete service    login-app mysql        --ignore-not-found
  kubectl delete pvc        mysql-pvc             --ignore-not-found
  kubectl delete pv         mysql-pv              --ignore-not-found
  kubectl delete secret     mysql-secret          --ignore-not-found
}

function build_image() {
  log "Clone repo & build Docker image lokal"
  if [[ ! -d "$BASE_DIR" ]]; then
    git clone --depth=1 "$REPO_URL" "$BASE_DIR"
  else
    log "Repo sudah ada di $BASE_DIR, skip cloning."
  fi

  cd "$APP_SUBDIR"
  docker build -t "$IMAGE_NAME" .
  log "Image $IMAGE_NAME siap di node ini"
}

function prep_storage() {
  log "Siapkan direktori MySQL data"
  sudo mkdir -p /mnt/data
  sudo chmod 777 /mnt/data
}

function deploy_mysql() {
  log "Apply konfigurasi MySQL"
  cd "$K8S_DIR"
  kubectl apply -f k8s/mysql-secret.yaml
  kubectl apply -f k8s/mysql-pv.yaml
  kubectl apply -f k8s/mysql-pvc.yaml
  kubectl apply -f k8s/mysql-service.yaml
  kubectl apply -f k8s/mysql-deployment.yaml

  log "Tunggu MySQL ready (maks 180s)"
  kubectl wait --for=condition=ready pod -l app=mysql --timeout=180s
}

function deploy_web() {
  log "Patch web-deployment supaya pakai image lokal"
  sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' "$K8S_DIR/k8s/web-deployment.yaml" || true

  log "Apply konfigurasi Web App"
  cd "$K8S_DIR"
  kubectl apply -f k8s/web-deployment.yaml
  kubectl apply -f k8s/web-service.yaml

  log "Tunggu Web App pod ready"
  kubectl wait --for=condition=ready pod -l app=login-app --timeout=120s
}

# MAIN
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Harus dijalankan sebagai root (sudo)"
  exit 1
fi

case "$ROLE" in
  worker)
    build_image
    prep_storage
    log ">>> Worker siap (image & storage sudah di‑setup)."
    ;;
  master)
    cleanup
    deploy_mysql
    deploy_web
    log ">>> Master selesai deploy. Akses via NodePort di service/login-app"
    ;;
  *)
    echo "Usage: sudo bash $0 <master|worker>"
    exit 1
    ;;
esac