# Plex Benchmarker Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a Prometheus Pushgateway alongside the plex-benchmarker CronJob, wire metrics into Grafana Cloud via Alloy, and store a Grafana dashboard JSON for import.

**Architecture:** The CronJob pushes final benchmark metrics to a co-located Pushgateway on exit. Alloy scrapes the Pushgateway every 60s and remote-writes to Grafana Cloud Prometheus. A dashboard JSON (stored in the repo) is imported once into Grafana Cloud manually.

**Tech Stack:** Kubernetes Deployment/Service, `prom/pushgateway:v1.10.0`, Grafana Alloy (River config), Grafana Cloud Prometheus, Grafana dashboard JSON (schemaVersion 38)

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `apps/plex-benchmarker/templates/pushgateway.yaml` | Pushgateway Deployment + Service |
| Modify | `apps/plex-benchmarker/values.yaml` | Add `pushgateway.tag` |
| Modify | `apps/plex-benchmarker/templates/cronjob.yaml` | Add `--pushgateway` arg |
| Modify | `apps/observability/values.yaml` | Add Alloy scrape block for Pushgateway |
| Create | `apps/plex-benchmarker/dashboard.json` | Grafana dashboard for import |

---

### Task 1: Pushgateway Deployment and Service

**Files:**
- Create: `apps/plex-benchmarker/templates/pushgateway.yaml`
- Modify: `apps/plex-benchmarker/values.yaml`

- [ ] **Step 1: Add pushgateway image tag to values.yaml**

The full content of `apps/plex-benchmarker/values.yaml` after edit:

```yaml
plexHost: "10.0.0.50:32400"
image:
  tag: v1.0.0
pushgateway:
  tag: v1.10.0
```

- [ ] **Step 2: Create templates/pushgateway.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-pushgateway
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: prometheus-pushgateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus-pushgateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus-pushgateway
    spec:
      containers:
        - name: pushgateway
          image: prom/pushgateway:{{ .Values.pushgateway.tag }}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 9091
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-pushgateway
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: prometheus-pushgateway
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 9091
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: prometheus-pushgateway
```

- [ ] **Step 3: Verify helm template renders both resources**

```bash
helm template plex-benchmarker apps/plex-benchmarker/ | grep "kind:"
```

Expected output includes all of:
```
kind: ConfigMap
kind: CronJob
kind: Deployment
kind: Service
```

- [ ] **Step 4: Verify helm lint passes**

```bash
helm lint apps/plex-benchmarker/ --strict
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 5: Commit**

```bash
git add apps/plex-benchmarker/templates/pushgateway.yaml apps/plex-benchmarker/values.yaml
git commit -m "feat(plex-benchmarker): deploy prometheus pushgateway"
```

---

### Task 2: Add --pushgateway arg to CronJob

**Files:**
- Modify: `apps/plex-benchmarker/templates/cronjob.yaml` (line 34 — after `--json`)

- [ ] **Step 1: Add the --pushgateway arg**

In `apps/plex-benchmarker/templates/cronjob.yaml`, the `args` block currently ends with `- --json`. Add one line after it so the args block reads:

```yaml
              args:
                - --host=$(PLEX_HOST)
                - --resolution=both
                - --type=both
                - --ramp-interval=10s
                - --stability-window=30s
                - --startup-grace=5s
                - --json
                - --pushgateway=prometheus-pushgateway:9091
```

- [ ] **Step 2: Verify the arg is rendered**

```bash
helm template plex-benchmarker apps/plex-benchmarker/ | grep pushgateway
```

Expected output includes:
```
- --pushgateway=prometheus-pushgateway:9091
```

- [ ] **Step 3: Verify helm lint**

```bash
helm lint apps/plex-benchmarker/ --strict
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 4: Commit**

```bash
git add apps/plex-benchmarker/templates/cronjob.yaml
git commit -m "feat(plex-benchmarker): push metrics to pushgateway on job completion"
```

---

### Task 3: Add Alloy scrape config for Pushgateway

**Files:**
- Modify: `apps/observability/values.yaml` (append to `collectors.alloy.extraConfig`, after the `plex` scrape block ending at line 164)

- [ ] **Step 1: Append scrape block to extraConfig**

In `apps/observability/values.yaml`, the current `collectors.alloy.extraConfig` ends with:

```alloy
        prometheus.scrape "plex" {
          job_name = "integrations/plex"
          scrape_interval = "30s"
          targets = [
            {"__address__" = "10.0.0.50:9000", "instance" = "vault"},
          ]
          honor_labels = true
          forward_to = [prometheus.remote_write.grafana_cloud_prometheus.receiver]
        }
```

Append the following block immediately after it (before the `    alloy-logs:` line):

```alloy
        prometheus.scrape "plex_benchmarker" {
          job_name        = "integrations/plex-benchmarker"
          scrape_interval = "60s"
          targets = [
            {"__address__" = "prometheus-pushgateway.plex-benchmarker:9091"},
          ]
          honor_labels = true
          forward_to = [prometheus.remote_write.grafana_cloud_prometheus.receiver]
        }
```

- [ ] **Step 2: Verify helm lint passes on observability**

```bash
helm lint apps/observability/ --strict
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 3: Verify the scrape block is in the rendered output**

```bash
helm template observability apps/observability/ | grep plex_benchmarker
```

Expected output includes:
```
plex_benchmarker
```

- [ ] **Step 4: Commit**

```bash
git add apps/observability/values.yaml
git commit -m "feat(observability): scrape plex-benchmarker pushgateway"
```

---

### Task 4: Grafana Dashboard JSON

**Files:**
- Create: `apps/plex-benchmarker/dashboard.json`

- [ ] **Step 1: Create dashboard.json**

```json
{
  "__inputs": [
    {
      "name": "DS_PROMETHEUS",
      "label": "Prometheus",
      "description": "Grafana Cloud Prometheus data source",
      "type": "datasource",
      "pluginId": "prometheus",
      "pluginName": "Prometheus"
    }
  ],
  "__requires": [
    {
      "type": "grafana",
      "id": "grafana",
      "name": "Grafana",
      "version": "10.0.0"
    },
    {
      "type": "datasource",
      "id": "prometheus",
      "name": "Prometheus",
      "version": "1.0.0"
    },
    {
      "type": "panel",
      "id": "stat",
      "name": "Stat",
      "version": ""
    },
    {
      "type": "panel",
      "id": "timeseries",
      "name": "Time series",
      "version": ""
    },
    {
      "type": "panel",
      "id": "bargauge",
      "name": "Bar gauge",
      "version": ""
    }
  ],
  "annotations": { "list": [] },
  "description": "Plex Media Server benchmark results — max stable streams and delivery ratios tracked over time",
  "editable": true,
  "graphTooltip": 1,
  "links": [],
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "1080p Direct — Max Stable Streams",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": ["lastNotNull"],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "fixed", "fixedColor": "green" },
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [{ "color": "green", "value": null }]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "plex_benchmark_max_stable_streams{scenario=\"1080p_direct\"}",
          "legendFormat": "1080p direct",
          "refId": "A"
        }
      ]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "1080p Transcode — Max Stable Streams",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": ["lastNotNull"],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "fixed", "fixedColor": "blue" },
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [{ "color": "blue", "value": null }]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "plex_benchmark_max_stable_streams{scenario=\"1080p_transcode\"}",
          "legendFormat": "1080p transcode",
          "refId": "A"
        }
      ]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "4K Direct — Max Stable Streams",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": ["lastNotNull"],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "fixed", "fixedColor": "yellow" },
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [{ "color": "yellow", "value": null }]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "plex_benchmark_max_stable_streams{scenario=\"4k_direct\"}",
          "legendFormat": "4K direct",
          "refId": "A"
        }
      ]
    },
    {
      "id": 4,
      "type": "stat",
      "title": "4K Transcode — Max Stable Streams",
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": ["lastNotNull"],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "fixed", "fixedColor": "orange" },
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [{ "color": "orange", "value": null }]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "plex_benchmark_max_stable_streams{scenario=\"4k_transcode\"}",
          "legendFormat": "4K transcode",
          "refId": "A"
        }
      ]
    },
    {
      "id": 5,
      "type": "timeseries",
      "title": "Max Stable Streams Over Time",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "tooltip": { "mode": "multi", "sort": "desc" },
        "legend": { "displayMode": "list", "placement": "bottom" }
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": {
            "lineWidth": 2,
            "fillOpacity": 10,
            "spanNulls": true
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "1080p_direct" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#73bf69" } }]
          },
          {
            "matcher": { "id": "byName", "options": "1080p_transcode" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#5794f2" } }]
          },
          {
            "matcher": { "id": "byName", "options": "4k_direct" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#f2cc0c" } }]
          },
          {
            "matcher": { "id": "byName", "options": "4k_transcode" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#ff9830" } }]
          }
        ]
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "plex_benchmark_max_stable_streams",
          "legendFormat": "{{scenario}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 6,
      "type": "bargauge",
      "title": "Latest Run — Delivery Ratio per Stream",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "displayMode": "gradient",
        "orientation": "horizontal",
        "reduceOptions": {
          "calcs": ["lastNotNull"],
          "fields": "",
          "values": false
        },
        "showUnfilled": true
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "min": 0,
          "max": 15,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 0.5 },
              { "color": "green", "value": 1.0 }
            ]
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "plex_benchmark_delivery_ratio",
          "legendFormat": "{{scenario}} s{{stream_id}}",
          "refId": "A"
        }
      ]
    },
    {
      "id": 7,
      "type": "timeseries",
      "title": "Avg Delivery Ratio Over Time",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 },
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "options": {
        "tooltip": { "mode": "multi", "sort": "desc" },
        "legend": { "displayMode": "list", "placement": "bottom" }
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": {
            "lineWidth": 2,
            "fillOpacity": 10,
            "spanNulls": true
          }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "1080p_direct" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#73bf69" } }]
          },
          {
            "matcher": { "id": "byName", "options": "1080p_transcode" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#5794f2" } }]
          },
          {
            "matcher": { "id": "byName", "options": "4k_direct" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#f2cc0c" } }]
          },
          {
            "matcher": { "id": "byName", "options": "4k_transcode" },
            "properties": [{ "id": "color", "value": { "mode": "fixed", "fixedColor": "#ff9830" } }]
          }
        ]
      },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
          "expr": "avg by (scenario) (plex_benchmark_delivery_ratio)",
          "legendFormat": "{{scenario}}",
          "refId": "A"
        }
      ]
    }
  ],
  "refresh": "",
  "schemaVersion": 38,
  "tags": ["plex", "benchmark"],
  "templating": {
    "list": [
      {
        "current": {},
        "hide": 0,
        "includeAll": false,
        "label": "Data Source",
        "name": "DS_PROMETHEUS",
        "options": [],
        "query": "prometheus",
        "refresh": 1,
        "type": "datasource"
      }
    ]
  },
  "time": { "from": "now-6M", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Plex Benchmarker",
  "uid": "plex-benchmarker",
  "version": 1
}
```

- [ ] **Step 2: Validate JSON is well-formed**

```bash
python3 -m json.tool apps/plex-benchmarker/dashboard.json > /dev/null && echo "VALID"
```

Expected: `VALID`

- [ ] **Step 3: Verify panel count**

```bash
python3 -c "
import json
d = json.load(open('apps/plex-benchmarker/dashboard.json'))
print(f'panels: {len(d[\"panels\"])}')
print(f'title: {d[\"title\"]}')
print(f'uid: {d[\"uid\"]}')
"
```

Expected:
```
panels: 7
title: Plex Benchmarker
uid: plex-benchmarker
```

- [ ] **Step 4: Commit**

```bash
git add apps/plex-benchmarker/dashboard.json
git commit -m "feat(plex-benchmarker): add grafana dashboard json"
```

---

### Task 5: Final validation

- [ ] **Step 1: Full helm lint on both charts**

```bash
helm lint apps/plex-benchmarker/ --strict && helm lint apps/observability/ --strict
```

Expected: both report `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 2: Verify all 5 resource types render**

```bash
helm template plex-benchmarker apps/plex-benchmarker/ | grep "^kind:"
```

Expected:
```
kind: ConfigMap
kind: Deployment
kind: Service
kind: CronJob
```

- [ ] **Step 3: Verify pushgateway arg in cronjob**

```bash
helm template plex-benchmarker apps/plex-benchmarker/ | grep "pushgateway"
```

Expected output includes both:
```
- --pushgateway=prometheus-pushgateway:9091
name: prometheus-pushgateway
```

- [ ] **Step 4: Verify Alloy scrape block in observability**

```bash
helm template observability apps/observability/ | grep -A5 "plex-benchmarker"
```

Expected output includes `prometheus-pushgateway.plex-benchmarker:9091`.

- [ ] **Step 5: Push to origin**

```bash
git push origin main
```

ArgoCD will sync both `plex-benchmarker` and `observability` applications within ~20 seconds.

- [ ] **Step 6: Import dashboard into Grafana Cloud**

1. Open Grafana Cloud → Dashboards → New → Import
2. Upload `apps/plex-benchmarker/dashboard.json`
3. Select your Grafana Cloud Prometheus data source when prompted
4. Click Import

Dashboard will show data after the next CronJob run (Sunday 02:00). To test immediately, trigger a manual run:

```bash
kubectl create job plex-benchmarker-manual --from=cronjob/plex-benchmarker -n plex-benchmarker
```
