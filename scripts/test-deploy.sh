#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CALLS="$tmp/calls" NAMESPACE=clickhouse-offline
cat > "$tmp/kubectl" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  'get namespace'*) [[ "$SCENARIO" != existing ]] || echo namespace/clickhouse-offline ;;
  'get storageclass'*) ;;
  'get crd -o name') [[ "$SCENARIO" != existing-crd ]] || echo customresourcedefinition.apiextensions.k8s.io/clickhouseinstallations.clickhouse.altinity.com ;;
  'get pods'*nodeName*) printf 'node-0\nnode-1\nnode-2\n' ;;
  'get pods'*claimName*) printf 'claim-0\nclaim-1\nclaim-2\n' ;;
  'get pods'*) printf 'pod-0\npod-1\npod-2\n' ;;
  'get pvc'*status.phase*) [[ "$SCENARIO" == unbound ]] && echo Pending || echo Bound ;;
  'get pvc'*) echo "pv-$3" ;;
  *) ;;
esac
exit 0
MOCK
chmod +x "$tmp/kubectl"
export PATH="$tmp:$PATH"
cat > "$tmp/secret.env" <<'ENV'
OBJECT_STORAGE_ENDPOINT=https://example.invalid/bucket/clickhouse-offline/
OBJECT_STORAGE_REGION=us-ashburn-1
OBJECT_STORAGE_ACCESS_KEY=fake-offline-key
OBJECT_STORAGE_SECRET_KEY=fake-offline-secret
ENV
export OBJECT_STORAGE_ENV_FILE="$tmp/secret.env" ALLOW_NEW_RESOURCES=yes
for scenario in existing existing-crd unbound reuse install; do
  : > "$CALLS"
  mode=reuse
  [[ "$scenario" != install && "$scenario" != existing-crd ]] || mode=install
  if SCENARIO="$scenario" OPERATOR_MODE="$mode" bash scripts/deploy.sh apply > "$tmp/output" 2>&1; then
    [[ "$scenario" == reuse || "$scenario" == install ]] || { cat "$tmp/output"; echo "FAIL: accepted $scenario"; exit 1; }
    grep -q 'create secret generic' "$CALLS"
    grep -q 'create -f build/clickhouse-offline/clickhouse.yaml' "$CALLS"
    if [[ "$scenario" == reuse ]]; then
      ! grep -q 'apply.*clickhouse-operator.yaml' "$CALLS"
    else
      grep -q 'apply --server-side.*clickhouse-operator.yaml' "$CALLS"
    fi
  else
    [[ "$scenario" != reuse && "$scenario" != install ]] || { cat "$tmp/output"; exit 1; }
    if [[ "$scenario" != unbound ]]; then
      ! grep -Eq '^(apply|create|delete|patch)' "$CALLS"
    fi
  fi
  echo "PASS: deployment $scenario"
done
if NAMESPACE=clickhouse-demo bash scripts/render.sh >/dev/null 2>&1; then echo 'FAIL: protected namespace accepted'; exit 1; fi
if NAMESPACE=clickhouse-demo bash scripts/validate.sh hot >/dev/null 2>&1; then echo 'FAIL: protected write accepted'; exit 1; fi
echo 'PASS: protected namespace guards'
