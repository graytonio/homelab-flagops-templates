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
  dir  = "/home/coder"
}

# No `count` here -- this must persist across workspace stop/start, unlike
# the pod below.
resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}-home"
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
resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    namespace = "coder"
  }
  spec {
    container {
      name    = "dev"
      image   = "ghcr.io/graytonio/nixos-workspace:latest"
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
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }
  }
}
