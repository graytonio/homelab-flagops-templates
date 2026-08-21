# Coder Template Auto-Sync CronJob Implementation Plan

> **For agentic workers:** This plan is executed via two parallel implementer subagents, each in its own isolated worktree, since Task Group A and Task Group B touch entirely disjoint files with no dependency between them. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate `coder templates push` via an in-cluster CronJob, add image-change pre-pulling, and switch the workspace image reference to a Renovate-trackable digest pin.

**Architecture:** Task Group A adds a CronJob + its own ServiceAccount/Role/RoleBinding + a script ConfigMap + an ExternalSecret to `apps/coder/templates/`. Task Group B pins `coder-templates/nix-dev/main.tf`'s image reference to a specific digest and adds a Renovate `customManagers` entry to track it. Both groups are independently testable and mergeable.

**Tech Stack:** Kubernetes CronJob/DaemonSet/RBAC, `alpine/k8s` image, `sh`, `kubectl`, `git`, `coder` CLI, Renovate `customManagers` (regex).

Reference spec: `docs/superpowers/specs/2026-08-21-coder-template-sync-cronjob-design.md`

Current `ghcr.io/graytonio/nixos-workspace:latest` digest (fetched at plan time):
`sha256:8a90bbb1ec92be3720b1d9cceffbbea1862d90099548fe9cb365c6b27a98b168`

---

## Task Group A: CronJob + RBAC + script + secret

**Worktree:** `.worktrees/coder-template-sync-manifests`, branch `feature/coder-template-sync-manifests`

**Files:**
- Create: `apps/coder/templates/template-sync-secret.yaml`
- Create: `apps/coder/templates/template-sync-script.yaml`
- Create: `apps/coder/templates/template-sync-cronjob.yaml`

### Task A1: ExternalSecret for the Coder API token

- [ ] **Step 1: Write `apps/coder/templates/template-sync-secret.yaml`**

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

- [ ] **Step 2: Commit**

```bash
git add apps/coder/templates/template-sync-secret.yaml
git commit -m "feat(coder): add ExternalSecret for template-sync API token"
```

### Task A2: Script ConfigMap

- [ ] **Step 1: Write `apps/coder/templates/template-sync-script.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coder-template-sync-script
  namespace: coder
data:
  sync.sh: |
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

    # Pre-pull the workspace image on every node before anyone tries to
    # create a workspace with it. Runs unconditionally, decoupled from the
    # per-template push loop below -- must fire even when only the image
    # digest changed and no template text did.
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

- [ ] **Step 2: Validate the YAML parses and the embedded script is valid shell**

```bash
cd apps/coder
python3 -c "import yaml; d = yaml.safe_load(open('templates/template-sync-script.yaml')); print('YAML OK'); open('/tmp/sync.sh', 'w').write(d['data']['sync.sh'])"
sh -n /tmp/sync.sh && echo "sync.sh: syntax OK"
```

Expected: `YAML OK` then `sync.sh: syntax OK` (a `sh -n` syntax-only check, doesn't execute anything).

- [ ] **Step 3: Commit**

```bash
git add apps/coder/templates/template-sync-script.yaml
git commit -m "feat(coder): add template-sync script ConfigMap"
```

### Task A3: CronJob + ServiceAccount + RBAC

- [ ] **Step 1: Write `apps/coder/templates/template-sync-cronjob.yaml`**

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

- [ ] **Step 2: Validate the YAML parses**

```bash
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('apps/coder/templates/template-sync-cronjob.yaml')))
assert len(docs) == 4, f'expected 4 documents, got {len(docs)}'
kinds = [d['kind'] for d in docs]
assert kinds == ['ServiceAccount', 'Role', 'RoleBinding', 'CronJob'], kinds
print('YAML OK:', kinds)
"
```

Expected: `YAML OK: ['ServiceAccount', 'Role', 'RoleBinding', 'CronJob']`.

- [ ] **Step 3: Commit**

```bash
git add apps/coder/templates/template-sync-cronjob.yaml
git commit -m "feat(coder): add template-sync CronJob and RBAC"
```

### Task A4: Full-chart render validation

- [ ] **Step 1: Render the whole `apps/coder` chart and confirm the new resources appear correctly**

```bash
cd apps/coder
helm dependency update . >/dev/null 2>&1
helm template . --debug > /tmp/coder-full-render.yaml 2>&1
grep -c "^kind: CronJob$" /tmp/coder-full-render.yaml
grep -c "^kind: ExternalSecret$" /tmp/coder-full-render.yaml
grep -n "schedule:" /tmp/coder-full-render.yaml
rm -rf Chart.lock charts
```

Expected: both `grep -c` calls print `1` (exactly one CronJob, one ExternalSecret in the whole chart — confirms no accidental duplication and that these plain-YAML templates coexist fine alongside the chart's Helm-templated resources), and `schedule:` shows `*/15 * * * *`.

- [ ] **Step 2: Confirm no untracked artifacts remain**

```bash
cd ../..
git status --short apps/coder
```

Expected: clean.

### Task A5: Push and open a PR

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feature/coder-template-sync-manifests
gh pr create --title "Add Coder template auto-sync CronJob" --body "$(cat <<'EOF'
## Summary
- Adds a CronJob (every 15m) that pushes coder-templates/*/ changes to the
  live Coder deployment automatically, running in-cluster to avoid the
  private-ingress reachability problem a GitHub Actions runner would hit
- Pre-pulls a new workspace image on all nodes via a short-lived DaemonSet
  when the pinned image digest changes
- New coder-template-sync ServiceAccount/Role/RoleBinding, scoped to
  configmaps + daemonsets in the coder namespace only

Design spec: docs/superpowers/specs/2026-08-21-coder-template-sync-cronjob-design.md

## Prerequisite (manual, one-time, before this actually syncs anything)
A Coder API token must exist in AWS Secrets Manager under the key
`coder-template-sync-token`:
```
coder tokens create --lifetime 8760h
# store the printed token in AWS Secrets Manager as coder-template-sync-token
```

## Test plan
- [x] helm template renders the new resources correctly (CronJob, ExternalSecret,
      ServiceAccount/Role/RoleBinding), no duplication
- [ ] After merge + the token exists: manually trigger a run
      (`kubectl create job --from=cronjob/coder-template-sync -n coder manual-test`),
      confirm it pushes/skips correctly and updates the state ConfigMap

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## Task Group B: Digest-pinned image + Renovate tracking

**Worktree:** `.worktrees/coder-template-sync-digest-pin`, branch `feature/coder-template-sync-digest-pin`

**Files:**
- Modify: `coder-templates/nix-dev/main.tf`
- Modify: `renovate.json`

### Task B1: Pin the workspace image by digest

- [ ] **Step 1: Change the image line in `coder-templates/nix-dev/main.tf`**

Find the `container` block's `image` line:
```hcl
      image   = "ghcr.io/graytonio/nixos-workspace:latest"
```
Change it to:
```hcl
      image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:8a90bbb1ec92be3720b1d9cceffbbea1862d90099548fe9cb365c6b27a98b168"
```

Also update the `init_container` block's `image` line (it references the same image, for the home-seeding copy step) the same way:
```hcl
      image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:8a90bbb1ec92be3720b1d9cceffbbea1862d90099548fe9cb365c6b27a98b168"
```

Both the `init_container` and the main `container` must reference the identical pinned image — they need to be running the exact same build for the home-seed copy step to make sense (copying from a different image version than what the main container actually runs would seed stale/mismatched content).

- [ ] **Step 2: Validate**

```bash
NIXPKGS_ALLOW_UNFREE=1 nix profile install nixpkgs#terraform --impure 2>&1 | tail -3
cd coder-templates/nix-dev
terraform fmt -check
terraform init -backend=false >/dev/null 2>&1 && terraform validate 2>&1
rm -rf .terraform .terraform.lock.hcl
cd ../..
git status --short coder-templates/
```

Expected: `terraform fmt -check` prints nothing, `terraform validate` prints `Success! The configuration is valid.`, `git status --short` shows only `coder-templates/nix-dev/main.tf` modified (no untracked `.terraform`/lock file left behind).

- [ ] **Step 3: Commit**

```bash
git add coder-templates/nix-dev/main.tf
git commit -m "fix(coder-templates): pin workspace image by digest instead of floating :latest"
```

### Task B2: Renovate tracking for the digest

- [ ] **Step 1: Add a new entry to `renovate.json`'s `customManagers` array**

Current `renovate.json`:
```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended"
  ],
  "assignees": [
    "graytonio"
  ],
  "customManagers": [
    {
      "customType": "regex",
      "description": "Track container image tags in values.yaml files that use FlagOps template syntax (invalid YAML, skipped by helm-values manager)",
      "fileMatch": ["apps/.+/values\\.yaml$"],
      "matchStrings": [
        "repository: (?<depName>[^\\n\\[]+)\\n\\s+tag: (?<currentValue>[^\\n\\[]+)"
      ],
      "datasourceTemplate": "docker"
    }
  ]
}
```

Add a second entry to the `customManagers` array (keep the existing one unchanged):
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

So the full file becomes:
```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended"
  ],
  "assignees": [
    "graytonio"
  ],
  "customManagers": [
    {
      "customType": "regex",
      "description": "Track container image tags in values.yaml files that use FlagOps template syntax (invalid YAML, skipped by helm-values manager)",
      "fileMatch": ["apps/.+/values\\.yaml$"],
      "matchStrings": [
        "repository: (?<depName>[^\\n\\[]+)\\n\\s+tag: (?<currentValue>[^\\n\\[]+)"
      ],
      "datasourceTemplate": "docker"
    },
    {
      "customType": "regex",
      "description": "Track ghcr.io/graytonio/nixos-workspace:latest digest in the nix-dev Coder workspace template",
      "fileMatch": ["^coder-templates/nix-dev/main\\.tf$"],
      "matchStrings": [
        "image\\s*=\\s*\"(?<depName>ghcr\\.io/graytonio/nixos-workspace):(?<currentValue>latest)@(?<currentDigest>sha256:[a-f0-9]+)\""
      ],
      "datasourceTemplate": "docker"
    }
  ]
}
```

- [ ] **Step 2: Validate the JSON parses and matches the target line**

```bash
python3 -c "
import json, re
cfg = json.load(open('renovate.json'))
assert len(cfg['customManagers']) == 2, cfg['customManagers']
pattern = cfg['customManagers'][1]['matchStrings'][0]
target = open('coder-templates/nix-dev/main.tf').read()
m = re.search(pattern, target)
assert m, 'regex did not match main.tf'
print('depName:', m.group('depName'))
print('currentValue:', m.group('currentValue'))
print('currentDigest:', m.group('currentDigest'))
"
```

Expected:
```
depName: ghcr.io/graytonio/nixos-workspace
currentValue: latest
currentDigest: sha256:8a90bbb1ec92be3720b1d9cceffbbea1862d90099548fe9cb365c6b27a98b168
```

If this doesn't match, the regex or the `main.tf` edit from Task B1 has a typo — fix whichever is wrong and re-run this validation before committing.

- [ ] **Step 3: Commit**

```bash
git add renovate.json
git commit -m "feat: track nix-dev workspace image digest with Renovate"
```

### Task B3: Push and open a PR

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feature/coder-template-sync-digest-pin
gh pr create --title "Pin nix-dev workspace image by digest, track with Renovate" --body "$(cat <<'EOF'
## Summary
- coder-templates/nix-dev/main.tf now pins ghcr.io/graytonio/nixos-workspace
  by digest instead of floating :latest -- Docker ignores the tag once a
  digest is present (identical pull behavior), but keeping the tag lets
  Renovate know which stream to keep polling
- renovate.json: new customManagers entry tracks that digest, same shape as
  the existing values.yaml image-tag manager

Design spec: docs/superpowers/specs/2026-08-21-coder-template-sync-cronjob-design.md

## Test plan
- [x] terraform validate passes
- [x] Renovate regex confirmed to actually match the new main.tf line (verified
      the exact depName/currentValue/currentDigest captures locally)
- [ ] Watch for a real Renovate PR after the next nixos-config image publish

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## Explicitly out of scope

- Actually creating the Coder API token and storing it in AWS Secrets Manager —
  a manual step the PR description documents but this plan doesn't perform
  (needs interactive `coder login` as the user, not something to automate).
- Merging either PR — both are opened for review, matching how every other
  piece of this feature has landed this session.
- Testing the CronJob's actual scheduled execution against the live cluster —
  the manual-trigger test in Task A5's PR description is the closest
  pre-merge check; full validation needs the token to exist first.
