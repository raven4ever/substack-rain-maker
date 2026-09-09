# One Atlas project per environment directory. The name is derived, never
# declared: a field whose value is always computable is a field that can be wrong.

resource "mongodbatlas_project" "env" {
  for_each = local.environments

  name   = "${var.org_name}-${each.key}"
  org_id = local.atlas_org_id
  tags   = try(each.value.project.tags, {})

  # Project role bindings are mongodbatlas_team_project_assignment, in teams.tf.
  #
  # This lifecycle rule is what makes that safe, and it is not optional. The
  # project resource carries its own deprecated `teams` block; with the block
  # absent from the configuration, every project update sends an empty teams set
  # and Atlas deletes each binding the assignment resource made — silently, with
  # no diff and no error. Ignoring the attribute makes the planned value the one
  # read back from the API, so an unrelated tag change stops being a way to lose
  # your access control. Verified both ways against a live project.
  lifecycle {
    ignore_changes = [teams]
  }
}
