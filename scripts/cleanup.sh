#!/usr/bin/env bash
set -euo pipefail

echo 'Cleanup disabled: preserve the working deployment, shared operator/CRDs, PVCs, and OCI data.' >&2
echo 'Any future cleanup needs a separately reviewed list of the new resources to remove.' >&2
exit 2
