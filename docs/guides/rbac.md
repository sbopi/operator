---
title: RBAC | Vault operator
description: RBAC
menu:
  product_vault-operator_0.1.0:
    identifier: rbac-stash
    name: RBAC
    parent: guides
    weight: 40
product_name: vault-operator
menu_name: product_vault-operator_0.1.0
section_menu_id: guides
---
> New to Vault operator? Please start [here](/docs/concepts/README.md).

# Configuring RBAC

To use Vault operator in a RBAC enabled cluster, [install Vault operator](/docs/setup/install.md) with RBAC options. This creates a ClusterRole named `stash-sidecar`.

Sidecar container added to workloads makes various calls to Kubernetes api. ServiceAccounts used with Deployment, ReplicaSet, DaemonSet and ReplicationController workloads are automatically bound to `stash-sidecar` ClusterRole by Vault operator. Users should manually add the following RoleBinding to service accounts used with StatefulSet workloads to authorize these api calls.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: <statefulset-name>-stash-sidecar
  namespace: <statefulset-namespace>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: stash-sidecar
subjects:
- kind: ServiceAccount
  name: <statefulset-sa>
  namespace: <statefulset-namespace>
```

You can find full working examples [here](/docs/guides/workloads.md).

## Next Steps

- Learn how to use Vault operator to backup a Kubernetes deployment [here](/docs/guides/backup.md).
- Learn about the details of Restic CRD [here](/docs/concepts/crds/restic.md).
- To restore a backup see [here](/docs/guides/restore.md).
- Learn about the details of Recovery CRD [here](/docs/concepts/crds/recovery.md).
- To run backup in offline mode see [here](/docs/guides/offline_backup.md)
- See the list of supported backends and how to configure them [here](/docs/guides/backends.md).
- See working examples for supported workload types [here](/docs/guides/workloads.md).
- Thinking about monitoring your backup operations? Vault operator works [out-of-the-box with Prometheus](/docs/guides/monitoring.md).
- Want to hack on Vault operator? Check our [contribution guidelines](/docs/CONTRIBUTING.md).
