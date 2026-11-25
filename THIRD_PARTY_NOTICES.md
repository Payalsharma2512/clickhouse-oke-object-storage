# Third-party notices

## Altinity Kubernetes Operator for ClickHouse

Copyright (c) 2019-2025, Altinity Inc and/or its affiliates. All rights reserved.

- Upstream: https://github.com/Altinity/clickhouse-operator/tree/0.26.3
- Source: https://github.com/Altinity/clickhouse-operator/blob/0.26.3/deploy/operator/clickhouse-operator-install-bundle.yaml
- Vendored file: `k8s/clickhouse-operator.yaml`.
- License: Apache License 2.0; the upstream license text is reproduced without
  alteration in `LICENSES/Altinity-clickhouse-operator-Apache-2.0.txt`.

This is a modified bundle. Compared with the pinned upstream source, the existing
demo bundle substitutes the namespace and associated RBAC names, omits the
alternative namespaced Role/RoleBinding while retaining ClusterRole/Binding,
uses `IfNotPresent` for operator/exporter images, and replaces example pod-IP
comments with placeholders. A modification notice was added for this publication.
When generating the deployment manifests, `scripts/render.sh` substitutes the
selected namespace and adds the `docker.io/` registry prefix to Altinity image names.

The pinned upstream root contained no NOTICE file when checked on 2026-11-17.
This notice preserves attribution from its README and documents local changes;
it does not relicense upstream code or imply Altinity endorsement.

Container images are referenced for runtime pulling, not distributed in this
repository. Their respective licenses and notices continue to apply.
