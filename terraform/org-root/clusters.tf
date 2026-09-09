# Clusters, from a platform template or fully custom. Either way the spec reaching
# this file is flat, and this is where it becomes the provider's nested shape.

resource "mongodbatlas_advanced_cluster" "this" {
  for_each = local.clusters

  project_id   = mongodbatlas_project.env[each.value.environment].id
  name         = each.value.name
  cluster_type = each.value.spec.cluster_type

  # One region config per entry in local.cluster_regions, so single-region and
  # multi-region are the same code path. Shared tiers are provisioned as TENANT
  # with the real cloud behind them, and are single-region by construction.
  replication_specs = [
    {
      region_configs = [
        for region in local.cluster_regions[each.key] : {
          provider_name         = local.is_tenant[each.key] ? "TENANT" : each.value.spec.cloud_provider
          backing_provider_name = local.is_tenant[each.key] ? each.value.spec.cloud_provider : null
          region_name           = region.name
          priority              = region.priority

          electable_specs = {
            instance_size = each.value.spec.instance_size
            # Atlas reports no nodeCount at all for a tenant cluster, so sending
            # one makes the provider fail its own consistency check after apply.
            node_count   = local.is_tenant[each.key] ? null : region.node_count
            disk_size_gb = local.is_tenant[each.key] ? null : try(each.value.spec.disk_size_gb, null)
          }
        }
      ]
    }
  ]

  # Tenant clusters reject these three outright: the API answers
  # TENANT_ATTRIBUTE_READ_ONLY rather than ignoring them. The YAML still carries
  # them, because a team should not have to know which tier hides which knob.
  backup_enabled                 = local.is_tenant[each.key] ? null : try(each.value.spec.backup_enabled, false)
  termination_protection_enabled = local.is_tenant[each.key] ? null : try(each.value.spec.termination_protection, false)
  mongo_db_major_version         = local.is_tenant[each.key] ? null : try(each.value.spec.mongodb_major_version, null)

  tags = merge(
    try(local.environments[each.value.environment].project.tags, {}),
    { environment = each.value.environment, template = coalesce(each.value.template, "custom") },
  )

  # Without this, a cluster created alongside a PrivateLink acceptance comes back
  # with empty private connection strings — the link is real but the cluster does
  # not know about it. There is no attribute reference between the two, so the
  # dependency has to be stated (research ticket 04).
  depends_on = [mongodbatlas_privatelink_endpoint_service.this]
}
