# Coder Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Coder (the remote development platform control plane) as `apps/coder/` in this FlagOps/ArgoCD repo, backed by a dedicated postgres-operator-managed database, reachable at `coder.[env_domain]` on the private Traefik ingress class — and fix the plaintext-password pattern in both `coder` and `gotify` by relying on the postgres-operator's built-in credential-secret generation instead.

**Architecture:** `apps/coder/Chart.yaml` depends directly on the official `coder/coder` Helm chart (v2.36.1, aliased to `coder`), matching the `traefik`/`db-operators` pattern for apps with their own upstream chart. A `postgresql` CRD in `apps/coder/templates/pg.yaml` provisions the database; the Zalando postgres-operator auto-generates the credentials Secret (no Helm-templated secret). `apps/coder/values.yaml` wires that secret into `CODER_PG_CONNECTION_URL` via Kubernetes' native `$(VAR)` env substitution, sets `CODER_ACCESS_URL`, and configures the ingress. `gotify` gets the same credential-wiring treatment as a follow-on fix.

**Tech Stack:** Helm, Kubernetes, ArgoCD (via the repo's `flagops` CMP), Zalando postgres-operator (`acid.zalan.do/v1 postgresql` CRD), Coder Helm chart v2.36.1, Traefik ingress (`private-traffic` class), cert-manager.

Reference spec: `docs/superpowers/specs/2026-08-20-coder-control-plane-design.md`

---

### Task 1: Scaffold `apps/coder/Chart.yaml`

**Files:**
- Create: `apps/coder/Chart.yaml`

- [ ] **Step 1: Write the Chart.yaml**

```yaml
apiVersion: v2
name: coder
description: Remote development environments
type: application
version: 0.1.0
dependencies:
  - name: coder
    repository: https://helm.coder.com/v2
    version: 2.36.1
    alias: coder
```

- [ ] **Step 2: Commit**

```bash
git add apps/coder/Chart.yaml
git commit -m "feat(coder): add Chart.yaml for Coder control plane"
```

---

### Task 2: Add the Postgres backend

**Files:**
- Create: `apps/coder/templates/pg.yaml`

- [ ] **Step 1: Write the postgresql CRD manifest**

```yaml
apiVersion: "acid.zalan.do/v1"
kind: postgresql
metadata:
  name: coder-postgresql
spec:
  teamId: "coder"
  volume:
    size: 20Gi
  numberOfInstances: 1
  users:
    coder:
    - superuser
    - createdb
  databases:
    coder: coder
  postgresql:
    version: "17"
```

No `templates/secret.yaml` is created here — the postgres-operator (deployed via `apps/db-operators`) auto-generates the credentials Secret `coder.coder-postgresql.credentials.postgresql.acid.zalan.do` the first time it reconciles the `coder` role above. This is deliberate; see the spec's "Credential handling — no manual secret" section for why.

- [ ] **Step 2: Commit**

```bash
git add apps/coder/templates/pg.yaml
git commit -m "feat(coder): add postgres-operator database manifest"
```

---

### Task 3: Write `apps/coder/values.yaml`

**Files:**
- Create: `apps/coder/values.yaml`

- [ ] **Step 1: Write the values file**

```yaml
coder:
  service:
    type: ClusterIP

  ingress:
    enable: true
    className: private-traffic
    host: coder.[{ env "env_domain" }]
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    tls:
      enable: false

  env:
    - name: PGUSER
      valueFrom:
        secretKeyRef:
          name: coder.coder-postgresql.credentials.postgresql.acid.zalan.do
          key: username
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: coder.coder-postgresql.credentials.postgresql.acid.zalan.do
          key: password
    - name: CODER_PG_CONNECTION_URL
      value: "postgres://$(PGUSER):$(PGPASSWORD)@coder-postgresql.coder.svc.cluster.local:5432/coder?sslmode=disable"
    - name: CODER_ACCESS_URL
      value: "https://coder.[{ env \"env_domain\" }]"
```

`service.type: ClusterIP` overrides the chart's default of `LoadBalancer` — Traefik fronts the service via the Ingress, so it doesn't need its own MetalLB IP. The `PGUSER`/`PGPASSWORD` entries must stay listed **before** `CODER_PG_CONNECTION_URL` in this list — Kubernetes' `$(VAR)` substitution only resolves references to env vars defined earlier in the same container's env list, and this chart's `env` field is a real ordered list (unlike `app-template`'s map-style `env`, which Helm renders in sorted-key order and would silently break this).

- [ ] **Step 2: Commit**

```bash
git add apps/coder/values.yaml
git commit -m "feat(coder): configure ingress, access URL, and DB connection wiring"
```

---

### Task 4: Validate the `apps/coder` chart renders correctly

**Files:** none (validation only)

- [ ] **Step 1: Fetch the chart dependency and lint**

```bash
cd apps/coder
helm dependency update .
helm lint .
```

Expected: `helm dependency update` downloads the `coder` chart into `charts/coder-2.36.1.tgz` and writes `Chart.lock`; `helm lint` prints `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 2: Render the chart and inspect the output**

```bash
helm template . --debug > /tmp/coder-rendered.yaml
grep -n "CODER_PG_CONNECTION_URL" /tmp/coder-rendered.yaml
grep -n 'name: PGUSER' /tmp/coder-rendered.yaml
grep -n 'name: PGPASSWORD' /tmp/coder-rendered.yaml
grep -n "className: private-traffic\|ingressClassName: private-traffic" /tmp/coder-rendered.yaml
grep -n "type: ClusterIP" /tmp/coder-rendered.yaml
```

Expected: every grep finds at least one match. Confirm by eye in `/tmp/coder-rendered.yaml` that `PGUSER` and `PGPASSWORD` env entries appear **before** `CODER_PG_CONNECTION_URL` in the container spec's `env:` list — this can't be checked by `helm template` alone (the `$(VAR)` substitution itself only happens at pod runtime via kubelet), so this manual order check is the only pre-merge verification available. The env order was already fixed as a list in Task 3's `values.yaml`, so this step is confirming that ordering survived rendering unchanged.

- [ ] **Step 3: Clean up local dependency artifacts**

This repo does not commit `Chart.lock` or `charts/` for any app (confirmed via `git ls-files apps/traefik apps/db-operators` — neither is tracked, even though both have chart dependencies). Remove them so they don't show up as untracked cruft:

```bash
rm -rf Chart.lock charts
cd ../..
git status --short apps/coder
```

Expected: `git status --short apps/coder` prints nothing (clean).

---

### Task 5: Migrate `gotify` off its hardcoded plaintext DB secret

**Files:**
- Modify: `apps/gotify/values.yaml`
- Delete: `apps/gotify/templates/secret.yaml`

- [ ] **Step 1: Rewrite the gotify container env as an ordered list**

Change `apps/gotify/values.yaml` from the current map-style `env` block:

```yaml
          env:
            TZ: America/New_York
            GOTIFY_DATABASE_DIALECT: postgres
            GOTIFY_DATABASE_CONNECTION: host=gotify-postgresql.gotify.svc.cluster.local port=5432 user=gotify password=gotify dbname=gotify # TODO Move to secret with secure password
```

to:

```yaml
          env:
            - name: TZ
              value: America/New_York
            - name: GOTIFY_DATABASE_DIALECT
              value: postgres
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: gotify.gotify-postgresql.credentials.postgresql.acid.zalan.do
                  key: username
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: gotify.gotify-postgresql.credentials.postgresql.acid.zalan.do
                  key: password
            - name: GOTIFY_DATABASE_CONNECTION
              value: "host=gotify-postgresql.gotify.svc.cluster.local port=5432 user=$(PGUSER) password=$(PGPASSWORD) dbname=gotify"
```

`app-template`'s map-style `env:` (the form gotify used before) supports per-key `valueFrom` objects too, but Helm/Go's `text/template` renders map keys in sorted order — `GOTIFY_DATABASE_CONNECTION` would sort before `PGPASSWORD`/`PGUSER` alphabetically and break the substitution. Switching to the list form (also supported by `app-template`) preserves the YAML-authored order, same reasoning as Task 3.

- [ ] **Step 2: Delete the manual credentials secret**

```bash
git rm apps/gotify/templates/secret.yaml
```

Once this manifest is gone, the postgres-operator will auto-generate `gotify.gotify-postgresql.credentials.postgresql.acid.zalan.do` with a fresh random password on its next reconcile of the existing `gotify-postgresql` cluster — replacing the hardcoded `gotify`/`gotify` credentials this app has used until now. The operator manages both the DB role's actual password and the Secret together, so nothing else needs to change for them to stay in sync.

- [ ] **Step 3: Commit**

```bash
git add apps/gotify/values.yaml
git commit -m "fix(gotify): replace hardcoded DB password with postgres-operator auto-generated secret"
```

---

### Task 6: Validate the `apps/gotify` chart renders correctly

**Files:** none (validation only)

- [ ] **Step 1: Fetch the chart dependency and lint**

```bash
cd apps/gotify
helm dependency update .
helm lint .
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 2: Render the chart and inspect the output**

```bash
helm template . --debug > /tmp/gotify-rendered.yaml
grep -n "GOTIFY_DATABASE_CONNECTION" /tmp/gotify-rendered.yaml
grep -n "password=gotify" /tmp/gotify-rendered.yaml
grep -n 'name: PGUSER' /tmp/gotify-rendered.yaml
```

Expected: `GOTIFY_DATABASE_CONNECTION` line shows `password=$(PGPASSWORD)` (not a literal password); the `password=gotify` grep finds **nothing** (confirms the hardcoded plaintext value is gone); `PGUSER` is present. Also manually confirm in the file that `PGUSER`/`PGPASSWORD` entries precede `GOTIFY_DATABASE_CONNECTION` in the env list, same caveat as Task 4 Step 2 — actual `$(VAR)` substitution only happens at pod runtime.

- [ ] **Step 3: Clean up local dependency artifacts**

```bash
rm -rf Chart.lock charts
cd ../..
git status --short apps/gotify
```

Expected: clean (no untracked `Chart.lock`/`charts/`).

---

### Task 7: Final repo-wide sanity check

**Files:** none (validation only)

- [ ] **Step 1: Confirm the full diff matches intent**

```bash
git log --oneline -6
git diff main~4..main -- apps/coder apps/gotify
```

Expected: four commits (Chart.yaml, pg.yaml, values.yaml for `coder`; the `gotify` fix commit — adjust the range if commit count differs), and the diff shows only the files this plan touched: `apps/coder/Chart.yaml`, `apps/coder/templates/pg.yaml`, `apps/coder/values.yaml`, `apps/gotify/values.yaml`, and the deletion of `apps/gotify/templates/secret.yaml`.

- [ ] **Step 2: Confirm no untracked cruft remains**

```bash
git status --short
```

Expected: empty output.

---

## Explicitly out of scope

Per the design spec: workspace templates, Nix-config/nix-based workspace image integration, and `coder config-ssh` client setup are follow-up work once this control plane is deployed and merged. Post-merge ArgoCD sync verification (confirming `coder` and `gotify` Applications reach `Synced`/`Healthy`, and that `https://coder.<env_domain>` serves the first-user setup page) happens after this plan's PR is merged and is not part of these tasks.
