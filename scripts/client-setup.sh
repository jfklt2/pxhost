#!/bin/bash
set -e

# Interactive setup script for Flux GitOps
# curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.2+k3s1 INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --tls-san X.X.X.X --disable traefik --flannel-backend=wireguard-native" sh -

read -p "Enter root domain: (e.g smthn.com)" ROOT_DOMAIN
read -p "Enter OTEL bearer token: " OTEL_TOKEN
read -p "Enter admin password (for Grafana & ClickHouse): " ADMIN_PASSWORD
read -p "Enter Loki memory limit in GB (e.g. 8): " LOKI_MEMORY_GB
read -p "Enter ClickHouse memory limit in GB (e.g. 24): " CLICKHOUSE_MEMORY_GB
read -p "Enter backup S3 endpoint URL (optional, leave empty to disable backups): " CLICKHOUSE_BACKUP_S3_ENDPOINT
read -p "Enter backup S3 bucket (default: bkp, leave empty to use default if endpoint is set): " CLICKHOUSE_BACKUP_S3_BUCKET
read -p "Enter backup S3 region (default: auto): " CLICKHOUSE_BACKUP_S3_REGION
read -p "Enter backup S3 force path style (default: true): " CLICKHOUSE_BACKUP_S3_FORCE_PATH_STYLE
read -p "Enter backup S3 access key (optional): " CLICKHOUSE_BACKUP_S3_ACCESS_KEY
read -p "Enter backup S3 secret key (optional): " CLICKHOUSE_BACKUP_S3_SECRET_KEY

if [[ -z "$ROOT_DOMAIN" || -z "$OTEL_TOKEN" || -z "$ADMIN_PASSWORD" ]]; then
  echo "Error: Domain, OTEL token, and admin password are required"
  exit 1
fi

if [[ -z "$CLICKHOUSE_BACKUP_S3_BUCKET" ]]; then
  CLICKHOUSE_BACKUP_S3_BUCKET="bkp"
fi

if [[ -z "$CLICKHOUSE_BACKUP_S3_REGION" ]]; then
  CLICKHOUSE_BACKUP_S3_REGION="auto"
fi

if [[ -z "$CLICKHOUSE_BACKUP_S3_FORCE_PATH_STYLE" ]]; then
  CLICKHOUSE_BACKUP_S3_FORCE_PATH_STYLE="true"
fi

if ! [[ "$LOKI_MEMORY_GB" =~ ^[0-9]+$ ]] || [ "$LOKI_MEMORY_GB" -lt 1 ]; then
  echo "Error: Loki memory must be a number >= 1 GB"
  exit 1
fi

if ! [[ "$CLICKHOUSE_MEMORY_GB" =~ ^[0-9]+$ ]] || [ "$CLICKHOUSE_MEMORY_GB" -lt 1 ]; then
  echo "Error: ClickHouse memory must be a number >= 1 GB"
  exit 1
fi

# Calculate Loki resource allocations
LOKI_MEMORY_LIMIT=$((LOKI_MEMORY_GB * 1024))
LOKI_MEMORY_REQUEST=2048
LOKI_GOMEMLIMIT=$((LOKI_MEMORY_LIMIT * 94 / 100))
LOKI_CHUNKS_CACHE_MB=$((LOKI_MEMORY_LIMIT * 25 / 100))
LOKI_RESULTS_CACHE_MB=$((LOKI_MEMORY_LIMIT * 12 / 100))

# ClickHouse memory limit (in Gi)
CLICKHOUSE_MEMORY_LIMIT=${CLICKHOUSE_MEMORY_GB}

echo ">>> Resource allocations:"
echo "    Loki:       ${LOKI_MEMORY_LIMIT}Mi limit / ${LOKI_MEMORY_REQUEST}Mi request"
echo "    ClickHouse: ${CLICKHOUSE_MEMORY_LIMIT}Gi limit / 2Gi request"
echo "    VM:         2Gi limit / 512Mi request (fixed)"
echo "    OTEL:       512Mi (fixed)"
echo "    Grafana:    1Gi (fixed)"

echo ">>> Installing Flux components..."
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml

echo ">>> Waiting for Flux controllers..."
kubectl wait --for=condition=available --timeout=120s \
  deployment/source-controller -n flux-system
kubectl wait --for=condition=available --timeout=120s \
  deployment/kustomize-controller -n flux-system

echo ">>> Installing Gateway API CRDs (experimental for GRPCRoute)..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml

echo ">>> Creating client-specific settings..."
kubectl create configmap client-settings \
  --namespace flux-system \
  --from-literal=ROOT_DOMAIN=${ROOT_DOMAIN} \
  --from-literal=OTEL_TOKEN=${OTEL_TOKEN} \
  --from-literal=ADMIN_PASSWORD=${ADMIN_PASSWORD} \
  --from-literal=LOKI_MEMORY_LIMIT=${LOKI_MEMORY_LIMIT} \
  --from-literal=LOKI_MEMORY_REQUEST=${LOKI_MEMORY_REQUEST} \
  --from-literal=LOKI_GOMEMLIMIT=${LOKI_GOMEMLIMIT} \
  --from-literal=LOKI_CHUNKS_CACHE_MB=${LOKI_CHUNKS_CACHE_MB} \
  --from-literal=LOKI_RESULTS_CACHE_MB=${LOKI_RESULTS_CACHE_MB} \
  --from-literal=CLICKHOUSE_MEMORY_LIMIT=${CLICKHOUSE_MEMORY_LIMIT} \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Creating node exporter targets..."
read -p "Path to node exporter targets JSON file (leave empty for none): " NODE_EXPORTER_FILE
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap clickhouse-backup-config \
  --namespace monitoring \
  --from-literal=endpoint="${CLICKHOUSE_BACKUP_S3_ENDPOINT}" \
  --from-literal=bucket="${CLICKHOUSE_BACKUP_S3_BUCKET}" \
  --from-literal=region="${CLICKHOUSE_BACKUP_S3_REGION}" \
  --from-literal=force-path-style="${CLICKHOUSE_BACKUP_S3_FORCE_PATH_STYLE}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic clickhouse-backup-s3 \
  --namespace monitoring \
  --from-literal=access-key="${CLICKHOUSE_BACKUP_S3_ACCESS_KEY}" \
  --from-literal=secret-key="${CLICKHOUSE_BACKUP_S3_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
if [[ -n "$NODE_EXPORTER_FILE" ]]; then
  if [[ ! -f "$NODE_EXPORTER_FILE" ]]; then
    echo "Error: File not found: $NODE_EXPORTER_FILE"
    exit 1
  fi
  kubectl create configmap node-exporter-targets \
    --namespace monitoring \
    --from-file=targets.json="${NODE_EXPORTER_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    Node exporter targets loaded from ${NODE_EXPORTER_FILE}"
else
  echo '[]' > /tmp/empty-targets.json
  kubectl create configmap node-exporter-targets \
    --namespace monitoring \
    --from-file=targets.json=/tmp/empty-targets.json \
    --dry-run=client -o yaml | kubectl apply -f -
  rm /tmp/empty-targets.json
  echo "    Empty targets (can be updated later with kubectl)"
fi

echo ">>> Connecting to GitHub repo..."
REPO_RAW="https://raw.githubusercontent.com/jfklt2/pxhost/main"
kubectl apply -f "${REPO_RAW}/flux-system/git-repository.yaml"
kubectl apply -f "${REPO_RAW}/flux-system/kustomization.yaml"

echo ">>> Done! Flux will sync in ~1 minute."
echo ">>> Monitor with: flux get kustomizations --watch"
echo ">>> Or: kubectl get kustomization -n flux-system -w"
