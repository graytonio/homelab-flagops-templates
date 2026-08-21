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

WORKDIR=$(mktemp -d)
git clone --depth 50 --quiet "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

kubectl get configmap "$STATE_CONFIGMAP" -n "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl create configmap "$STATE_CONFIGMAP" -n "$NAMESPACE"

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
