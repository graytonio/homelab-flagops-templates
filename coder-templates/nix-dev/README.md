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

## Browser editor (code-server)

Workspaces expose code-server as a Coder app, in addition to the web
terminal and SSH. Open it from the workspace page in the dashboard; it is
served path-based at
`coder.<domain>/@<user>/<workspace>.main/apps/code-server/` on the existing
hostname, so no wildcard DNS, Ingress, or TLS certificate is involved.

The version is pinned in `main.tf` (`local.code_server_version`). To
upgrade, bump that value and commit — the `coder-template-sync` CronJob
pushes the new template version within 15 minutes, and the next workspace
start installs it and deletes the old install directory. The bump takes
effect on disk immediately, but the running editor is only replaced when
the pod is, which is what `coder update` does.

On first start the workspace downloads ~235MB and the app tile is briefly
unhealthy; the install lands in `~/.local/lib/code-server-<version>` on the
PVC, so later starts are immediate. Runtime log:
`~/.local/share/code-server.log`, rotated to `.log.1` past 10MB.

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
