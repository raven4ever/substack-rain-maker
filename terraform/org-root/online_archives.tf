# Online archive. Moves documents older than a cutoff to cheaper storage while
# leaving them queryable through the same connection string.
#
# It needs M10 or above. It does not need the collection to exist: Atlas accepts
# an archive for a collection that has never been written to, parks it in
# PENDING, and moves it to ACTIVE by itself once the data appears. So an archive
# can be declared alongside the cluster that will eventually hold the data, which
# is exactly what a GitOps flow wants — nothing here is ordered against
# scripts/seed.sh.

resource "mongodbatlas_online_archive" "this" {
  for_each = local.online_archives

  project_id   = mongodbatlas_project.env[local.clusters[each.value.cluster].environment].id
  cluster_name = mongodbatlas_advanced_cluster.this[each.value.cluster].name

  db_name   = each.value.database
  coll_name = each.value.collection

  # A multi-region cluster has no single obvious home for archived data, so Atlas
  # refuses to guess: ONLINE_ARCHIVE_CANNOT_DETERMINE_DL_REGION_FOR_MULTI_REGION_CLUSTER.
  # The answer is the region that takes writes, which is the priority 7 one, so it
  # is derived rather than declared. Set on every archive, not only multi-region
  # ones, so the two shapes cannot drift apart.
  data_process_region {
    cloud_provider = local.clusters[each.value.cluster].spec.cloud_provider
    region         = one([for r in local.cluster_regions[each.value.cluster] : r.name if r.priority == 7])
  }

  criteria {
    type              = "DATE"
    date_field        = each.value.date_field
    expire_after_days = try(each.value.expire_after_days, null)
  }

  # Atlas refuses a DATE archive whose date field is not also a partition field:
  # ONLINE_ARCHIVE_DATE_CRITERIA_NOT_IN_PARTITION. It is derived here rather than
  # asked for, because a team repeating the same field name in two places is a
  # team that will eventually repeat it wrongly.
  partition_fields {
    field_name = each.value.date_field
    order      = 0
  }

  # Further partition fields are optional, and order matters: archived queries
  # are efficient when they filter on the leading fields.
  dynamic "partition_fields" {
    for_each = { for i, f in try(each.value.partition_fields, []) : f => i }

    content {
      field_name = partition_fields.key
      order      = partition_fields.value + 1
    }
  }
}
