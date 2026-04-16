# plex-benchmarker CronJob Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `apps/plex-benchmarker/` — a Helm chart that deploys a weekly Kubernetes CronJob running the plex-benchmarker load-test tool against `10.0.0.50:32400`.

**Architecture:** Raw Kubernetes manifests in `templates/` (no sub-chart dependencies), following the `apps/system-upgrade/` pattern. A ConfigMap holds the Plex host; the CronJob reads it via `configMapKeyRef`. ArgoCD's ApplicationSet picks up the new app automatically when `Chart.yaml` is committed.

**Tech Stack:** Helm (chart scaffolding only), Kubernetes CronJob/ConfigMap, `ghcr.io/graytonw/plex-benchmarker:v1.0.0`

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Create | `apps/plex-benchmarker/Chart.yaml` | Helm chart metadata, no dependencies |
| Create | `apps/plex-benchmarker/values.yaml` | Plex host address |
| Create | `apps/plex-benchmarker/templates/configmap.yaml` | Kubernetes ConfigMap for PLEX_HOST |
| Create | `apps/plex-benchmarker/templates/cronjob.yaml` | Kubernetes CronJob manifest |

---

### Task 1: Chart.yaml

**Files:**
- Create: `apps/plex-benchmarker/Chart.yaml`

- [ ] **Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: plex-benchmarker
description: Weekly load-test CronJob for Plex Media Server
type: application
version: 0.1.0
```

- [ ] **Step 2: Verify helm lint passes**

```bash
helm lint apps/plex-benchmarker/
```

Expected output contains: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 3: Commit**

```bash
git add apps/plex-benchmarker/Chart.yaml
git commit -m "feat(plex-benchmarker): scaffold chart"
```

---

### Task 2: values.yaml

**Files:**
- Create: `apps/plex-benchmarker/values.yaml`

- [ ] **Step 1: Create values.yaml**

```yaml
plexHost: "10.0.0.50:32400"
```

- [ ] **Step 2: Verify helm lint still passes**

```bash
helm lint apps/plex-benchmarker/
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 3: Commit**

```bash
git add apps/plex-benchmarker/values.yaml
git commit -m "feat(plex-benchmarker): add values with plex host"
```

---

### Task 3: ConfigMap template

**Files:**
- Create: `apps/plex-benchmarker/templates/configmap.yaml`

- [ ] **Step 1: Create templates/configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: plex-benchmarker
  namespace: {{ .Release.Namespace }}
data:
  PLEX_HOST: {{ .Values.plexHost | quote }}
```

- [ ] **Step 2: Verify rendering**

```bash
helm template plex-benchmarker apps/plex-benchmarker/
```

Expected output includes a ConfigMap with `PLEX_HOST: "10.0.0.50:32400"`.

- [ ] **Step 3: Verify helm lint**

```bash
helm lint apps/plex-benchmarker/
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 4: Commit**

```bash
git add apps/plex-benchmarker/templates/configmap.yaml
git commit -m "feat(plex-benchmarker): add configmap template"
```

---

### Task 4: CronJob template

**Files:**
- Create: `apps/plex-benchmarker/templates/cronjob.yaml`

- [ ] **Step 1: Create templates/cronjob.yaml**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: plex-benchmarker
  namespace: {{ .Release.Namespace }}
  labels:
    app: plex-benchmarker
spec:
  schedule: "0 2 * * 0"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 7200
      backoffLimit: 0
      template:
        metadata:
          labels:
            app: plex-benchmarker
        spec:
          restartPolicy: Never
          containers:
            - name: plex-benchmarker
              image: ghcr.io/graytonw/plex-benchmarker:v1.0.0
              imagePullPolicy: IfNotPresent
              args:
                - --host=$(PLEX_HOST)
                - --resolution=both
                - --type=both
                - --ramp-interval=10s
                - --stability-window=30s
                - --startup-grace=5s
                - --json
              env:
                - name: PLEX_HOST
                  valueFrom:
                    configMapKeyRef:
                      name: plex-benchmarker
                      key: PLEX_HOST
              resources:
                requests:
                  cpu: 100m
                  memory: 64Mi
                limits:
                  cpu: 500m
                  memory: 128Mi
```

- [ ] **Step 2: Verify rendering**

```bash
helm template plex-benchmarker apps/plex-benchmarker/
```

Expected output includes a CronJob with:
- `schedule: "0 2 * * 0"`
- `image: ghcr.io/graytonw/plex-benchmarker:v1.0.0`
- `--host=$(PLEX_HOST)` in args
- `configMapKeyRef` pointing to `plex-benchmarker` / `PLEX_HOST`

- [ ] **Step 3: Verify helm lint**

```bash
helm lint apps/plex-benchmarker/
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 4: Commit**

```bash
git add apps/plex-benchmarker/templates/cronjob.yaml
git commit -m "feat(plex-benchmarker): add cronjob template"
```

---

### Task 5: Set file permissions and final validation

- [ ] **Step 1: Set correct permissions**

```bash
chmod 644 apps/plex-benchmarker/Chart.yaml apps/plex-benchmarker/values.yaml
chmod 644 apps/plex-benchmarker/templates/configmap.yaml apps/plex-benchmarker/templates/cronjob.yaml
```

- [ ] **Step 2: Full helm lint with strict flag**

```bash
helm lint apps/plex-benchmarker/ --strict
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 3: Full helm template render with debug**

```bash
helm template plex-benchmarker apps/plex-benchmarker/ --debug
```

Expected: Two resources rendered — a ConfigMap and a CronJob — with no errors.

- [ ] **Step 4: Commit permissions if changed**

```bash
git add -u apps/plex-benchmarker/
git diff --staged --quiet || git commit -m "chore(plex-benchmarker): set file permissions"
```

- [ ] **Step 5: Verify the app will be discovered by ArgoCD ApplicationSet**

The ApplicationSet generator scans `apps/**/Chart.yaml`. Confirm the new chart is in the right location:

```bash
ls apps/plex-benchmarker/Chart.yaml
```

Expected: file exists at that exact path.
