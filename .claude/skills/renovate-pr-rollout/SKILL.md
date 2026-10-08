---
name: renovate-pr-rollout
description: Use when reviewing, merging, or rolling out a batch of open Renovate PRs in this repo — for a full sweep of open dependency PRs, deciding which are safe to merge, verifying a major Helm chart bump won't break production, or confirming a merged PR actually landed healthy in ArgoCD. Also use when an ArgoCD Application's sync revision looks stuck/empty despite a merge, or before touching an app with PersistentVolumeClaims during an upgrade.
---

# Renovate PR Rollout

## Overview

End-to-end process for taking a batch of open Renovate PRs in this repo from
"open" to "merged and verified healthy in production," with enough rigor to
catch breaking changes that changelogs don't mention. Complements this repo's
CLAUDE.md, which already has the risk-tier priority list, the per-chart
migration notes (k8s-monitoring v1→v4, Traefik v36+, ArgoCD v2→v3), and basic
troubleshooting commands — read those first, this skill is the workflow that
ties them together.

## When to Use

- User asks to "review the Renovate PRs", "merge what's safe", "roll out the
  dependency updates", or similar batch-PR sweep.
- Verifying whether a specific major-version PR is safe before merging.
- An ArgoCD Application's sync status looks stuck after a merge (see the
  multi-source revision gotcha below).
- Any upgrade that touches PVCs, LoadBalancer Services, or other stateful
  resources.

## Phase 1 — Survey and parallel research

```bash
gh pr list --state open --json number,title,url,author,createdAt
```

For each PR, grep the affected `Chart.yaml`/`values.yaml` to find the
*currently deployed* version (Renovate's title only tells you the target).

Dispatch **one research subagent per PR** (group trivial patch bumps
together), all launched in a single parallel batch. Each subagent prompt must
be self-contained — no shared conversation context — and must include:

- PR number, current vs. target version, affected app/files.
- Instruction to run `gh pr view <n>` / `gh pr diff <n>` to confirm exact scope.
- Instruction to fetch upstream release notes via `gh release list -R <org>/<repo>`
  and `gh release view <tag> -R <org>/<repo>` — **not** raw web fetches (this
  repo's CLAUDE.md mandates `gh` for PR/release research).
- Instruction to read the app's actual current `values.yaml`/`Chart.yaml` so
  the verdict is grounded in this repo's config, not generic changelog prose.
- A required verdict, exactly one of:
  - **SAFE TO MERGE**
  - **MERGE BUT SCHEDULE OFF-PEAK** (higher-risk apps per CLAUDE.md's
    priority list — metallb, longhorn, external-dns, external-secrets, traefik)
  - **NEEDS MANUAL CHANGES BEFORE MERGE** (major bump, breaking values.yaml schema)
  - **INVESTIGATE FURTHER**
- A report length cap (under 200–300 words) so results stay skimmable.

## Phase 2 — Merge the SAFE TO MERGE batch

Merge **one PR at a time**, each followed immediately by Phase 3 verification
before starting the next merge. Never batch merges — a bad rollout must be
caught before it's compounded by the next one.

This repo squash-merges exclusively (confirm with `git log --merges`, which
should show none — only squash commits carrying PR numbers):

```bash
gh pr merge <number> --squash --delete-branch
```

## Phase 3 — Track the rollout in ArgoCD

Applications are named `<app>-production`:

```bash
kubectl -n argocd get application \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

**Gotcha — multi-source Applications have no `.status.sync.revision`.** Many
Applications here use the FlagOps Helm CMP plugin as a multi-source
Application (`spec.sources`, plural). For those, `.status.sync.revision` is
always empty — polling it spins forever. The synced git revision instead
lives at `.status.history[-1:].revisions[0]` (a list, even for one source).

Correct poll pattern:

```bash
sha=$(gh pr view <number> --json mergeCommit -q '.mergeCommit.oid')

until [ "$(kubectl -n argocd get application <app>-production \
    -o jsonpath='{.status.history[-1:].revisions[0]}')" = "$sha" ] \
  && [ "$(kubectl -n argocd get application <app>-production \
    -o jsonpath='{.status.sync.status}')" = "Synced" ] \
  && [ "$(kubectl -n argocd get application <app>-production \
    -o jsonpath='{.status.health.status}')" = "Healthy" ] \
  && [ "$(kubectl -n argocd get application <app>-production \
    -o jsonpath='{.status.operationState.phase}')" = "Succeeded" ]; do
  sleep 5
done
```

All four conditions are required together.

**Single-source Applications are the opposite.** `argo-cd` (and any other
Application with singular `spec.source`) records its revision in
`.status.sync.revision` and leaves `.status.history[-1:].revisions` empty, so
the poll above never matches for it. Read both and use whichever is set:
`-o jsonpath='{.status.history[-1:].revisions[0]}{.status.sync.revision}'`.
Similarly, `.status.operationState.syncResult` only describes the *last*
operation — ArgoCD sometimes follows a full sync with an immediate "partial
sync" (seen pruning RBAC in coder), so prune counts there can look short. To
confirm a prune, check the resource is absent from `.status.resources`.

**ArgoCD's "Healthy" can lag reality.** Cross-check actual pods:
`kubectl -n <namespace> get pods`. A pod can crash-loop for a few seconds
right after sync while ArgoCD still reports stale "Healthy".

**`Running 1/1` does not mean the app is up — always make a real request.**
Several images here (linuxserver/* in pirate-ship) keep the container alive
after the application process exits, and app-template's default TCP probes
don't catch it. Prowlarr 2.5.2 → 2.6.5 (#189) was reported "verified" on
pod readiness alone while the app had crashed at startup; Traefik returned
502 for over an hour until a later sweep caught it. After every rollout, hit
the app's ingress and require a 2xx/3xx:

```bash
# Private hosts don't resolve from inside the cluster -- target the private
# Traefik Service directly instead of relying on DNS.
PIP=$(kubectl -n traefik get svc traefik-production-privateingress -o jsonpath='{.spec.clusterIP}')
curl -s -o /dev/null -m 10 --resolve <host>:443:$PIP -w '%{http_code}\n' https://<host>/
```

and scan the logs for startup failures, not just restarts:
`kubectl -n <ns> logs deploy/<name> | grep -E 'Fatal|Exception'`.

**Gotcha — the *arr apps' `config.xml` is a read-only ConfigMap.** Radarr,
Sonarr, Prowlarr and Lidarr mount `apps/pirate-ship/templates/config-map.yaml`
at `/config/config.xml` via `subPath`. Any new release that reads a config
key with `persist: true` (the default in `ConfigFileProvider.GetValue`) and
finds it missing tries to write a default and **crashes on startup** with
`UnauthorizedAccessException: Access to the path '/config/config.xml' is
denied`. That's what broke Prowlarr 2.6.x (`AllowedHosts`). For any *arr
bump, diff `src/NzbDrone.Core/Configuration/ConfigFileProvider.cs` between
the old and new tags for new `GetValue("<Key>", ...)` calls without
`persist: false`, and add each key to that app's ConfigMap (an empty element
is fine -- an existing element is read without a write) **before** merging.
One `[Error] Task Error ... config.xml is denied` per start from
`DeleteOldValues` is expected and harmless — every *arr logs it.

**StatefulSet/DaemonSet slow rollouts are normal.** Ordinal-by-ordinal
replacement (seen with ArgoCD's own redis-ha-server, and observability's
Alloy StatefulSet) can leave health at "Progressing" for several minutes.
Not a failure by itself — confirm via `kubectl get pods` that nothing is
actually crash-looping, and that it eventually resolves.

## Phase 4 — Snapshot state before touching stateful/network infra

Before merging anything touching metallb (LoadBalancer IPs), longhorn or any
PVC-bearing app-template migration, capture a baseline:

```bash
kubectl get svc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName,AGE:.metadata.creationTimestamp
```

Diff against the same snapshot after rollout. Watch for:

- A LoadBalancer external IP that moved.
- A PVC whose **VOLUME** (bound PV) or **AGE** changed while the PVC *name*
  stayed the same — this is silent data loss: the app happily mounts
  whatever empty PV matches its storage class/size, so a matching name proves
  nothing.

This exact failure happened once already in this repo's history: an
AdGuardHome app-template v5 migration kept PVC names stable via
`forceRename`, but the pod attached to brand-new PV IDs anyway — config,
filter rules, and query history were lost, and it wasn't root-caused because
Kubernetes events only retain ~12 minutes of history. **Name stability alone
is not proof of data continuity.** Always diff VOLUME and AGE, before and
after, for anything touching persistence.

## Phase 5 — Major bumps needing manual values.yaml prep

When a research agent returns NEEDS MANUAL CHANGES:

1. `gh pr view <number> --json headRefName` → get the exact branch name, then
   `git fetch origin <branch>` and check it out locally.
2. `git rebase origin/main` — Renovate branches are often stale; rebase
   first so the diff isn't polluted by already-merged changes from earlier
   in the batch.
3. Make the manual fix commits on top.
4. **Verify by rendering the chart before/after** (see sub-technique below)
   rather than trusting the changelog's summary — changelogs describe
   framework-level changes and miss repo-specific consequences.
5. `git push --force-with-lease origin <local-branch>:<branch>`, then confirm
   the PR picked it up: `gh pr view <number> --json headRefOid` (allow a few
   seconds for GitHub API propagation).
6. `gh pr merge <number> --squash --delete-branch`.
7. Track per Phase 3, with extra scrutiny per Phase 4 if PVCs are involved.

**Gotcha — Helm never upgrades existing CRDs.** `helm template`/`helm install`
only *installs* CRDs from a chart's `crds/` directory if they're missing —
it never updates ones already in the cluster, even on a major version bump.
If the new chart's manifests use fields the old CRD schema doesn't know
about, ArgoCD's sync gets stuck with a `ComparisonError` (sync status
`Unknown`) reading something like:

```
error building typed value from config resource: .configuration.<field>: field not declared in schema
```

or, after the CRD partially catches up, a `SyncError` naming the still-missing
fields. Nothing is broken yet at this point — the workload keeps running on
its pre-upgrade state until the sync actually completes, so there's no rush,
but the sync won't resolve on its own. Fix: pull the CRDs from the *new*
chart version (they live in `<chart>/crds/*.yaml` in the tarball you already
pulled for the render-diff sub-technique) and apply them directly:

```bash
kubectl apply --server-side --force-conflicts -f new/<chart>/crds/<file>.yaml
```

Before applying, diff the CRD against the live one (`kubectl get crd <name>
-o yaml`) to confirm the change is additive (new optional fields) rather than
removing/renaming anything a live custom resource depends on — same
diligence as the resource-render diff below, just applied to the CRD schema
itself. Once applied, ArgoCD's next reconcile (automatic, since `selfHeal` is
on for every Application in this repo) picks it up — no manual re-sync
needed, but re-check status a few seconds later since a stale `SyncError`
condition can still be showing from before the CRD fix landed.

This happened on the postgres-operator v1→v2 bump: the `OperatorConfiguration`
CRD was missing `enable_maintenance_windows` and (after the first CRD apply)
`logical_backup.logical_backup_failed_jobs_history_limit` too — the chart
adds fields incrementally across its own default values, so check the sync
error message again after each CRD apply rather than assuming one pass gets
everything. All three of the operator's CRDs
(`operatorconfigurations`, `postgresqls`, `postgresteams`) may need updating
together even if the sync error only names one.

## Sub-technique: verify a major bump by rendering, not reading

This is the highest-value technique in this workflow — it has caught real
breaking changes (an immutable Deployment selector-label rename; a default
resource-naming change that would have orphaned PVCs and broken a
hostname-hardcoded Service) that changelog-only review missed.

```bash
# 0. Locate helm if not on PATH (Nix environments):
find / -maxdepth 6 -iname helm -type f 2>/dev/null

# 1. Pull both versions
helm repo add <name> <url> && helm repo update
helm pull <chart> --version <old> --untar --untardir old
helm pull <chart> --version <new> --untar --untardir new
```

This repo's `values.yaml` uses FlagOps templating (`[{ env "VAR" }]`,
`[{- if env "VAR" }] ... [{- end }]`) which is not valid raw YAML. Strip it
before feeding to `helm template`:

```python
import re, yaml

CTRL = re.compile(r'^\[\{-?\s*(if|end|else).*\}\]$')
EXPR = re.compile(r'\[\{.*?\}\]')

lines = [l for l in open("values.yaml") if not CTRL.match(l.strip())]
text = EXPR.sub('"dummy"', "".join(lines))
data = yaml.safe_load(text)
yaml.safe_dump({"<alias>": data["<alias>"]}, open("/tmp/target-values.yaml", "w"))
```

```bash
# Render both, using the ACTUAL production release name (see gotcha below)
helm template <release-name> old/<chart> -f /tmp/target-values.yaml > /tmp/old.yaml
helm template <release-name> new/<chart> -f /tmp/target-values.yaml > /tmp/new.yaml

# Compare resource identities — use `yq eval`, NOT `yq eval-all`
# (eval-all merges the whole multi-doc stream and silently gives wrong output)
diff \
  <(yq eval 'select(.kind != null) | .kind + "/" + .metadata.name' /tmp/old.yaml | sort -u) \
  <(yq eval 'select(.kind != null) | .kind + "/" + .metadata.name' /tmp/new.yaml | sort -u)
```

Any changed PVC/Service/ConfigMap name is an orphaning/breakage risk — fix
via the chart's naming-override mechanism if one exists (bjw-s-labs
app-template v5 exposes `forceRename`/`prefix`/`suffix` per resource; check
`<chart>/charts/common/values.schema.json` for equivalents in other charts).

Also diff `spec.selector` on any Deployment/StatefulSet between renders — a
changed label key there is immutable in Kubernetes and will hard-fail
ArgoCD's sync unless you add `argocd.argoproj.io/sync-options: Replace=true`
to that resource's annotations. For bjw-s app-template,
`controllers.<name>.annotations` maps straight to the Deployment's own
`metadata.annotations` — confirmed by rendering, not assumed.

**Gotcha — resource names depend on the ACTUAL release name.** Helm's
fullname template uses `fullnameOverride` if set; otherwise
`<release-name>-<chart-name>` (or just `<release-name>` if it already
contains the chart name). In this repo, ArgoCD Application/release names are
typically `<app>-production`, not `<app>`. An app without an explicit
`fullnameOverride` gets production resources prefixed accordingly — e.g. a
PVC ends up `gotify-production-data`, not `gotify-data`. A first pass on this
exact app once assumed the release name was `gotify` and computed the wrong
`forceRename` target; it was only caught by cross-checking against
`kubectl get pvc -n <namespace>` live output before merging. **Always verify
any computed/pinned resource name against the live cluster resource, for any
app without an explicit `fullnameOverride`, before trusting a local render.**

**Gotcha — a research subagent's NEEDS MANUAL CHANGES verdict can overstate
the risk.** Subagents reason from changelogs and schema diffs, which flag a
value as "moved" or "renamed" without knowing whether this repo's config for
that value was ever actually wired up in the first place. On the Traefik
v39→v41 bump, a research pass correctly found that `service.loadBalancerIP`
moved to `service.spec.loadBalancerIP` in v40, and flagged it as blocking
since this repo set the old top-level key. Tracing the *actual* Go template
in both the old and new chart tarballs (`grep -rn loadBalancerIP
old/<chart>/templates/`, then read the helper template that consumes it)
showed the old chart never read the top-level key at all — it was already a
silent no-op, and the LoadBalancer IP's real stability came from MetalLB
remembering the assignment per Service object, not from this Helm value. The
fix was still worth making (for correctness, and so the pin becomes
functional for the first time), but it was not a break — a plain `helm
template ... > /tmp/out.yaml` with the repo's as-is values against the new
chart, checked for a non-zero exit or schema error, confirmed no sync
failure either way. **Before treating a subagent's blocking verdict as fact,
spend two minutes tracing whether the field was actually consumed by the
currently-deployed chart version** — it changes both the urgency and the
correct fix.
