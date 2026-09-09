# Two kinds of database user, and only one of them has a password.

# The primary path: passwordless, AWS IAM workload identity. The role ARN is a
# string the development team supplies; Rain Maker never touches their account
# (ADR 0006).
resource "mongodbatlas_database_user" "app" {
  for_each = local.database_users

  project_id         = mongodbatlas_project.env[each.value.environment].id
  username           = each.value.aws_iam_role_arn
  aws_iam_type       = "ROLE"
  auth_database_name = "$external"

  # database: "*" means every database. Atlas spells that as the AnyDatabase
  # variant of the role, granted on admin rather than on a named database — so
  # the YAML says what is meant and the module knows how Atlas says it.
  dynamic "roles" {
    for_each = each.value.roles
    content {
      database_name = roles.value.database == "*" ? "admin" : roles.value.database
      role_name     = roles.value.database == "*" ? "${roles.value.role}AnyDatabase" : roles.value.role
    }
  }
}

# The break-glass superuser, one per cluster. Never declared in YAML; teams are
# forbidden from granting atlasAdmin themselves.
#
# ACCEPTED TRADE-OFF: this password is in Terraform state and in every historical
# state version, readable by anyone with workspace read access. password_wo would
# keep it out of state, but then nobody could ever retrieve it, which defeats the
# point of break-glass access. See docs/adr/0007.
resource "random_password" "superuser" {
  for_each = local.clusters

  length  = 32
  special = false
}

resource "mongodbatlas_database_user" "superuser" {
  for_each = local.clusters

  project_id         = mongodbatlas_project.env[each.value.environment].id
  username           = "${each.value.name}-admin"
  password           = random_password.superuser[each.key].result
  auth_database_name = "admin"
  description        = "Break-glass superuser, created by Rain Maker. Not declared in YAML."

  roles {
    database_name = "admin"
    role_name     = "atlasAdmin"
  }

  scopes {
    name = mongodbatlas_advanced_cluster.this[each.key].name
    type = "CLUSTER"
  }
}
