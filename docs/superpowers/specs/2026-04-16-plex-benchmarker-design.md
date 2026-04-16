# plex-benchmarker CronJob — Design Spec

**Date:** 2026-04-16

## Overview

Add a new app (`apps/plex-benchmarker/`) that deploys a Kubernetes CronJob to run the [plex-benchmarker](https://github.com/graytonio/plex-benchmarker) load-test tool on a weekly schedule. The tool ramps up concurrent simulated streams against a Plex server and reports the maximum stable stream count as JSON to stdout.

## App Structure

```
apps/plex-benchmarker/
├── Chart.yaml           # minimal chart, no dependencies
├── values.yaml          # plex host address
└── templates/
    ├── configmap.yaml   # PLEX_HOST value
    └── cronjob.yaml     # CronJob manifest
```

Raw Kubernetes manifests in `templates/` with no Helm sub-chart dependencies. This matches the `system-upgrade` pattern in the repo — appropriate for a CronJob with no ingress, service, or PVC.

ArgoCD's ApplicationSet auto-creates the `plex-benchmarker` namespace via `CreateNamespace=true` in syncOptions.

## CronJob Spec

| Field | Value |
|-------|-------|
| Schedule | `0 2 * * 0` (Sunday 02:00) |
| Image | `ghcr.io/graytonw/plex-benchmarker:v1.0.0` |
| concurrencyPolicy | `Forbid` |
| backoffLimit | `0` |
| activeDeadlineSeconds | `7200` (2 h) |
| successfulJobsHistoryLimit | `3` |
| failedJobsHistoryLimit | `3` |
| restartPolicy | `Never` |
| CPU request/limit | `100m` / `500m` |
| Memory request/limit | `64Mi` / `128Mi` |

## CLI Args

```
--host=$(PLEX_HOST)
--resolution=both
--type=both
--ramp-interval=10s
--stability-window=30s
--startup-grace=5s
--json
```

No `--token` — the Plex server at `10.0.0.50:32400` has auth disabled.

## ConfigMap

A single ConfigMap `plex-benchmarker` in the `plex-benchmarker` namespace:

```yaml
data:
  PLEX_HOST: "10.0.0.50:32400"
```

The CronJob reads this via `configMapKeyRef`.

## Output

JSON summary printed to stdout on exit. Pod logs are collected cluster-wide by Loki (via `podLogsViaLoki` in the observability stack), so results are queryable in Grafana without any additional metrics wiring.
