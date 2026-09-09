# The VCS connection, looked up rather than passed in. A hand-copied ot-... id is
# a step that can be got wrong; a lookup cannot be. This fails loudly if the
# organization has no GitHub connection, or more than one.
data "tfe_oauth_client" "github" {
  organization     = var.tfc_organization
  service_provider = "github"
}

# One workspace per organization. This is what makes state per organization
# (ADR 0001) without any per-organization Terraform existing anywhere.

resource "tfe_workspace" "org" {
  for_each = local.orgs

  name         = "rain-maker-${each.key}"
  organization = var.tfc_organization
  description  = "Rain Maker: everything below the Atlas organization '${each.key}'."

  working_directory = "terraform/org-root"

  # Replan this workspace when its own org changes, or when anything shared
  # changes. A pull request touching one org directory must not queue the others:
  # on the free tier they would serialise behind a single concurrent run.
  trigger_patterns = [
    "orgs/${each.key}/**/*",
    "terraform/org-root/**/*",
    "platform/**/*",
  ]

  # The pull request review is the gate; merge is the trigger (ADR 0009).
  auto_apply = true

  # Do not run on creation: the Atlas credential is not in the variable set yet.
  queue_all_runs = false

  # Drift detection is Standard tier and above.
  assessments_enabled = false

  vcs_repo {
    identifier     = var.github_repo
    oauth_token_id = data.tfe_oauth_client.github.oauth_token_id
  }
}

# The only per-org Terraform artifact: one variable naming the directory.
resource "tfe_variable" "org_name" {
  for_each = local.orgs

  workspace_id = tfe_workspace.org[each.key].id
  key          = "org_name"
  value        = each.key
  category     = "terraform"
  description  = "Selects the orgs/<name>/ subtree read by terraform/org-root."
}
