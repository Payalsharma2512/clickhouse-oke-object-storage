#!/usr/bin/env bash
# Local only: render the unchanged architecture into an isolated namespace.
set -euo pipefail
cd "$(dirname "$0")/.."
ns=${NAMESPACE:-clickhouse-clean}
[[ "$ns" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ && ${#ns} -le 40 && "$ns" != clickhouse-demo ]] || { echo 'Use a new DNS-label namespace (2-40 characters), not clickhouse-demo' >&2; exit 2; }
out="build/$ns"
mkdir -p "$out"
for file in namespace.yaml clickhouse.yaml test-workload.yaml storageclasses.yaml clickhouse-operator.yaml; do
  sed "s/clickhouse-demo/$ns/g; s/$ns-sql/clickhouse-demo-sql/g" "k8s/$file" > "$out/$file"
done
echo "$out"
