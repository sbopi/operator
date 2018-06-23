---
title: Monitoring | Vault operator
description: monitoring of Vault operator
menu:
  product_vault-operator_0.1.0:
    identifier: monitoring-stash
    name: Monitoring
    parent: guides
    weight: 45
product_name: vault-operator
menu_name: product_vault-operator_0.1.0
section_menu_id: guides
---

> New to Vault operator? Please start [here](/docs/concepts/README.md).

# Monitoring Vault operator

Vault operator has native support for monitoring via Prometheus.

## Monitoring Vault operator Operator
Vault operator exposes Prometheus native monitoring data via `/metrics` endpoint on `:56790` port. You can setup a [CoreOS Prometheus ServiceMonitor](https://github.com/coreos/prometheus-operator) using `stash-operator` service.

## Monitoring Backup Operation
Since backup operations are run as cron jobs, Vault operator can use [Prometheus Pushgateway](https://github.com/prometheus/pushgateway) cache metrics for backup operation. The installation scripts for Vault operator deploys a Prometheus Pushgateway as a sidecar container. You can configure a Prometheus server to scrape this Pushgateway via `stash-operator` service on port `:56789`. Backup operations send the following metrics to this Pushgateway:

 - `restic_session_success{job="<restic.namespace>-<restic.name>", app="<workload>"}`: Indicates if session was successfully completed
 - `restic_session_fail{job="<restic.namespace>-<restic.name>", app="<workload>"}`: Indicates if session failed
 - `restic_session_duration_seconds_total{job="<restic.namespace>-<restic.name>", app="<workload>"}`: Total seconds taken to complete restic session
 - `restic_session_duration_seconds{job="<restic.namespace>-<restic.name>", app="<workload>", filegroup="dir1", op="backup|forget"}`: Total seconds taken to complete restic session

## Grafana Dashboard
The dashboard can be downloaded directly [from the repo](/contrib/monitoring/Grafana%20-%20Vault operator%20-%20Backup%20Overview.json) or from [Grafana.com](https://grafana.com/dashboards/4198).
You can import the dashboard JSON file or through Grafana.com import by ID `4198`.

The dashboard looks like this:
![Vault operator - Backup Overview - Grafana Dashboard](/docs/images/grafana/dashboard-stash-backup-overview.png)

## Next Steps

- Learn how to use Vault operator to backup a Kubernetes deployment [here](/docs/guides/backup.md).
- Learn about the details of Restic CRD [here](/docs/concepts/crds/restic.md).
- To restore a backup see [here](/docs/guides/restore.md).
- Learn about the details of Recovery CRD [here](/docs/concepts/crds/recovery.md).
- To run backup in offline mode see [here](/docs/guides/offline_backup.md)
- See the list of supported backends and how to configure them [here](/docs/guides/backends.md).
- See working examples for supported workload types [here](/docs/guides/workloads.md).
- Learn about how to configure [RBAC roles](/docs/guides/rbac.md).
- Want to hack on Vault operator? Check our [contribution guidelines](/docs/CONTRIBUTING.md).
