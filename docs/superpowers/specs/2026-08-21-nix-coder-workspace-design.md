# Nix-config Coder Workspace Template — Design Spec

**Date:** 2026-08-21

## Overview

Follow-up to the Coder control plane (`docs/superpowers/specs/2026-08-20-coder-control-plane-design.md`),
explicitly scoped out of that spec: give the user a Coder workspace template that boots a persistent
dev environment with their normal `nixos-config` (https://github.com/graytonio/nixos-config) tooling —
reachable via Coder's web terminal/dashboard and real `ssh` (`coder config-ssh`), matching the original
ask (terminal + SSH + web interface + their own dev tools).

This spans two repositories:
- **`nixos-config`** (`graytonio/nixos-config`) — builds and publishes the workspace container image.
- **`homelab-flagops-templates`** (this repo) — the Coder workspace Terraform template that runs it.

Base commit for the `nixos-config` PR: `8daf918fee875206b391329b38b904a3167362c7` (main, at spec time).

## Why Terraform is unavoidable

Investigated during brainstorming: Coder's self-hosted workspace/template system is fundamentally built on
Terraform — the provisioner daemon (already running inside the `coder-production` pod, via the chart's
default `workspacePerms: true` RBAC) executes Terraform to create/destroy every workspace, and there is no
CRD-native or pure-YAML template mode, even for "point at existing compute" scenarios. The practical impact
is small, though: Terraform's *output* here is nothing exotic (a plain `kubernetes_pod` + `kubernetes_persistent_volume_claim`,
no CRDs), and Coder manages its own Terraform state internally in the Postgres database the control plane
already has — there's no separate state backend or CI tool to introduce. `coder templates push` is the one
unavoidable imperative step (Coder has no GitOps-native "sync templates from git" without enterprise features).

Confirmed directly from the chart's vendored templates (`charts/libcoder/templates/_rbac.yaml`,
`_helpers.tpl`) that the `coder` ServiceAccount already has full CRUD on `pods` and
`persistentvolumeclaims` in the `coder` namespace via the chart's default
`serviceAccount.workspacePerms: true` / `enableDeployments: true` — already active in the deployed
`coder-production` release, no additional RBAC changes needed.

## Phase 1 — `nixos-config`: workspace image

### Flake context

`flake.nix` already defines `homeConfigurations."shell-linux" = mkHome "x86_64-linux" ./systems/shell/home.nix`,
which imports `modules/base` (fish, nvim, starship, tmux, yazi, git, common CLI tools) + `modules/dev`
(go/python/rust/node/kotlin toolchains, `k8s.nix`, docker CLI, postgresql client, etc.) + `modules/apps`
(Firefox, Ghostty — GUI packages that don't belong in a headless container).

**Decision:** use `shell-linux` as-is for v1, accepting the GUI-package bloat/build cost. Trimming
`modules/apps` out into a separate headless-specific profile is a fast-follow, not blocking this work.

`systems/shell/home.nix` requires `--impure` on Linux (reads `$USER`/`$HOME` via `builtins.getEnv`), so the
build must set `USER`/`HOME` env vars and pass `--impure` to `home-manager switch`.

### New files

```
nixos-config/
├── coder/
│   └── Dockerfile
└── .github/workflows/coder-workspace-image.yml
```

`coder/Dockerfile`:
- `FROM nixos/nix:latest`
- Enable flakes: append `experimental-features = nix-command flakes` to `/etc/nix/nix.conf`
- Copy the flake into `/flake`
- `ENV USER=coder HOME=/home/coder`, create `$HOME`
- Single-stage build: run `home-manager switch --flake /flake#shell-linux --impure` directly, so
  `/nix/store` and the home-manager profile symlinks land in the final image's layers — no separate
  copy/export step needed.
- No Coder-specific baking required in the image itself: `coder_agent`'s `init_script` (injected via the
  Pod's `command` in Phase 2) downloads and starts the actual agent binary at container start. The image
  only needs `sh` and `curl` to exist, both of which are present in the base `nixos/nix` image already.

`.github/workflows/coder-workspace-image.yml`:
- Triggers on push to `main` touching `flake.nix`, `flake.lock`, `modules/**`, `systems/shell/**`, or
  `coder/Dockerfile`
- Builds `coder/Dockerfile`, pushes to `ghcr.io/graytonio/nixos-workspace` tagged both `:latest` and
  `:<git-sha>` (so the Terraform template can pin an exact tag instead of always floating to latest)

## Phase 2 — `homelab-flagops-templates`: Terraform template

### File structure

```
coder-templates/
└── nix-dev/
    ├── main.tf
    └── README.md
```

Lives outside `apps/` deliberately — this is a Terraform template pushed imperatively via the `coder` CLI,
not an ArgoCD-managed Helm chart, and mixing it into `apps/**/Chart.yaml` discovery would confuse the
ApplicationSet's chart-scanning generator.

### `main.tf`

- `terraform { required_providers { coder = { source = "coder/coder" }, kubernetes = { source = "hashicorp/kubernetes" } } }`
- `provider "kubernetes" { config_path = null }` — `null` triggers the provider's in-cluster auto-auth,
  since Terraform runs inside the `coder-production` pod itself, using the ServiceAccount already granted
  the RBAC above.
- `data "coder_workspace" "me"` / `data "coder_workspace_owner" "me"` — for unique per-workspace/owner
  resource naming.
- `resource "coder_agent" "main"` — `os = "linux"`, `arch = "amd64"`, `dir = "/home/coder"`. Coder's
  dashboard gets its web terminal automatically from this; no extra resource needed for that.
- `resource "kubernetes_persistent_volume_claim" "home"` — Longhorn-backed, **no `count`** (so it persists
  across workspace stop/start, unlike the Pod below), 20Gi to start (matches this repo's other
  moderately-sized stateful volumes; adjustable later).
- `resource "kubernetes_pod" "main"` — `count = data.coder_workspace.me.start_count` (0 when stopped, 1
  when running — this is what makes stop/start actually work), namespace `coder`, image
  `ghcr.io/graytonio/nixos-workspace:latest`, `command = ["sh", "-c", coder_agent.main.init_script]`,
  mounts the PVC at `/home/coder`.
- Container `securityContext`/`fsGroup` needs to actually match up with whatever UID the image's `coder`
  user resolves to, so the mounted (root-owned-by-default Longhorn) volume is writable — pinned down
  concretely during implementation rather than guessed here.

### `README.md`

Documents the one-time/occasional imperative steps this can't avoid:
```
coder login https://coder.graytonward.com
coder templates push nix-dev -d coder-templates/nix-dev/
```
Re-run `templates push` whenever the template or image tag changes.

### Explicitly out of scope for v1

No browser code-editor (no code-server `coder_app`) — Coder's own dashboard already covers "web interface"
(workspace management + built-in web terminal), and real `ssh`/VS Code Remote-SSH covers the
terminal/editor use case from the original ask. Adding code-server is a small, separate follow-up if
wanted later.

## Data flow & lifecycle

1. Push to `nixos-config` main → CI builds + pushes `ghcr.io/graytonio/nixos-workspace:latest` (+ sha tag).
2. Push to `homelab-flagops-templates` main touching `coder-templates/nix-dev/**` → nothing automatic
   happens (not ArgoCD-managed) → `coder templates push` run manually when the template changes.
3. `coder create` (CLI or dashboard) → Coder's in-cluster provisioner creates the PVC (if missing) + Pod →
   Pod's `command` runs `coder_agent`'s init script → agent registers with `coder-production`, tunnel
   established.
4. Connect via: web terminal (dashboard), `coder config-ssh` + `ssh coder.<workspace>` (real terminal), or
   VS Code Remote-SSH against the same SSH config entry.
5. Stop workspace → Pod deleted (`count=0`) but PVC retained. Start again → new Pod created, same PVC
   reattached, home directory persists.

## Verification plan

- Phase 1: the actual check is the GitHub Actions run producing a working image once merged — a fully
  local `docker build` would mean downloading all of nixpkgs from scratch, too slow/heavy to do as a
  pre-merge check in this environment. Once the image exists, a quick `docker run --rm -it
  ghcr.io/graytonio/nixos-workspace:latest fish -c 'go version; kubectl version --client'`-style smoke test
  confirms the expected tools landed.
- Phase 2: `terraform fmt -check` / `terraform validate` locally (need to install `terraform` — not present
  in this environment, will pull via `nix profile install nixpkgs#terraform` or `nix run`). Real end-to-end
  check is `coder templates push` followed by creating an actual test workspace and confirming: Pod comes
  up, agent registers (shows "Connected" in the dashboard), `coder config-ssh` + `ssh` works, `/home/coder`
  survives a stop/start cycle.

## Sequencing note

Phase 1 must land and its image must exist in GHCR before Phase 2's template is pushed/tested — pushing the
Terraform template first would still succeed (Terraform doesn't validate image existence at push time), but
the first workspace creation would fail with `ImagePullBackOff`.
