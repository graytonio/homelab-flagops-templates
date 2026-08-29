terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
  }
}

provider "coder" {}

# config_path = null triggers in-cluster auto-auth -- Terraform runs inside
# the coder-production pod itself, using the coder ServiceAccount, which
# already has full CRUD on pods/persistentvolumeclaims in this namespace
# (chart default serviceAccount.workspacePerms: true).
provider "kubernetes" {
  config_path = null
}

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

locals {
  # The agent's init_script downloads the coder agent binary from a URL
  # baked in at template-push time from the server's CODER_ACCESS_URL --
  # this is NOT read dynamically from a CODER_AGENT_URL env var at
  # container runtime (confirmed empirically: setting that env var alone
  # did not change the hardcoded download URL in the generated script).
  # That public hostname isn't resolvable from inside this cluster's pod
  # network (confirmed via `kubectl run --rm -i busybox -- nslookup`:
  # CoreDNS returns NXDOMAIN, since cluster nodes' upstream resolver
  # doesn't cover the homelab's private DNS zone). Fix: inject a
  # /etc/hosts entry via host_aliases mapping that same hostname to an
  # in-cluster IP, so curl resolves it locally without touching
  # cluster-wide DNS config. This must point at the private Traefik
  # ingress's ClusterIP (traefik-production-privateingress), NOT the
  # coder Service directly -- the URL is https:// and the coder Service
  # only listens on port 80 (TLS terminates at the Traefik ingress, which
  # then does SNI/Host-based routing to the coder Service). Pointing
  # straight at the coder Service's ClusterIP:80 for an https:// request
  # just hangs (confirmed empirically: curl sat with no output/no error
  # for 20+s, since nothing in the chain expected TLS on that port).
  #
  # The IP is hardcoded rather than looked up via a kubernetes_service
  # data source: the coder ServiceAccount's RBAC (chart default) only
  # grants pods/persistentvolumeclaims, not services -- widening it just
  # for this lookup isn't worth the extra permission surface for a value
  # that only changes if the Traefik LoadBalancer Service is deleted and
  # recreated (essentially never). If that ever happens, get the new
  # value with `kubectl get svc traefik-production-privateingress -n
  # traefik -o jsonpath='{.spec.clusterIP}'` and update it here.
  traefik_private_cluster_ip = "10.43.33.82"
  coder_access_host          = regex("^https?://([^/]+)", data.coder_workspace.me.access_url)[0]
  # home-manager's activation writes ~/.nix-profile/etc/profile.d/hm-session-vars.sh,
  # which sets NIX_SSL_CERT_FILE/SSL_CERT_FILE (TLS trust for nix-built git/kubectl/etc,
  # since nix binaries don't trust the base image's system CA store by default) and
  # LOCALE_ARCHIVE (glibc locale data for fish/starship/nvim). These paths are
  # content-addressed Nix store paths that change on every flake.lock update in the
  # nixos-config repo, so they can't be hardcoded as static image ENV vars -- source
  # the script dynamically here instead, right before starting the Coder agent, so
  # the agent (and everything it spawns: terminal sessions, SSH sessions) inherits a
  # correctly-configured environment regardless of which image build is running.
  agent_start_script = "[ -f $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh; ${coder_agent.main.init_script}"

  # Pinned deliberately rather than resolved from the GitHub API at install
  # time, matching how the workspace image below is pinned by digest: an
  # upgrade should be a reviewable one-line commit, and two workspaces
  # created months apart should get the same editor.
  #
  # Bumping this has a coupling that is easy to miss: the release tarball ships
  # prebuilt native modules (node-pty and friends) built against the Node major
  # in its .node-version, and we run them under the image's Nix node rather
  # than the tarball's bundled one. 4.135.0 wants 24.18.1 and the image ships
  # 24.19.0 -- same major, same NODE_MODULE_VERSION, so they load. If either
  # side crosses a major (this pin, or nodejs in the nixos-config flake), those
  # modules fail to load at runtime in the integrated terminal and extension
  # host, while the startup liveness check and /healthz both still pass. Check
  # `node --version` in the workspace against the release's .node-version.
  code_server_version = "4.135.0"
  code_server_port    = 13337
  # Under $HOME, so this lands on the Longhorn PVC and the ~235MB download
  # happens on first start only. Version-suffixed so a version bump installs
  # cleanly alongside rather than half-overwriting the old tree.
  code_server_dir = "/home/coder/.local/lib/code-server-${local.code_server_version}"
}

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
#
# The shebang below is decorative -- Coder passes this body to the login shell
# with -c rather than exec'ing it as a file. What actually guarantees bash
# semantics (set -euo pipefail, [ ! -f ], backgrounding) is root's passwd shell
# being Nix bash; worth knowing because this image also ships fish. The curl
# call additionally depends on the CA-certificate environment that
# local.agent_start_script sources from hm-session-vars.sh, documented above.
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
    # Every path below is derived from DIR, never from $HOME. The Coder agent
    # passes this script to the login shell, and its environment is not
    # guaranteed to carry the container's HOME (/home/coder) rather than
    # root's passwd entry (/root). If the two ever disagreed, the prune below
    # would run against a nonexistent directory, fail under set -e, and stop
    # the editor from ever starting -- with nothing in the log but a find error.
    LIB_DIR="$(dirname "$DIR")"
    LOG_DIR="$(dirname "$LIB_DIR")/share"
    LOG="$LOG_DIR/code-server.log"

    # Unconditional, and before the prune: the prune must never be the thing
    # that depends on the install branch having created these first.
    mkdir -p "$LIB_DIR" "$LOG_DIR"

    # The log is appended to (never truncated) on every start and lives on the
    # PVC, so bound it or it grows for the life of the workspace.
    [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 10485760 ] && mv "$LOG" "$LOG.1" || true

    # The `|| true` keeps a failing tee (unwritable $LOG_DIR, full volume) from
    # aborting the script here, since this is a pipeline and pipefail is set.
    # It does NOT make the editor survive a broken log destination -- node's
    # own `>> "$LOG"` redirect below needs the same file, so the launch fails
    # and the liveness check reports it (verified: an unwritable log yields
    # "code-server exited immediately", exit 1). The guard just ensures that
    # failure is diagnosed at the launch, rather than aborting silently at the
    # first log line before any work has been done.
    log() { echo "$*" | tee -a "$LOG" || true; }

    if [ ! -f "$DIR/out/node/entry.js" ]; then
      log "Installing code-server $VERSION into $DIR"
      # Extract to a sibling and rename, so out/node/entry.js -- the
      # idempotency sentinel checked above -- can only appear on a complete
      # tree. It is member 6544 of 6584 in the tarball, so a download
      # truncated in the last ~40 members would otherwise leave the sentinel
      # present with its required modules missing, and every later start would
      # report "already installed" while code-server died on MODULE_NOT_FOUND.
      TMP="$DIR.partial"
      rm -rf "$TMP"
      mkdir -p "$TMP"
      curl -fsSL "https://github.com/coder/code-server/releases/download/v$VERSION/code-server-$VERSION-linux-amd64.tar.gz" \
        | tar -xz -C "$TMP" --strip-components=1
      rm -rf "$DIR"
      mv "$TMP" "$DIR"
    else
      log "code-server $VERSION already installed at $DIR"
    fi

    # After the install, so bumping local.code_server_version still lands the
    # new tree on disk, but BEFORE the prune below: this guard exists precisely
    # because the script can re-run while an instance is live, and in that
    # situation pruning would delete the directory the running process was
    # launched from, breaking its lazy require()s and extension-host spawns
    # until the pod restarts.
    if curl -fsS "http://127.0.0.1:${local.code_server_port}/healthz" >/dev/null 2>&1; then
      log "code-server already listening on ${local.code_server_port}; not starting a second instance"
      exit 0
    fi

    # Reclaim PVC space from any previously pinned version. -mindepth 1 keeps
    # LIB_DIR itself out of scope; any leftover .partial tree is swept too.
    find "$LIB_DIR" -mindepth 1 -maxdepth 1 -name 'code-server-*' ! -name "code-server-$VERSION" -exec rm -rf {} +

    # No nohup/disown needed: the agent runs scripts without a controlling
    # terminal, so nothing sends SIGHUP when this script exits. Appending
    # rather than truncating keeps the previous boot's crash output, which is
    # the only debug surface this feature has.
    # --user-data-dir/--extensions-dir are passed explicitly even though these
    # are exactly code-server's defaults today. Everything above deliberately
    # avoids trusting $HOME, but code-server resolves both of these from
    # $XDG_DATA_HOME/$HOME internally -- so in the very scenario that hardening
    # defends against, the script would run fine and log to the PVC while every
    # setting and installed extension landed on ephemeral container storage and
    # vanished on the next restart. Quieter failure than the one it replaced.
    node "$DIR/out/node/entry.js" \
      --auth none \
      --bind-addr "127.0.0.1:${local.code_server_port}" \
      --user-data-dir "$LOG_DIR/code-server" \
      --extensions-dir "$LOG_DIR/code-server/extensions" \
      --disable-telemetry \
      >> "$LOG" 2>&1 &
    PID=$!

    # set -e cannot observe a backgrounded process, so without this check the
    # script reports success even when node exits instantly (bad flag, missing
    # module, port already bound) and only the coder_app healthcheck notices,
    # ~30s later, while this log claims it started.
    sleep 2
    if ! kill -0 "$PID" 2>/dev/null; then
      log "code-server exited immediately; last log lines:"
      tail -20 "$LOG"
      exit 1
    fi

    log "code-server started on 127.0.0.1:${local.code_server_port} (pid $PID), logging to $LOG"
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
  # The provider default is "slim-window", a chrome-less popup that browsers'
  # popup blockers sometimes eat on first click -- and a full IDE wants the
  # room anyway.
  open_in = "tab"

  # Holds the dashboard tile in an unhealthy state until the editor actually
  # serves, instead of offering a link that 502s. Note the grace period here is
  # 30s (interval x threshold) while a first-ever start spends minutes
  # downloading ~235MB, so expect a multi-minute unhealthy window exactly once
  # per workspace; it flips healthy on its own once /healthz answers.
  healthcheck {
    url       = "http://localhost:${local.code_server_port}/healthz"
    interval  = 5
    threshold = 6
  }
}

# No `count` here -- this must persist across workspace stop/start, unlike
# the pod below.
#
# Named using the workspace's stable `id` (not `name`) so renaming the
# workspace doesn't orphan this PVC -- Terraform would otherwise see the
# name change as "create a new resource" and lose track of the old one
# and its data.
resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.id}-home"
    namespace = "coder"
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
}

# start_count is 0 when the workspace is stopped and 1 when running -- this
# is what makes Coder's stop/start actually delete/recreate the pod while
# the PVC above stays put.
#
# A bare Pod (not a Deployment) is a deliberate choice: container-level
# restart-on-crash still works via kubelet's default restartPolicy=Always,
# and stop/start already works via the count toggle below. The trade-off is
# no pod-level self-healing if the node itself reboots/evicts this pod --
# acceptable for a single-user homelab where that's noticed quickly, but
# worth knowing if this ever needs hands-off reliability.
resource "kubernetes_pod_v1" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    namespace = "coder"
  }
  spec {
    # Mounting the PVC directly at /home/coder in the main container hides
    # whatever the image has baked in at that same path (confirmed
    # empirically: `docker run` against the raw image shows fish/go/kubectl
    # present via /home/coder/.nix-profile, but a workspace with the PVC
    # mounted there had none of it -- the empty volume shadows the image
    # content, standard Kubernetes mount behavior). Fix: this init
    # container mounts the PVC at a different path (so nothing shadows the
    # image's real /home/coder here) and, only on first boot, copies the
    # baked home directory into it. The main container's mount then sees a
    # pre-seeded copy instead of an empty directory. First-boot detection
    # checks specifically for .nix-profile, not "is the directory empty" --
    # a fresh ext4-formatted Longhorn volume always contains a lost+found
    # directory, so a naive emptiness check (confirmed empirically) never
    # sees the volume as empty and the seed never runs. Known limitation:
    # only seeds once -- if nixos-config publishes a new image later, an
    # already-created workspace's PVC won't pick up the updated profile
    # automatically (would need a fresh workspace, or a manual
    # `home-manager switch` inside it).
    init_container {
      name    = "seed-home"
      image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:466bdc3f965ff7376e4bc241deebfc59895cfe25d849541cc1f164891597cac3"
      command = ["sh", "-c", "if [ ! -e /mnt/persistent-home/.nix-profile ]; then cp -a /home/coder/. /mnt/persistent-home/; fi"]

      volume_mount {
        mount_path = "/mnt/persistent-home"
        name       = "home"
      }
    }

    container {
      name    = "dev"
      image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:466bdc3f965ff7376e4bc241deebfc59895cfe25d849541cc1f164891597cac3"
      command = ["sh", "-c", local.agent_start_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }

    host_aliases {
      ip        = local.traefik_private_cluster_ip
      hostnames = [local.coder_access_host]
    }
  }

  # The image is large (go/rust/node/kotlin toolchains, vscode, etc.) --
  # a cold pull on a node that hasn't cached it yet can take several
  # minutes, well past this resource's default wait timeout. Confirmed
  # empirically: a real workspace creation hit "context deadline exceeded"
  # waiting on a first-time pull.
  timeouts {
    create = "15m"
  }
}
