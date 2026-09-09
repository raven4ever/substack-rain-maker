terraform {
  required_version = ">= 1.11"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.80"
    }
  }
}

# The bootstrap workspace. The platform team owns it, and it is the only
# Terraform Cloud workspace a human creates by hand.
#
# It reads the org directories and creates one workspace per org. Nothing here
# generates Terraform: every workspace points at the same terraform/org-root
# module and is told which org it is (ADR 0003).
#
# No backend or cloud block anywhere in this repository. The workspaces are
# VCS-driven, so Terraform Cloud owns the state and the trigger both (ADR 0014).

# Authenticates with a Terraform Cloud organization token, from TFE_TOKEN. It
# never touches Atlas: the Atlas keys live in the per-org variable sets this
# module creates, and only the org workspaces ever read them.
provider "tfe" {}
