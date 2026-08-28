# Browser code-server for the `nix-dev` Coder Workspace — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a browser-based VS Code (code-server) to the `nix-dev` Coder workspace, alongside the existing SSH and web-terminal access.

**Architecture:** Two new Terraform resources in a single file. A `coder_script` downloads the code-server standalone tarball once into the PVC-backed home directory and launches it with the workspace image's Nix-provided `node`; a `coder_app` exposes it path-based through Coder's authenticated proxy. No cluster, chart, or container-image changes.

**Tech Stack:** Terraform (HCL), the `coder/coder` Terraform provider (>= 2.0), code-server 4.135.0, Kubernetes/ArgoCD homelab, Coder control plane at `https://coder.graytonward.com`.

**Spec:** `docs/superpowers/specs/2026-08-28-coder-browser-ide-design.md`

---

## A note on testing for this plan

There is no unit-test framework for a Coder Terraform template, so the usual red-green TDD loop does not apply literally. The equivalent discipline here is:

- **Static gate (every code task):** `terraform init/validate/fmt` must pass. This is real verification — the provider schema is downloaded, so a misnamed attribute or a bad block on `coder_script`/`coder_app` fails `validate`.
- **Acceptance gate (Task 6):** live checks against the real workspace. This is the actual proof the feature works, and it is a required task, not an optional afterthought.

Run all Terraform commands against a **copy** of the template in the scratchpad directory, never in the repo. `terraform init` writes `.terraform/` (~100MB) and `.terraform.lock.hcl`, the repo's `.gitignore` does not cover them, and the `coder-template-sync` CronJob uploads the whole template directory verbatim — committed Terraform junk would be pushed to the Coder server.

Scratchpad path used throughout (referred to below as `$SP`):

```
/tmp/claude-1000/-home-graytonio-repos-homelab-flagops-templates/1916ed37-2307-4264-ac18-264bdce1962d/scratchpad/tfcheck
```

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `coder-templates/nix-dev/main.tf` | The entire workspace definition: providers, agent, PVC, pod, and now the code-server script + app | Modify — add 3 locals, 2 resources |
| `coder-templates/nix-dev/README.md` | Human-facing operator notes for this template | Modify — document the editor and the Nix/glibc constraint |

Only one source file changes. Splitting the template across multiple `.tf` files is not warranted at this size and would obscure the tight coupling between the agent, script, and app resources.

---

## Task 0: Branch and baseline

**Files:** none (setup only)

- [ ] **Step 1: Confirm the repo is clean and on `main`**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
git status --short
git log --oneline -1
```

Expected: no output from `git status --short`; the log shows `4d3d8ae docs: add design spec for browser code-server in nix-dev workspace`.

- [ ] **Step 2: Create the feature branch**

```bash
git checkout -b feat/coder-code-server
```

Expected: `Switched to a new branch 'feat/coder-code-server'`

- [ ] **Step 3: Establish the Terraform validation baseline**

```bash
SP=/tmp/claude-1000/-home-graytonio-repos-homelab-flagops-templates/1916ed37-2307-4264-ac18-264bdce1962d/scratchpad/tfcheck
rm -rf "$SP" && mkdir -p "$SP"
cp coder-templates/nix-dev/main.tf "$SP/"
cd "$SP" && terraform init -no-color -input=false >/dev/null && terraform validate -no-color && terraform fmt -check -no-color && echo "FMT OK"
```

Expected:
```
Success! The configuration is valid.
FMT OK
```

This proves the tooling works and the template is valid *before* any edit, so a later failure is unambiguously caused by the new code. Do not commit anything in this task.

---

## Task 1: Add code-server locals and the install/launch script

**Files:**
- Modify: `coder-templates/nix-dev/main.tf` (append to the existing `locals` block; add one resource after `resource "coder_agent" "main"`)

- [ ] **Step 1: Add the three locals**

Use Edit on `coder-templates/nix-dev/main.tf`. Find this exact text (the last entry of the existing `locals` block plus its closing brace):

```hcl
  agent_start_script = "[ -f $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh; ${coder_agent.main.init_script}"
}
```

Replace it with:

```hcl
  agent_start_script = "[ -f $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh; ${coder_agent.main.init_script}"

  # Pinned deliberately rather than resolved from the GitHub API at install
  # time, matching how the workspace image below is pinned by digest: an
  # upgrade should be a reviewable one-line commit, and two workspaces
  # created months apart should get the same editor.
  code_server_version = "4.135.0"
  code_server_port    = 13337
  # Under $HOME, so this lands on the Longhorn PVC and the ~235MB download
  # happens on first start only. Version-suffixed so a version bump installs
  # cleanly alongside rather than half-overwriting the old tree.
  code_server_dir = "/home/coder/.local/lib/code-server-${local.code_server_version}"
}
```

- [ ] **Step 2: Add the `coder_script` resource**

Use Edit on the same file. Find this exact text:

```hcl
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
}
```

Replace it with:

```hcl
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
}

# Installs (once) and starts code-server. The workspace image is a pure
# NixOS container: there is no /lib64/ld-linux-x86-64.so.2 and nix-ld is not
# configured, so the glibc-linked `node` bundled inside code-server's release
# tarball cannot exec at all -- confirmed empirically in a live workspace:
#
#   ./lib/node --version              -> "cannot execute: required file not found" (127)
#   node out/node/entry.js --version  -> "4.135.0 ... with Code 1.135.0"           (0)
#
# So this must invoke `out/node/entry.js` with the image's Nix-provided node
# and must never call `bin/code-server`, whose wrapper execs the bundled
# binary. This is also why Coder's official registry code-server module is
# unusable here -- it launches through that same wrapper and exposes no hook
# to override the node binary.
resource "coder_script" "code_server" {
  agent_id     = coder_agent.main.id
  display_name = "code-server"
  icon         = "/icon/code.svg"
  run_on_start = true

  script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="${local.code_server_version}"
    DIR="${local.code_server_dir}"
    LOG="$HOME/.local/share/code-server.log"

    if [ ! -f "$DIR/out/node/entry.js" ]; then
      echo "Installing code-server $VERSION into $DIR"
      mkdir -p "$DIR"
      curl -fsSL "https://github.com/coder/code-server/releases/download/v$VERSION/code-server-$VERSION-linux-amd64.tar.gz" \
        | tar -xz -C "$DIR" --strip-components=1
    else
      echo "code-server $VERSION already installed at $DIR"
    fi

    # Reclaim PVC space from any previously pinned version.
    find "$HOME/.local/lib" -maxdepth 1 -name 'code-server-*' ! -name "code-server-$VERSION" -exec rm -rf {} +

    mkdir -p "$(dirname "$LOG")"
    node "$DIR/out/node/entry.js" \
      --auth none \
      --bind-addr "127.0.0.1:${local.code_server_port}" \
      --disable-telemetry \
      > "$LOG" 2>&1 &

    echo "code-server started on 127.0.0.1:${local.code_server_port}, logging to $LOG"
  EOT
}
```

Three details that matter and are easy to get wrong:

1. **`${...}` inside the heredoc is Terraform interpolation, not shell.** `${local.code_server_version}` and `${local.code_server_port}` are substituted by Terraform. Shell variables are written bare (`$HOME`, `$DIR`, `$VERSION`) precisely so Terraform leaves them alone. Never write `${VERSION}` here — Terraform would try to resolve `VERSION` as an HCL reference and fail.
2. **The process is backgrounded (`&`) with output to a log.** `coder_script` with `run_on_start` waits for the script to exit; without backgrounding, workspace start would hang forever.
3. **`--auth none` is correct.** It binds to `127.0.0.1`, unreachable from outside the pod, and every request arrives through Coder's already-authenticated proxy.

All script prerequisites were verified present in the live workspace image: `/usr/bin/env`, `bash`, `curl`, `tar`, `find`, `mkdir`, and `node` (at `/home/coder/.nix-profile/bin/node`, already on the agent's inherited `PATH`).

- [ ] **Step 3: Format and validate**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
terraform fmt coder-templates/nix-dev/main.tf
SP=/tmp/claude-1000/-home-graytonio-repos-homelab-flagops-templates/1916ed37-2307-4264-ac18-264bdce1962d/scratchpad/tfcheck
cp coder-templates/nix-dev/main.tf "$SP/"
cd "$SP" && terraform validate -no-color
```

Expected: `Success! The configuration is valid.`

`terraform fmt` will realign the `locals` assignments — that is expected and desirable, not a mistake.

If validate fails with `Invalid reference` or `Unknown variable`, the cause is almost certainly a shell `${...}` that Terraform tried to interpolate. Re-read detail 1 above.

- [ ] **Step 4: Commit**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
git add coder-templates/nix-dev/main.tf
git commit -m "feat(coder): install and start code-server in nix-dev workspaces

Launches out/node/entry.js with the image's Nix-provided node -- the
tarball's bundled glibc node cannot exec on the pure-NixOS workspace
image, which also rules out Coder's official code-server module.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UZ4XTeHEyHNd3mwbvLLb7A"
```

---

## Task 2: Expose code-server as a Coder app

**Files:**
- Modify: `coder-templates/nix-dev/main.tf` (add one resource directly after `resource "coder_script" "code_server"`)

- [ ] **Step 1: Add the `coder_app` resource**

Use Edit on `coder-templates/nix-dev/main.tf`. Find this exact text (the closing lines of the script resource added in Task 1):

```hcl
    echo "code-server started on 127.0.0.1:${local.code_server_port}, logging to $LOG"
  EOT
}
```

Replace it with:

```hcl
    echo "code-server started on 127.0.0.1:${local.code_server_port}, logging to $LOG"
  EOT
}

# subdomain = false serves this path-based on the existing hostname, at
# coder.<domain>/@<user>/<workspace>.main/apps/code-server/ -- so no
# CODER_WILDCARD_ACCESS_URL, no wildcard Ingress, no wildcard DNS record, and
# no wildcard certificate are needed. The trade-off is that the editor shares
# an origin with the Coder dashboard and can therefore read the Coder session
# cookie; acceptable for a single-user homelab running only the owner's code,
# and the reason to revisit this if the deployment ever gains other users.
resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:${local.code_server_port}/?folder=/home/coder"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  # Keeps the dashboard tile greyed out until the editor actually serves,
  # instead of offering a link that 502s during the first-start download.
  healthcheck {
    url       = "http://localhost:${local.code_server_port}/healthz"
    interval  = 5
    threshold = 6
  }
}
```

- [ ] **Step 2: Format and validate**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
terraform fmt coder-templates/nix-dev/main.tf
SP=/tmp/claude-1000/-home-graytonio-repos-homelab-flagops-templates/1916ed37-2307-4264-ac18-264bdce1962d/scratchpad/tfcheck
cp coder-templates/nix-dev/main.tf "$SP/"
cd "$SP" && terraform validate -no-color && terraform fmt -check -no-color && echo "FMT OK"
```

Expected:
```
Success! The configuration is valid.
FMT OK
```

- [ ] **Step 3: Commit**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
git add coder-templates/nix-dev/main.tf
git commit -m "feat(coder): expose code-server as a path-based coder_app

Path-based (subdomain = false) so no wildcard DNS, Ingress, or TLS
certificate is required on the existing coder hostname.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UZ4XTeHEyHNd3mwbvLLb7A"
```

---

## Task 3: Document the editor and the constraint behind it

**Files:**
- Modify: `coder-templates/nix-dev/README.md`

- [ ] **Step 1: Append the documentation section**

Use Edit on `coder-templates/nix-dev/README.md`. Find this exact text (the final section of the file):

```markdown
## Prerequisites

The `ghcr.io/graytonio/nixos-workspace:latest` image must exist before
creating a workspace from this template — see the `nixos-config` repo's
`coder-workspace-image` GitHub Actions workflow. Pushing this template
without the image existing will succeed, but the first workspace creation
will fail with `ImagePullBackOff`.
```

Replace it with:

```markdown
## Prerequisites

The `ghcr.io/graytonio/nixos-workspace:latest` image must exist before
creating a workspace from this template — see the `nixos-config` repo's
`coder-workspace-image` GitHub Actions workflow. Pushing this template
without the image existing will succeed, but the first workspace creation
will fail with `ImagePullBackOff`.

## Browser editor (code-server)

Workspaces expose code-server as a Coder app, in addition to the web
terminal and SSH. Open it from the workspace page in the dashboard; it is
served path-based at
`coder.<domain>/@<user>/<workspace>.main/apps/code-server/` on the existing
hostname, so no wildcard DNS, Ingress, or TLS certificate is involved.

The version is pinned in `main.tf` (`local.code_server_version`). To
upgrade, bump that value and commit — the `coder-template-sync` CronJob
pushes the new template version within 15 minutes, and the next workspace
start installs it and deletes the old install directory.

On first start the workspace downloads ~235MB and the app tile is briefly
unhealthy; the install lands in `~/.local/lib/code-server-<version>` on the
PVC, so later starts are immediate. Runtime log:
`~/.local/share/code-server.log`.

> **Do not switch this to Coder's official code-server registry module, and
> do not launch `bin/code-server`.** This image is a pure NixOS container:
> `/lib64/ld-linux-x86-64.so.2` does not exist and nix-ld is not configured,
> so the glibc-linked `node` bundled in the code-server tarball cannot exec
> (`cannot execute: required file not found`). `main.tf` therefore runs
> `out/node/entry.js` with the image's Nix-provided `node`. The registry
> module launches through the `bin/code-server` wrapper and offers no way to
> override the node binary, so it fails on this image.

The same missing-loader problem likely affects VS Code Remote-SSH, Cursor,
and Windsurf remote servers, which are also generic prebuilt glibc
binaries. Adding `nix-ld` to the workspace image in `nixos-config` is the
general fix; this template deliberately does not depend on it.

## Terraform validation

`terraform init` writes `.terraform/` and `.terraform.lock.hcl`, which are
not gitignored and would be uploaded verbatim by `coder templates push`.
Validate against a copy outside the repo instead:

```bash
d=$(mktemp -d) && cp coder-templates/nix-dev/main.tf "$d/"
(cd "$d" && terraform init -input=false >/dev/null && terraform validate)
```
```

- [ ] **Step 2: Verify the repo is still clean of Terraform artifacts**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
git status --short
ls -a coder-templates/nix-dev/
```

Expected: `git status --short` shows only ` M coder-templates/nix-dev/README.md`. The directory listing shows only `.`, `..`, `main.tf`, `README.md` — no `.terraform` or `.terraform.lock.hcl`.

- [ ] **Step 3: Commit**

```bash
git add coder-templates/nix-dev/README.md
git commit -m "docs(coder): document code-server app and the NixOS loader constraint

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UZ4XTeHEyHNd3mwbvLLb7A"
```

---

## Task 4: Land on `main` and push the template

**This task changes the live homelab. Confirm with the user before starting it.**

**Files:** none (git and cluster operations)

- [ ] **Step 1: Capture a pre-change baseline of the running workspace**

```bash
kubectl -n coder get pod coder-graytonio-ward-homelab-management -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
kubectl -n coder get pvc -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,CREATED:.metadata.creationTimestamp
```

Record both outputs. The PVC `volumeName` must be identical after the workspace update — that is the proof no home directory was lost.

- [ ] **Step 2: Merge to `main` and push**

```bash
cd /home/graytonio/repos/homelab-flagops-templates
git checkout main
git merge --ff-only feat/coder-code-server
git log --oneline -4
git push origin main
```

Expected: fast-forward merge listing the three feature commits plus the earlier spec commit; push succeeds.

The `coder-template-sync` CronJob clones this repo's `main` branch, so the change is inert until it is pushed.

- [ ] **Step 3: Trigger the template sync immediately instead of waiting up to 15 minutes**

```bash
kubectl -n coder create job --from=cronjob/coder-template-sync coder-template-sync-manual-$(date +%s)
kubectl -n coder get jobs -l job-name --sort-by=.metadata.creationTimestamp | tail -3
```

- [ ] **Step 4: Confirm the push succeeded**

```bash
kubectl -n coder logs -l job-name --tail=50 --prefix | grep -A2 'nix-dev'
```

Expected: a line reading `[nix-dev] change detected (<old-sha> -> <new-sha>), pushing` and no error after it. If it instead says `unchanged`, the commit did not reach `main` on the remote — recheck Step 2.

- [ ] **Step 5: Update the existing workspace to the new template version**

Pushing a template version does **not** touch running workspaces. This recreates the pod and will drop live SSH and remote-editor sessions:

```bash
coder update homelab-management
```

If the `coder` CLI is not authenticated locally, use the dashboard's "Update" prompt on the workspace page instead.

- [ ] **Step 6: Watch the pod come back**

```bash
kubectl -n coder get pods -w | grep homelab-management
```

Expected: the old pod terminates and a new one reaches `1/1 Running`. Press Ctrl-C once it does.

---

## Task 5: Live acceptance verification

**Files:** none (verification only)

This is the task that actually proves the feature works. Do not mark the plan complete without it.

- [ ] **Step 1: Confirm the install ran and the process started**

```bash
kubectl -n coder exec coder-graytonio-ward-homelab-management -- sh -c \
  'ls -d ~/.local/lib/code-server-*; tail -20 ~/.local/share/code-server.log'
```

Expected: a single directory `code-server-4.135.0`, and a log containing `HTTP server listening on http://127.0.0.1:13337/`. There must be **no** `cannot execute: required file not found` — that string would mean the bundled node is being launched and Task 1's core requirement was not met.

- [ ] **Step 2: Confirm the editor answers on its health endpoint**

```bash
kubectl -n coder exec coder-graytonio-ward-homelab-management -- \
  curl -fsS http://127.0.0.1:13337/healthz
```

Expected: a JSON body containing `"status"` — e.g. `{"status":"expired","lastHeartbeat":0}`. Any curl failure means the process is not listening; read the log from Step 1.

- [ ] **Step 3: Confirm no PVC was lost**

```bash
kubectl -n coder get pvc -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,CREATED:.metadata.creationTimestamp
```

Expected: the home PVC's `volumeName` and creation timestamp match the baseline captured in Task 4, Step 1.

- [ ] **Step 4: Confirm the app tile is healthy in Coder**

Open the workspace page at `https://coder.graytonward.com`. Expected: a `code-server` tile with the VS Code icon, not greyed out.

- [ ] **Step 5: Open the editor in a browser — the real test**

Click the tile. Expected: the VS Code UI loads fully (not a blank page), with `/home/coder` open in the file explorer showing the seeded dotfiles.

**If the page is blank or assets 404**, this is the known residual risk from the spec: path-based proxying. Do not start guessing. Check the browser devtools network tab for 404s on `/stable-<hash>/static/...`, then apply fallbacks in order:
1. Add `--abs-proxy-base-path "/@graytonio-ward/homelab-management.main/apps/code-server"` to the `node ... entry.js` invocation in `main.tf`.
2. If that fails, escalate to the user — the remaining option is wildcard subdomain apps, which they explicitly declined during design and which requires `CODER_WILDCARD_ACCESS_URL`, a wildcard Ingress, DNS, and certificate.

- [ ] **Step 6: Confirm the integrated terminal has the Nix toolchain**

In the editor's terminal, run:

```bash
which node go kubectl fish
```

Expected: all four resolve under `/home/coder/.nix-profile/bin` or `/root/.nix-profile/bin`.

- [ ] **Step 7: Confirm the install persists across a restart**

```bash
coder stop homelab-management && coder start homelab-management
```

Then:

```bash
kubectl -n coder exec coder-graytonio-ward-homelab-management -- \
  grep -c 'already installed' ~/.local/share/code-server.log
```

Expected: at least `1`. This proves the idempotency check works and the ~235MB download does not repeat on every start — the main efficiency claim of the design.

- [ ] **Step 8: Report results**

Report to the user: whether the editor loaded, whether the tile was healthy, the PVC comparison result, and whether the restart skipped the download. If anything failed, report it plainly with the command output rather than describing the feature as working.

---

## Self-review against the spec

Spec coverage check — every section maps to a task:

| Spec requirement | Task |
|---|---|
| Pinned version in `locals` | Task 1, Step 1 |
| `coder_script`: idempotent install, prune old versions, launch via `entry.js` with Nix node, backgrounded | Task 1, Step 2 |
| `coder_app`: path-based, `share = "owner"`, folder, icon, healthcheck | Task 2, Step 1 |
| Security model (`--auth none` on loopback) | Task 1, Step 2 (code + rationale comment) |
| README note | Task 3 |
| Rollout via `coder-template-sync` CronJob + `coder update` | Task 4 |
| Verification: `terraform fmt`/`validate` | Task 0 Step 3, Task 1 Step 3, Task 2 Step 2 |
| Verification: clean log, healthy tile, editor loads, terminal tooling, no re-download on restart | Task 5, Steps 1–7 |
| Residual risk: path-based proxying fallback | Task 5, Step 5 |
| Out of scope: extensions, settings.json, second editor, wildcard subdomains, nix-ld shim | Not implemented anywhere; nix-ld follow-up noted in Task 3's README text only |

No placeholders, no "similar to Task N" references, and the identifiers are consistent across tasks: `local.code_server_version`, `local.code_server_port`, `local.code_server_dir`, `coder_script.code_server`, `coder_app.code_server`, port `13337`, and install path `~/.local/lib/code-server-4.135.0` are used identically everywhere they appear.
