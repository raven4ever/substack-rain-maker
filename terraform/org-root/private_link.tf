# AWS PrivateLink, Atlas side only.
#
# This is a two-party handshake and Rain Maker owns one party (ADR 0006). The
# development team creates the interface endpoint in their own AWS account, in
# their own repository, against the service name published below. Nothing here
# reaches into their account, and there is no aws provider to do it with.
#
# Phase 1 is this endpoint. Phase 2 is the acceptance below it, which needs an id
# that does not exist until the team has done their half.

resource "mongodbatlas_privatelink_endpoint" "this" {
  for_each = local.private_link

  project_id    = mongodbatlas_project.env[each.value.environment].id
  provider_name = "AWS"
  region        = each.value.name

  # The provider defaults to a two-hour wait. A delete that is going to wedge
  # should say so in twenty minutes, not hold a burn-day teardown hostage —
  # PrivateLink blocks until every cluster in the project reaches IDLE.
  timeouts {
    create = "30m"
    delete = "20m"
  }
}

# Phase 2: accept the connection the development team created. Present only once
# aws_vpc_endpoint_id appears in their YAML, so phase 1 plans cleanly without it.
resource "mongodbatlas_privatelink_endpoint_service" "this" {
  for_each = local.private_link_accepted

  project_id          = mongodbatlas_project.env[each.value.environment].id
  provider_name       = "AWS"
  private_link_id     = mongodbatlas_privatelink_endpoint.this[each.key].private_link_id
  endpoint_service_id = each.value.aws_vpc_endpoint_id

  timeouts {
    create = "30m"
    delete = "20m"
  }
}

# Atlas SQL and the online archive reach a MongoDB-owned service, not the
# cluster's, so they need an endpoint of their own. Same two-phase shape.
resource "mongodbatlas_privatelink_endpoint_service_data_federation_online_archive" "this" {
  for_each = local.federation_endpoints

  project_id    = mongodbatlas_project.env[each.key].id
  provider_name = "AWS"
  endpoint_id   = each.value
  comment       = "Rain Maker: data federation and online archive for ${var.org_name}-${each.key}"
}
