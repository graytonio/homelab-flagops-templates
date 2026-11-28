# muster

[muster](https://github.com/graytonio/agent-muster) runs multi-agent coding workflows (plan → build → review → PR) on a herdr server. This app runs one pod with:

- the herdr server
- muster
- Claude Code
- git and gh
- tailscaled, so you can reach the pod over Tailscale SSH

The pod has no ingress or Service.

The image is `ghcr.io/graytonio/muster`, built by agent-muster's release workflow. [`container/entrypoint.sh`](https://github.com/graytonio/agent-muster/blob/main/container/entrypoint.sh) in that repo documents what the pod does on startup.

## What's here

| Path | What it is |
|---|---|
| `config/` | The muster config directory: `muster.toml`, `workflows/`, `prompts/`. It's packed into the `muster-config` ConfigMap and mounted read-only at `/etc/muster`. Edits apply to the next `muster start` without a pod restart. Runs already in flight keep the snapshot they started with. |
| `values.yaml` | Image, repos to clone, git identity, Tailscale hostname, secret names, PVC size. |
| `templates/` | Deployment, ConfigMap, PVC (`muster-data`, never pruned), ExternalSecret. |

Validate config changes before merging:

```sh
muster validate --config-dir apps/muster/config
```

## Prerequisites (one-time)

1. **Secrets in AWS Secrets Manager.** The ExternalSecret `muster-secrets` reads three entries. The pod won't start until all three exist.

   | Entry | JSON | Notes |
   |---|---|---|
   | `coder-claude-token` | `{"token": "..."}` | Already exists for coder. It's from `claude setup-token`. |
   | `muster-github-token` | `{"token": "..."}` | Fine-grained PAT on the repos muster works on: Contents and Pull requests read/write, Metadata read. Add Workflows write if agents may touch `.github/workflows`. |
   | `muster-tailscale-authkey` | `{"authkey": "tskey-auth-..."}` | Must not be ephemeral. Tailscale state persists on the PVC, so the key is only used the first time. |

   ```sh
   aws secretsmanager create-secret --region us-east-1 --name muster-github-token \
     --secret-string '{"token":"github_pat_..."}'
   aws secretsmanager create-secret --region us-east-1 --name muster-tailscale-authkey \
     --secret-string '{"authkey":"tskey-auth-..."}'
   ```

2. **Tailscale SSH access.** Your tailnet policy must allow you to SSH to the node as `muster`. If the auth key is tagged (e.g. `tag:muster`), add a rule like this:

   ```json
   "ssh": [{"action": "accept", "src": ["autogroup:member"], "dst": ["tag:muster"], "users": ["muster"]}]
   ```

   Without tags, the node belongs to you. The default policy's `autogroup:self` rule already allows `autogroup:nonroot` users, and `muster` is one of those.

3. **Image visibility.** The first push to `ghcr.io/graytonio/muster` creates a private package. Either make it public (GitHub → Packages → muster → Package settings), or add an image pull secret here.

4. **Repos.** List the repos muster should work on in `values.yaml` under `repos:`. The pod clones any that are missing at startup. A repo added later is cloned on the next pod restart, or you can clone it by hand over SSH into `/var/lib/muster/repos/<name>`.

## Using it

```sh
ssh muster@muster muster doctor          # every runtime check should pass
ssh muster@muster 'muster start feature --repo <name> --brief-stdin --detach' < brief.md
ssh muster@muster muster status
herdr --remote muster@muster             # watch the agents' panes
```

Pod logs show the startup steps and the first `muster doctor` result:

```sh
kubectl -n muster logs deploy/muster
```

## Things to know

- **A pod restart stops every running agent.** This includes image bumps, ConfigMap-unrelated chart changes, and node drains. herdr restores its layout, but not the agent processes. Run `muster status` afterwards and `muster resume` affected runs. Don't merge image bumps while runs are in flight.
- **Persistent data.** The PVC holds everything stateful:
  - the muster user's home: herdr session, Claude Code state, `gh`/git config
  - run state and logs
  - repos and worktrees
  - Tailscale node state

  Longhorn has no backup target, so deleting the PVC loses all of it. Expect a new Tailscale identity in that case.
- **Upgrading tools.** Claude Code auto-update is disabled because the binary is part of the image. Upgrading Claude Code or herdr means a new muster image.
