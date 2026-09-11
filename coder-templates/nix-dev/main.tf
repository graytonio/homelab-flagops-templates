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

# Optional list. Empty means "no repos" and every piece below no-ops, so a
# workspace created without it behaves exactly as before.
#
# A list rather than a single string because the case this exists for is a
# project spread across several repositories: they are cloned side by side under
# ~/repos and, from two upwards, opened together as one multi-root VS Code
# workspace so search and go-to-definition span all of them.
#
# mutable = true so an existing workspace can gain or change repos via `coder
# update` rather than being recreated. Each clone only happens on a start where
# its target directory is absent, so adding a repo clones just the new one and
# removing one leaves the existing clone untouched on disk.
#
# Replaces an earlier single-string `repo_url`. Coder stores list(string) values
# as a JSON array, which a bare URL string would not parse as, so this is a new
# parameter name rather than a type change on the old one -- existing workspaces
# simply pick the list up empty on their next update.
data "coder_parameter" "repo_urls" {
  name         = "repo_urls"
  display_name = "Git repositories"
  description  = "Optional. Each is cloned to ~/repos/<name> on first start. One repo opens as the editor's root; two or more open together as a multi-root workspace."
  type         = "list(string)"
  default      = jsonencode([])
  mutable      = true
  icon         = "/icon/git.svg"
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
  #
  # Home-manager's activation runs first, and has to. The home directory below
  # is a PVC seeded from the image exactly once and never re-seeded, so the
  # home-manager dotfile symlinks it captured freeze pointing at whichever
  # home-manager-files store path the seeding image had. Every later image
  # digest bump changes that hash and leaves them dangling -- fish, starship,
  # tmux and nvim silently lose their config while still starting normally, so
  # the shell looks fine and simply behaves like a stock one. Confirmed
  # empirically: ~/.config/fish/config.fish pointed at a store path absent from
  # the running image. Re-activating re-points every link at the current image
  # (~500ms, idempotent, leaves PATH and ~/.nix-profile alone).
  #
  # /hm-activation is a stable out-link created by coder/Dockerfile in
  # nixos-config. The glob is a fallback for images built before that existed;
  # it works because those images carry exactly one generation, but it would
  # pick arbitrarily if one ever carried more, which is why the out-link is the
  # preferred path rather than the only one.
  #
  # `|| true` is load-bearing: activation must never abort this chain. If it
  # fails the agent still has to come up, otherwise the workspace is
  # unreachable and the failure cannot be diagnosed from inside it.
  agent_start_script = <<-EOT
    ACT=/hm-activation
    [ -x "$ACT/activate" ] || ACT=$(ls -d /nix/store/*-home-manager-generation 2>/dev/null | head -1)
    [ -x "$ACT/activate" ] && "$ACT/activate" || true
    [ -f $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh ] && . $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh
    ${coder_agent.main.init_script}
  EOT

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

  # The parameter arrives as a JSON array string. Guarded against an empty value
  # because jsondecode("") is an error, and a workspace migrating from the old
  # single-string parameter can present exactly that.
  repo_urls_raw = trimspace(data.coder_parameter.repo_urls.value) == "" ? [] : jsondecode(data.coder_parameter.repo_urls.value)

  # Filtered, not merely trimmed. These values are interpolated into the startup
  # script, so the character class is an allowlist of what actually appears in a
  # git URL rather than a blocklist of what looks dangerous.
  #
  # Shell safety here rests on the single-quoted assignment below -- inside single
  # quotes $(...) and backticks are inert -- and excluding the quote character is
  # what guarantees a value cannot escape them. The allowlist is belt and braces
  # on top of that, and it also stops a malformed entry from producing a nonsense
  # clone directory: `https://host/$(cmd)x` is harmless but would otherwise create
  # a directory literally named `$(cmd)x`.
  repo_urls = [
    for u in local.repo_urls_raw : trimspace(u)
    if can(regex("^(https://|git@)[A-Za-z0-9._~:/@+-]+$", trimspace(u)))
  ]

  # basename handles both URL shapes without special-casing: it splits on "/",
  # so https://host/org/repo and git@host:org/repo.git both reduce to the repo
  # segment, and trimsuffix drops the .git. Trailing slashes are handled too
  # (basename follows filepath.Base semantics).
  repo_names = [for u in local.repo_urls : trimsuffix(basename(u), ".git")]
  repo_dirs  = [for n in local.repo_names : "/home/coder/repos/${n}"]

  # Multi-root workspace file, written next to the clones so its folder entries
  # can be plain relative names.
  workspace_file = "/home/coder/repos/${data.coder_workspace.me.name}.code-workspace"
  workspace_folders_json = jsonencode([
    for n in local.repo_names : { path = n }
  ])

  # What the browser editor opens, resolved here because coder_app.url is a
  # Terraform value rather than something the workspace decides at runtime.
  # Three cases on purpose: no repos falls back to the home directory; exactly
  # one opens that repo directly, since a single-folder multi-root workspace is
  # just noise; two or more open the .code-workspace so the repos share one
  # window and cross-repo search works.
  code_server_query = (
    length(local.repo_dirs) == 0 ? "folder=/home/coder" :
    length(local.repo_dirs) == 1 ? "folder=${local.repo_dirs[0]}" :
    "workspace=${local.workspace_file}"
  )
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

    # Seed SSH host keys before any clone. A fresh workspace has no
    # ~/.ssh/known_hosts and the clone runs without a tty, so an SSH URL dies on
    # "Host key verification failed" before authentication is even attempted --
    # confirmed empirically against github.com.
    #
    # Coder supplies the key half of SSH auth itself, via
    # GIT_SSH_COMMAND=<agent> gitssh, so once the host is known and that key is
    # registered with the forge, SSH URLs work with no further setup.
    # The system-wide file, NOT ~/.ssh/known_hosts, and that distinction is the
    # whole reason this works. OpenSSH expands `~` from the *passwd entry*, not
    # $HOME: this container runs as root, whose passwd home is /root, while HOME
    # is /home/coder. Seeding /home/coder/.ssh/known_hosts therefore wrote a file
    # ssh never opens -- confirmed with `ssh -v`, which reported
    # "fopen /root/.ssh/known_hosts: No such file or directory" while a fully
    # populated /home/coder/.ssh/known_hosts sat right there. Same
    # $HOME-versus-passwd divergence documented on the install paths above,
    # landing the opposite way round.
    #
    # /etc/ssh/ssh_known_hosts sidesteps the question entirely: ssh consults it
    # for every user regardless of home directory. It lives on the image's
    # ephemeral filesystem rather than the PVC, so it is re-seeded on each start,
    # which costs one API call and three keyscans and keeps the keys fresh.
    KNOWN_HOSTS=/etc/ssh/ssh_known_hosts
    mkdir -p /etc/ssh
    touch "$KNOWN_HOSTS"

    # GitHub's keys come from its meta API over TLS rather than ssh-keyscan.
    # keyscan is trust-on-first-use -- it records whatever answers, including a
    # man-in-the-middle -- while this response is authenticated by the
    # certificate chain. Fetching also beats pinning fingerprints in this file,
    # which would silently rot: GitHub replaced its RSA host key in 2023 after
    # it was briefly exposed.
    if ! ssh-keygen -F github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
      if gh_keys=$(curl -fsS --max-time 20 https://api.github.com/meta | jq -r '.ssh_keys[]? | "github.com " + .') && [ -n "$gh_keys" ]; then
        printf '%s\n' "$gh_keys" >> "$KNOWN_HOSTS"
        log "seeded github.com host keys from api.github.com/meta"
      else
        log "WARNING: could not fetch GitHub host keys; SSH clones from github.com will fail"
      fi
    fi

    # These have no equivalent published endpoint, so they are trust-on-first-use
    # via ssh-keyscan. A deliberate trade-off: the alternative is hardcoding
    # fingerprints that go stale without anyone noticing.
    for host in gitlab.com bitbucket.org codeberg.org; do
      if ! ssh-keygen -F "$host" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
        if ssh-keyscan -T 10 "$host" 2>/dev/null >> "$KNOWN_HOSTS"; then
          log "seeded $host host keys (ssh-keyscan, trust-on-first-use)"
        else
          log "WARNING: could not scan host keys for $host"
        fi
      fi
    done
    # World-readable on purpose: this is a system-wide file of public host keys,
    # and any user in the container needs to read it.
    chmod 644 "$KNOWN_HOSTS"

    # Clone each configured repo that is not already present. Absent-directory
    # check rather than a marker file, so this is genuinely first-start-only per
    # repo and can never clobber work in an existing clone -- if the directory is
    # there, for any reason, it is left alone.
    #
    # Single-quoted because the values come from a workspace parameter: with
    # double quotes a URL containing $(...) or backticks would execute here. The
    # Terraform-side filter rejecting anything but https:// and git@ URLs (and
    # any value containing a single quote) is what makes this assignment safe.
    # Newline-separated because a URL cannot contain a newline.
    #
    # Never fatal. A bad URL, an unauthorized private repo, or a network blip
    # must not stop the workspace coming up -- it starts without that clone and
    # says so in the log. One repo failing does not prevent the others.
    REPO_URLS='${join("\n", local.repo_urls)}'
    if [ -n "$REPO_URLS" ]; then
      mkdir -p /home/coder/repos
      printf '%s\n' "$REPO_URLS" | while IFS= read -r url; do
        [ -n "$url" ] || continue
        name=$(basename "$url" .git)
        dir="/home/coder/repos/$name"
        if [ -d "$dir" ]; then
          log "repo $name already present, leaving it alone"
        else
          log "cloning $url into $dir"
          git clone "$url" "$dir" >> "$LOG" 2>&1 \
            || log "WARNING: could not clone $url; continuing without it"
        fi
      done
    fi

    # Multi-root workspace file, for two or more repos. Regenerating only the
    # `folders` key rather than rewriting the file keeps anything added by hand
    # -- workspace-level settings, extension recommendations, launch configs --
    # while still letting the repo list change. Writing the whole file each time
    # would silently discard that; seeding it once would leave the folder list
    # permanently stale after a repo is added.
    #
    # Folder paths are relative to the file's own directory, so they are just the
    # repo names and the file stays valid regardless of where home is mounted.
    WS_FILE='${local.workspace_file}'
    WS_FOLDERS='${local.workspace_folders_json}'
    if [ "$(printf '%s' "$WS_FOLDERS" | jq 'length')" -gt 1 ]; then
      if [ -f "$WS_FILE" ]; then
        tmp=$(mktemp)
        if jq --argjson f "$WS_FOLDERS" '.folders = $f' "$WS_FILE" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$WS_FILE"
          log "updated folder list in $WS_FILE"
        else
          rm -f "$tmp"
          log "WARNING: $WS_FILE is not valid JSON; leaving it untouched"
        fi
      else
        jq -n --argjson f "$WS_FOLDERS" '{folders: $f, settings: {}}' > "$WS_FILE"
        log "created multi-root workspace $WS_FILE"
      fi
    fi

    # Editor defaults, seeded once. Deliberately only written when absent: this
    # file is what the settings UI writes to, so owning it on every start would
    # silently revert anything changed in the editor -- the same surprise the
    # home-manager dotfile activation above legitimately causes for dotfiles,
    # but wrong for this file. Consequence to know: changing these defaults
    # later will not reach a workspace that already has the file; delete it and
    # restart to pick them up.
    USER_DIR="$LOG_DIR/code-server/User"
    if [ ! -f "$USER_DIR/settings.json" ]; then
      mkdir -p "$USER_DIR"
      # Both identifiers verified against the extensions' package.json on Open
      # VSX. They are not the same form and are easy to get wrong: the colour
      # theme is matched by its *label* ("Catppuccin Mocha"), the icon theme by
      # its *id* ("catppuccin-mocha"). A wrong value fails silently -- the
      # editor just falls back to the default theme with no error anywhere.
      printf '%s\n' \
        '{' \
        '  "workbench.colorTheme": "Catppuccin Mocha",' \
        '  "workbench.iconTheme": "catppuccin-mocha",' \
        '  "telemetry.telemetryLevel": "off"' \
        '}' > "$USER_DIR/settings.json"
      log "seeded code-server settings.json"
    fi

    # Catppuccin Mocha to match nvim, tmux and kitty in the nixos-config flake.
    # Fetched from Open VSX -- code-server cannot use the Microsoft marketplace,
    # so a Microsoft-only extension id would simply never resolve here.
    #
    # Per-extension seed check, and never fatal: an Open VSX outage or a network
    # blip must not stop the editor from starting. It just starts unthemed, logs
    # a warning, and picks the extension up on the next restart.
    EXT_DIR="$LOG_DIR/code-server/extensions"
    for ext in Catppuccin.catppuccin-vsc Catppuccin.catppuccin-vsc-icons; do
      # Installed extensions land in a lowercased <publisher>.<name>-<version>
      # directory, so the check has to lowercase the id to match.
      lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
      if ! ls -d "$EXT_DIR/$lower-"* >/dev/null 2>&1; then
        log "installing $ext from Open VSX"
        node "$DIR/out/node/entry.js" \
          --user-data-dir "$LOG_DIR/code-server" \
          --extensions-dir "$EXT_DIR" \
          --install-extension "$ext" >> "$LOG" 2>&1 \
          || log "WARNING: could not install $ext; the editor will start without it"
      fi
    done

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
  url          = "http://localhost:${local.code_server_port}/?${local.code_server_query}"
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

# replicas is 0 when the workspace is stopped and 1 when running -- this is
# what makes Coder's stop/start work, with the PVC above staying put.
#
# A Deployment, not a bare Pod. The original bare Pod was a deliberate
# simplification whose stated trade-off was "no pod-level self-healing if the
# node itself reboots/evicts this pod" -- and that trade-off came due: the
# workspace pod vanished with nothing to recreate it, while Coder still
# reported the workspace as Started. A Deployment's ReplicaSet reschedules it.
#
# strategy must be Recreate, not the default RollingUpdate. The home volume is
# a ReadWriteOnce Longhorn PVC, so two pods can never mount it at once; a
# rolling update would deadlock with the new pod stuck ContainerCreating on a
# volume the old pod still holds. Recreate tears the old one down first, which
# is also what a single-user dev workspace wants anyway.
#
# Note this makes pod names generated (coder-<owner>-<workspace>-<hash>) rather
# than fixed, so anything scripted against the old exact pod name needs a label
# selector instead: -l coder.workspace=<name>.
resource "kubernetes_deployment_v1" "main" {
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    namespace = "coder"
  }
  spec {
    replicas = data.coder_workspace.me.start_count

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "coder.workspace" = data.coder_workspace.me.name
        "coder.owner"     = data.coder_workspace_owner.me.name
      }
    }

    template {
      metadata {
        labels = {
          "coder.workspace" = data.coder_workspace.me.name
          "coder.owner"     = data.coder_workspace_owner.me.name
        }
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
          image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:c7939accb5837f1b073c8348c44d59f2bde4482b62e536bf5a27e5748ff6cfb9"
          command = ["sh", "-c", "if [ ! -e /mnt/persistent-home/.nix-profile ]; then cp -a /home/coder/. /mnt/persistent-home/; fi"]

          volume_mount {
            mount_path = "/mnt/persistent-home"
            name       = "home"
          }
        }

        container {
          name    = "dev"
          image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:c7939accb5837f1b073c8348c44d59f2bde4482b62e536bf5a27e5748ff6cfb9"
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
    }
  }

  # The image is large (go/rust/node/kotlin toolchains) -- a cold pull on a node
  # that hasn't cached it yet can take several minutes, well past this resource's
  # default wait timeout. Confirmed empirically: a real workspace creation hit
  # "context deadline exceeded" waiting on a first-time pull. update matters as
  # much as create now: with Recreate, an image change tears down the old pod and
  # waits on the new one pulling.
  timeouts {
    create = "15m"
    update = "15m"
  }
}
