#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source "${DEMO_TARGET_FILE:-/dev/null}"
export NAMESPACE=${NAMESPACE:-clickhouse-clean}
[[ "$NAMESPACE" != clickhouse-demo ]] || { echo 'Refusing write rehearsal in the protected working deployment'; exit 2; }
mkdir -p evidence
log="evidence/rehearsal-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee "$log") 2>&1
trap 'echo "FAIL: rehearsal interrupted at line $LINENO; see $log"' ERR
echo "Rehearsal started: $(date -u +%FT%TZ)"
kubectl config current-context
kubectl get pods,pvc -n "$NAMESPACE" -o wide
nodes=$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
[[ $(printf '%s\n' "$nodes" | sed '/^$/d' | sort -u | wc -l) -eq 3 ]] || { echo 'FAIL: pods must occupy three distinct nodes'; exit 1; }
bash scripts/validate.sh disks
bash scripts/validate.sh smoke
# These modes recreate only the demo.events and demo.object_storage_events tables.
BATCHES=2 ROWS_PER_BATCH=100000 bash scripts/validate.sh hot
bash scripts/validate.sh object-storage
bash scripts/validate.sh summary
echo "PASS: rehearsal completed: $(date -u +%FT%TZ)"
