# Coder Template Auto-Sync CronJob — Design Spec

**Date:** 2026-08-21

## Overview

Follow-up to the nix-config Coder workspace template work
(`docs/superpowers/specs/2026-08-21-nix-coder-workspace-design.md`). That spec's
`README.md` documents `coder templates push` as a manual step, since Coder has no
GitOps-native way to sync templates from git without enterprise features. This spec
automates that step with an in-cluster CronJob, added to the existing `apps/coder`
app, and also fixes a related gap: the workspace image tag (`:latest`) can change
without anything in this repo reflecting it.

## Why in-cluster, not GitHub Actions

`coder.graytonward.com` sits behind the private-only Traefik ingress (LAN IP only,
not internet-routable), so a GitHub-hosted Actions runner can't reach it. A
CronJob running inside the same cluster as `coder-production` has no such problem —
it talks to `http://coder.coder.svc.cluster.local` directly, entirely sidestepping
the DNS/TLS issues worked through during the Phase 3 integration test (see the
`nix-coder-workspace` plan's Phase 3 notes for that saga).

## Image version tracking

The Terraform template currently references `ghcr.io/graytonio/nixos-workspace:latest`
— a floating tag. Kubernetes' default `imagePullPolicy: Always` for `:latest` means
new images already apply automatically on next pod create/restart, but silently:
no record in Coder's version history of when the image changed, no "update
available" signal for existing workspaces.

Fix: pin the image by digest, keeping the tag for Renovate's benefit —
`ghcr.io/graytonio/nixos-workspace:latest@sha256:<digest>`. Docker ignores the tag
once a digest is present (always pulls by digest, so no functional difference from
today), but the tag is what tells Renovate which stream to keep polling for a new
digest. This is Renovate's own documented recommendation for exactly this
floating-tag-plus-digest-pin scenario. When `nixos-config` publishes a new image,
Renovate opens a real, reviewable PR bumping the digest in `main.tf` — which then
flows through the CronJob's existing git-diff logic with no special-casing needed.

## Image pre-pull on change

Even with a fast template push, the first `coder create` (or `coder start` on a
stopped workspace) after an image update still has to cold-pull it — confirmed
directly during the Phase 3 integration test, where a fresh pull of this
multi-GB image took 8+ minutes on a node that hadn't cached it yet. The sync
script pre-warms every node's image cache as soon as it detects a change,
*before* anyone tries to create a workspace against it.

Mechanism: a short-lived DaemonSet whose pod spec references the new image with
a trivial `sleep` command. A DaemonSet schedules exactly one pod per node, so
applying it forces kubelet to pull the image everywhere; `kubectl rollout
status` blocks until every node's pod is `Ready` (which requires the pull to
have finished), at which point the DaemonSet is deleted. The image stays cached
in containerd on each node afterward regardless — Kubernetes doesn't evict
pulled images just because nothing currently references them; eviction only
happens under kubelet's own disk-pressure garbage collection.

This runs unconditionally at the top of `sync.sh`, decoupled from the
per-template push loop below — it needs to fire even on the (arguably more
common) case where only the image digest changed and no template *text*
changed, and it needs to complete before workspaces get created against the
new template, not after.

Requires widening `coder-template-sync`'s RBAC to include `daemonsets`
(`apps` API group): `get`/`create`/`patch`/`delete`, still scoped to the
`coder` namespace only.

## File structure

```
apps/coder/templates/
├── template-sync-cronjob.yaml   # CronJob + ServiceAccount + Role + RoleBinding
├── template-sync-script.yaml    # ConfigMap holding sync.sh
└── template-sync-secret.yaml    # ExternalSecret: Coder API token from AWS Secrets Manager

coder-templates/nix-dev/main.tf  # image line: digest-pinned instead of floating :latest

renovate.json                    # new customManagers entry tracking that digest
```

## `template-sync-secret.yaml`

Same shape as `apps/traefik`'s admin-token ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: coder-template-sync-token
  namespace: coder
spec:
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
    name: coder-template-sync-token
  data:
    - secretKey: token
      remoteRef:
        key: coder-template-sync-token
```

A Coder API token (`coder tokens create --lifetime <duration>`) must be created
once and stored in AWS Secrets Manager under the key `coder-template-sync-token`
before this syncs successfully — a manual one-time step, documented in the plan.

## `template-sync-script.yaml`

A ConfigMap holding `sync.sh`, mounted into the CronJob's pod:

```sh
#!/bin/sh
set -eu

REPO_URL="https://github.com/graytonio/homelab-flagops-templates.git"
STATE_CONFIGMAP="coder-template-sync-state"
NAMESPACE="coder"
CODER_URL="http://coder.coder.svc.cluster.local"
PREPULL_DAEMONSET="coder-template-image-prepull"

WORKDIR=$(mktemp -d)
git clone --depth 50 --quiet "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

kubectl get configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl create configmap "$STATE_CONFIGMAP" -n "$NAMESPACE"

# Pre-pull the workspace image on every node before anyone tries to create a
# workspace with it. Runs unconditionally, decoupled from the per-template
# push loop below -- must fire even when only the image digest changed and
# no template text did.
current_image=$(grep -oE 'image\s*=\s*"[^"]+nixos-workspace[^"]+"' coder-templates/nix-dev/main.tf | sed -E 's/image\s*=\s*"([^"]+)"/\1/' | head -1)
last_image=$(kubectl get configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" \
  -o jsonpath='{.data.prepulled_image}' 2>/dev/null || true)

if [ -n "$current_image" ] && [ "$current_image" != "$last_image" ]; then
  echo "Image changed ($last_image -> $current_image), pre-pulling on all nodes"
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $PREPULL_DAEMONSET
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: $PREPULL_DAEMONSET
  template:
    metadata:
      labels:
        app: $PREPULL_DAEMONSET
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: prepull
          image: $current_image
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
EOF
  kubectl rollout status daemonset/"$PREPULL_DAEMONSET" -n "$NAMESPACE" --timeout=600s
  kubectl delete daemonset "$PREPULL_DAEMONSET" -n "$NAMESPACE"

  kubectl patch configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" --type merge \
    -p "{\"data\":{\"prepulled_image\":\"${current_image}\"}}"
fi

for template_dir in coder-templates/*/; do
  template_name=$(basename "$template_dir")
  current_sha=$(git log -1 --format=%H -- "$template_dir")
  last_sha=$(kubectl get configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" \
    -o jsonpath="{.data.${template_name}}" 2>/dev/null || true)

  if [ "$current_sha" = "$last_sha" ]; then
    echo "[$template_name] unchanged since $current_sha, skipping"
    continue
  fi

  echo "[$template_name] change detected ($last_sha -> $current_sha), pushing"
  coder login "$CODER_URL" --token "$CODER_TOKEN"
  coder templates push "$template_name" -d "$template_dir" --yes

  kubectl patch configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" --type merge \
    -p "{\"data\":{\"${template_name}\":\"${current_sha}\"}}"
done
```

Loops over every `coder-templates/*/` directory (not just `nix-dev`), so adding a
second template later needs no changes here. `kubectl patch --type merge` (not
`create --dry-run | apply`, which would replace the whole ConfigMap) so multiple
templates' tracked SHAs coexist in the same state ConfigMap without clobbering
each other.

## `template-sync-cronjob.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coder-template-sync
  namespace: coder
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: coder-template-sync
  namespace: coder
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "create", "patch"]
  - apiGroups: ["apps"]
    resources: ["daemonsets"]
    verbs: ["get", "create", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: coder-template-sync
  namespace: coder
subjects:
  - kind: ServiceAccount
    name: coder-template-sync
    namespace: coder
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: coder-template-sync
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: coder-template-sync
  namespace: coder
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 600
      template:
        spec:
          serviceAccountName: coder-template-sync
          restartPolicy: Never
          containers:
            - name: sync
              image: alpine/k8s:1.36.2
              command: ["/bin/sh", "/scripts/sync.sh"]
              env:
                - name: CODER_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: coder-template-sync-token
                      key: token
              volumeMounts:
                - name: script
                  mountPath: /scripts
          volumes:
            - name: script
              configMap:
                name: coder-template-sync-script
                defaultMode: 0755
```

`coder-template-sync`'s RBAC (get/create/patch on `configmaps` only, scoped to the
`coder` namespace) is deliberately its own ServiceAccount, separate from the main
`coder` ServiceAccount's pods/PVC permissions — least privilege, and this job has
no business touching workspace Pods or PVCs at all.

`alpine/k8s:1.36.2` bundles `kubectl` (matching the cluster's `v1.36.3`), `git`,
`curl`, and `bash` — no custom image needs building for this.

`concurrencyPolicy: Forbid` prevents overlapping runs if a push ever takes longer
than 15 minutes. `activeDeadlineSeconds: 600` caps a stuck run.

## `coder-templates/nix-dev/main.tf` change

```hcl
resource "kubernetes_pod_v1" "main" {
  ...
  spec {
    container {
      ...
      image = "ghcr.io/graytonio/nixos-workspace:latest@sha256:<current-digest>"
      ...
    }
  }
}
```

The exact digest gets filled in during implementation from the actual current
`:latest` digest at that time (`nixos-config` PR #4's build, once merged).

## `renovate.json` change

New entry in the existing `customManagers` array, same shape as the current
`values.yaml` image-tag manager:

```json
{
  "customType": "regex",
  "description": "Track ghcr.io/graytonio/nixos-workspace:latest digest in the nix-dev Coder workspace template",
  "fileMatch": ["^coder-templates/nix-dev/main\\.tf$"],
  "matchStrings": [
    "image\\s*=\\s*\"(?<depName>ghcr\\.io/graytonio/nixos-workspace):(?<currentValue>latest)@(?<currentDigest>sha256:[a-f0-9]+)\""
  ],
  "datasourceTemplate": "docker"
}
```

## Manual image cache cleanup

Every digest bump leaves the *previous* image version cached on all 3 nodes
too — pre-pulling makes this worse, not better, since it guarantees each new
version actually lands everywhere rather than only on whichever node happens
to run a workspace. These images are multi-GB, so this is worth a real answer,
not just "kubelet will handle it eventually."

**Baseline (already active, no work needed):** kubelet's own image garbage
collection runs automatically once a node's disk usage crosses a threshold
(defaults to evicting unused images starting at 85% disk usage, down to 80%).
This is a real safety net, but it's reactive — usage can grow quite large
before it kicks in, and it doesn't distinguish "old workspace image" from
anything else on the node.

**Manual, on-demand purge (what was asked for — deliberately not automated):**
k3s bundles `crictl` with a `--prune` flag specifically for this: removes every
image not currently referenced by a running or pending container, in one
command per node.

```bash
ssh <node> sudo k3s crictl rmi --prune
```

Run this by hand, whenever, on whichever node(s) actually need space back —
`crictl images` first if you want to see what's cached before removing
anything. This is intentionally left as a manual command rather than folded
into the CronJob's schedule: automating cleanup of container-runtime state on
a schedule is a meaningfully different (and riskier) kind of automation than
templates/configmaps, and running it unattended isn't something this spec
proposes. A containerized alternative exists (a privileged DaemonSet running
`crictl rmi --prune` against the node's mounted containerd socket) but requires
privileged pod access to the container runtime socket — a real security
tradeoff not worth taking on for an occasional manual task.

## Explicitly out of scope

- Handling templates other than `nix-dev` — the script is written generically, but
  no second template exists yet to test against.
- Notifications on sync failure (e.g. Gotify) — could be a fast follow if the
  CronJob's `failedJobsHistoryLimit` visibility in `kubectl get jobs -n coder`
  proves insufficient in practice.

## Verification plan

- `kubectl apply --dry-run=server` (or a full ArgoCD sync) against the new
  manifests, confirm the CronJob/ServiceAccount/Role/RoleBinding/ExternalSecret
  render and sync cleanly.
- Manually trigger a run (`kubectl create job --from=cronjob/coder-template-sync
  -n coder manual-test`) rather than waiting up to 15 minutes, watch its logs,
  confirm it correctly skips (no prior changes) or pushes (after a real edit to
  `coder-templates/nix-dev/`) and updates the state ConfigMap.
- Confirm the Renovate digest manager actually fires: `renovate-config-validator`
  locally if available, or just watch for a real PR after the next `nixos-config`
  image publish.
- Confirm the pre-pull DaemonSet actually forces a pull on all 3 nodes: trigger
  a manual run after bumping the pinned digest, watch `kubectl get daemonset
  -n coder -w` reach `3 desired / 3 ready` before it gets deleted, and confirm
  via `crictl images` on a node that previously lacked it that the new image
  is now present.
