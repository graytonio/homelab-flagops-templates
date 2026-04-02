# Homelab FlagOps Project - CLAUDE.md

This project uses the FlagOps framework with ArgoCD to manage a homelab Kubernetes deployment.

## Project Overview

- **Framework**: FlagOps - feature flag-based Kubernetes configuration management
- **GitOps**: ArgoCD manages all deployments
- **Source Control**: This repository is managed by ArgoCD Autopilot
- **Environment**: Production deployments to Kubernetes clusters

## Structure

```
.
├── bootstrap/          # ArgoCD bootstrapping manifests
├── projects/           # Environment definitions (AppProject, ApplicationSet)
├── apps/               # Application Helm charts and configs
│   ├── infrastructure/ # Infrastructure services
│   │   ├── external-dns
│   │   ├── external-secrets
│   │   ├── metallb
│   │   ├── longhorn
│   │   ├── traefik
│   │   ├── observability
│   │   ├── gotify
│   │   ├── reloader
│   │   └── db-operators
│   └── user-apps/      # User-facing applications
│       ├── homeassistant
│       ├── homepage
│       ├── radarr
│       ├── sonarr
│       ├── overseerr
│       ├── pirate-ship
│       └── discord-file-sync-bot
├── projects/           # Environment YAML files
└── readme.md
```

## FlagOps Framework

### Environment Variables

Each app uses FlagOps environment variables in `values.yaml`:

```yaml
# Environment-specific variables
env:
  FLAGOPS_ENVIRONMENT: production  # staging, production, etc.
  FLAGOPS_PROP_OWNER: graytonw     # Git user who owns this resource
  FLAGOPS_PROP_CLUSTER: datacenter  # Cluster name
  FLAGOPS_PROP_TYPE: public/private # Access type
```

### Variable Substitution

Environment variables are referenced in `values.yaml` using `[{ env "VAR_NAME"}]`:

```yaml
ingress:
  host: traefik.[{ env "env_domain" }]
storageClass: [{ env "longhorn_storageclass_enabled" }]
secretName: [{ env "acme_certs.cloud_secret"}]
```

These variables are set per-environment via the ApplicationSet's environment block.

## Adding a New Application

### 1. Create app directory structure

```bash
mkdir -p apps/<app-name>/templates
```

### 2. Create Chart.yaml

```yaml
apiVersion: v2
name: <app-name>
description: <brief description>
type: application
version: 0.1.0

dependencies:
  - name: <dependency-name>
    repository: <helm-repo-url>
    version: <version>
    alias: <alias>  # Optional: for multi-instance deployments
```

### 3. Create values.yaml

```yaml
# App-specific configuration here
# Reference environment variables where needed:
# [{ env "VAR_NAME" }]
```

### 4. Create templates/ (if using Helm templates)

Place Kubernetes manifests here. Common patterns:
- `deployment.yaml`
- `service.yaml`
- `ingress.yaml`
- `secret.yaml`
- `configmap.yaml`

### 5. Set permissions

```bash
chmod 644 apps/<app-name>/*.yaml
```

## Common Helm Dependencies

### Infrastructure Dependencies

| App | Repository | Purpose |
|------|------------|---------|
| metallb | https://metallb.github.io/metallb | Baremetal LoadBalancer |
| longhorn | https://charts.longhorn.io | Block storage |
| traefik | https://traefik.github.io/charts | Ingress controller |
| cert-manager | https://charts.jetstack.io | TLS certificates |
| external-dns | https://charts.bitnami.com/bitnami | DNS management |
| observability | https://grafana.github.io/helm-charts | Monitoring |

### External Service Dependencies

Some apps use custom repositories:
- `https://charts.graytonward.com` - External service wrappers
- `https://bjw-s-labs.github.io/helm-charts/` - app-template and related

## Updating Helm Dependencies

### Automated Version Updates via Renovate

Helm version updates are managed through **Renovate PRs**:

1. Renovate automatically checks for Helm chart updates
2. Opens PRs for version changes with breaking change detection
3. Merges PRs automatically when:
   - No breaking changes detected
   - Or breaking changes addressed in PR description
4. Post-merge monitoring is automatic via:
   - ArgoCD sync verification
   - Service health check endpoints
   - Alerting if deployments fail

> **CRITICAL**: Renovate only bumps version numbers in `Chart.yaml`. It **never** updates `values.yaml`.
> For major version bumps with breaking schema changes, you **must** manually rewrite `values.yaml`
> before or alongside merging the PR, or ArgoCD will fail to sync after the merge.

**Renovate PR review workflow:**
1. Check PR title for major version bump (e.g. `1.x → 4.x` = major, research required)
2. Fetch official migration guide for the chart: `gh release list -R <org>/<repo>` or chart docs
3. Check if `values.yaml` schema changed — if so, rewrite it before merging
4. For safe (minor/patch) bumps: merge and monitor ArgoCD
5. For major bumps: prepare `values.yaml` migration on a branch, merge with the PR, then monitor

### Manual Dependency Updates (if needed)

**Update all dependencies:**
```bash
# From repository root
cd apps/<app>
helm dependency update .
helm dependency list .
```

**Validate changes before merging PR:**
```bash
cd apps/<app>
helm lint .
helm template . --debug
```

## Environment Configuration

### Projects Directory

Each environment has a YAML file defining:
- `AppProject` - ArgoCD project with permissions
- `ApplicationSet` - Dynamically creates applications from `apps/**/Chart.yaml`

### ApplicationSet Template

The ApplicationSet:
1. Scans `apps/**/Chart.yaml` files
2. Creates one Application per app
3. Sets environment variables from the project's `production.yaml` (or other env)
4. Deploys to the destination cluster

### Environment Variables by Env

Each environment (`production.yaml`, etc.) defines different variables:

```yaml
environment:
  FLAGOPS_PROP_CLUSTER: datacenter
  FLAGOPS_PROP_TYPE: production  # or staging, dev
```

## Secrets Management

### External Secrets Integration

Apps can sync secrets from AWS Secrets Manager via `external-secrets`:

1. Create ExternalSecret manifest in `templates/secret.yaml`
2. Reference the secret in `values.yaml`
3. Ensure `external-secrets` app is deployed first

### Secret Template Example

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "traefik.secret.name" . }}
spec:
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: ADMIN_TOKEN
      remoteRef:
        conversionStrategy: JSONPatch
        key: traefik-admin-token
        property: token
```

## Troubleshooting

### ArgoCD Sync Issues

**Sync stuck or failed:**
```bash
kubectl -n argocd get application <app-name> -o yaml
```

Check for:
- Resource conflicts (ignoreDifferences not enough)
- Missing dependencies (wait for other apps to deploy)
- CRD conversion webhook issues (common with Bitnami charts)

**Trigger sync without argocd CLI** (use when `argocd` binary is unavailable):
```bash
kubectl patch application <app-name> -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

**Force sync (with argocd CLI):**
```bash
kubectl -n argocd argocd app set <app-name> --sync-policy-prune=false
kubectl -n argocd argocd app sync <app-name>
```

**Watch sync status:**
```bash
kubectl -n argocd get application -w
# Or for a single app:
kubectl -n argocd get application <app-name> -o jsonpath='{.status.sync.status} {.status.health.status}'
```

### Environment Variable References

If `[{ env "VAR" }]` isn't resolved:
1. Verify the variable exists in the project's env block
2. Check the ApplicationSet generator is picking up the right file
3. Verify `FLAGOPS_ENVIRONMENT` is set correctly

### Common Chart Issues

**Bitnami external-dns:**
- Use alias pattern: `repository: {... alias: <name>}`
- Requires two deployments (public + private)
- Uses sidecar webhook for AdGuard integration

**Longhorn:**
- May need storageclass permissions
- Verify Node affinity settings
- Ingress requires domain environment variable

**Traefik (v36+):**
- JSON schema validation is strict — unknown properties in values.yaml fail the sync
- `ports.web.redirections` renamed to `ports.web.http.redirections` in v36+
- Sub-chart aliased blocks (e.g. `privateingress:`, `publicingress:`) are validated against the Traefik chart's JSON schema — do not put custom keys (like `host:`) inside them. Instead, use a top-level `hosts:` key in your wrapper chart's `values.yaml` and reference it from `templates/ingress.yaml` as `{{ .Values.hosts.private }}`.

**k8s-monitoring (Grafana, v4):**
Major schema rewrite from v1 → v4. See migration section below.

**ArgoCD bootstrap:**
- Large CRDs (e.g. `applicationsets.argoproj.io`) exceed the 262KB client-side apply annotation limit
- The `bootstrap/argo-cd.yaml` Application **must** have `ServerSideApply=true` in syncOptions
- `repository.credentials` key in argocd-cm was removed in v3; use labeled `repo-creds` Secrets instead

### AppOrder Dependencies

Some apps must deploy in order:
1. **metallb** - Load balancer first
2. **longhorn** - Storage
3. **external-secrets** - Secret syncing
4. **external-dns** - DNS (depends on adguard)
5. **traefik** - Ingress (depends on cert-manager)
6. **Apps** - Deploy after infrastructure

## Git Workflow

### Before committing changes

```bash
# Validate Helm charts
cd apps/<app>
helm lint .

# Test rendering
helm template . --debug

# Check for env var references
grep -r "env" values.yaml
```

### Commit guidelines

- Update `.gitignore` if needed
- Add `Chart.lock` when dependencies change
- Include both `Chart.yaml` and `values.yaml` in commits
- Keep templates in a `templates/` subdirectory

## CI/CD Integration

This repo is managed by ArgoCD Autopilot. Changes trigger:
1. Git push
2. ArgoCD detects changes
3. ApplicationSet creates/updates Applications
4. Helm renders with environment variables
5. Deployments sync to clusters

## Quick Reference

| Task | Command/Location |
|------|------------------|
| View deployed apps | `kubectl get apps -n argocd` |
| Check ArgoCD status | `kubectl -n argocd get application -A` |
| Trigger manual sync | `kubectl patch application <name> -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'` |
| List Helm dependencies | `helm dependency list apps/<app>/` |
| Render Helm chart | `helm template <app> apps/<app>/` |
| Find env var references | `grep -r "env" apps/*/values.yaml` |
| Check ApplicationSet | `kubectl -n argocd get applicationset production -o yaml` |
| Pre-install a CRD (server-side) | `curl -sL <crd-url> \| kubectl apply --server-side -f -` |

## Support

For issues:
1. Check ArgoCD diff view for sync issues
2. Review Helm logs in Kubernetes
3. Check project `production.yaml` for env var definitions
4. Search for similar issues in FlagOps documentation

---

## Helm Upgrade Assessment

### Check for Available Updates

Run this to find all apps with newer versions available:

```bash
cd /home/graytonio/repos/homelab-flagops-templates/apps
for dir in */; do
  if [ -f "$dir/Chart.yaml" ]; then
    name=$(basename "$dir")
    echo "== Checking $name =="
    # Check for new versions available
    repo=$(grep "repository:" "$dir/Chart.yaml" | head -1 | awk '{print $2}')
    current=$(grep "version:" "$dir/Chart.yaml" | grep -v "^apiVersion" | awk '{print $2}')
    if [ -n "$repo" ] && [ -n "$current" ]; then
      chart=$(basename "$dir")
      echo "Current: $current from $repo"
      # Find latest version
      latest=$(curl -s "https://$repo/charts/$chart/index.yaml" | \
        grep -E "^name:|^version:" | grep "name: $chart" | grep -v "^name: [a-z]*$chart" | \
        head -1 | awk '{print $2}' | head -1)
      if [ -n "$latest" ] && [ "$latest" != "$current" ]; then
        echo "Latest: $latest (diff: $(echo $latest $current | tr ' ' '\n' | sort | uniq | tail -1))"
      fi
    fi
    echo ""
  fi
done
```

### Least Disruptive Upgrade Strategy

**Priority order (safe to upgrade):**

1. **Low risk** - Non-critical infrastructure (logging, monitoring):
   - `observability` (k8s-monitoring)
   - `gotify` (notification server)
   - `homepage` (web portal)

2. **Medium risk** - Configuration-focused services:
   - `reloader` (configmap watcher)
   - `discord-file-sync-bot`
   - `pirate-ship` (servarr)

3. **Higher risk** - Core infrastructure:
   - `metallb` (load balancer) ⚠️ **Never upgrade during traffic**
   - `longhorn` (storage) ⚠️ **Requires storageclass changes**
   - `external-dns` ⚠️ **DNS record management**
   - `external-secrets` ⚠️ **Secret syncing**
   - `traefik` (ingress) ⚠️ **Route changes during deploy**

4. **Highest risk** - Stateful dependencies:
   - `db-operators` ⚠️ **Database migration concerns**

**Renovate workflow:**
1. Renovate PR opens → review breaking change notes
2. Check ArgoCD diff for expected changes
3. For low/medium risk: merge PR, monitor ArgoCD
4. For high risk: merge in off-peak hours, verify services

**Renovate handles:**
- Dependency version checking
- Breaking change detection
- PR merging when safe
- Post-merge deployment monitoring

**Manual upgrade command (if needed):**
```bash
helm dependency update apps/<app>/
git add apps/<app>/Chart.yaml apps/<app>/Chart.lock
git commit -m "chore: upgrade <app> to v<version>"
git push  # Triggers ArgoCD sync
```

---

## Major Version Migration Notes

### k8s-monitoring v1 → v4 (Grafana)

Complete schema rewrite. Key changes:

| v1 key | v4 key |
|--------|--------|
| `externalServices.prometheus` / `externalServices.loki` | `destinations.<name>` map |
| `metrics.enabled` / `metrics.cost.enabled` | `clusterMetrics.enabled: true` + `collector: alloy` |
| `logs.pod_logs.enabled` | `podLogsViaLoki.enabled: true` + `collector: alloy-logs` |
| `logs.cluster_events.enabled` | `clusterEvents.enabled: true` + `collector: alloy-logs` |
| `alloy` / `alloy-logs` top-level keys | `collectors.alloy` / `collectors.alloy-logs` map |
| `prometheus-operator-crds` dependency | Removed entirely |

Every feature block (`clusterMetrics`, `hostMetrics`, `podLogsViaLoki`, `clusterEvents`) **must** have an explicit `collector:` field.

`alloy-logs` **must** include `presets: [filesystem-log-reader, daemonset]` or pod log collection fails.

**Alloy Operator CRD bootstrap problem:**
v4 uses the `collectors.grafana.com/Alloy` CRD managed by the alloy-operator. ArgoCD will refuse to sync ("synchronization tasks are not valid") if this CRD doesn't exist yet because the operator and CRs are in the same Helm release. Fix: pre-install the CRD manually:
```bash
curl -sL "https://github.com/grafana/alloy-operator/releases/download/alloy-operator-0.5.2/collectors.grafana.com_alloy.yaml" \
  | kubectl apply --server-side -f -
```

**extraConfig `forward_to` references:**
In v4, destination names are used directly (with hyphens converted to underscores) in Alloy config:
```alloy
# destination named "grafana-cloud-prometheus" becomes:
forward_to = [prometheus.remote_write.grafana_cloud_prometheus.receiver]
```
Old v1 internal component names like `prometheus.relabel.metrics_service.receiver` no longer exist.

**extraConfig discovery components:**
v4 does not provide global `discovery.kubernetes` components. If your `extraConfig` scrapes services or pods, declare them explicitly at the top of `extraConfig`:
```alloy
discovery.kubernetes "services" {
  role = "service"
}
discovery.kubernetes "pods" {
  role = "pod"
}
```

---

### Traefik v36+ Schema Changes

- `ports.web.redirections` → `ports.web.http.redirections`
- Sub-chart alias blocks (`privateingress:`, `publicingress:`) are validated against Traefik's JSON schema. Never add non-Traefik keys (e.g. `host:`) directly inside these blocks. Use a top-level `hosts:` block in the wrapper chart's `values.yaml`:

```yaml
# values.yaml (wrapper chart level, not inside alias block)
hosts:
  private: traefik.private.[{ env "env_domain" }]
  public: traefik.public.[{ env "env_domain" }]

privateingress:
  ports:
    web:
      http:
        redirections:
          entryPoint:
            to: websecure
            scheme: https
            permanent: true
```

---

### ArgoCD v2 → v3 Upgrade Procedure

**Pre-upgrade steps (do before merging PR):**

1. Update **both** the image tag AND the install manifest URL in `bootstrap/argo-cd/kustomization.yaml`:
   ```yaml
   images:
   - name: quay.io/argoproj/argocd
     newTag: v3.3.6   # update image tag

   resources:
   - https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.6/manifests/ha/install.yaml  # must match!
   ```

2. Update all CMP sidecar container images in `bootstrap/argo-cd/argocd-repo-server.yaml` to match the new version.

3. Migrate `repository.credentials` (removed in v3). Create a `repo-creds` labeled Secret before merging:
   ```bash
   kubectl create secret generic argocd-github-repo-creds \
     -n argocd \
     --from-literal=type=git \
     --from-literal=url=https://github.com/ \
     --from-literal=username=<git-username> \
     --from-literal=password=<git-token> \
     --dry-run=client -o yaml \
     | kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
     | kubectl apply -f -
   ```
   Then remove the `repository.credentials` literal from the `argocd-cm` configMapGenerator.

4. Ensure `bootstrap/argo-cd.yaml` has `ServerSideApply=true` in syncOptions (required for large v3 CRDs):
   ```yaml
   syncPolicy:
     syncOptions:
     - allowEmpty=true
     - ServerSideApply=true
   ```

**Post-upgrade:**
- Watch the `argo-cd` application sync; it self-manages so it will rolling-restart its own pods
- If sync gets stuck on CRD size limit error, apply ServerSideApply patch to the live Application:
  ```bash
  kubectl patch application argo-cd -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"syncOptions":["allowEmpty=true","ServerSideApply=true"]}}}'
  ```

---

## Current Deployed Versions (as of 2026-04-02)

| App | Version |
|-----|---------|
| ArgoCD | v3.3.6 |
| k8s-monitoring | 4.0.0 |
| traefik (public + private) | v39.x |
| longhorn | (latest at time of upgrade) |
| external-secrets | v2.x |
| postgres-operator | (latest at time of upgrade) |

---

*Last updated: 2026-04-02*

## Tool Permissions

Curl commands are enabled for fetching release notes, Helm chart indexes, and external documentation. Use curl with these patterns:

- `curl -sL <url>` - Fetch release notes and documentation
- `curl -s <url>` - Fetch raw YAML/JSON data
- `curl -s --retry 3 --retry-delay 2 <url>` - Retry failed requests

Curl is safe to use for:
- Fetching GitHub release notes
- Checking Helm repository indexes
- Getting external documentation
- Validating API responses

Never use curl to:
- Upload sensitive data
- Send requests to untrusted endpoints without review
- Bypass authentication requirements

## GitHub CLI for PR Research

When researching PRs and their changes, always use the GitHub CLI (`gh`) instead of fetching directly from GitHub URLs:

- `gh pr view <number> --json title,createdAt,state,url -q '.title'`
- `gh pr diff <number> --name-status` - See what files changed
- `gh pr list --state all` - List all PRs

Use `gh` because:
- It provides structured JSON output for parsing
- It's faster than browser-based fetches
- It respects your auth token for private repos
- The CLI tool can be called repeatedly without rate limiting issues