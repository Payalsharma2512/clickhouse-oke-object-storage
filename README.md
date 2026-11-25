# ClickHouse on OKE with OCI Block Volume and Object Storage

This demonstration runs ClickHouse on Oracle Kubernetes Engine (OKE)
and makes two storage paths visible: MergeTree data on OCI Block Volumes and
MergeTree data on an OCI Object Storage-backed disk. The same SQL engine reads
both. Kubernetes PVCs identify the block devices; ClickHouse system tables show
where the active table parts reside.

The architecture has three workers, three ClickHouse pods, three 50 GiB Block
Volumes, and one shared Object Storage bucket. It uses Altinity ClickHouse Operator
0.26.3. No Terraform, Keeper deployment, external monitoring, or public database
load balancer is needed.

## Validation results and scope

The existing deployment passed a live rehearsal on November 17, 2026, followed by
a read-only final summary. A separate live installation in `clickhouse-clean` on November 24, 2026 tested operator install mode on a disposable three-worker OKE cluster. All nine read-only checks passed from a local Bash client.

| Check | Observed result | Evidence scope |
|---|---|---|
| ClickHouse pods | 3 Running and Ready, on 3 different workers | Existing live deployment |
| Block storage | 3 Bound PVCs, each 50 GiB | Existing live deployment |
| Hot data | 200,000 rows per pod; 600,000 total | Successful inserts and subsequent reads |
| Object-backed data | 10,000 rows per pod; 30,000 total | Successful inserts and subsequent reads |
| Active part placement | `hot` and `oci_object_storage`, respectively | `system.parts` checks |
| Payload reads | Successful for both table types on every pod | Nonempty-payload count queries |
| Fresh-install scripts | Install mode passed on a new OKE cluster | Three Ready instances, three bound 50 GiB volumes, ClickHouse 25.8.33.6 |
| Customer demo script | All 9 summary checks passed against the existing deployment | Read-only run outside Cloud Shell |
| OCI Cloud Shell execution | All nine read-only checks passed | Existing deployment |

## Storage layout

The [ClickHouse manifest](k8s/clickhouse.yaml) defines three shards with one replica each.
Required pod anti-affinity spreads these pods across hostnames. Each mounts one
`hot-data` PVC at `/var/lib/clickhouse/hot`. Server metadata is under
`/var/lib/clickhouse/hot/server/`, and the named `hot` disk uses
`/var/lib/clickhouse/hot/data/`.

`demo.events` uses `hot_policy`. `demo.object_storage_events` uses
`oci_object_storage_policy`. Both are ordinary local MergeTree tables. They are
not replicated tables, and the demo does not create a Distributed table. Totals
in this article sum the independently queried shards; no automatic redistribution
or replication is implied. Sharing a bucket does not make the tables shared replicas.

The Object Storage disk keeps its metadata locally on the pod's Block Volume.
The local-looking path in `system.parts` therefore does not mean object-backed
payloads live entirely on block storage. Verify `disk_name` and the configured disk
type. Preserve both object data and local metadata; a bucket alone is not a complete
backup of this design. There is no automatic hot-to-object tiering in these policies.

## 1. Prepare OCI permissions, networking, and workers

Use an existing suitable OKE cluster, or have your administrator prepare a dedicated
cluster for a new installation. These repository scripts do not create OKE, node
pools, networking, IAM policies, or buckets. Creating those resources incurs charges.
For a full operator-from-scratch test, use a cluster without an existing Altinity
operator or its CRDs. The existing demo must not be used for that test.

Requirements:

- Three Ready, schedulable **amd64** worker nodes. The working environment used
  OKE Kubernetes `v1.36.4` and 16 GiB RAM workers. The repository pins the tested
  ClickHouse image digest; do not assume it supports a different CPU architecture.
- Each ClickHouse pod requests `500m` CPU and `1Gi` RAM and is limited to `2` CPU
  and `4Gi` RAM. Leave capacity for the operator and Kubernetes system pods, and
  for any other workloads. Taints must permit scheduling, with free pod IPs.
- Working DNS, worker egress to image registries and the regional S3-compatible
  Object Storage endpoint, and client network access to the Kubernetes API.
- The OCI Block Volume CSI driver, `blockvolume.csi.oraclecloud.com`, and OKE's
  IAM permissions for provisioning and attaching volumes. Allow quota and attachment
  headroom for three 50 GiB volumes. Do not manually create the three data volumes:
  Kubernetes provisions them from PVCs.

**Installation permissions:** namespace, Secret, ConfigMap, StorageClass and
ClickHouseInstallation creation are required. `OPERATOR_MODE=install` additionally
requires CRD installation/management and cluster-scoped RBAC permissions for the
operator's ClusterRole and ClusterRoleBinding, as well as its namespaced resources.
Namespace-level permissions alone are not sufficient. OKE's OCI identity must be
authorized to provision and attach Block Volumes; the Customer Secret Key identity
must be authorized to read, write and manage the demo's Object Storage objects.

**Validation permissions:** read access to Kubernetes nodes, pods, PVCs and PVs,
`pods/exec`, and ClickHouse SELECT access to the demonstration and relevant system
tables. Validation does not require permission to create resources or read Secrets.

OCI IAM access to OKE and Kubernetes RBAC are separate checks. Ask the administrator
to authorize the intended cluster and compartment, following Oracle's
[OKE prerequisites](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengprerequisites.htm)
and [cluster-access instructions](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengdownloadkubeconfigfile.htm).
The console's **Access Cluster** dialog supplies the environment-specific access command.

The identity behind the Customer Secret Key needs Object Storage permissions in
the bucket's compartment. The installer additionally needs bucket creation permission
if creating a bucket. For a dedicated demo compartment, an administrator can use
the broad demo policy pattern below, then narrow it for the organization's requirements:

```text
Allow group <object-storage-demo-group> to manage object-family in compartment <demo-compartment-name>
```

This is an IAM policy template, not a shell command. It covers more than read-only
access: ClickHouse must write objects and may delete them during merges or table drops.
See [OCI S3 compatibility and authorization](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi.htm).

## 2. Obtain the repository and configure cluster access

Clone the entire repository into OCI Cloud Shell or another Bash environment. Keep the directory structure intact so the scripts can load `scripts/lib/read-queries.sh`:

```bash
command -v git
git clone 'https://github.com/Payalsharma2512/clickhouse-oke-object-storage.git'
cd clickhouse-oke-object-storage
```

Run all remaining commands from the repository root. If already cloned, skip the
clone command and change into your existing checkout. Alternatively use GitHub's
**Code > Download ZIP**, extract it, and open the extracted directory containing
this README, `scripts/`, `k8s/`, and `oci/`. Git is required only for cloning;
the ZIP option needs an unzip utility instead. Do not upload a private working
directory or any filled credential files.

Use Bash 4+, OCI CLI, `kubectl`, `jq`, and the shell utilities below. `column`
formats the anonymized tables; `tar` is needed only for tar-based source archives; `mktemp`, `tr`, and
`date` support validation and rehearsal. Git is required **only when cloning** an
optionally published repository. A locally installed `clickhouse-client` is needed
only for the optional port-forward example; normal validation uses the client in
the ClickHouse container.

```bash
for tool in bash kubectl oci jq column tar mktemp tr date sed grep sort wc seq tee mkdir dirname sleep cat chmod cp rm uname; do
  command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool"; exit 1; }
done
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Bash 4 or newer is required'; exit 1; }
```

Configure a dedicated kubeconfig, replacing the placeholders privately:

```bash
export OCI_REGION='<region>'
export CLUSTER_OCID='<cluster-ocid>'
mkdir -p "$HOME/.kube"
export KUBECONFIG="$HOME/.kube/clickhouse-demo"
oci ce cluster create-kubeconfig \
  --cluster-id "$CLUSTER_OCID" --file "$KUBECONFIG" \
  --region "$OCI_REGION" --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

# Use the active OCI session and kubeconfig.
export DEMO_TARGET_FILE=/dev/null
kubectl get nodes
kubectl get csinodes -o 'custom-columns=NODE:.metadata.name,DRIVERS:.spec.drivers[*].name'
```

`kubectl get nodes`, `kubectl config current-context` and
`kubectl get pods -o wide` are **private setup/diagnostic checks**, not publication
screenshots. They may reveal private IPs, contexts or infrastructure identifiers.
Use `scripts/customer-demo.sh` to show worker placement with anonymized aliases.

Use `PUBLIC_ENDPOINT` only for a public API endpoint you can reach. For a private
endpoint, establish the required Cloud Shell private-network access first and use
the corresponding `PRIVATE_ENDPOINT` command from Access Cluster. Changing the
flag alone does not establish connectivity. Do not expose kubeconfig contents,
cluster identifiers, or raw endpoint errors during screen sharing.

For the new installation, choose a fresh namespace:

```bash
export NAMESPACE=clickhouse-clean
export OPERATOR_MODE=install
```

The scripts reserve `clickhouse-demo` for the existing validated deployment and protect it from deployment
and write tests. All new-install commands use `clickhouse-clean`; screenshot examples of the existing environment use `clickhouse-demo`. If the cluster already has an operator, `OPERATOR_MODE=reuse`
uses it without modifying its bundle, provided it already watches the new namespace.
That validates a fresh workload, not a fresh operator installation. Do not run two
operators watching the same namespace. See the pinned
[operator configuration](https://github.com/Altinity/clickhouse-operator/blob/0.26.3/docs/operator_configuration.md).

In reuse mode, `scripts/deploy.sh` checks Deployment `clickhouse-operator` in
`${OPERATOR_NAMESPACE:-clickhouse-demo}`. If the existing operator is installed
elsewhere, set its actual namespace before running the deployment script:

```bash
export OPERATOR_MODE=reuse
export OPERATOR_NAMESPACE='<existing-operator-namespace>'
```

`NAMESPACE` remains the new ClickHouse namespace. The existing operator must already
watch that namespace; the script does not change its watch configuration.

## 3. Prepare one Object Storage bucket and the Secret inputs

Use one Standard-tier bucket. For a new, authorized installation only, this is the
bucket-creation procedure; skip creation when using an existing suitable bucket:

```bash
export COMPARTMENT_OCID='<demo-compartment-ocid>'
export OBJECT_NAMESPACE='<object-storage-namespace>'
export BUCKET='<demo-bucket-name>'
oci os bucket create --namespace-name "$OBJECT_NAMESPACE" \
  --compartment-id "$COMPARTMENT_OCID" --name "$BUCKET" \
  --storage-tier Standard --public-access-type NoPublicAccess \
  --region "$OCI_REGION"
```

Create or obtain an OCI **Customer Secret Key** for the authorized identity. These
are S3-compatible access/secret keys, not OCI API signing keys. Follow Oracle's
[Customer Secret Key procedure](https://docs.oracle.com/en-us/iaas/Content/Identity/access/working-with-customer-secret-keys.htm).
Keep the returned secret private; never paste it into the blog or a recorded terminal.

The endpoint includes the Object Storage namespace, region, bucket, and a fresh
ClickHouse-owned prefix. All three pods use that bucket and prefix:

```text
https://<object-storage-namespace>.compat.objectstorage.<region>.oraclecloud.com/<bucket>/clickhouse-clean/
```

No directory creation is needed in Object Storage. Do not reuse a prefix containing
another installation's objects. Do not apply lifecycle rules that remove live parts.


Prepare the repository's expected input file privately:

```bash
umask 077
cp oci/object-storage.env.example "$HOME/clickhouse-object-storage.env"
chmod 600 "$HOME/clickhouse-object-storage.env"
export OBJECT_STORAGE_ENV_FILE="$HOME/clickhouse-object-storage.env"
# Edit this file privately, replacing every placeholder before deployment.
```

Its four required entries are literal `KEY=value` lines with no shell quotes:

```text
OBJECT_STORAGE_ENDPOINT=https://<object-storage-namespace>.compat.objectstorage.<region>.oraclecloud.com/<bucket>/clickhouse-clean/
OBJECT_STORAGE_REGION=<region>
OBJECT_STORAGE_ACCESS_KEY=<customer-secret-key-access-key>
OBJECT_STORAGE_SECRET_KEY=<customer-secret-key-secret-key>
```

The endpoint must end in `/$NAMESPACE/`. The script creates the Kubernetes Secret
named `clickhouse-oci-object-storage` with these entries before deploying ClickHouse.
Never commit the filled file or include it in the customer archive.

## 4. Review and install the Kubernetes resources

First render the manifests locally, without creating resources:

```bash
bash scripts/deploy.sh plan
ls "build/$NAMESPACE"
```

`scripts/render.sh` renders namespace, operator, StorageClass, CHI and SQL ConfigMap
manifests from `k8s/`. It changes the namespace and associated resource names while
preserving `clickhouse-demo-sql`, which validation expects. It does not render secrets.

The source CHI pins ClickHouse to the image digest observed on the working deployment:

```yaml
image: docker.io/clickhouse/clickhouse-server@sha256:0152dd511befe6a2c2ef53e930726179669b08116da78500b37c51c96ff5ee77
```

The operator bundle is already vendored and rendered, with operator and exporter
version `0.26.3`. It contains the standard upstream CRDs, RBAC, configuration and
Deployment; Keeper-related CRD definitions do not create Keeper pods.


Only after authorizing the new resources, run:

```bash
export ALLOW_NEW_RESOURCES=yes
bash scripts/deploy.sh apply
```

For full install mode, the script performs this sequence:

1. Validate inputs; refuse an existing namespace or conflicting StorageClass; check CSI.
2. Refuse pre-existing Altinity CRDs in full install mode.
3. Create namespace and Object Storage Secret.
4. Apply the operator bundle server-side, wait for the CHI CRD to be Established,
   and wait for the operator Deployment rollout.
5. Create the unique StorageClass, SQL ConfigMap and ClickHouseInstallation.
6. Wait for exactly three ClickHouse pods, then their Ready conditions.
7. Assert distinct worker placement and three Bound PVCs mapped to distinct PVs.

## 5. Understand PVC provisioning and Object Storage configuration

The rendered StorageClass has the following configuration:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: oci-bv-clickhouse-clean
provisioner: blockvolume.csi.oraclecloud.com
parameters:
  attachment-type: "paravirtualized"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

The CHI's PVC template requests `50Gi`, uses `ReadWriteOnce`, and refers to this
StorageClass. `WaitForFirstConsumer` means provisioning/binding follows scheduling;
an initial Pending PVC is not automatically an error. OCI's requirements are
documented in [Provisioning PVCs on Block Volume](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingpersistentvolumeclaim_topic-Provisioning_PVCs_on_BV.htm).



The exact Object Storage disk fragment in the CHI is:

```xml
<oci_object_storage>
  <type>object_storage</type>
  <object_storage_type>s3</object_storage_type>
  <endpoint from_env="OBJECT_STORAGE_ENDPOINT"/>
  <access_key_id from_env="OBJECT_STORAGE_ACCESS_KEY"/>
  <secret_access_key from_env="OBJECT_STORAGE_SECRET_KEY"/>
  <region from_env="OBJECT_STORAGE_REGION"/>
  <metadata_type>local</metadata_type>
  <metadata_path>/var/lib/clickhouse/hot/oci-object-storage-metadata/</metadata_path>
  <skip_access_check>false</skip_access_check>
</oci_object_storage>
```

The container receives the Secret through `envFrom.secretRef`. `hot_policy` selects
disk `hot`; `oci_object_storage_policy` selects disk `oci_object_storage`. The
policies are explicit table settings, not an automatic migration rule.


Verify deployment privately; the customer script below avoids printing addresses:

```bash
kubectl get pods -n "$NAMESPACE" -l clickhouse.altinity.com/chi=oke-hot-object-demo
kubectl get pvc -n "$NAMESPACE"
kubectl get chi oke-hot-object-demo -n "$NAMESPACE"
bash scripts/validate.sh infrastructure
```

## 6. Connect to ClickHouse and inspect storage

The service is ClusterIP. Use `kubectl exec` for the walkthrough; it needs no
externally exposed ClickHouse endpoint:

```bash
POD=$(kubectl get pods -n "$NAMESPACE" \
  -l clickhouse.altinity.com/chi=oke-hot-object-demo \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$POD" -c clickhouse -- \
  clickhouse-client --readonly 2 --query "SELECT version(), 1 AS healthy"
bash scripts/validate.sh disks
```

For a local interactive client, use a temporary local-only port-forward in a
separate terminal, then close it after the walkthrough:

```bash
kubectl port-forward -n "$NAMESPACE" "pod/$POD" 9000:9000
# In another terminal with clickhouse-client installed:
clickhouse-client --host 127.0.0.1 --port 9000
```

The manifest's default ClickHouse user has an empty password and broad network
allowlisting. This is an isolated demo configuration; keep its service internal.
Do not expose it as a public database endpoint.

## 7. Load sample data

Run this step only in a fresh or disposable demo namespace. The loader drops and
recreates the demo tables, replacing any rows they contain.

Choose **one** loading approach below. Do not run both approaches against the same
tables. Each targets a new or explicitly disposable installation; neither is part
of the read-only customer demonstration.

### Option A: Automated loading

Retain `NAMESPACE=clickhouse-clean` and `DEMO_TARGET_FILE=/dev/null` from setup.
The smoke test runs first because it recreates `demo.events` on the first pod:

```bash
# NAMESPACE must still identify the newly installed environment.
bash scripts/validate.sh smoke
BATCHES=2 ROWS_PER_BATCH=100000 bash scripts/validate.sh hot
bash scripts/validate.sh object-storage
bash scripts/validate.sh summary
```

`bash scripts/rehearse.sh` is an alternative wrapper for that same automated path:
it runs disks, smoke, both loads and the final summary with a timestamped log.
Do not run it in addition to the commands above. These scripts recreate the demo
tables, and use one execution thread, one insert thread, and 8,192-row blocks.

### Option B: Manual SQL loading

Skip Option A. Execute the SQL below independently on **each of the three pods**.
The following loop opens an interactive client on one pod at a time using the exact
memory-conscious client options in `scripts/validate.sh`:

```bash
for POD in $(kubectl get pods -n "$NAMESPACE" \
  -l clickhouse.altinity.com/chi=oke-hot-object-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  printf '\nManual load target: %s\n' "$POD"
  kubectl exec -it -n "$NAMESPACE" "$POD" -c clickhouse -- \
    clickhouse-client --max_threads 1 --max_insert_threads 1 \
    --max_block_size 8192 --max_insert_block_size 8192 --multiquery
done
```

In each client session, execute the hot-table definition, both INSERT batches,
the Object Storage table definition/INSERT, and the verification SQL below. Type
`exit` only after completing that pod; the loop then opens the next pod. Do not
paste Bash commands into the SQL client. These SQL definitions recreate the tables.

The hot table definition used by `scripts/validate.sh` is:

```sql
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
```

For each pod, insert the following two batches, matching the script's event-ID
offset and payload expression for `batch` 1 and 2:

```sql
-- Batch 1: 100,000 rows.
INSERT INTO demo.events
SELECT
    toDateTime('2026-01-01 00:00:00') + toIntervalSecond(number % 86400),
    number + (1 * 1000000000000),
    1,
    repeat(concat('batch-', toString(1), '-'), 16)
FROM numbers(100000);

-- Batch 2: another 100,000 rows with its own event-ID offset.
INSERT INTO demo.events
SELECT
    toDateTime('2026-01-01 00:00:00') + toIntervalSecond(number % 86400),
    number + (2 * 1000000000000),
    2,
    repeat(concat('batch-', toString(2), '-'), 16)
FROM numbers(100000);
```


`k8s/test-workload.yaml` supplies `object_storage.sql`, applied through the SQL
ConfigMap and streamed to `clickhouse-client` on all three pods:

```sql
CREATE DATABASE IF NOT EXISTS demo;
DROP TABLE IF EXISTS demo.object_storage_events;
CREATE TABLE demo.object_storage_events
(
    event_time DateTime,
    event_id UInt64,
    payload String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)
SETTINGS storage_policy = 'oci_object_storage_policy';

INSERT INTO demo.object_storage_events
SELECT now(), number, repeat('object-storage-', 64)
FROM numbers(10000);
```


For Option B, run this verification SQL in the same client before typing `exit`:

```sql
SELECT count(), countIf(length(payload) > 0) FROM demo.events;
SELECT count(), countIf(length(payload) > 0) FROM demo.object_storage_events;
SELECT table, disk_name, sum(rows) AS rows
FROM system.parts
WHERE database = 'demo'
  AND table IN ('events', 'object_storage_events') AND active
GROUP BY table, disk_name ORDER BY table, disk_name;
```

Complete the full manual sequence on all three pods to reproduce the aggregate
600,000 hot rows and 30,000 object-backed rows. A single pod accounts for only
200,000 and 10,000 rows respectively.

Use SELECT queries to verify both data and placement. These examples run on one
pod; the automated summary repeats the checks on all three:

```bash
kubectl exec -n "$NAMESPACE" "$POD" -c clickhouse -- \
  clickhouse-client --readonly 2 --max_threads 1 --multiquery --query "
SELECT count(), countIf(length(payload) > 0) FROM demo.events;
SELECT count(), countIf(length(payload) > 0) FROM demo.object_storage_events;
SELECT table, disk_name, sum(rows) AS rows
FROM system.parts
WHERE database = 'demo'
  AND table IN ('events', 'object_storage_events') AND active
GROUP BY table, disk_name ORDER BY table, disk_name;
SELECT name, type FROM system.disks
WHERE name IN ('hot', 'oci_object_storage') ORDER BY name;
"
```

Expected per-pod counts are `200000` and `10000`; corresponding active parts should
use `hot` and `oci_object_storage`. Payload predicates ensure the read test does
more than retrieve a count from table metadata. Reads may use caches: this is not
a cold-read or Object Storage latency benchmark.


## Customer Demo: End-to-End Validation from OCI Cloud Shell

From the repository root, use the kubeconfig configured in section 2 and select
the namespace containing the loaded tables. For the existing deployment, run:

```bash
NAMESPACE=clickhouse-demo bash scripts/customer-demo.sh
```

For a new installation loaded in section 7, use `NAMESPACE=clickhouse-clean`.
The script uses the active kubeconfig and runs read-only ClickHouse queries.

### What the one-command walkthrough verifies

1. Kubernetes API reachability, with an actionable stop if access fails.
2. The three workers hosting ClickHouse are Ready (other workers may exist).
3. Exactly three nonterminating Running/Ready pods, on distinct workers.
4. The three attached `hot-data` PVCs are Bound and 50 GiB, with distinct PVs using
   the OCI Block Volume CSI driver and the same capacity.
5. Each ClickHouse server answers SQL and reports cluster `demo` with three shards
   and one replica per shard in `system.clusters`.
6. Exactly 200,000 hot rows and 10,000 object-backed rows per pod.
7. Active parts are exclusively on each expected disk, with at least one active part.
8. Payload reads succeed for all counted rows in both tables.

Output uses `Pod 1`, `worker A` and similar aliases, not private addresses or volume
identifiers. Placement values `1` mean the `system.parts` assertion passed. Each
check receives PASS/FAIL; dependent checks are marked NOT RUN if an earlier check
prevents completion. Any required failure returns a nonzero exit code. Raw errors
are suppressed for screen sharing; troubleshoot with kubectl privately.

The script needs node/pod/PVC/PV read access and `pods/exec`; an exec request is a
Kubernetes POST, but it runs only read-only database queries. No DDL/DML or Kubernetes
resource mutations occur. It validates per-pod health and configured shard layout,
not replicated availability or a cross-shard Distributed query.

The customer script passed a live read-only run outside Cloud Shell on November 17,
2026. The final output was:

```text
FINAL VALIDATION SUMMARY
  PASS    OKE connectivity
  PASS    Three healthy workers
  PASS    Pod health and distribution
  PASS    Three OCI Block Volume PVCs (50 GiB each)
  PASS    ClickHouse health and shard layout
  PASS    Hot storage: 600,000 rows
  PASS    Object Storage: 30,000 rows
  PASS    Storage placement
  PASS    Queries read payloads from both storage types

PASS: End-to-end read-only validation complete.
```


Offline regression tests cover API failure, unhealthy nodes and pods, duplicate worker placement, incorrect PVCs, SQL errors, and incorrect counts or disk placement. Shell syntax and manifest checks support the procedure but do not execute a fresh installation or cleanup.

All nine read-only checks also passed from OCI Cloud Shell against the existing deployment. The fresh installation passed the same nine checks from a local client. If expected tables or rows are missing, the script
fails rather than silently loading data.

## Troubleshooting

| Symptom | Check | Resolution direction |
|---|---|---|
| API inaccessible from Cloud Shell | Active kubeconfig, OCI session, IAM/RBAC, endpoint reachability | Configure Access Cluster and the required network; no workload changes are needed to diagnose access |
| Pods Pending | `kubectl describe pod` and namespace events | Check three schedulable workers, resources, taints, anti-affinity, pod IP capacity and PVC binding |
| Pods crash or cannot pull images | Pod events and ClickHouse/operator logs | Check registry egress, architecture, Secret existence/keys, configuration and S3 access; inspect logs privately |
| PVCs remain Pending | `kubectl describe pvc`, pod scheduling, CSI driver | `WaitForFirstConsumer` needs a scheduled consumer; check OCI quotas, IAM, topology and attachment capacity |
| S3 authentication or signature error | Customer Secret Key validity, region, endpoint and bucket/prefix spelling | Use Customer Secret Keys, correct region and namespace; verify the key owner's Object Storage permissions without printing credentials |
| `MEMORY_LIMIT_EXCEEDED` | ClickHouse query error and pod limits | Use the script's one-thread, 8,192-row-block workload and small payloads; do not increase load size during the demo |
| Rows on the wrong disk | `system.tables.storage_policy`, `system.storage_policies`, active `system.parts.disk_name` | Check the table's policy and rendered CHI; changing configuration alone does not relocate existing parts |
| Missing/incorrect counts | Namespace, table names, per-shard counts and failed load logs | Use the correct existing environment; reload only in an explicitly authorized test installation |

Useful private diagnostics:

```bash
kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp
kubectl describe pod -n "$NAMESPACE" "$POD"
kubectl get pvc -n "$NAMESPACE"
kubectl logs -n "$NAMESPACE" "$POD" -c clickhouse --tail=100
kubectl exec -n "$NAMESPACE" "$POD" -c clickhouse -- clickhouse-client --query \
  "SELECT name, storage_policy FROM system.tables WHERE database='demo'"
```

The first rehearsal encountered a ClickHouse memory-limit error on one pod. After
reducing payload size and insert concurrency, the complete rerun passed. That is
why the walkthrough fixes the smaller workload instead of treating it as a stress test.

## Destructive cleanup — new disposable installations only

**Do not run this against the working demo.** The repository's `cleanup.sh` is
disabled. Both the CHI PVC policy and StorageClass use `Delete`: removing claims
can delete their OCI Block Volumes and all local metadata. Review backups and the
target resources before any cleanup. On the disposable install-mode test, the namespace and StorageClass were deleted, the three data volumes were released, and the dedicated Object Storage prefix was verified empty.

For an independently created disposable namespace only, explicitly select its name
and inspect the resources first. The guard refuses the protected namespace:

```bash
export CLEANUP_NAMESPACE='<disposable-namespace>'
[[ -n "$CLEANUP_NAMESPACE" && "$CLEANUP_NAMESPACE" != clickhouse-demo ]] || exit 1
kubectl get chi,pods,pvc -n "$CLEANUP_NAMESPACE"
# DESTRUCTIVE: execute only after reviewing the targets above.
kubectl delete chi oke-hot-object-demo -n "$CLEANUP_NAMESPACE" --wait=true
kubectl delete namespace "$CLEANUP_NAMESPACE" --wait=true
kubectl delete storageclass "oci-bv-$CLEANUP_NAMESPACE"
```

For a namespace that installed its own operator on a dedicated cluster, this leaves
cluster-scoped operator definitions. Do not delete shared CRDs or RBAC casually:
CRD deletion can affect every installation of that type. A cluster administrator
must review any remaining global resources separately. In reuse mode, leave the
existing operator and its global resources untouched.

Deleting Kubernetes resources does not guarantee that all bucket objects disappear.
After confirming the disposable prefix is no longer referenced, use the Object
Storage console to review and delete **only that prefix's objects**. Preserve the
shared bucket, other prefixes, existing OKE cluster and node pool. Verify the three
disposable Block Volumes were removed before assuming billing has stopped.

## Offline checks

These checks use mocked kubectl calls and do not contact OKE:

```bash
for file in scripts/*.sh scripts/lib/*.sh; do bash -n "$file"; done
bash scripts/test-validation.sh
bash scripts/test-deploy.sh
bash scripts/test-customer-demo.sh
```

The package uses the active kubeconfig and OCI session. No private target file is required.
The optional rehearsal creates a local evidence directory; keep its generated logs private.

## Repository contents

- `k8s/clickhouse-operator.yaml`: pinned Altinity operator 0.26.3 bundle.
- `k8s/clickhouse.yaml`: three-shard ClickHouseInstallation and hot/object policies.
- `k8s/storageclasses.yaml`: OCI Block Volume CSI StorageClass.
- `k8s/namespace.yaml`: namespace template.
- `k8s/test-workload.yaml`: SQL ConfigMap, including Object Storage workload.
- `oci/object-storage.env.example`: placeholder-only Customer Secret Key inputs.
- `scripts/`: deploy/render, loaders, read-only customer validation, shared SQL,
  offline regression tests and disabled automatic cleanup.

## Licensing

[License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
