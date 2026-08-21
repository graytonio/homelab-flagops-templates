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
