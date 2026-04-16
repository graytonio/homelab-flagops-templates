# Plex Benchmarker Dashboard — Design Spec

**Date:** 2026-04-16

## Overview

Add a Grafana dashboard to track plex-benchmarker results over time. The benchmark CronJob runs weekly; this dashboard surfaces max stable streams per scenario and per-stream delivery ratios, enabling regression detection and long-term trend analysis.

## Architecture

```
CronJob --pushgateway→ Pushgateway ←scrape-- Alloy →remote_write→ Grafana Cloud Prometheus ←query-- Grafana Dashboard
```

Three changes to the existing stack:

1. **Prometheus Pushgateway** deployed in the `plex-benchmarker` namespace alongside the CronJob. Holds the last set of pushed metrics between weekly runs.
2. **CronJob updated** with `--pushgateway=prometheus-pushgateway:9091` arg. The tool natively supports this flag.
3. **Alloy scrape config** added to `apps/observability/values.yaml` — targets `prometheus-pushgateway.plex-benchmarker:9091`, forwarding to `grafana-cloud-prometheus`.
4. **Dashboard JSON** stored at `apps/plex-benchmarker/dashboard.json` and imported once into Grafana Cloud via the UI.

## Changes Required

### `apps/plex-benchmarker/templates/pushgateway.yaml`

New file. Contains:
- `Deployment` — `prom/pushgateway:latest`, 1 replica, port 9091, resource requests 50m/32Mi limits 100m/64Mi
- `Service` — ClusterIP, name `prometheus-pushgateway`, port 9091

### `apps/plex-benchmarker/templates/cronjob.yaml`

Add one arg to the container:
```yaml
- --pushgateway=prometheus-pushgateway:9091
```

### `apps/plex-benchmarker/values.yaml`

Add pushgateway image tag:
```yaml
pushgateway:
  tag: v1.10.0
```

### `apps/observability/values.yaml`

Add to `collectors.alloy.extraConfig`:
```alloy
prometheus.scrape "plex_benchmarker" {
  job_name        = "integrations/plex-benchmarker"
  scrape_interval = "60s"
  targets = [
    {"__address__" = "prometheus-pushgateway.plex-benchmarker:9091"},
  ]
  honor_labels = true
  forward_to   = [prometheus.remote_write.grafana_cloud_prometheus.receiver]
}
```

### `apps/plex-benchmarker/dashboard.json`

Grafana dashboard JSON with 4 rows:

## Dashboard Layout

**Layout:** Option B — overlaid comparison + stats

### Row 1 — Latest run: max stable streams (4 stat panels)

One stat panel per scenario. Spark line enabled. Color threshold: green ≥ 1.

| Panel title | Query |
|-------------|-------|
| 1080p Direct | `plex_benchmark_max_stable_streams{scenario="1080p_direct"}` |
| 1080p Transcode | `plex_benchmark_max_stable_streams{scenario="1080p_transcode"}` |
| 4K Direct | `plex_benchmark_max_stable_streams{scenario="4k_direct"}` |
| 4K Transcode | `plex_benchmark_max_stable_streams{scenario="4k_transcode"}` |

### Row 2 — Max stable streams over time (time series)

Single panel, all 4 scenarios overlaid.

| Field | Value |
|-------|-------|
| Query | `plex_benchmark_max_stable_streams` |
| Legend | `{{scenario}}` |
| Series colors | 1080p_direct=#73bf69, 1080p_transcode=#5794f2, 4k_direct=#f2cc0c, 4k_transcode=#ff9830 |

### Row 3 — Latest run: delivery ratio per stream (bar gauge)

One bar per stream per scenario. Color thresholds match the tool's health states.

| Field | Value |
|-------|-------|
| Query | `plex_benchmark_delivery_ratio` |
| Legend | `{{scenario}} s{{stream_id}}` |
| Thresholds | red=0, yellow=0.5, green=1.0 |
| Orientation | Horizontal |

### Row 4 — Avg delivery ratio over time (time series)

Single panel, all 4 scenarios overlaid.

| Field | Value |
|-------|-------|
| Query | `avg by (scenario) (plex_benchmark_delivery_ratio)` |
| Legend | `{{scenario}}` |
| Threshold line | 1.0 (dashed) — marks the "just keeping up" boundary |

## Dashboard Import

Since Grafana Cloud is used (not self-hosted), dashboard.json is imported manually:

1. Open Grafana Cloud → Dashboards → Import
2. Upload `apps/plex-benchmarker/dashboard.json`
3. Select the Grafana Cloud Prometheus data source
4. Save

The JSON is stored in the repo as the source of truth. Re-import if the dashboard is accidentally deleted.
