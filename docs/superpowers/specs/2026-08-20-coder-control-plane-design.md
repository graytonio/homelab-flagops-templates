# Coder Control Plane — Design Spec

**Date:** 2026-08-20

## Overview

Add a new app (`apps/coder/`) that deploys [Coder](https://coder.com) — a self-hosted remote development platform — into the homelab cluster. This spec covers only the control plane: the Coder server, its Postgres backend, and ingress/access. It does **not** cover workspace templates or Nix-based tooling integration (Nix-config-driven workspace images, `coder ssh`/devcontainer wiring); that is a separate follow-up sub-project once the server is reachable and can be tested against.

Motivation: give the user a way to reach a persistent dev environment (with their normal nix-config tooling, once the follow-up lands) from any device — web IDE, browser terminal, and real `ssh` — without exposing a raw SSH port through MetalLB. Coder's SSH access tunnels through its own embedded DERP/WireGuard relay, so only the web/API needs to go through the existing Traefik ingress.

## App Structure

```
apps/coder/
├── Chart.yaml          # depends on the official coder/coder chart
├── values.yaml         # coder.* values: ingress, access URL, DB env wiring
└── templates/
    └── pg.yaml          # postgresql CRD (Zalando postgres-operator)
```

This follows the `traefik` / `db-operators` pattern: apps that ship their own official upstream Helm chart depend on it directly (aliased to a top-level values key), rather than using the `app-template` wrapper reserved for plain-container apps like `gotify`/`homepage`.

## Chart.yaml

```yaml
apiVersion: v2
name: coder
description: Remote development environments
type: application
version: 0.1.0
dependencies:
  - name: coder
    repository: https://helm.coder.com/v2
    version: 2.36.1
    alias: coder
```

Chart version `2.36.1` is the latest published version in the upstream repo's `index.yaml` as of this spec's date. Renovate will pick up future bumps per the repo's usual PR review workflow.

## Postgres Backend

`apps/coder/templates/pg.yaml` defines a dedicated `postgresql` CRD resource for the Zalando postgres-operator (already deployed via `apps/db-operators`), matching the shape of `gotify/templates/pg.yaml`:

```yaml
apiVersion: "acid.zalan.do/v1"
kind: postgresql
metadata:
  name: coder-postgresql
spec:
  teamId: "coder"
  volume:
    size: 20Gi
  numberOfInstances: 1
  users:
    coder:
    - superuser
    - createdb
  databases:
    coder: coder
  postgresql:
    version: "17"
```

### Credential handling — no manual secret

Unlike `gotify` (which pre-creates `templates/secret.yaml` with a hardcoded plaintext password), this app defines **no manual credentials Secret**. The Zalando postgres-operator auto-generates a strong random password into `coder.coder-postgresql.credentials.postgresql.acid.zalan.do` the first time it reconciles a role that doesn't already have a secret — this is documented, built-in operator behavior, not something this chart needs to implement.

This avoids two problems with a `randAlphaNum`-in-Helm-template approach:
- ArgoCD renders this repo via a custom `flagops` Config Management Plugin (`bootstrap/argo-cd/cmp-plugin.yaml`), not `helm install`/`helm upgrade`. Whether its `helm template` invocation supports the `lookup` function (needed to keep a random value stable across re-syncs) is unverified — if it doesn't, a `randAlphaNum` value would regenerate on every sync while the operator's actual DB password stays fixed, breaking the connection.
- Letting the operator own the secret lifecycle end-to-end is simpler and is exactly what the operator is designed to do.

### Wiring the connection string into Coder

Coder's chart takes a single `CODER_PG_CONNECTION_URL` env var (a full DSN), not separate host/user/password fields. This app composes it using Kubernetes' native `$(VAR)` env substitution — no Helm secret templating involved:

```yaml
coder:
  env:
    - name: PGUSER
      valueFrom:
        secretKeyRef:
          name: coder.coder-postgresql.credentials.postgresql.acid.zalan.do
          key: username
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: coder.coder-postgresql.credentials.postgresql.acid.zalan.do
          key: password
    - name: CODER_PG_CONNECTION_URL
      value: "postgres://$(PGUSER):$(PGPASSWORD)@coder-postgresql.coder.svc.cluster.local:5432/coder?sslmode=disable"
```

`$(VAR)` substitution only works for env entries defined via `value:` referencing previously-defined env vars in the same container — this is native Kubernetes behavior, not a Coder-specific feature.

## Ingress, Access URL, Auth

```yaml
coder:
  service:
    type: ClusterIP     # Traefik fronts it; chart default is LoadBalancer (would consume a MetalLB IP)
  ingress:
    enable: true
    className: private-traffic
    host: coder.[{ env "env_domain" }]
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    tls:
      enable: false     # cert-manager/Traefik terminate TLS at the ingress, same as gotify/homepage
  env:
    - name: CODER_ACCESS_URL
      value: "https://coder.[{ env \"env_domain\" }]"
```

- Ingress class is `private-traffic` (internal-only, same as `homepage`/`traefik`/`longhorn`) — not exposed to the internet.
- Auth is Coder's built-in email/password with a first-user setup wizard on first visit to the web UI. No additional Helm values are required for this; it's the default when no OIDC/GitHub OAuth env vars are set.

## Related change: gotify secret migration

As a follow-on to fixing the credential-handling pattern, migrate `gotify` off its hardcoded plaintext secret using the same operator-auto-gen approach:

- Delete `apps/gotify/templates/secret.yaml`.
- Remove the hardcoded `password=gotify` from `GOTIFY_DATABASE_CONNECTION` in `apps/gotify/values.yaml`.
- Rewire the connection string using the same `$(VAR)`-substitution pattern against the operator's auto-generated `gotify.gotify-postgresql.credentials.postgresql.acid.zalan.do` secret.

This is a behavior-preserving change (same DB, same operator-managed cluster) but changes the actual password value in the database — the operator will generate a new random password and update its secret; nothing needs to be done manually since the operator manages both the DB role and the secret together. Should be verified via ArgoCD sync + a gotify health check after merge, same as any other rollout in this repo.

## Explicitly out of scope for this spec

- Workspace templates (Terraform `coder_agent`/`coder_app` resources).
- Nix-config integration (building a workspace image from the user's nix-config flake, home-manager provisioning, persistent `/nix` store PVC).
- `coder config-ssh` / SSH client setup on the user's machine.

These are the natural next sub-project once the control plane is deployed and reachable.

## Verification plan

- `helm dependency update apps/coder/` + `helm lint apps/coder/` + `helm template apps/coder/ --debug` before merging.
- After ArgoCD sync: confirm the `coder` Application reaches `Synced`/`Healthy`, confirm the `coder-postgresql` cluster comes up and the credentials secret is created, and confirm `https://coder.<env_domain>` serves the Coder first-user setup page.
- For the gotify migration: confirm `gotify` Application resyncs cleanly and the app remains reachable/functional (notifications still deliverable) after the password rotation.
