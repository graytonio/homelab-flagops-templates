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
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
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
      image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:e0e0ca48df927b69c61360e02a80195d23c32f901e3f21d3ff710fcc10779615"
      command = ["sh", "-c", "if [ ! -e /mnt/persistent-home/.nix-profile ]; then cp -a /home/coder/. /mnt/persistent-home/; fi"]

      volume_mount {
        mount_path = "/mnt/persistent-home"
        name       = "home"
      }
    }

    container {
      name    = "dev"
      image   = "ghcr.io/graytonio/nixos-workspace:latest@sha256:e0e0ca48df927b69c61360e02a80195d23c32f901e3f21d3ff710fcc10779615"
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
