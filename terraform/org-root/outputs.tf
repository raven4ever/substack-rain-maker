output "org" {
  description = "The organization this workspace serves."
  value       = var.org_name
}

output "projects" {
  description = "Atlas project ids, keyed by environment."
  value       = { for k, p in mongodbatlas_project.env : k => p.id }
}

output "clusters" {
  description = "Resolved cluster set: what the template merge produced, and how to reach it."
  value = {
    for k, c in local.clusters : k => {
      project       = c.project
      class         = c.class
      template      = coalesce(c.template, "custom")
      instance_size = c.spec.instance_size
      regions       = [for r in local.cluster_regions[k] : "${r.name}:${r.node_count}"]
      connection    = mongodbatlas_advanced_cluster.this[k].connection_strings.standard_srv
    }
  }
}

# Break-glass only. See docs/adr/0007: this is in state either way, so hiding it
# from the outputs would buy nothing but inconvenience.
output "superuser_passwords" {
  description = "atlasAdmin password per cluster. Sensitive; rotate after use."
  sensitive   = true
  value = {
    for k, c in local.clusters : k => {
      username = "${c.name}-admin"
      password = random_password.superuser[k].result
    }
  }
}

# Phase 1 of the PrivateLink handshake ends here: the development team reads this
# and creates an interface endpoint against the service name, in their own AWS
# account and their own repository. Phase 2 is them adding the resulting
# vpce- id to their environment.yaml.
output "private_link" {
  description = "Atlas endpoint service per environment and region, and whether the connection has been accepted."
  value = {
    for k, e in mongodbatlas_privatelink_endpoint.this : k => {
      endpoint_service_name = e.endpoint_service_name
      status                = e.status
      accepted              = contains(keys(local.private_link_accepted), k)
    }
  }
}
