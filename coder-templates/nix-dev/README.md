# nix-dev Coder workspace template

Runs `ghcr.io/graytonio/nixos-workspace` (built from
[graytonio/nixos-config](https://github.com/graytonio/nixos-config),
`coder/Dockerfile`) as a Kubernetes Pod in the `coder` namespace, with a
Longhorn-backed PersistentVolumeClaim mounted at `/home/coder` that survives
workspace stop/start.

This directory is **not** ArgoCD-managed — Coder has no GitOps-native way to
sync templates from git without enterprise features.

## How this template reaches the Coder server

Automatically. The `coder-template-sync` CronJob (`apps/coder/templates/`)
runs every 15 minutes, clones `main`, and runs `coder templates push` for
every `coder-templates/*/` whose git SHA changed since its last run. It also
pre-pulls the workspace image on every node via a DaemonSet when the pinned
image digest in `main.tf` changes, so a fresh digest doesn't leave the first
workspace creation waiting on a cold multi-minute pull.

So: commit to `main` and the template lands within 15 minutes. Nothing here
needs a manual push.

To skip the wait, run the job immediately:

```bash
J=coder-template-sync-manual-$(date +%s)
kubectl -n coder create job --from=cronjob/coder-template-sync "$J"
kubectl -n coder wait --for=condition=complete --timeout=600s job/"$J"
kubectl -n coder logs job/"$J"
```

Pushing by hand is only needed if the CronJob is broken or you want to test
an uncommitted change:

```bash
coder login https://coder.graytonward.com
coder templates push nix-dev -d coder-templates/nix-dev/
```

Note that pushing a new template version does **not** update running
workspaces — that needs `coder update <workspace>`, which recreates the pod.

## Prerequisites

The `ghcr.io/graytonio/nixos-workspace:latest` image must exist before
creating a workspace from this template — see the `nixos-config` repo's
`coder-workspace-image` GitHub Actions workflow. Pushing this template
without the image existing will succeed, but the first workspace creation
will fail with `ImagePullBackOff`.

## Cloning repos into the workspace

Workspace creation offers an optional **Git repositories** list. Each entry is
cloned to `~/repos/<name>` on the next start. Leave it empty and nothing
changes.

What the editor opens depends on how many there are:

| Repos | Editor opens |
|---|---|
| none | `/home/coder` |
| one | that repo as the root |
| two or more | `~/repos/<workspace>.code-workspace`, a multi-root workspace |

The multi-root case is the point: all repos appear as top-level folders in one
window, so search, go-to-definition and refactors span the whole project
instead of stopping at a repo boundary. That is VS Code's own mechanism, not
something bolted on here.

The parameter is mutable, so an existing workspace can gain or change repos
without being recreated. Easiest from the dashboard's workspace settings.

From the CLI the quoting is genuinely awkward: `--parameter` parses its
argument as a single CSV field, so a JSON array has to be CSV-escaped — the
**whole** `name=value` wrapped in quotes, with every inner quote doubled.
Anything less fails with `bare " in non-quoted-field`:

```bash
coder update homelab-management \
  --parameter '"repo_urls=[""git@github.com:graytonio/nixos-config.git"",""git@github.com:graytonio/homelab-flagops-templates.git""]"'
```

Adding a repo clones only the new one and adds it to the workspace file;
removing one drops it from the workspace file and leaves the clone on disk.

The `.code-workspace` file is **not** owned by the template. Only its `folders`
key is rewritten, so workspace-level `settings`, `extensions.recommendations`
and launch configs added by hand survive. If the file is not valid JSON it is
left completely untouched, with a warning in the log.

Entries that are not `https://` or `git@` URLs are silently dropped, as are any
containing characters that do not belong in a git URL.

**Use the `https://` form.** Both shapes parse correctly, with or without a
trailing `.git`, but only HTTPS actually authenticates out of the box:

```
https://github.com/graytonio/homelab-flagops-templates.git
```

`git@` SSH URLs fail, with two distinct blockers confirmed in a live
workspace:

1. `Host key verification failed` — there is no `~/.ssh/known_hosts`, and the
   clone is non-interactive so it cannot accept the key.
2. With the host key supplied manually, the clone still fails on access
   rights. Coder sets `GIT_SSH_COMMAND=<agent> gitssh --` and offers its own
   managed key, but that key is not registered on the GitHub account. Coder
   prints it in the clone error, and it goes at
   <https://github.com/settings/ssh/new>.

Private repos over HTTPS are also unlikely to work from the clone: `GIT_ASKPASS`
is **not** set in the environment the startup script runs in — verified by
reading `/proc/<pid>/environ` of a process the agent spawned, which carries
`GIT_SSH_COMMAND` but no `GIT_ASKPASS`. The `primary-github` external auth
still covers interactive git use inside the workspace; it just does not reach
this script.

So: public repos over HTTPS work today. Private repos, or SSH URLs, need the
Coder key added to GitHub and `known_hosts` seeded first.

Two behaviours worth knowing:

- **The clone only happens when the target directory is absent.** It is
  genuinely first-start-only and will never overwrite an existing clone, so
  changing the parameter clones the new repo and leaves the old one on disk.
- **A failed clone never blocks startup.** A bad URL, an unauthorized private
  repo, or a network blip logs a warning to
  `~/.local/share/code-server.log` and the workspace starts without it.

## Workspace pods are a Deployment

The workspace runs as a Deployment with `replicas` toggled between 0 and 1 by
Coder's stop/start, not as a bare Pod. A bare Pod had no self-healing: when a
node rebooted or evicted it, nothing recreated it and Coder still reported the
workspace as `Started`.

The strategy is `Recreate` and must stay that way. The home volume is a
ReadWriteOnce Longhorn PVC, so two pods can never mount it simultaneously — a
rolling update would deadlock with the new pod stuck `ContainerCreating` on a
volume the old one still holds.

Consequence for anything scripted: pod names are generated
(`coder-<owner>-<workspace>-<hash>`), not fixed. Select by label instead:

```bash
kubectl -n coder get pods -l coder.workspace=homelab-management
kubectl -n coder logs -l coder.workspace=homelab-management -c dev
```

## Browser editor (code-server)

Workspaces expose code-server as a Coder app, in addition to the web
terminal and SSH. Open it from the workspace page in the dashboard; it is
served path-based at
`coder.<domain>/@<user>/<workspace>.main/apps/code-server/` on the existing
hostname, so no wildcard DNS, Ingress, or TLS certificate is involved.

The version is pinned in `main.tf` (`local.code_server_version`). To
upgrade, bump that value and commit — the sync CronJob pushes the new
template version, and nothing changes until the workspace restarts, which
`coder update` does. The next start installs the new version and deletes
the old install directory.

When bumping, keep the workspace image's `node --version` major aligned
with the code-server release's `.node-version`. The tarball's prebuilt
native modules run under the image's Nix node, and a major mismatch breaks
them at runtime in the integrated terminal and extension host while the
startup check and `/healthz` both still pass.

A first-ever start downloads ~235MB, during which the app tile sits
unhealthy for several minutes (the healthcheck's grace period is only 30s)
before flipping healthy on its own. The install lands in
`~/.local/lib/code-server-<version>` on the PVC, so later starts are
immediate.

Two logs, and they hold different things. `~/.local/share/code-server.log`
(rotated to `.log.1` past 10MB) has the editor's runtime output plus the
script's own progress messages. Failures in the install itself — a `curl`
or `tar` error under `set -o pipefail` — go to the Coder agent's script log
instead, visible in the dashboard's workspace build log. If the install
directory is missing and `code-server.log` ends at
`Installing code-server ...`, look there.

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
repo=$(git rev-parse --show-toplevel)
d=$(mktemp -d) && cp "$repo/coder-templates/nix-dev/main.tf" "$d/"
(cd "$d" && terraform init -input=false >/dev/null && terraform validate)
```
