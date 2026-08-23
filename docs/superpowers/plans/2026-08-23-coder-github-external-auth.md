# Coder GitHub External Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up Coder's built-in GitHub External Authentication so `nix-dev` workspaces get automatic git credentials for GitHub, no static SSH key or manual git config needed.

**Architecture:** An `ExternalSecret` pulls the GitHub App's client secret from AWS Secrets Manager into `apps/coder`'s namespace; `apps/coder/values.yaml` adds 5 `CODER_EXTERNAL_AUTH_0_*` env entries to the existing `coder.env` list (client ID plain, client secret via the new Secret); `coder-templates/nix-dev/main.tf` adds a `data "coder_external_auth"` block so the Coder agent auto-injects git credentials once a user has authorized.

**Tech Stack:** Kubernetes ExternalSecret (external-secrets.io), Helm values, Terraform (`coder` provider).

**GitHub App already created by the user** (manual step, not automatable — GitHub has no API for creating OAuth/GitHub Apps):
- Client ID: `Iv23liwNrD7odUfBMsY0` (not secret — GitHub treats client IDs as public, same as any OAuth client_id; safe to commit)
- Client secret: already shared with the user directly, **never written to any file in this plan or the repo** — stored only in AWS Secrets Manager, referenced here only via its remote key name

Reference spec: `docs/superpowers/specs/2026-08-23-coder-github-external-auth-design.md`

---

### Task 1: ExternalSecret for the GitHub App client secret

**Files:**
- Create: `apps/coder/templates/github-external-auth-secret.yaml`

- [ ] **Step 1: Write the ExternalSecret**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: coder-github-external-auth
  namespace: coder
spec:
  secretStoreRef:
    name: aws-secret-manager
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

This does not create the underlying AWS Secrets Manager entry — that's a manual step for the user (Task 5 below), same as every AWS-backed secret in this repo.

- [ ] **Step 2: Validate the YAML parses**

```bash
cd apps/coder
python3 -c "
import yaml
d = yaml.safe_load(open('templates/github-external-auth-secret.yaml'))
assert d['kind'] == 'ExternalSecret'
assert d['metadata']['name'] == 'coder-github-external-auth'
assert d['spec']['data'][0]['remoteRef']['key'] == 'coder-github-external-auth-client-secret'
print('YAML OK')
"
```

If `python3`'s `yaml` module isn't available, install `pyyaml` into a throwaway venv, run the check, then remove the venv.

Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
git add apps/coder/templates/github-external-auth-secret.yaml
git commit -m "feat(coder): add ExternalSecret for GitHub external auth client secret"
```

---

### Task 2: Wire the external auth env vars into the Coder deployment

**Files:**
- Modify: `apps/coder/values.yaml`

- [ ] **Step 1: Add 5 entries to the existing `coder.env` list**

Current end of the file:
```yaml
      - name: CODER_ACCESS_URL
        value: https://coder.[{ env "env_domain" }]
```

Change to:
```yaml
      - name: CODER_ACCESS_URL
        value: https://coder.[{ env "env_domain" }]
      - name: CODER_EXTERNAL_AUTH_0_ID
        value: primary-github
      - name: CODER_EXTERNAL_AUTH_0_TYPE
        value: github
      - name: CODER_EXTERNAL_AUTH_0_CLIENT_ID
        value: Iv23liwNrD7odUfBMsY0
      - name: CODER_EXTERNAL_AUTH_0_CLIENT_SECRET
        valueFrom:
          secretKeyRef:
            name: coder-github-external-auth
            key: client_secret
      - name: CODER_EXTERNAL_AUTH_0_REVOKE_URL
        value: https://api.github.com/applications/Iv23liwNrD7odUfBMsY0/grant
```

Only this block changes — the rest of the file (service/ingress/PGUSER/PGPASSWORD/CODER_PG_CONNECTION_URL) stays exactly as-is.

- [ ] **Step 2: Commit**

```bash
git add apps/coder/values.yaml
git commit -m "feat(coder): configure GitHub external auth on the Coder deployment"
```

---

### Task 3: Full-chart render validation

**Files:** none (validation only)

- [ ] **Step 1: Render the whole `apps/coder` chart**

```bash
cd apps/coder
helm dependency update . >/dev/null 2>&1
helm template . --debug > /tmp/coder-github-auth-render.yaml 2>&1
echo "exit: $?"
grep -c "^kind: ExternalSecret$" /tmp/coder-github-auth-render.yaml
grep -n "CODER_EXTERNAL_AUTH_0_ID\|CODER_EXTERNAL_AUTH_0_CLIENT_ID\|CODER_EXTERNAL_AUTH_0_CLIENT_SECRET\|CODER_EXTERNAL_AUTH_0_REVOKE_URL" /tmp/coder-github-auth-render.yaml
rm -rf Chart.lock charts
```

Expected: exit `0`; `grep -c "^kind: ExternalSecret$"` prints `1` (the new one — confirms no duplication and it coexists fine with the chart's other resources); each `CODER_EXTERNAL_AUTH_0_*` var appears in the rendered Deployment env list, with `CODER_EXTERNAL_AUTH_0_CLIENT_ID` showing the literal value `Iv23liwNrD7odUfBMsY0` and `CODER_EXTERNAL_AUTH_0_CLIENT_SECRET` showing a `secretKeyRef` (not a literal value — if a literal secret value shows up here, STOP, something is wrong, do not commit).

- [ ] **Step 2: Confirm no untracked artifacts remain**

```bash
cd ../..
git status --short apps/coder
```

Expected: clean.

---

### Task 4: Add the workspace template's external auth data source

**Files:**
- Modify: `coder-templates/nix-dev/main.tf`

- [ ] **Step 1: Add the `coder_external_auth` data source**

Find the existing data source declarations near the top of the file:
```hcl
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
```

Add a third one immediately after:
```hcl
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# optional = true: workspace creation/start never blocks on GitHub auth.
# Once a user completes the one-time authorization (a link Coder surfaces
# in the dashboard/CLI), the agent automatically sets up GIT_ASKPASS for
# any github.com HTTPS remote inside the workspace -- no init scripts or
# git config needed here. The id must match CODER_EXTERNAL_AUTH_0_ID on
# the Coder deployment (apps/coder/values.yaml) exactly.
data "coder_external_auth" "github" {
  id       = "primary-github"
  optional = true
}
```

- [ ] **Step 2: Validate**

```bash
NIXPKGS_ALLOW_UNFREE=1 nix profile install nixpkgs#terraform --impure 2>&1 | tail -3
cd coder-templates/nix-dev
terraform fmt -check
terraform init -backend=false >/dev/null 2>&1 && terraform validate 2>&1
rm -rf .terraform .terraform.lock.hcl
cd ../..
git status --short coder-templates/
```

Expected: `terraform fmt -check` prints nothing, `terraform validate` prints `Success! The configuration is valid.`, `git status --short` shows only `coder-templates/nix-dev/main.tf` modified (no untracked `.terraform`/lock file left behind).

- [ ] **Step 3: Commit**

```bash
git add coder-templates/nix-dev/main.tf
git commit -m "feat(coder-templates): wire up GitHub external auth in nix-dev"
```

---

### Task 5: Push, open PR, merge

**Files:** none

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feature/coder-github-external-auth
gh pr create --title "Add GitHub external auth for Coder workspaces" --body "$(cat <<'EOF'
## Summary
- Adds ExternalSecret + Coder deployment config for GitHub External
  Authentication (CODER_EXTERNAL_AUTH_0_*)
- nix-dev template gets a `data "coder_external_auth" "github"` block
  (optional = true, never blocks workspace creation)
- Once authorized (one-time, per Coder user), the agent auto-injects git
  credentials for GitHub HTTPS remotes -- no static SSH key, no manual
  git config

Design spec: docs/superpowers/specs/2026-08-23-coder-github-external-auth-design.md

## Prerequisite (manual, one-time, before this actually authenticates anything)
The GitHub App's client secret must exist in AWS Secrets Manager under the
key `coder-github-external-auth-client-secret` -- documented separately,
not committed here.

## Test plan
- [x] helm template renders the new ExternalSecret + env vars correctly,
      client secret only ever appears as a secretKeyRef, never a literal
- [x] terraform validate passes on the updated nix-dev template
- [ ] After merge + the AWS secret exists: push the template, create a test
      workspace, complete the one-time GitHub authorization, confirm
      `git clone` over HTTPS works from inside the workspace with no
      credential prompt

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Merge**

```bash
gh pr merge --squash --delete-branch
```

Expected: PR merged, branch deleted.

---

### Task 6: Bootstrap the AWS secret and verify end-to-end (blocked on the user creating the AWS secret)

**Files:** none (operational verification, not a code change)

**Precondition:** the AWS Secrets Manager entry `coder-github-external-auth-client-secret` must exist before this task can produce a working authorization. The exact `aws secretsmanager create-secret` command (containing the actual client secret value) is given directly to the user in conversation, not written into this plan file or committed anywhere.

- [ ] **Step 1: Confirm the ExternalSecret synced**

```bash
kubectl get secret coder-github-external-auth -n coder
```

Expected: the Secret exists with a `client_secret` key. If this errors or the secret is empty, **stop here and report status** rather than proceeding — the AWS-side secret likely doesn't exist yet or `external-secrets` hasn't reconciled it.

- [ ] **Step 2: Sync ArgoCD and confirm the Coder deployment picked up the new env vars**

```bash
kubectl patch application coder-production -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

Wait for `Synced`/`Healthy`, then:
```bash
kubectl get deployment coder -n coder -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool | grep -A3 CODER_EXTERNAL_AUTH
```

Expected: all 5 `CODER_EXTERNAL_AUTH_0_*` entries present, `CLIENT_SECRET` shown as a `secretKeyRef` object (never a literal string).

- [ ] **Step 3: Push the updated template and create a real test workspace**

```bash
export CODER_URL="https://coder.graytonward.com"
# CODER_SESSION_TOKEN: use the existing authenticated session from this
# conversation, or re-authenticate if it has since expired/rotated
coder templates push nix-dev -d coder-templates/nix-dev/ --yes
coder create --template nix-dev github-auth-test --yes
```

- [ ] **Step 4: Complete the one-time GitHub authorization**

```bash
coder external-auth access-token primary-github 2>&1
```

Expected: if not yet authorized, this prints a URL to visit to complete GitHub OAuth. Report this URL to the user and wait for them to complete it interactively (this step cannot be automated — it's an actual GitHub OAuth consent screen).

- [ ] **Step 5: Verify git access from inside the workspace**

Once authorized:
```bash
coder ssh github-auth-test -- 'git ls-remote https://github.com/graytonio/homelab-flagops-templates.git 2>&1 | head -3'
```

Expected: a list of refs (commit SHAs + branch names), with no credential prompt or authentication error — proof the `GIT_ASKPASS` injection actually works.

- [ ] **Step 6: Clean up the test workspace**

```bash
coder delete github-auth-test --yes
```

---

## Explicitly out of scope

- Other git providers (GitLab, Bitbucket, etc.).
- Making auth mandatory (`optional = false`).
- Automating GitHub App creation (impossible — no GitHub API for it) or AWS
  secret creation (no AWS credentials available in this environment).
