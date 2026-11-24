#!/usr/bin/env bash
# Offline regression checks: failures must never be reported as successful runs.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/kubectl" <<'MOCK'
#!/usr/bin/env bash
case "${SCENARIO}" in
  api-error) exit 9 ;;
  empty) exit 0 ;;
esac
case "$*" in
  'get pods'*) printf 'pod-0\npod-1\npod-2\n' ;;
  wait*) exit 0 ;;
  'get configmap'*) echo 'SELECT 1;' ;;
  *'SELECT count() FROM'*) [[ "$SCENARIO" == bad-rows ]] && echo 999 || echo 10000 ;;
  *'SELECT count() > 0'*) [[ "$SCENARIO" == bad-disk ]] && echo 0 || echo 1 ;;
  exec*) cat >/dev/null ;;
  *) exit 8 ;;
esac
MOCK
chmod +x "$tmp/kubectl"
export PATH="$tmp:$PATH"
export NAMESPACE=clickhouse-test
for scenario in api-error empty bad-rows bad-disk good; do
  if SCENARIO="$scenario" bash scripts/validate.sh object-storage >"$tmp/output" 2>&1; then
    [[ "$scenario" == good ]] || { cat "$tmp/output"; echo "FAIL: accepted $scenario"; exit 1; }
  else
    [[ "$scenario" != good ]] || { cat "$tmp/output"; echo 'FAIL: rejected valid run'; exit 1; }
  fi
  echo "PASS: $scenario"
done
