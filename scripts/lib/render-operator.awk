# The checksum-verified upstream bundle separates YAML documents with ---.
BEGIN {
    RS = "\n---\n"
    print "# Modified from Altinity clickhouse-operator 0.26.3 (Apache-2.0)."
    print "# Changes: namespace/RBAC selection, pull policies, and example-IP redaction."
    print "# See THIRD_PARTY_NOTICES.md and LICENSES/Altinity-clickhouse-operator-Apache-2.0.txt."
}

# Use the cluster-scoped RBAC pair for this installation.
/\nkind: (Role|RoleBinding)\n/ { next }

{
    if (NR > 1) printf "\n---\n"
    lines = split($0, line, "\n")
    for (i = 1; i <= lines; i++) {
        if (line[i] !~ /# metadata.namespace:/)
            gsub(/kube-system/, ns, line[i])
        sub(/image: altinity\//, "image: docker.io/altinity/", line[i])
        sub(/imagePullPolicy: Always/, "imagePullPolicy: IfNotPresent", line[i])
        sub(/_PULL_POLICY=Always/, "_PULL_POLICY=IfNotPresent", line[i])
        sub(/# status.podIP: [0-9.]+/, "# status.podIP: <pod-ip>", line[i])
        printf "%s%s", (i == 1 ? "" : "\n"), line[i]
    }
}
