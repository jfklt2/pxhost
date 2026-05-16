# Observability Stack (Flux GitOps)

Flux-managed observability stack for proxy infrastructure. Deploys onto a single-node k3s cluster.

## What's included

**Infrastructure layer** (deployed first):
- Traefik (ingress + Gateway API)
- cert-manager (Let's Encrypt TLS)
- Altinity ClickHouse Operator

**Apps layer** (depends on infrastructure):
- ClickHouse (analytics DB + Flyway migrations)
- Grafana (dashboards)
- Loki (log aggregation)
- VictoriaMetrics (metrics)
- OpenTelemetry Collector (trace/log ingestion)

## Prerequisites

- A server with a public IP and a domain pointed at it (wildcard DNS or individual records for `grafana.`, `ch.`, `otel.` subdomains)
- OTEL bearer token (for authenticating proxy-agent telemetry)

## Fresh install

### 1. Install k3s

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.35.1+k3s1 \
  INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --tls-san <SERVER_IP> --disable traefik --flannel-backend=wireguard-native" \
  sh -
```

Traefik is disabled because we deploy our own version via Helm.

### 2. Run the setup script

```bash
curl -sfLO https://raw.githubusercontent.com/jfklt2/pxhost/main/scripts/client-setup.sh
bash client-setup.sh
```

The script will prompt for:

| Parameter | Description |
|-----------|-------------|
| `ROOT_DOMAIN` | Base domain |
| `OTEL_TOKEN` | Bearer token for OTEL collector auth |
| `ADMIN_PASSWORD` | Shared password for Grafana & ClickHouse |
| `LOKI_MEMORY_GB` | Loki memory limit in GB |
| `CLICKHOUSE_MEMORY_GB` | ClickHouse memory limit in GB |
| `CLICKHOUSE_BACKUP_S3_ENDPOINT` | Optional S3 endpoint for ClickHouse backups |
| `CLICKHOUSE_BACKUP_S3_BUCKET` | Optional S3 bucket for ClickHouse backups (default: `bkp`) |
| `CLICKHOUSE_BACKUP_S3_REGION` | Optional S3 region (default: `auto`) |
| `CLICKHOUSE_BACKUP_S3_FORCE_PATH_STYLE` | Optional S3 path style toggle (default: `true`) |
| `CLICKHOUSE_BACKUP_S3_ACCESS_KEY` | Optional S3 access key |
| `CLICKHOUSE_BACKUP_S3_SECRET_KEY` | Optional S3 secret key |
| `CH_MIGRATION_TAG` | ClickHouse migration image version (default: `v6.1`) |
| Node exporter targets | Path to a JSON file with scrape targets (optional) |

The script installs Flux, Gateway API CRDs, creates a `client-settings` ConfigMap with these values, and points Flux at this repo. Everything else reconciles automatically.

### ClickHouse backups

Flux deploys a `clickhouse-backup-cron` job in the `monitoring` namespace. If backup S3 settings are configured, it uploads backups and status files under:

```text
clickhouse-backups/<ROOT_DOMAIN>/
```

If the S3 endpoint or credentials are left empty, the backup job exits with a `skipped` status and does not affect existing clusters. This keeps older production clients backward-compatible until you explicitly opt them into backups.

### Node exporter targets

The setup script optionally accepts a JSON file with node exporter scrape targets (Prometheus `file_sd_configs` format):

```json
[
  {"targets": ["host1.example.net:9100"], "labels": {"instance": "host1"}},
  {"targets": ["host2.example.net:9100"], "labels": {"instance": "host2"}}
]
```

To update targets on an existing cluster:

```bash
kubectl create configmap node-exporter-targets \
  --namespace monitoring \
  --from-file=targets.json=targets.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/otel-collector -n monitoring
```

### Tailscale DNS for node exporters

If scrape targets use Tailscale hostnames (e.g. `host.tail02dd2b.ts.net`), k3s CoreDNS won't resolve them by default. Add a custom CoreDNS server block to forward your Tailnet domain to Tailscale's MagicDNS resolver:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  tailscale.server: |
    <TAILNET_DOMAIN>:53 {
      forward . 100.100.100.100
    }
EOF
```

Replace `<TAILNET_DOMAIN>` with your Tailnet domain (e.g. `tail02dd2b.ts.net`). CoreDNS auto-reloads within ~30 seconds.
