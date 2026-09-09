# Atlas Teams, the people in them, and the roles they hold on each project.

resource "mongodbatlas_team" "this" {
  for_each = local.teams

  org_id = local.atlas_org_id
  name   = "${var.org_name}-${each.key}"

  # Membership is managed by mongodbatlas_cloud_user_team_assignment below.
  # Setting usernames here would fight it.
  lifecycle {
    ignore_changes = [usernames]
  }
}

# Declaring a person invites them. The resource takes the email and emits the
# user id, so there is no lookup and no hand-copied ids; an unaccepted
# invitation shows as PENDING rather than a silent gap.
resource "mongodbatlas_cloud_user_org_assignment" "member" {
  for_each = local.members

  org_id   = local.atlas_org_id
  username = each.key

  roles = {
    org_roles = each.value
  }
}

resource "mongodbatlas_cloud_user_team_assignment" "member" {
  for_each = local.team_members

  org_id  = local.atlas_org_id
  team_id = mongodbatlas_team.this[each.value.team].team_id
  user_id = mongodbatlas_cloud_user_org_assignment.member[each.value.email].user_id
}

# Project role bindings. See the lifecycle rule in projects.tf: without it, this
# resource is silently undone by any update to the project it points at.
resource "mongodbatlas_team_project_assignment" "this" {
  for_each = local.team_access

  project_id = mongodbatlas_project.env[each.value.environment].id
  team_id    = mongodbatlas_team.this[each.value.team].team_id
  role_names = each.value.project_roles
}
