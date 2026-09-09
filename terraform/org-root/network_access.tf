# IP access list per project. Every entry carries a mandatory comment, and
# 0.0.0.0/0 is refused in any class whose allow_open_ip is false.

resource "mongodbatlas_project_ip_access_list" "this" {
  for_each = local.ip_access

  project_id = mongodbatlas_project.env[each.value.environment].id
  cidr_block = each.value.cidr
  comment    = each.value.comment
}
