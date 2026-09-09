# Atlas SQL. A federated database instance that exposes a cluster's collections
# over the SQL interface, for BI tools that cannot speak MongoDB.
#
# The join between the two halves is by name and nothing else: storage_stores
# declares a store called after the cluster, and each data source refers back to
# it through store_name. Get that string wrong and the instance builds fine and
# returns nothing, so it is derived here rather than declared in YAML.
#
# One instance per environment. The private endpoint it can also carry belongs to
# the deferred PrivateLink work: it needs its own endpoint against a
# MongoDB-owned service and cannot reuse the cluster's.

resource "mongodbatlas_federated_database_instance" "this" {
  for_each = local.sql_interfaces

  project_id = mongodbatlas_project.env[each.key].id
  name       = "${var.org_name}-${each.key}-sql"

  storage_stores {
    name         = each.value.source_cluster
    cluster_name = mongodbatlas_advanced_cluster.this["${each.key}/${each.value.source_cluster}"].name
    project_id   = mongodbatlas_project.env[each.key].id
    provider     = "atlas"

    read_preference {
      mode = "secondary"
    }
  }

  dynamic "storage_databases" {
    for_each = { for db in try(each.value.databases, []) : db.name => db }

    content {
      name = storage_databases.key

      dynamic "collections" {
        for_each = toset(storage_databases.value.collections)

        content {
          name = collections.value

          data_sources {
            store_name = each.value.source_cluster
            database   = storage_databases.key
            collection = collections.value
          }
        }
      }
    }
  }
}
