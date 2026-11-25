#!/usr/bin/env bash
# Render manifests for the selected namespace and operator mode.
set -euo pipefail
cd "$(dirname "$0")/.."
ns=${NAMESPACE:-clickhouse-clean}
[[ "$ns" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ && ${#ns} -le 40 && "$ns" != clickhouse-demo ]] || { echo 'Use a new DNS-label namespace (2-40 characters), not clickhouse-demo' >&2; exit 2; }
out="build/$ns"
mkdir -p "$out"
for file in namespace.yaml clickhouse.yaml test-workload.yaml storageclasses.yaml; do
  sed "s/clickhouse-demo/$ns/g; s/$ns-sql/clickhouse-demo-sql/g; s|image: altinity/|image: docker.io/altinity/|g" "k8s/$file" > "$out/$file"
done
if [[ ${OPERATOR_MODE:-reuse} == install ]]; then
  source_url=https://raw.githubusercontent.com/Altinity/clickhouse-operator/0.26.3/deploy/operator/clickhouse-operator-install-bundle.yaml
  sha256=be2463c884b04376c7f1fe211b2fba60a0d13a9585911e9b25147b90d6a4e952
  work=$(mktemp -d "$out/.operator.XXXXXXXX")
  trap 'rm -rf "$work"' EXIT
  if [[ -n ${ALTINITY_BUNDLE_FILE:-} ]]; then
    cp -- "$ALTINITY_BUNDLE_FILE" "$work/source.yaml"
  else
    curl --fail --silent --show-error --location --retry 2 --proto '=https' \
      --output "$work/source.yaml" "$source_url"
  fi
  (cd "$work" && printf '%s  source.yaml\n' "$sha256" | sha256sum --check --status) || {
    echo 'Altinity 0.26.3 manifest failed SHA-256 verification' >&2
    exit 1
  }
  awk -v ns="$ns" -f scripts/lib/render-operator.awk "$work/source.yaml" > "$work/operator.yaml"
  mv -- "$work/operator.yaml" "$out/clickhouse-operator.yaml"
else
  rm -f -- "$out/clickhouse-operator.yaml"
fi
echo "$out"
