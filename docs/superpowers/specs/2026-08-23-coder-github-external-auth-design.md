# Coder GitHub External Authentication — Design Spec

**Date:** 2026-08-23

## Overview

Give Coder workspaces (starting with `nix-dev`) automatic, per-user GitHub git
access — clone/push without a static SSH key baked into the image or a
manually-managed deploy key. Coder's built-in "External Authentication"
feature handles this: a one-time OAuth authorization per Coder user, after
which the workspace agent automatically injects a git credential (via
`GIT_ASKPASS`) for any GitHub HTTPS remote, with no template-side scripting
needed.

This is deliberately scoped to GitHub only, and to wiring it into the
existing `nix-dev` template — not a general "add N git providers" framework.

## Why a GitHub App, not a classic OAuth App

Verified directly against Coder's own docs (not assumed): Coder's
external-auth setup guide for GitHub explicitly instructs creating a
**GitHub App** (`github.com/settings/apps`), not a classic OAuth App
(`github.com/settings/developers`), even though the resulting Coder-side
config uses a plain `CLIENT_ID`/`CLIENT_SECRET` pair (the standard OAuth
user-to-server flow both app types support — the GitHub App's private key,
used for the JWT/server-to-server flow, is not needed here). The reason to
prefer the App form: it supports installation-scoped repo access (the user's
choice this session: "All repositories," selectable at install time,
changeable later without touching any Coder-side config) — a classic OAuth
App has no such scoping and would always get blanket access to everything
the authorizing user can see.

## GitHub App registration (manual step — GitHub has no API for creating
OAuth/GitHub Apps, this cannot be automated)

At `github.com/settings/apps/new`:
- **Homepage URL:** `https://coder.graytonward.com`
- **Callback URL:** `https://coder.graytonward.com/external-auth/primary-github/callback`
  — the `primary-github` segment must exactly match `CODER_EXTERNAL_AUTH_0_ID`
  below; a mismatch fails auth with "redirect URI is not valid."
- **Webhooks:** deactivated (not used for this flow)
- **Permissions:**
  - Contents: Read & Write (clone/push)
  - Pull requests: Read & Write (create/update PRs from workspaces)
  - Metadata: Read-only (required baseline for any GitHub App)
- After creation: generate a client secret (shown once — capture it
  immediately), note the Client ID
- Install the app with **"All repositories"** access (user's choice)

## Coder deployment config

New file `apps/coder/templates/github-external-auth-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: coder-github-external-auth
  namespace: coder
spec:
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
    name: coder-github-external-auth
  data:
    - secretKey: client_secret
      remoteRef:
        key: coder-github-external-auth-client-secret
```
AWS Secrets Manager is the right backing store here (unlike the CronJob's API
token): a GitHub App client secret is static and doesn't self-rotate, so
there's no conflict between ExternalSecret's periodic refresh and something
else trying to rotate it — this is exactly the case ExternalSecret is
designed for, and matches the repo's established secret-handling convention
(e.g. `apps/traefik`'s admin token).

`apps/coder/values.yaml` gets 5 new entries in the existing `coder.env` list
(same list `CODER_ACCESS_URL`/`CODER_PG_CONNECTION_URL` already live in):
```yaml
    - name: CODER_EXTERNAL_AUTH_0_ID
      value: primary-github
    - name: CODER_EXTERNAL_AUTH_0_TYPE
      value: github
    - name: CODER_EXTERNAL_AUTH_0_CLIENT_ID
      value: "<GitHub App Client ID, filled in during implementation>"
    - name: CODER_EXTERNAL_AUTH_0_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: coder-github-external-auth
          key: client_secret
    - name: CODER_EXTERNAL_AUTH_0_REVOKE_URL
      value: "https://api.github.com/applications/<GitHub App Client ID>/grant"
```
The Client ID itself isn't a secret (GitHub treats it as public, same as any
OAuth client_id) — plain value, not secret-backed, consistent with how
`CODER_ACCESS_URL` etc. are already plain values in this same list.

## Workspace template change

`coder-templates/nix-dev/main.tf` gets one new data source:
```hcl
data "coder_external_auth" "github" {
  id       = "primary-github"
  optional = true
}
```
`optional = true` (confirmed via the `coder/coder` Terraform provider's own
docs) means workspace creation/start never blocks waiting for GitHub
authorization — git operations simply won't be authenticated until the user
completes the one-time authorization flow (a link Coder surfaces in the
dashboard/CLI once this data source exists). No other template changes are
needed: Coder's agent automatically sets up `GIT_ASKPASS` inside the
workspace once the data source is present and the user has authorized,
picking the right token based on the git remote's hostname — no init
scripts, no manual git config.

## Explicitly out of scope

- Other git providers (GitLab, Bitbucket, etc.) — GitHub only, per the ask.
- Making the auth mandatory (`optional = false`) — deliberately left
  non-blocking.
- Automating GitHub App creation — not possible via any GitHub API; this is
  the one unavoidable manual step, same category as the Coder API token
  bootstrap from the template-sync CronJob work.

## Verification plan

- `terraform validate` on the updated `main.tf`.
- `helm template` render check on `apps/coder` confirming the new
  ExternalSecret and the 5 new env entries appear exactly once, no
  duplication, and that removing/adding this doesn't disturb any existing
  `apps/coder` resource.
- After merge + ArgoCD sync + the manual GitHub App creation step: push the
  template, create a test workspace, complete the one-time GitHub
  authorization via the link Coder shows, then from inside the workspace
  `git clone` one of the installed repos over HTTPS and confirm it succeeds
  without any credential prompt — the real end-to-end proof this works, not
  just that the pieces render correctly.
