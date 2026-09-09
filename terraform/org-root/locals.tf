# All locals for this root module: the YAML ingestion, the derived work lists,
# and the guardrail evaluation. Resources live in their own per-service files.

locals {
  repo_root = "${path.module}/../.."
  org_dir   = "${local.repo_root}/orgs/${var.org_name}"

  org        = yamldecode(file("${local.org_dir}/org.yaml"))
  guardrails = yamldecode(file("${local.repo_root}/platform/guardrails.yaml"))

  # The directory set is the source of truth. Adding an environment is adding
  # a directory; there is no list to keep in step with it.
  environments = {
    for f in fileset(local.org_dir, "*/environment.yaml") :
    dirname(f) => yamldecode(file("${local.org_dir}/${f}"))
  }

  templates = {
    for f in fileset("${local.repo_root}/platform/templates", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/platform/templates/${f}"))
  }

  clusters = merge([
    for env_name, env in local.environments : {
      for cluster_name, cluster in env.clusters :
      "${env_name}/${cluster_name}" => {
        environment = env_name
        name        = cluster_name

        # Derived, never declared. A field whose value is always derivable is a
        # field that can be wrong.
        project = "${var.org_name}-${env_name}"

        # Omitting `class` gets the strictest class, so forgetting is safe and
        # weakening the floors is an explicit line in the diff.
        class = try(env.class, local.guardrails.default_class)

        template = try(cluster.template, null)

        # Extras are declared on the cluster, never inside a template, so they
        # are read from the raw declaration rather than from the merged spec —
        # on the template path the merge would drop them entirely.
        online_archive = try(cluster.online_archive, [])

        # Template specs are flat by construction, so a shallow merge is total
        # (ADR 0004).
        spec = try(
          merge(local.templates[cluster.template].spec, try(cluster.overrides, {})),
          cluster,
        )

        # Class floors apply to every cluster. A template may only tighten them.
        min = merge(
          local.guardrails.classes[try(env.class, local.guardrails.default_class)].min,
          try(local.templates[cluster.template].min, {}),
        )
        max = merge(
          local.guardrails.classes[try(env.class, local.guardrails.default_class)].max,
          try(local.templates[cluster.template].max, {}),
        )
        required = merge(
          local.guardrails.classes[try(env.class, local.guardrails.default_class)].required,
          try(local.templates[cluster.template].required, {}),
        )

        sealed_violations = try(
          setsubtract(keys(cluster.overrides), local.templates[cluster.template].overridable),
          [],
        )
      }
    }
  ]...)

  # Shared-tier instance sizes go through provider_name TENANT with the real
  # cloud provider behind backing_provider_name, and reject disk sizing.
  tenant_sizes = ["M0", "M2", "M5"]

  # Flattened work lists. Terraform addresses are "<env>/<name>" throughout,
  # so an address reads the same as the path in the repository.
  # Keyed by ARN, because the ARN is the identity. A name alongside it would be
  # a second thing to keep in step with the first.
  database_users = merge([
    for env_name, env in local.environments : {
      for user in try(env.database_users, []) :
      "${env_name}/${user.aws_iam_role_arn}" => merge(user, { environment = env_name })
    }
  ]...)

  ip_access = merge([
    for env_name, env in local.environments : {
      for entry in try(env.network_access, []) :
      "${env_name}/${entry.cidr}" => merge(entry, { environment = env_name })
    }
  ]...)

  team_access = merge([
    for env_name, env in local.environments : {
      for binding in try(env.team_access, []) :
      "${env_name}/${binding.team}" => merge(binding, { environment = env_name })
    }
  ]...)

  teams = { for t in local.org.teams : t.name => t }

  # A person may sit in several teams. Atlas grants org roles to the user, not
  # to the team, so the roles are unioned into one assignment per email.
  members = {
    for email in distinct(flatten([for t in local.org.teams : try(t.members, [])])) :
    email => distinct(flatten([
      for t in local.org.teams : t.org_roles if contains(try(t.members, []), email)
    ]))
  }

  team_members = merge([
    for t in local.org.teams : {
      for email in try(t.members, []) : "${t.name}/${email}" => { team = t.name, email = email }
    }
  ]...)
}

locals {
  atlas_org_id = local.org.organization.atlas_org_id

  is_tenant = {
    for k, c in local.clusters : k => contains(local.tenant_sizes, c.spec.instance_size)
  }

  # One region list per cluster, whichever way it was declared. A single-region
  # cluster writes `region:` and gets one entry at priority 7; a multi-region one
  # writes `regions:` and gets what it declared. Everything downstream reads this
  # and never the raw spec, so there is exactly one shape to handle.
  cluster_regions = {
    for k, c in local.clusters : k => try(
      [for r in c.spec.regions : {
        name       = r.name
        node_count = try(r.node_count, 3)
        priority   = r.priority
      }],
      [{
        name       = c.spec.region
        node_count = try(c.spec.node_count, 3)
        priority   = 7
      }],
    )
  }

  # Online archives, flattened to "<env>/<cluster>/<db>.<collection>".
  online_archives = merge([
    for k, c in local.clusters : {
      for a in c.online_archive :
      "${k}/${a.database}.${a.collection}" => merge(a, { cluster = k })
    }
  ]...)

  # PrivateLink, one Atlas endpoint per environment and region. Phase 2 adds
  # aws_vpc_endpoint_id to an entry that already exists; nothing else changes,
  # which is what keeps the two pull requests honest about being one declaration.
  private_link = merge([
    for env_name, env in local.environments : {
      for r in try(env.private_link.regions, []) :
      "${env_name}/${r.name}" => merge(r, { environment = env_name })
    } if try(env.private_link.enabled, false)
  ]...)

  # The subset of the above that has reached phase 2 and can be accepted.
  private_link_accepted = {
    for k, v in local.private_link : k => v if try(v.aws_vpc_endpoint_id, null) != null
  }

  # Atlas SQL and the online archive cannot reuse the cluster's endpoint: they
  # need their own, against a MongoDB-owned service.
  federation_endpoints = {
    for env_name, env in local.environments :
    env_name => env.private_link.data_federation_vpc_endpoint_id
    if try(env.private_link.data_federation_vpc_endpoint_id, null) != null
  }

  # Atlas SQL: at most one federated database instance per environment.
  sql_interfaces = {
    for env_name, env in local.environments : env_name => env.sql_interface
    if try(env.sql_interface.enabled, false)
  }
}

# --- Guardrail evaluation -----------------------------------------------------
# Enforced by terraform_data.guardrails in main.tf, and independently by
# scripts/validate.py in CI (ADR 0005).

locals {
  # ponytail: instance_size is the only ordered guardrail, so it is compared
  # directly against tier_order. Generalise to a per-key comparator only if a
  # second ordered key ever appears.
  violations = {
    for k, c in local.clusters : k => concat(
      [for key in c.sealed_violations : "${key} is sealed by template ${c.template}"],

      try(index(local.guardrails.tier_order, c.spec.instance_size) < index(local.guardrails.tier_order, c.min.instance_size)
      ? ["instance_size ${c.spec.instance_size} is below the ${c.class} floor ${c.min.instance_size}"] : [], []),

      try(index(local.guardrails.tier_order, c.spec.instance_size) > index(local.guardrails.tier_order, c.max.instance_size)
      ? ["instance_size ${c.spec.instance_size} is above the ${c.class} ceiling ${c.max.instance_size}"] : [], []),

      [for key, want in c.required : "${key} must be ${want} in class ${c.class}, got ${try(c.spec[key], "unset")}"
      if try(c.spec[key], null) != want],

      [for r in local.cluster_regions[k] : "region ${r.name} is not in the allowlist"
      if !contains(local.guardrails.regions, r.name)],

      # Multi-region rules. Atlas takes writes in the highest-priority region, so
      # priorities must be unique, and an even electable count cannot elect.
      length(local.cluster_regions[k]) > local.guardrails.quotas.regions_per_cluster
      ? ["${length(local.cluster_regions[k])} regions exceeds the quota of ${local.guardrails.quotas.regions_per_cluster}"] : [],

      # How many regions the class expects. Development is single-region because
      # spanning regions bills twice for resilience nobody relies on; production
      # is multi-region because a single-region cluster loses its primary with
      # the region.
      length(local.cluster_regions[k]) < local.guardrails.classes[c.class].min_regions
      ? ["class ${c.class} requires at least ${local.guardrails.classes[c.class].min_regions} region(s), got ${length(local.cluster_regions[k])}"] : [],

      length(local.cluster_regions[k]) > local.guardrails.classes[c.class].max_regions
      ? ["class ${c.class} allows at most ${local.guardrails.classes[c.class].max_regions} region(s), got ${length(local.cluster_regions[k])}"] : [],

      length(local.cluster_regions[k]) > 1 && local.is_tenant[k]
      ? ["a shared-tier cluster cannot be multi-region; ${local.guardrails.dedicated_features_min_tier} or above is required"] : [],

      length(distinct([for r in local.cluster_regions[k] : r.priority])) != length(local.cluster_regions[k])
      ? ["region priorities must be unique"] : [],

      max([for r in local.cluster_regions[k] : r.priority]...) != 7
      ? ["the highest region priority must be 7"] : [],

      sum([for r in local.cluster_regions[k] : r.node_count]) % 2 == 0
      ? ["${sum([for r in local.cluster_regions[k] : r.node_count])} electable nodes is even; a replica set needs an odd count"] : [],

      # Online archive needs a dedicated tier, and its collection must already
      # exist when it applies. Only the first of those is checkable here.
      length(c.online_archive) > 0 && local.is_tenant[k]
      ? ["online archive requires ${local.guardrails.dedicated_features_min_tier} or above, got ${c.spec.instance_size}"] : [],

      # The date field is added as partition field 0 automatically, so declaring
      # it again would send Atlas the same field twice.
      [for a in c.online_archive : "online archive ${a.database}.${a.collection}: date_field ${a.date_field} is added as a partition field automatically, remove it from partition_fields"
      if contains(try(a.partition_fields, []), a.date_field)],
      contains(local.guardrails.cloud_providers, c.spec.cloud_provider) ? [] : ["cloud_provider ${c.spec.cloud_provider} is not allowed"],
      can(regex(local.guardrails.cluster_name_pattern, c.name)) ? [] : ["cluster name ${c.name} does not match ${local.guardrails.cluster_name_pattern}"],
    )
  }

  env_violations = {
    for env_name, env in local.environments : env_name => concat(
      [for e in try(env.network_access, []) : "network_access ${e.cidr} is not allowed in class ${try(env.class, local.guardrails.default_class)}"
      if e.cidr == "0.0.0.0/0" && !local.guardrails.classes[try(env.class, local.guardrails.default_class)].allow_open_ip],

      # A repeated ARN would collapse silently in the merge above, leaving one
      # of the two declarations with no effect and no error.
      [for arn in distinct([for u in try(env.database_users, []) : u.aws_iam_role_arn]) :
        "database_user ${arn} is declared more than once"
      if length([for u in try(env.database_users, []) : u if u.aws_iam_role_arn == arn]) > 1],

      flatten([for user in try(env.database_users, []) :
        [for r in user.roles : "database_user ${user.aws_iam_role_arn} may not grant ${r.role}"
      if !contains(local.guardrails.database_roles, r.role)]]),

      flatten([for t in try(env.team_access, []) :
        [for r in t.project_roles : "team ${t.team} may not be granted ${r}"
      if !contains(local.guardrails.project_roles, r)]]),

      [for t in try(env.team_access, []) : "team ${t.team} is not defined in org.yaml"
      if !contains([for ot in local.org.teams : ot.name], t.team)],

      try(env.project.tags.owner, "") == var.org_name ? [] : ["tag owner must be ${var.org_name}"],
      can(regex(local.guardrails.cost_center_pattern, try(env.project.tags.cost_center, ""))) ? [] : ["tag cost_center does not match ${local.guardrails.cost_center_pattern}"],

      length(env.clusters) > local.guardrails.quotas.clusters_per_environment
      ? ["${length(env.clusters)} clusters exceeds the quota of ${local.guardrails.quotas.clusters_per_environment}"] : [],

      # Atlas SQL reads from one cluster in the same environment. A source that
      # does not exist builds an instance that returns nothing, silently.
      # PrivateLink is dedicated-tier only, and an endpoint in a region no cluster
      # runs in is an endpoint nothing can route to.
      [for r in try(env.private_link.regions, []) : "private_link region ${r.name} is not in the allowlist"
      if try(env.private_link.enabled, false) && !contains(local.guardrails.regions, r.name)],

      [for r in try(env.private_link.regions, []) : "private_link region ${r.name} has no cluster in this environment"
        if try(env.private_link.enabled, false) && !contains(flatten([
          for cn, c in env.clusters : [for cr in local.cluster_regions["${env_name}/${cn}"] : cr.name]
      ]), r.name)],

      # Atlas gives a multi-region cluster no private connection string at all
      # unless every region it spans has an endpoint — not a partial one for the
      # covered region, none. Verified against a live cluster: endpoint AVAILABLE
      # in one of two regions, connectionStrings had no privateEndpoint key.
      flatten([for cn, c in env.clusters : [
        for cr in local.cluster_regions["${env_name}/${cn}"] :
        "cluster ${cn} runs in ${cr.name} but private_link has no endpoint there; Atlas returns no private connection string unless every region is covered"
        if try(env.private_link.enabled, false) && !contains([for r in try(env.private_link.regions, []) : r.name], cr.name)
      ]]),

      try(env.private_link.enabled, false) && alltrue([
        for cn, c in env.clusters : local.is_tenant["${env_name}/${cn}"]
      ])
      ? ["private_link requires ${local.guardrails.dedicated_features_min_tier} or above; this environment has no dedicated cluster"] : [],

      try(env.sql_interface.enabled, false) && !contains(keys(env.clusters), try(env.sql_interface.source_cluster, ""))
      ? ["sql_interface source_cluster ${try(env.sql_interface.source_cluster, "<unset>")} is not a cluster in this environment"] : [],

      try(env.sql_interface.enabled, false) && contains(keys(env.clusters), try(env.sql_interface.source_cluster, "")) &&
      contains(local.tenant_sizes, try(local.clusters["${env_name}/${env.sql_interface.source_cluster}"].spec.instance_size, "M0"))
      ? ["sql_interface requires ${local.guardrails.dedicated_features_min_tier} or above on ${try(env.sql_interface.source_cluster, "")}"] : [],
    )
  }

  org_violations = concat(
    length(local.environments) > local.guardrails.quotas.environments_per_org ? [
      "${length(local.environments)} environments exceeds the quota of ${local.guardrails.quotas.environments_per_org}"
    ] : [],

    flatten([for t in local.org.teams :
      [for r in t.org_roles : "team ${t.name} may not be granted ${r}"
    if !contains(local.guardrails.org_roles, r)]]),
  )

  # Flattened for the precondition messages, which want one string.
  all_violations = concat(
    flatten([for k, v in local.violations : [for m in v : "clusters[${k}]: ${m}"]]),
    flatten([for k, v in local.env_violations : [for m in v : "orgs/${var.org_name}/${k}: ${m}"]]),
    [for m in local.org_violations : "orgs/${var.org_name}/org.yaml: ${m}"],
  )
}
