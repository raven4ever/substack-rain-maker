# No backend or cloud block. The workspaces are VCS-driven, so Terraform Cloud
# owns both the state and the trigger, and a backend block here would only get in
# the way of that (ADR 0014).

terraform {
  # 1.11+ for write-only arguments and ephemeral values.
  required_version = ">= 1.11"

  required_providers {
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Rain Maker, one organization. Everything below the Atlas organization itself,
# which is created by hand in the UI and named in org.yaml (ADR 0002).
#
# Resources are split by service: projects.tf, clusters.tf, database_users.tf,
# network_access.tf, teams.tf. This file holds the provider and the one thing
# that belongs to no service — the plan gate.

# Credentials come from this workspace's Terraform Cloud variable set
# (MONGODB_ATLAS_PUBLIC_KEY / MONGODB_ATLAS_PRIVATE_KEY as environment
# variables). One key per organization, and never from this repository.
provider "mongodbatlas" {}