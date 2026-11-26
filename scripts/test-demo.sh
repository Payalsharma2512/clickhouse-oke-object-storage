#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CALLS="$tmp/calls"
cat > "$tmp/kubectl" <<'MOCK'
#!/usr/bin/env bash
shift # request timeout
echo "$*" >> "$CALLS"
if [[ "$SCENARIO" == unreachable ]]; then echo 'private-endpoint-secret-marker' >&2; exit 1; fi
case "$*" in
  'get --raw=/version') echo '{}' ;;
  'get nodes'*)
    jq -n --arg s "$SCENARIO" '{items:[range(0;3)|{metadata:{name:("node-"+tostring)},status:{conditions:[{type:"Ready",status:(if $s=="bad-node" then "False" else "True" end)}]}}]}' ;;
  'get pods'*)
    jq -n --arg s "$SCENARIO" '{items:[range(0;3)|{metadata:{name:("pod-"+tostring)},spec:{nodeName:(if $s=="same-node" then "node-0" else "node-"+tostring end),volumes:[{name:"hot-data",persistentVolumeClaim:{claimName:("claim-"+tostring)}}]},status:{phase:"Running",conditions:[{type:"Ready",status:(if $s=="bad-pod" then "False" else "True" end)}]}}]}' ;;
  'get pvc'*)
    jq -n --arg s "$SCENARIO" '{items:[range(0;3)|{metadata:{name:("claim-"+tostring)},spec:{volumeName:("pv-"+tostring)},status:{phase:(if $s=="unbound" then "Pending" else "Bound" end),capacity:{storage:(if $s=="bad-size" then "100Gi" else "50Gi" end)}}}]}' ;;
  'get pv '*)
    jq -n --arg s "$SCENARIO" '{items:[range(0;3)|{spec:{csi:{driver:(if $s=="bad-driver" then "other.driver" else "blockvolume.csi.oraclecloud.com" end)},capacity:{storage:"50Gi"}},status:{phase:"Bound"}}]}' ;;
  exec*)
    [[ "$SCENARIO" != query-error ]] || exit 7
    if [[ "$SCENARIO" == bad-layout ]]; then printf '2\t2\t1\n'; else printf '3\t3\t1\n'; fi
    [[ "$SCENARIO" != bad-count ]] && echo 200000 || echo 199999
    [[ "$SCENARIO" != bad-read ]] && echo 200000 || echo 199999
    [[ "$SCENARIO" != bad-placement ]] && echo 1 || echo 0
    printf '10000\n10000\n1\n' ;;
  *) exit 8 ;;
esac
MOCK
chmod +x "$tmp/kubectl"
export PATH="$tmp:$PATH"
for scenario in good unreachable bad-node same-node bad-pod unbound bad-size bad-driver query-error bad-layout bad-count bad-read bad-placement; do
  : > "$CALLS"
  if SCENARIO="$scenario" bash scripts/demo.sh > "$tmp/output" 2>&1; then
    [[ "$scenario" == good ]] || { cat "$tmp/output"; echo "FAIL: accepted $scenario"; exit 1; }
    grep -q 'PASS: End-to-end read-only validation complete' "$tmp/output"
  else
    [[ "$scenario" != good ]] || { cat "$tmp/output"; exit 1; }
    grep -q 'FINAL VALIDATION SUMMARY' "$tmp/output"
  fi
  ! grep -q 'private-endpoint-secret-marker' "$tmp/output"
  ! grep -Eq '^(apply|create|delete|patch)|INSERT INTO|DROP TABLE' "$CALLS"
  echo "PASS: customer demo $scenario"
done
