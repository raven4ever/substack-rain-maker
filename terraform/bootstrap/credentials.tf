# One credential per Atlas organization, so a compromised key reaches one tenant.
#
# The bootstrap creates the variable set and the two variables with a placeholder,
# then stops caring about their values: a human pastes the real key into the
# Terraform Cloud UI. The repository has no aws provider and therefore no secret
# store to read from (ADR 0006), so the paste is unavoidable. What the bootstrap
# still guarantees is that the shape exists and is attached to the right
# workspace, which is the part that is easy to get wrong by hand.

resource "tfe_variable_set" "atlas_credential" {
  for_each = local.orgs

  name         = "atlas-${each.key}"
  organization = var.tfc_organization
  description  = "ORG_OWNER API key for the Atlas organization '${each.key}'. Filled by hand."
}

resource "tfe_workspace_variable_set" "atlas_credential" {
  for_each = local.orgs

  variable_set_id = tfe_variable_set.atlas_credential[each.key].id
  workspace_id    = tfe_workspace.org[each.key].id
}

resource "tfe_variable" "atlas_key" {
  for_each = merge([
    for org in local.orgs : {
      "${org}/MONGODB_ATLAS_PUBLIC_KEY"  = { org = org, key = "MONGODB_ATLAS_PUBLIC_KEY", half = "PUBLIC" }
      "${org}/MONGODB_ATLAS_PRIVATE_KEY" = { org = org, key = "MONGODB_ATLAS_PRIVATE_KEY", half = "PRIVATE" }
    }
  ]...)

  variable_set_id = tfe_variable_set.atlas_credential[each.value.org].id
  key             = each.value.key
  category        = "env"
  sensitive       = true

  # The placeholder names the organization and the half of the key pair it wants.
  # Four sensitive fields that all read REPLACE_IN_THE_UI is how an analytics key
  # ends up in the payments workspace, and a sensitive value cannot be read back
  # over the API to catch it — only a failed run tells you.
  value       = "PASTE-THE-${upper(replace(each.value.org, "-", "_"))}-${each.value.half}-KEY-HERE"
  description = "Atlas ${lower(each.value.half)} key for the '${each.value.org}' organization. Paste it in the Terraform Cloud UI; Terraform ignores the value after creation."

  lifecycle {
    ignore_changes = [value]
  }
}
