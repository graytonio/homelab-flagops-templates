# Browser code-server for the `nix-dev` Coder Workspace — Design Spec

**Date:** 2026-08-28

## Overview

Add a browser-based VS Code (code-server) to the `nix-dev` Coder workspace template, alongside the
existing SSH and web-terminal access. This is the follow-up explicitly deferred in
`docs/superpowers/specs/2026-08-21-nix-coder-workspace-design.md` ("No browser code-editor (no
code-server `coder_app`) ... Adding code-server is a small, separate follow-up if wanted later").

Scope is one file: `coder-templates/nix-dev/main.tf`, plus a README note. No ArgoCD application, no
Helm chart, no cluster configuration, no `nixos-config` change, and no workspace image rebuild.

## The constraint that shapes this design

The workspace image (`ghcr.io/graytonio/nixos-workspace`) is a **pure NixOS container with no FHS
paths**. Verified empirically in the live `coder-graytonio-ward-homelab-management` workspace:

```
/lib, /lib64, /usr/lib          -> do not exist
/lib64/ld-linux-x86-64.so.2     -> does not exist
NIX_LD                          -> unset (nix-ld not configured)
```

code-server's standalone release tarball bundles its own glibc-linked Node binary and its
`bin/code-server` wrapper execs that binary. With no dynamic loader present, it cannot run:

```
./lib/node --version                  -> "cannot execute: required file not found" (exit 127)
node out/node/entry.js --version      -> "4.135.0 ... with Code 1.135.0"           (exit 0)
```

code-server itself is fine — only its bundled Node is unusable. Launching its entrypoint with the
image's Nix-provided `node` works. **Every decision below follows from this.**

Consequence: Coder's official registry module
(`registry.coder.com/coder/code-server/coder`) cannot be used. It installs the standalone tarball and
launches it through `bin/code-server`, hitting exactly the broken path above. Rejected alternatives are
recorded at the end of this document.

## Design

All changes are in `coder-templates/nix-dev/main.tf`.

### 1. Pinned version in `locals`

```hcl
code_server_version = "4.135.0"
code_server_port    = 13337
code_server_dir     = "/home/coder/.local/lib/code-server-${local.code_server_version}"
```

The version is pinned rather than resolved from the GitHub API at install time, matching this repo's
existing convention (the workspace image is pinned by sha256 digest in the same file). Upgrades become
a deliberate one-line commit that flows through the normal sync/review path, and two workspaces created
months apart get the same editor.

### 2. `resource "coder_script" "code_server"`

`run_on_start = true`, `agent_id = coder_agent.main.id`. The script:

1. If `${code_server_dir}/out/node/entry.js` is absent, `curl` the standalone tarball from
   `https://github.com/coder/code-server/releases/download/v${version}/code-server-${version}-linux-amd64.tar.gz`
   and extract it with `tar -xz --strip-components=1` into `${code_server_dir}`.
   `~/.local` is on the Longhorn PVC, so this runs on first start only — subsequent workspace starts
   skip the ~235MB download entirely.
2. Prune any other `~/.local/lib/code-server-*` directory, so a future version bump does not
   accumulate ~700MB of stale installs on the PVC.
3. Launch the editor:
   ```
   node "${code_server_dir}/out/node/entry.js" \
     --auth none --bind-addr 127.0.0.1:${port} --disable-telemetry \
     > ~/.local/share/code-server.log 2>&1 &
   ```
   **Always `node .../out/node/entry.js`, never `bin/code-server`** — see the constraint section. The
   process is backgrounded with output redirected to a log file so the script exits promptly and does
   not block workspace start.

Prerequisites are all present in the image (verified in the live workspace): `bash`, `tar`, `curl`, and
`node` are on the agent's `PATH`, which the pod inherits from the image's `ENV PATH`
(`/home/coder/.nix-profile/bin:/root/.nix-profile/bin:...`).

### 3. `resource "coder_app" "code_server"`

```hcl
agent_id  = coder_agent.main.id
slug      = "code-server"
url       = "http://localhost:${port}/?folder=/home/coder"
icon      = "/icon/code.svg"
subdomain = false
share     = "owner"
healthcheck { url = "http://localhost:${port}/healthz", interval = 5, threshold = 6 }
```

`subdomain = false` serves the app path-based at
`coder.<domain>/@<user>/<workspace>.main/apps/code-server/` on the existing hostname. This requires no
changes to `apps/coder/values.yaml`, the Ingress, DNS, or TLS certificates. The alternative — wildcard
subdomain apps — would need `CODER_WILDCARD_ACCESS_URL`, a wildcard Ingress, a wildcard DNS record via
external-dns, and a wildcard certificate (feasible: the `letsencrypt` ClusterIssuer already uses a
Cloudflare DNS01 solver), but that is a much larger blast radius across a working control plane for a
single-user convenience feature.

The healthcheck exists so the dashboard tile stays greyed out until the editor is actually serving,
rather than offering a link that 502s during the first-start download.

## Security model

`--auth none` bound to `127.0.0.1` is deliberate, not a shortcut. Nothing outside the pod's network
namespace can reach the port, and every request necessarily arrives through Coder's already-authenticated
proxy; adding a second password would be redundant.

The real trade-off comes from path-based routing: the app shares an origin with the Coder dashboard, so
the editor can read the Coder session cookie. Accepted for a single-user homelab running only the
owner's own code. This would not be acceptable for multi-user or untrusted workspaces — that scenario
needs the wildcard-subdomain option instead.

## Rollout

1. Commit the `main.tf` change to `main`.
2. The `coder-template-sync` CronJob (runs every 15 minutes) detects the changed
   `coder-templates/nix-dev/` git SHA against its `coder-template-sync-state` ConfigMap and runs
   `coder templates push nix-dev`. No manual push is needed. To skip the wait:
   `kubectl -n coder create job --from=cronjob/coder-template-sync coder-template-sync-manual`.
3. **Pushing a new template version does not update running workspaces.** Run
   `coder update homelab-management` (or use the dashboard prompt) to move the existing workspace to the
   new version, which recreates the pod.
4. That pod recreation drops live SSH and remote-editor sessions, so do it when convenient. The home
   directory persists — it is on the PVC, which has no `count` and survives stop/start.

The image digest is unchanged by this work, so the sync job's image pre-pull DaemonSet path is not
triggered.

## Verification plan

Static, before commit:
- `terraform fmt -check` and `terraform validate` in `coder-templates/nix-dev/`. Terraform is not
  installed in this environment; use `nix run nixpkgs#terraform`. `validate` requires `terraform init`,
  which needs provider-registry egress.

Live, after rollout:
- `kubectl -n coder logs <workspace-pod>` and `~/.local/share/code-server.log` are clean, with no
  loader errors.
- The `coder_app` tile reports healthy in the dashboard (proves `/healthz` responds).
- The editor loads in a browser, opens `/home/coder`, and its integrated terminal has the normal
  fish/nix tooling.
- A workspace stop/start cycle does **not** re-download the tarball (proves PVC persistence and the
  idempotency check).

## Residual risk

Path-based proxying is the one thing that could still fail: if code-server's asset URLs do not resolve
under the `/@user/<workspace>.main/apps/code-server/` prefix, the page loads blank. This is the Coder
code-server module's own default configuration and is well-trodden upstream, so it is expected to work,
but it must be confirmed live rather than assumed. Fallbacks, in order: pass code-server an explicit
base path; failing that, adopt wildcard subdomain apps.

## Rejected alternatives

- **Coder registry `code-server` module** — the natural first choice, and the initially preferred option
  until testing falsified it. Launches via `bin/code-server` → bundled glibc Node → does not execute on
  this image. It exposes no hook to override the Node binary.
- **Registry module plus a `lib/node` symlink shim** — would work, but depends on script-versus-module
  execution ordering that Coder does not guarantee, and breaks silently on module upgrades.
- **Bake nixpkgs `code-server` into the workspace image** — genuinely clean (nixpkgs patches it to use
  the Nix Node) and fully declarative via `flake.lock`. Rejected for cost, not correctness: a cross-repo
  PR to `nixos-config`, a heavy image rebuild that may compile code-server from source in CI, and a
  sha256 digest bump in `main.tf`. Worth revisiting if the runtime download becomes annoying.
- **VS Code Web via `code serve-web`** — the `code` CLI is already in the image (`modules/dev/default.nix`)
  and supports `serve-web` with `--server-base-path`. Rejected in favour of code-server, which is
  purpose-built for Coder and better-tested against path-based app routing.
- **FHS loader shim (`/lib64/ld-linux-x86-64.so.2` → Nix glibc)** — the pod runs as root, so this is
  possible, and it would fix the registry module. Rejected as a broad, hand-rolled change (it is nix-ld's
  job, and needs `LD_LIBRARY_PATH` for `libstdc++` and friends) riding on a narrow feature. See follow-ups.

## Out of scope

- Pre-installed extensions and a seeded `settings.json` — add later if a concrete need appears.
- A second browser editor (VS Code Web / JetBrains).
- Wildcard subdomain app routing.

## Follow-up worth considering separately

The workspace home directory contains `.vscode-server`, `.cursor-server`, `.windsurf-server`,
`.vscodium-server`, and `.vscode-insiders-server`, all created at workspace start. Those remote-editor
servers are generic prebuilt glibc binaries and would hit the **same** missing-dynamic-loader problem
this spec works around. If VS Code Remote-SSH or Cursor remote sessions are failing or silently falling
back, adding `nix-ld` (or an FHS loader shim) to the workspace image is the general fix. Out of scope
here; this spec deliberately does not depend on it.
