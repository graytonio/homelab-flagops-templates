# Nix-config Coder Workspace Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the user a Coder workspace template that boots a persistent dev environment with their `nixos-config` tooling, spanning two repositories: `graytonio/nixos-config` (builds/publishes the workspace image) and this repo (the Coder Terraform template that runs it).

**Architecture:** A `Dockerfile` in `nixos-config` bakes `homeConfigurations.shell-linux` (via `nix run --impure .#homeConfigurations.shell-linux.activationPackage`) into an image, published to `ghcr.io/graytonio/nixos-workspace` by a GitHub Actions workflow on push to `main`. A new `coder-templates/nix-dev/` directory in this repo holds a Terraform template (`kubernetes` provider, in-cluster auth via the `coder` ServiceAccount's already-granted RBAC) that runs that image as a `kubernetes_pod`, backed by a persistent `kubernetes_persistent_volume_claim` for `/home/coder` that survives workspace stop/start.

**Tech Stack:** Nix flakes, home-manager, Docker, GitHub Actions, Terraform (`coder` and `hashicorp/kubernetes` providers), Coder CLI.

**Decisions made during planning** (deferred in the spec, resolved here):
- Container runs as **root** (no separate `coder` unix user, no non-root `securityContext`). This is a personal single-user homelab, not a multi-tenant environment — the Longhorn PVC mounted at `/home/coder` is root-owned by default, and running the container as root sidesteps the UID-matching problem entirely rather than fighting it.
- PVC uses `storageClassName = "longhorn"` explicitly (confirmed the cluster's default StorageClass via `kubectl get storageclass`).

Reference spec: `docs/superpowers/specs/2026-08-21-nix-coder-workspace-design.md`

---

## Phase 1: `nixos-config` (separate repo, PR only — do not merge)

### Task 1: Clone `nixos-config` and create a branch

**Files:** none (setup only)

- [ ] **Step 1: Clone into the scratchpad and branch**

```bash
mkdir -p /tmp/claude-1000/-home-graytonio-repos-homelab-flagops-templates/0acc0e27-28ab-44c3-97ef-d5ad75901a11/scratchpad
cd /tmp/claude-1000/-home-graytonio-repos-homelab-flagops-templates/0acc0e27-28ab-44c3-97ef-d5ad75901a11/scratchpad
git clone https://github.com/graytonio/nixos-config.git
cd nixos-config
git checkout -b feature/coder-workspace-image
```

Expected: clone succeeds, new branch created, `git status` clean.

---

### Task 2: Add the workspace Dockerfile

**Files:**
- Create: `coder/Dockerfile` (in the `nixos-config` clone from Task 1)

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

ENV USER=coder
ENV HOME=/home/coder
ENV PATH="/home/coder/.nix-profile/bin:${PATH}"
RUN mkdir -p "$HOME"

WORKDIR /flake
COPY . .

RUN nix run --impure /flake#homeConfigurations.shell-linux.activationPackage

WORKDIR $HOME
```

This uses the flake's own locked `home-manager` input (via `nix run .../activationPackage`, home-manager's standard documented way to activate a standalone `homeConfigurations` output) rather than fetching `home-manager` fresh from its `master` branch — matches what `flake.lock` actually pins, so the image reflects the exact same versions the user's own `nixup` alias would produce. `--impure` is required because `systems/shell/home.nix` reads `$USER`/`$HOME` via `builtins.getEnv`. Single-stage build: `/nix/store` and the home-manager profile symlinks under `/home/coder` just become part of the final image's layers.

- [ ] **Step 2: Commit**

```bash
git add coder/Dockerfile
git commit -m "feat(coder): add workspace image Dockerfile"
```

---

### Task 3: Add the image-build GitHub Actions workflow

**Files:**
- Create: `.github/workflows/coder-workspace-image.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: coder-workspace-image

on:
  push:
    branches: [main]
    paths:
      - flake.nix
      - flake.lock
      - modules/**
      - systems/shell/**
      - coder/Dockerfile

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: coder/Dockerfile
          push: true
          tags: |
            ghcr.io/graytonio/nixos-workspace:latest
            ghcr.io/graytonio/nixos-workspace:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Validate the YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/coder-workspace-image.yml'))" && echo "valid YAML"
```

Expected: `valid YAML`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/coder-workspace-image.yml
git commit -m "feat(coder): build and publish workspace image to GHCR on push"
```

---

### Task 4: Push the branch and open a PR (do not merge)

**Files:** none

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feature/coder-workspace-image
gh pr create --title "Add Coder workspace image build" --body "$(cat <<'EOF'
## Summary
- Adds coder/Dockerfile that bakes homeConfigurations.shell-linux into an image via home-manager's activationPackage
- Adds a GitHub Actions workflow that builds and pushes to ghcr.io/graytonio/nixos-workspace on push to main

Part of the homelab Coder remote-dev-environment work — see
graytonio/homelab-flagops-templates docs/superpowers/specs/2026-08-21-nix-coder-workspace-design.md

## Test plan
- [ ] CI build succeeds and pushes the image
- [ ] `docker run --rm -it ghcr.io/graytonio/nixos-workspace:latest fish -c 'go version; kubectl version --client'` shows expected tools

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. **Do not merge this PR** — merging `nixos-config` is the user's call. Report the PR URL and stop here for Phase 1; Task 11 (final integration test) depends on this PR being merged and CI having run.

---

## Phase 2: `homelab-flagops-templates` (this repo)

### Task 5: Set up an isolated worktree

**Files:** none (setup only)

- [ ] **Step 1: Create the worktree**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
git worktree add .worktrees/nix-coder-workspace -b feature/nix-coder-workspace-template
cd .worktrees/nix-coder-workspace
```

Expected: new worktree created (`.worktrees/` is already gitignored from the earlier Coder control plane work), branch checked out.

---

### Task 6: Write the Terraform template

**Files:**
- Create: `coder-templates/nix-dev/main.tf` (in the worktree from Task 5)

- [ ] **Step 1: Write main.tf**

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
  }
}

provider "coder" {}

# config_path = null triggers in-cluster auto-auth -- Terraform runs inside
# the coder-production pod itself, using the coder ServiceAccount, which
# already has full CRUD on pods/persistentvolumeclaims in this namespace
# (chart default serviceAccount.workspacePerms: true).
provider "kubernetes" {
  config_path = null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"
}

# No `count` here -- this must persist across workspace stop/start, unlike
# the pod below.
resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}-home"
    namespace = "coder"
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

# start_count is 0 when the workspace is stopped and 1 when running -- this
# is what makes Coder's stop/start actually delete/recreate the pod while
# the PVC above stays put.
resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    namespace = "coder"
  }
  spec {
    container {
      name    = "dev"
      image   = "ghcr.io/graytonio/nixos-workspace:latest"
      command = ["sh", "-c", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add coder-templates/nix-dev/main.tf
git commit -m "feat(coder-templates): add nix-dev workspace Terraform template"
```

---

### Task 7: Write the push-instructions README

**Files:**
- Create: `coder-templates/nix-dev/README.md`

- [ ] **Step 1: Write the README**

```markdown
# nix-dev Coder workspace template

Runs `ghcr.io/graytonio/nixos-workspace` (built from
[graytonio/nixos-config](https://github.com/graytonio/nixos-config),
`coder/Dockerfile`) as a Kubernetes Pod in the `coder` namespace, with a
Longhorn-backed PersistentVolumeClaim mounted at `/home/coder` that survives
workspace stop/start.

This directory is **not** ArgoCD-managed — Coder has no GitOps-native way to
sync templates from git without enterprise features, so pushing it is a
manual step.

## Push this template

```bash
coder login https://coder.graytonward.com
coder templates push nix-dev -d coder-templates/nix-dev/
```

Re-run `coder templates push` whenever this directory or the
`nixos-workspace` image tag changes.

## Prerequisites

The `ghcr.io/graytonio/nixos-workspace:latest` image must exist before
creating a workspace from this template — see the `nixos-config` repo's
`coder-workspace-image` GitHub Actions workflow. Pushing this template
without the image existing will succeed, but the first workspace creation
will fail with `ImagePullBackOff`.
```

- [ ] **Step 2: Commit**

```bash
git add coder-templates/nix-dev/README.md
git commit -m "docs(coder-templates): add nix-dev push instructions"
```

---

### Task 8: Validate the Terraform template

**Files:** none (validation only)

- [ ] **Step 1: Install terraform**

```bash
nix profile install nixpkgs#terraform
terraform version
```

Expected: prints a Terraform version (e.g. `Terraform v1.x.x`).

- [ ] **Step 2: Format check and validate**

```bash
cd coder-templates/nix-dev
terraform fmt -check
terraform init -backend=false
terraform validate
```

Expected: `terraform fmt -check` prints nothing (already formatted — if it lists `main.tf`, run `terraform fmt` and re-commit); `terraform init` downloads the `coder` and `kubernetes` providers successfully; `terraform validate` prints `Success! The configuration is valid.`

If `terraform validate` reports an error (e.g. a provider attribute name that's changed since this plan was written), fix `main.tf` to match the actual provider schema reported in the error, re-run `terraform validate`, and amend the Task 6 commit rather than leaving broken HCL committed.

- [ ] **Step 3: Clean up local Terraform state/plugin artifacts**

```bash
rm -rf .terraform .terraform.lock.hcl
cd ../..
git status --short coder-templates/
```

Expected: clean (nothing untracked left behind — this repo's convention throughout is not to commit locally-generated dependency/lock artifacts, matching how `Chart.lock`/`charts/` are handled for Helm apps).

---

### Task 9: Push the branch and open a PR

**Files:** none

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feature/nix-coder-workspace-template
gh pr create --title "Add nix-dev Coder workspace template" --body "$(cat <<'EOF'
## Summary
- Adds coder-templates/nix-dev/, a Terraform workspace template that runs
  ghcr.io/graytonio/nixos-workspace as a Pod in the coder namespace with a
  persistent /home/coder PVC
- Not ArgoCD-managed; coder-templates/nix-dev/README.md documents the
  `coder templates push` step

Depends on the nixos-config PR (workspace image build) being merged and its
CI run completing before the template can actually be pushed/tested against
a real image.

Design spec: docs/superpowers/specs/2026-08-21-nix-coder-workspace-design.md

## Test plan
- [x] `terraform fmt -check` / `terraform validate` pass
- [ ] `coder templates push nix-dev -d coder-templates/nix-dev/` succeeds
- [ ] Test workspace creation succeeds, agent shows Connected, `coder config-ssh` + `ssh` works
- [ ] `/home/coder` survives a stop/start cycle

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## Phase 3: Integration (blocked on Phase 1 merge)

### Task 10: Push the template and create a test workspace

**Files:** none (operational verification, not a code change)

**Precondition:** the `nixos-config` PR from Task 4 must be merged by the user, and its GitHub Actions run must have completed successfully, before this task can produce a working workspace. Check first:

- [ ] **Step 1: Confirm the image exists**

```bash
gh api /users/graytonio/packages/container/nixos-workspace/versions --jq '.[0].metadata.container.tags' 2>&1
```

Expected: a list including `latest`. If this errors (package/image doesn't exist yet) or the `nixos-config` PR isn't merged, **stop here and report status to the user** rather than proceeding — do not fabricate a successful test.

- [ ] **Step 2: Push the template**

```bash
cd /home/graytonio/repos/homelab-flagops-templates/.worktrees/nix-coder-workspace
coder login https://coder.graytonward.com
coder templates push nix-dev -d coder-templates/nix-dev/ --yes
```

Expected: template push succeeds.

- [ ] **Step 3: Create a test workspace and verify**

```bash
coder create --template nix-dev nix-dev-test --yes
coder ssh nix-dev-test -- 'fish -c "go version; kubectl version --client; echo HOME=$HOME"'
```

Expected: the SSH command runs successfully inside the workspace and shows real Go/kubectl versions and `HOME=/home/coder` — confirms the agent connected, the image's tools are on PATH, and the container came up correctly.

- [ ] **Step 4: Verify PVC persistence across stop/start**

```bash
coder ssh nix-dev-test -- 'echo persisted-marker > /home/coder/test-marker.txt'
coder stop nix-dev-test --yes
coder start nix-dev-test --yes
coder ssh nix-dev-test -- 'cat /home/coder/test-marker.txt'
```

Expected: `persisted-marker` printed after restart, confirming the PVC (not the pod) is what's carrying state.

- [ ] **Step 5: Clean up the test workspace**

```bash
coder delete nix-dev-test --yes
```

Expected: test workspace removed (the PVC from Task 6's `kubernetes_persistent_volume_claim` may or may not be deleted automatically depending on Coder's resource lifecycle for non-`count`-gated resources tied to a deleted workspace — verify with `kubectl get pvc -n coder` after deletion and manually `kubectl delete pvc` if it was orphaned).

---

## Explicitly out of scope

- Trimming `modules/apps` (Firefox/Ghostty) out of the `shell-linux` profile — accepted as-is for v1 per the design spec.
- A browser code-editor (`coder_app` for code-server) — Coder's own dashboard/web terminal covers this for v1.
- Merging either PR — both are opened for the user's review; this plan does not merge them.
