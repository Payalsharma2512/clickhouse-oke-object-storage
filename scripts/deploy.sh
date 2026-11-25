#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source "${DEMO_TARGET_FILE:-/dev/null}"
export NAMESPACE=${NAMESPACE:-clickhouse-clean}
MODE=${OPERATOR_MODE:-reuse}
[[ "$MODE" == reuse || "$MODE" == install ]] || { echo 'OPERATOR_MODE must be reuse or install'; exit 2; }
for tool in kubectl oci sed grep tr wc dirname mkdir sleep sort; do command -v "$tool" >/dev/null || { echo "Missing $tool"; exit 1; }; done
[[ "${1:-plan}" == plan || "${1:-plan}" == apply ]] || { echo 'Usage: deploy.sh [plan|apply]'; exit 2; }
out=$(OPERATOR_MODE="$MODE" bash scripts/render.sh)
echo "Target namespace: $NAMESPACE; operator mode: $MODE; manifests: $out"
echo 'Creates 3 ClickHouse pods, 3 new 50 GiB OCI Block Volumes, and new Object Storage data.'
echo 'No cleanup is performed. Existing namespaces are rejected.'
[[ "${1:-plan}" == apply ]] || exit 0
[[ "${ALLOW_NEW_RESOURCES:-}" == yes ]] || { echo 'Review additional resources and set ALLOW_NEW_RESOURCES=yes after approval'; exit 2; }
[[ -f "${OBJECT_STORAGE_ENV_FILE:-}" ]] || { echo 'Set OBJECT_STORAGE_ENV_FILE to the private key=value configuration file'; exit 2; }
for key in OBJECT_STORAGE_ENDPOINT OBJECT_STORAGE_REGION OBJECT_STORAGE_ACCESS_KEY OBJECT_STORAGE_SECRET_KEY; do
  grep -Eq "^${key}=.+" "$OBJECT_STORAGE_ENV_FILE" || { echo "Missing $key"; exit 2; }
done
endpoint=$(sed -n 's/^OBJECT_STORAGE_ENDPOINT=//p' "$OBJECT_STORAGE_ENV_FILE" | tr -d '\r')
[[ "$endpoint" == https://*"/$NAMESPACE/" ]] || { echo 'Endpoint must use HTTPS and end with the new namespace prefix /NAMESPACE/'; exit 2; }
! grep -Eq '<[^>]+>' "$OBJECT_STORAGE_ENV_FILE" || { echo 'Replace all secret-file placeholders'; exit 2; }
# API/auth errors are fatal; --ignore-not-found only tolerates genuine absence.
existing=$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name)
[[ -z "$existing" ]] || { echo 'Refusing to modify an existing namespace; choose a fresh namespace'; exit 1; }
registered=$(kubectl get csinodes -o jsonpath='{range .items[*]}{.spec.drivers[*].name}{"\n"}{end}')
ready_for_bv=$(printf '%s\n' "$registered" | tr -d '\r' | grep -Ec '(^| )blockvolume\.csi\.oraclecloud\.com( |$)' || true)
[[ "$ready_for_bv" -ge 3 ]] || { echo 'Expected OCI Block Volume CSI registration on at least three workers'; exit 1; }
sc=$(kubectl get storageclass "oci-bv-$NAMESPACE" --ignore-not-found -o name)
[[ -z "$sc" ]] || { echo 'StorageClass already exists; refusing to modify it'; exit 1; }
if [[ "$MODE" == reuse ]]; then
  kubectl wait --for=condition=Established crd/clickhouseinstallations.clickhouse.altinity.com --timeout=60s
  kubectl rollout status deployment/clickhouse-operator -n "${OPERATOR_NAMESPACE:-clickhouse-demo}" --timeout=60s
  echo 'Prerequisite: existing operator must already watch this namespace; it will not be modified.'
else
  crds=$(kubectl get crd -o name)
  [[ "$crds" != *clickhouse.altinity.com* ]] || { echo 'Install mode requires a cluster without existing Altinity CRDs/operators'; exit 1; }
fi
kubectl create -f "$out/namespace.yaml"
kubectl create secret generic clickhouse-oci-object-storage -n "$NAMESPACE" --from-env-file="$OBJECT_STORAGE_ENV_FILE"
if [[ "$MODE" == install ]]; then
  kubectl apply --server-side -f "$out/clickhouse-operator.yaml"
  kubectl wait --for=condition=Established crd/clickhouseinstallations.clickhouse.altinity.com --timeout=120s
  kubectl rollout status deployment/clickhouse-operator -n "$NAMESPACE" --timeout=180s
fi
kubectl create -f "$out/storageclasses.yaml"
kubectl create -f "$out/test-workload.yaml"
kubectl create -f "$out/clickhouse.yaml"
deadline=$((SECONDS + 900))
while true; do
  names=$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo -o name)
  count=$(printf '%s\n' "$names" | sed '/^$/d' | wc -l)
  [[ "$count" -eq 3 ]] && break
  (( SECONDS < deadline )) || { echo 'Timed out waiting for three pods; inspect events, no automatic cleanup performed'; exit 1; }
  sleep 5
done
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo --timeout=15m
bash scripts/validate.sh infrastructure
