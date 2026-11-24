#!/usr/bin/env bash
# Read-only: uses the caller's kubeconfig, uses no bundled private target configuration.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/read-queries.sh
NAMESPACE=${NAMESPACE:-clickhouse-demo}
labels=('OKE connectivity' 'Three healthy workers' 'Pod health and distribution' 'Three OCI Block Volume PVCs (50 GiB each)' 'ClickHouse health and shard layout' 'Hot storage: 600,000 rows' 'Object Storage: 30,000 rows' 'Storage placement' 'Queries read payloads from both storage types')
states=(); for label in "${labels[@]}"; do states+=('NOT RUN'); done
current=0
summary() {
  printf '\nFINAL VALIDATION SUMMARY\n'
  for i in "${!labels[@]}"; do printf '  %-7s %s\n' "${states[$i]}" "${labels[$i]}"; done
}
fail() { states[$current]=FAIL; printf '\nFAIL: %s\n' "$1"; summary; exit 1; }
trap 'fail "Validation could not finish. Check kubectl access, RBAC and the selected namespace privately; raw errors are hidden for screen sharing."' ERR
for cmd in kubectl jq mktemp rm uname; do command -v "$cmd" >/dev/null || fail "Install $cmd or use OCI Cloud Shell with $cmd on PATH."; done
# Native jq.exe otherwise writes CRLF into Bash arrays on Windows/Git Bash.
case "$(uname -s)" in MINGW*|MSYS*) jq() { command jq --binary "$@"; } ;; esac
err=$(mktemp)
trap 'rm -f "$err"' EXIT
k() { MSYS2_ARG_CONV_EXCL='--raw=' kubectl --request-timeout=20s "$@" 2>"$err"; }
pass() { states[$current]=PASS; printf 'PASS: %s\n' "${labels[$current]}"; }
printf 'Read-only validation; no inserts, deployment changes or OCI resource operations.\n'
if ! k get --raw=/version >/dev/null; then
  fail 'Cannot access OKE. Configure kubeconfig using Access Cluster in the OCI console, confirm your OCI session and IAM/RBAC, and verify Cloud Shell can reach the selected public endpoint or configured private network. Retry kubectl get nodes privately.'
fi
pass
current=1
nodes=$(k get nodes -o json)
pods=$(k get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo -o json)
[[ $(jq '.items|length' <<< "$pods") == 3 ]] || fail 'Expected exactly three ClickHouse pods. Check NAMESPACE and installation status privately.'
mapfile -t workers < <(jq -r '.items[].spec.nodeName // empty' <<< "$pods" | sort -u)
[[ ${#workers[@]} == 3 ]] || fail 'Expected three different workers for the three ClickHouse pods. Check scheduling and anti-affinity.'
for node in "${workers[@]}"; do
  jq -e --arg n "$node" 'any(.items[]; .metadata.name==$n and any(.status.conditions[]?; .type=="Ready" and .status=="True"))' <<< "$nodes" >/dev/null || fail 'A ClickHouse worker is not Ready. Inspect node conditions privately.'
done
pass
current=2
jq -e 'all(.items[]; .metadata.deletionTimestamp == null and .status.phase=="Running" and any(.status.conditions[]?; .type=="Ready" and .status=="True"))' <<< "$pods" >/dev/null || fail 'A ClickHouse pod is not Running and Ready. Inspect its events and logs privately.'
mapfile -t pod_names < <(jq -r '.items[].metadata.name' <<< "$pods" | sort)
printf '  Pod 1 -> worker A\n  Pod 2 -> worker B\n  Pod 3 -> worker C\n'
pass
current=3
claims_json=$(k get pvc -n "$NAMESPACE" -o json)
mapfile -t claims < <(jq -r '.items[].spec.volumes[] | select(.name=="hot-data") | .persistentVolumeClaim.claimName // empty' <<< "$pods" | sort -u)
[[ ${#claims[@]} == 3 ]] || fail 'Expected three distinct hot-data PVCs attached to the demo pods.'
volumes=()
for claim in "${claims[@]}"; do
  item=$(jq -c --arg c "$claim" '.items[] | select(.metadata.name==$c)' <<< "$claims_json")
  jq -e '.status.phase=="Bound" and .status.capacity.storage=="50Gi" and (.spec.volumeName|length)>0' <<< "$item" >/dev/null || fail 'A required PVC is missing, unbound, or not 50Gi. Inspect PVC events and CSI provisioning.'
  volumes+=("$(jq -r '.spec.volumeName' <<< "$item")")
done
[[ $(printf '%s\n' "${volumes[@]}" | sort -u | wc -l) -eq 3 ]] || fail 'Expected three distinct backing volumes.'
pvs=$(k get pv "${volumes[@]}" -o json)
jq -e '.items|length==3' <<< "$pvs" >/dev/null || fail 'Could not inspect all three backing PVs. Check PV read permissions.'
jq -e 'all(.items[]; .spec.csi.driver=="blockvolume.csi.oraclecloud.com" and .spec.capacity.storage=="50Gi" and .status.phase=="Bound")' <<< "$pvs" >/dev/null || fail 'Backing PVs must be Bound 50Gi volumes using the OCI Block Volume CSI driver.'
printf '  3 x 50 GiB = 150 GiB provisioned; OCI Block Volume CSI verified\n'
pass
current=4
hot_total=0; object_total=0; hot_ok=1; object_ok=1; placement_ok=1; reads_ok=1
for i in "${!pod_names[@]}"; do
  sql="SELECT count(), uniqExact(shard_num), uniqExact(replica_num) FROM system.clusters WHERE cluster='demo' FORMAT TabSeparatedRaw;
SELECT count() FROM demo.events FORMAT TabSeparatedRaw;
$(demo_read_query events);
$(demo_placement_query events hot);
SELECT count() FROM demo.object_storage_events FORMAT TabSeparatedRaw;
$(demo_read_query object_storage_events);
$(demo_placement_query object_storage_events oci_object_storage);"
  if ! result=$(k exec -n "$NAMESPACE" "${pod_names[$i]}" -c clickhouse -- clickhouse-client --readonly 2 --max_threads 1 --max_execution_time 30 --multiquery --query "$sql"); then
    fail 'ClickHouse SELECT failed. Verify pods/exec permission, client authentication, demo tables and Object Storage access; inspect errors privately. This script does not load missing data.'
  fi
  mapfile -t rows <<< "${result//$'\r'/}"
  [[ ${#rows[@]} == 7 && "${rows[0]}" == $'3\t3\t1' ]] || fail 'Expected the demo cluster layout to contain three shards with one replica each on every pod.'
  for j in 1 2 3 4 5 6; do [[ "${rows[$j]}" =~ ^[0-9]+$ ]] || fail 'Unexpected query output; inspect ClickHouse tables privately.'; done
  [[ ${rows[1]} == 200000 ]] || hot_ok=0
  [[ ${rows[4]} == 10000 ]] || object_ok=0
  [[ ${rows[3]} == 1 && ${rows[6]} == 1 ]] || placement_ok=0
  [[ ${rows[2]} == "${rows[1]}" && ${rows[5]} == "${rows[4]}" ]] || reads_ok=0
  hot_total=$((hot_total + rows[1])); object_total=$((object_total + rows[4]))
  printf '  Pod %d: hot=%s rows; object-backed=%s rows; hot placement=%s; object placement=%s\n' "$((i+1))" "${rows[1]}" "${rows[4]}" "${rows[3]}" "${rows[6]}"
done
pass
for current in 5 6 7 8; do
  ok=0
  case "$current" in
    5) if [[ $hot_ok == 1 && $hot_total == 600000 ]]; then ok=1; fi ;;
    6) if [[ $object_ok == 1 && $object_total == 30000 ]]; then ok=1; fi ;;
    7) if [[ $placement_ok == 1 ]]; then ok=1; fi ;;
    8) if [[ $reads_ok == 1 ]]; then ok=1; fi ;;
  esac
  if [[ $ok == 1 ]]; then pass; else states[$current]=FAIL; fi
done
summary
for state in "${states[@]}"; do [[ "$state" == PASS ]] || { printf '\nFAIL: Check row counts, payload reads and system.parts disk_name. No data was changed.\n'; exit 1; }; done
printf '\nPASS: End-to-end read-only validation complete.\n'
