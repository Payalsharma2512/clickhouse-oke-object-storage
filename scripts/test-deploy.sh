#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/repo"
cp -R scripts k8s "$tmp/repo/"
if [[ -n ${ALTINITY_BUNDLE_FILE:-} && $ALTINITY_BUNDLE_FILE != /* ]]; then
  export ALTINITY_BUNDLE_FILE="$PWD/$ALTINITY_BUNDLE_FILE"
fi
cd "$tmp/repo"
if [[ -z ${ALTINITY_BUNDLE_FILE:-} ]]; then
  # Exercise the real integrity check offline using a small release fixture.
  export ALTINITY_BUNDLE_FILE="$tmp/upstream.yaml"
  printf 'kind: Deployment\nmetadata:\n  namespace: kube-system\n' > "$ALTINITY_BUNDLE_FILE"
  digest=$(sha256sum "$ALTINITY_BUNDLE_FILE")
  sed -i "s/^  sha256=.*/  sha256=${digest%% *}/" scripts/render.sh
fi
export CALLS="$tmp/calls" NAMESPACE=clickhouse-offline
cat > "$tmp/kubectl" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  'get namespace'*) [[ "$SCENARIO" != existing ]] || echo namespace/clickhouse-offline ;;
  'get csinodes'*) [[ "$SCENARIO" == missing-csi ]] || printf 'blockvolume.csi.oraclecloud.com\n%.0s' {1..3} ;;
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
printf 'corrupt manifest\n' > "$tmp/corrupt.yaml"
touch "$CALLS"
if ALTINITY_BUNDLE_FILE="$tmp/corrupt.yaml" OPERATOR_MODE=install bash scripts/deploy.sh apply > "$tmp/output" 2>&1; then
  echo 'FAIL: accepted corrupt manifest'; exit 1
fi
grep -q 'failed SHA-256 verification' "$tmp/output"
[[ ! -s "$CALLS" ]]
echo 'PASS: corrupt manifest blocked before cluster access'
for scenario in existing existing-crd missing-csi unbound reuse install; do
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
