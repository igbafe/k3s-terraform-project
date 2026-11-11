#!/usr/bin/env bash
# Creates every Secret the Astronomy Shop needs, in the right namespaces.
# Secrets are never stored in Git. Run once, BEFORE the first Argo CD sync:
#
#   bash create-secrets.sh
#
# Safe to re-run: existing Secrets are left untouched (changing database
# passwords after the first start would lock the apps out of PostgreSQL).
# Requires: kubectl (pointing at the EKS cluster) and openssl.
set -euo pipefail

BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

rand() { openssl rand -hex "${1:-16}"; }

exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

# Namespaces normally come from Argo CD; create them if this runs first
for ns in ecommerce-app ecommerce-data observability logging; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
done

# ---- PostgreSQL passwords (shared by three namespaces) ----
if exists ecommerce-data postgres-secrets; then
  echo "postgres-secrets exists - reusing its passwords"
  get() { kubectl -n ecommerce-data get secret postgres-secrets -o "jsonpath={.data.$1}" | base64 -d; }
  PG_ASTRONOMY=$(get POSTGRES_ASTRONOMY_PASSWORD)
  PG_MONITORING=$(get POSTGRES_MONITORING_PASSWORD)
else
  PG_ADMIN=$(rand); PG_ASTRONOMY=$(rand); PG_MONITORING=$(rand)
  kubectl -n ecommerce-data create secret generic postgres-secrets \
    --from-literal=POSTGRES_PASSWORD="$PG_ADMIN" \
    --from-literal=POSTGRES_ASTRONOMY_PASSWORD="$PG_ASTRONOMY" \
    --from-literal=POSTGRES_MONITORING_PASSWORD="$PG_MONITORING"
fi

# ---- ecommerce-app: DB connection strings + flagd-ui session key ----
if exists ecommerce-app app-secrets; then
  echo "app-secrets exists - skipping"
else
  PG_HOST=astronomy-db.ecommerce-data
  kubectl -n ecommerce-app create secret generic app-secrets \
    --from-literal=PRODUCT_CATALOG_DB_CONNECTION_STRING="postgres://astronomy_user:${PG_ASTRONOMY}@${PG_HOST}/astronomy_db?sslmode=disable" \
    --from-literal=ACCOUNTING_DB_CONNECTION_STRING="Host=${PG_HOST};Username=astronomy_user;Password=${PG_ASTRONOMY};Database=astronomy_db" \
    --from-literal=FLAGD_UI_SECRET_KEY_BASE="$(rand 32)"
fi

# ---- observability: collector's Postgres monitoring login + Grafana admin ----
if exists observability collector-secrets; then
  echo "collector-secrets exists - skipping"
else
  kubectl -n observability create secret generic collector-secrets \
    --from-literal=POSTGRES_MONITORING_PASSWORD="$PG_MONITORING"
fi

if exists observability grafana-admin; then
  echo "grafana-admin exists - skipping"
else
  kubectl -n observability create secret generic grafana-admin \
    --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
    --from-literal=admin-password="$(rand)"
fi

# ---- basic auth for jaeger., prometheus. (observability) and logs. (logging) ----
if exists observability basic-auth && exists logging basic-auth; then
  echo "basic-auth exists - skipping"
else
  BASIC_AUTH_PASSWORD=$(rand)
  HTPASSWD="${BASIC_AUTH_USER}:$(openssl passwd -apr1 "$BASIC_AUTH_PASSWORD")"
  for ns in observability logging; do
    kubectl -n "$ns" delete secret basic-auth --ignore-not-found
    kubectl -n "$ns" create secret generic basic-auth \
      --type=nginx.org/htpasswd \
      --from-literal=htpasswd="$HTPASSWD" \
      --from-literal=password="$BASIC_AUTH_PASSWORD"
  done
fi

cat <<'EOF'

Done. Read the generated logins with:
  Grafana    (user / password):
    kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d; echo
    kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
  Jaeger, Prometheus, Logs (user "admin"):
    kubectl -n observability get secret basic-auth -o jsonpath='{.data.password}' | base64 -d; echo
EOF
