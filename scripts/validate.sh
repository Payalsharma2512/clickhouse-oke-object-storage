#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source "${DEMO_TARGET_FILE:-/dev/null}"
source scripts/lib/read-queries.sh
for tool in kubectl sed sort wc seq; do command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }; done

NAMESPACE="${NAMESPACE:-clickhouse-demo}"
MODE="${1:-smoke}"
BATCHES="${BATCHES:-2}"
ROWS_PER_BATCH="${ROWS_PER_BATCH:-100000}"

case "${MODE}" in smoke|hot|object-storage|disks|infrastructure|summary) ;; *) echo "Usage: $0 [smoke|hot|object-storage|disks|infrastructure|summary]" >&2; exit 2 ;; esac
case "$MODE" in
  smoke|hot|object-storage)
    [[ "$NAMESPACE" != clickhouse-demo ]] || { echo 'Protected working deployment: write tests are disabled in clickhouse-demo' >&2; exit 2; }
    ;;
esac
for value in "${BATCHES}" "${ROWS_PER_BATCH}"; do
  [[ "$value" =~ ^[1-9][0-9]{0,6}$ ]] || { echo "Batch settings must be positive integers up to 9999999" >&2; exit 2; }
done
# Capture discovery separately so API failures cannot become an empty successful loop.
POD_LIST=$(kubectl get pods -n "${NAMESPACE}" -l clickhouse.altinity.com/chi=oke-hot-object-demo -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
mapfile -t DEMO_PODS < <(printf '%s\n' "$POD_LIST" | sed '/^$/d')
[[ ${#DEMO_PODS[@]} -eq 3 ]] || { echo "FAIL: expected exactly three ClickHouse pods" >&2; exit 1; }
kubectl wait --for=condition=Ready pod -n "${NAMESPACE}" -l clickhouse.altinity.com/chi=oke-hot-object-demo --timeout=60s

assert_table() {
  local target="$1" table="$2" disk="$3" expected="$4" actual placement
  # Read payload data as well as counting; a metadata-only count cannot prove reads.
  actual=$(kubectl exec -n "$NAMESPACE" "$target" -- clickhouse-client --max_threads 1 --query "$(demo_read_query "$table")")
  placement=$(kubectl exec -n "$NAMESPACE" "$target" -- clickhouse-client --query "$(demo_placement_query "$table" "$disk")")
  [[ "$actual" == "$expected" && "$placement" == 1 ]] || { echo "FAIL: $target $table rows=$actual expected=$expected placement=$placement" >&2; exit 1; }
  echo "PASS: $target $table: $actual rows on $disk"
}

pod() {
  kubectl get pods \
    -n "${NAMESPACE}" \
    -l clickhouse.altinity.com/chi=oke-hot-object-demo \
    -o jsonpath='{.items[0].metadata.name}'
}

pods() {
  kubectl get pods \
    -n "${NAMESPACE}" \
    -l clickhouse.altinity.com/chi=oke-hot-object-demo \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

run_query() {
  local query="$1"
  kubectl exec -n "${NAMESPACE}" "$(pod)" -- clickhouse-client --multiquery --query "${query}"
}

run_query_on_pod() {
  local pod_name="$1"
  local query="$2"
  kubectl exec -n "${NAMESPACE}" "${pod_name}" -- clickhouse-client --max_threads 1 --max_insert_threads 1 --max_block_size 8192 --max_insert_block_size 8192 --multiquery --query "${query}"
}

run_file() {
  local key="$1"
  kubectl get configmap clickhouse-demo-sql -n "${NAMESPACE}" -o "jsonpath={.data.${key}}" \
    | kubectl exec -i -n "${NAMESPACE}" "$(pod)" -- clickhouse-client --max_threads 1 --max_insert_threads 1 --max_block_size 8192 --max_insert_block_size 8192 --multiquery
}

assert_infrastructure() {
  local nodes claims claim volume volumes=() phase
  nodes=$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
  [[ $(printf '%s\n' "$nodes" | sed '/^$/d' | sort -u | wc -l) -eq 3 ]] || { echo 'FAIL: expected three distinct worker nodes'; exit 1; }
  claims=$(kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo -o jsonpath='{range .items[*].spec.volumes[?(@.name=="hot-data")]}{.persistentVolumeClaim.claimName}{"\n"}{end}')
  mapfile -t claim_list < <(printf '%s\n' "$claims" | sed '/^$/d' | sort -u)
  [[ ${#claim_list[@]} -eq 3 ]] || { echo 'FAIL: expected three distinct hot-data PVCs'; exit 1; }
  for claim in "${claim_list[@]}"; do
    phase=$(kubectl get pvc "$claim" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    [[ "$phase" == Bound ]] || { echo "FAIL: $claim is $phase"; exit 1; }
    volume=$(kubectl get pvc "$claim" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
    [[ -n "$volume" ]] || { echo "FAIL: $claim has no PV"; exit 1; }
    volumes+=("$volume")
  done
  [[ $(printf '%s\n' "${volumes[@]}" | sort -u | wc -l) -eq 3 ]] || { echo 'FAIL: expected three distinct PVs'; exit 1; }
  echo 'PASS: three Ready pods on three workers with three Bound PVCs and distinct PVs'
}

case "${MODE}" in
  infrastructure)
    assert_infrastructure
    ;;
  summary)
    assert_infrastructure
    for pod_name in "${DEMO_PODS[@]}"; do
      assert_table "$pod_name" events hot 200000
      assert_table "$pod_name" object_storage_events oci_object_storage 10000
    done
    echo 'PASS: FINAL SUMMARY: 600000 hot rows; 30000 Object Storage rows; payload reads and placement verified'
    ;;
  smoke)
    run_file smoke\\.sql
    assert_table "$(pod)" events hot 10000
    ;;
  hot)
    for pod_name in "${DEMO_PODS[@]}"; do
      echo "== ${pod_name}: hot Block Volume workload =="
      run_query_on_pod "${pod_name}" "
      CREATE DATABASE IF NOT EXISTS demo;
      DROP TABLE IF EXISTS demo.events;
      CREATE TABLE demo.events
      (
          event_time DateTime,
          event_id UInt64,
          batch UInt32,
          payload String
      )
      ENGINE = MergeTree
      PARTITION BY toYYYYMM(event_time)
      ORDER BY (event_time, event_id)
      SETTINGS storage_policy = 'hot_policy';
      "

      for batch in $(seq 1 "${BATCHES}"); do
        run_query_on_pod "${pod_name}" "
        INSERT INTO demo.events
        SELECT
            toDateTime('2026-01-01 00:00:00') + toIntervalSecond(number % 86400),
            number + (${batch} * 1000000000000),
            ${batch},
            repeat(concat('batch-', toString(${batch}), '-'), 16)
        FROM numbers(${ROWS_PER_BATCH});
        "
      done

      run_query_on_pod "${pod_name}" "
      SELECT
          name AS part_name,
          disk_name,
          rows,
          formatReadableSize(bytes_on_disk) AS bytes_on_disk,
          path
      FROM system.parts
      WHERE database = 'demo'
        AND table = 'events'
        AND active
      ORDER BY min_block_number, name;

      SELECT
          disk_name,
          count() AS active_parts,
          sum(rows) AS rows,
          formatReadableSize(sum(bytes_on_disk)) AS bytes_on_disk
      FROM system.parts
      WHERE database = 'demo'
        AND table = 'events'
        AND active
      GROUP BY disk_name
      ORDER BY disk_name;

      "
      assert_table "$pod_name" events hot "$((BATCHES * ROWS_PER_BATCH))"
    done
    ;;
  object-storage)
    for pod_name in "${DEMO_PODS[@]}"; do
      echo "== ${pod_name}: Object Storage workload =="
      kubectl get configmap clickhouse-demo-sql -n "${NAMESPACE}" -o "jsonpath={.data.object_storage\\.sql}" \
        | kubectl exec -i -n "${NAMESPACE}" "${pod_name}" -- clickhouse-client --max_threads 1 --max_insert_threads 1 --max_block_size 8192 --max_insert_block_size 8192 --multiquery
      assert_table "$pod_name" object_storage_events oci_object_storage 10000
    done
    ;;
  disks)
    for pod_name in "${DEMO_PODS[@]}"; do
      echo "== ${pod_name}: disks and policies =="
      run_query_on_pod "${pod_name}" "
      SELECT name, path, type, formatReadableSize(free_space) AS free, formatReadableSize(total_space) AS total
      FROM system.disks
      ORDER BY name;

      SELECT policy_name, volume_name, disks, load_balancing
      FROM system.storage_policies
      ORDER BY policy_name, volume_name;
      "
    done
    ;;
  *)
    echo "Usage: $0 [smoke|hot|object-storage|disks]" >&2
    exit 2
    ;;
esac
