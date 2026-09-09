#!/usr/bin/env python3
"""Rain Maker guardrail check.

Runs in GitHub Actions on every pull request, and locally in about a second.
The same rules are enforced a second time as Terraform preconditions in
terraform/org-root/guardrails.tf, because a check a developer can skip is not a
guardrail. This one exists to give the answer immediately and with enough
context to act on, instead of behind a queued Terraform Cloud run.

    scripts/validate.py              # check the repository
    scripts/validate.py --self-test  # prove every rule still fires
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
PLATFORM_CONTACT = "open a pull request against platform/guardrails.yaml (owned by the platform team)"
TENANT_SIZES = ("M0", "M2", "M5")


def load(path: Path):
    return yaml.safe_load(path.read_text())


def resolve_cluster(name, cluster, env, guardrails, templates):
    """Reproduce the merge in terraform/org-root/ingest.tf, exactly."""
    cls = env.get("class", guardrails["default_class"])
    floors = guardrails["classes"][cls]
    template_name = cluster.get("template")
    template = templates.get(template_name, {}) if template_name else {}

    if template_name:
        spec = {**template.get("spec", {}), **cluster.get("overrides", {})}
        sealed = sorted(set(cluster.get("overrides", {})) - set(template.get("overridable", [])))
    else:
        spec = {k: v for k, v in cluster.items() if k not in ("online_archive", "private_link")}
        sealed = []

    # Extras are declared on the cluster, never inside a template, so they are
    # read from the raw declaration rather than the merged spec. Mirrors
    # local.clusters[*].online_archive in terraform/org-root/locals.tf.
    online_archive = cluster.get("online_archive", [])

    # Mirrors local.cluster_regions in terraform/org-root/locals.tf: one shape for
    # single-region and multi-region, so nothing downstream reads the raw spec.
    if spec.get("regions"):
        regions = [
            {"name": r["name"], "node_count": r.get("node_count", 3), "priority": r["priority"]}
            for r in spec["regions"]
        ]
    else:
        regions = [{"name": spec.get("region"), "node_count": spec.get("node_count", 3), "priority": 7}]

    return {
        "name": name,
        "class": cls,
        "regions": regions,
        "online_archive": online_archive,
        "template": template_name,
        "spec": spec,
        "sealed": sealed,
        "overridable": sorted(template.get("overridable", [])) if template_name else "all (custom cluster)",
        "min": {**floors["min"], **template.get("min", {})},
        "max": {**floors["max"], **template.get("max", {})},
        "required": {**floors["required"], **template.get("required", {})},
    }


def check_cluster(c, org, env_name, guardrails):
    """Every message names the file, the key, the attempted value and the way out."""
    where = f"orgs/{org}/{env_name}/environment.yaml -> clusters.{c['name']}"
    order = guardrails["tier_order"]
    out = []

    for key in c["sealed"]:
        out.append(
            f"{where}: '{key}' is sealed by template '{c['template']}'. "
            f"Attempted: {c['spec'].get(key)!r}. "
            f"Overridable keys are {c['overridable']}. "
            f"To widen that list, {PLATFORM_CONTACT}."
        )

    size = c["spec"].get("instance_size")
    if size not in order:
        out.append(f"{where}: instance_size {size!r} is not a known tier. Known tiers: {order}.")
    else:
        floor = c["min"].get("instance_size")
        ceil = c["max"].get("instance_size")
        if floor and order.index(size) < order.index(floor):
            out.append(
                f"{where}: instance_size {size} is below the floor {floor} for class '{c['class']}'. "
                f"Raise the tier, or move the environment to a class whose floor allows it."
            )
        if ceil and order.index(size) > order.index(ceil):
            out.append(
                f"{where}: instance_size {size} is above the ceiling {ceil} for class '{c['class']}'. "
                f"This ceiling exists so a forgotten dedicated cluster cannot quietly bill. To raise it, {PLATFORM_CONTACT}."
            )

    for key, want in c["required"].items():
        got = c["spec"].get(key, "unset")
        if got != want:
            out.append(
                f"{where}: '{key}' must be {want!r} in class '{c['class']}', got {got!r}. "
                f"Required values hold whatever the template says."
            )

    tenant = size in TENANT_SIZES
    min_tier = guardrails["dedicated_features_min_tier"]

    if not c["spec"].get("regions") and not c["spec"].get("region"):
        out.append(f"{where}: declare either 'region' for one region or 'regions' for several, and exactly one of them.")
    if c["spec"].get("regions") and c["spec"].get("region"):
        out.append(f"{where}: 'region' and 'regions' are mutually exclusive. Keep 'regions' and drop 'region'.")

    for r in c["regions"]:
        if r["name"] not in guardrails["regions"]:
            out.append(
                f"{where}: region {r['name']!r} is not in the allowlist {guardrails['regions']}. "
                f"An overridable key is still not a free key. To add a region, {PLATFORM_CONTACT}."
            )

    quota = guardrails["quotas"]["regions_per_cluster"]
    if len(c["regions"]) > quota:
        out.append(f"{where}: {len(c['regions'])} regions exceeds the quota of {quota}.")

    # How many regions the class expects. Development is single-region because
    # spanning regions bills twice for resilience nobody relies on; production is
    # multi-region because a single-region cluster loses its primary with the region.
    floors = guardrails["classes"][c["class"]]
    if len(c["regions"]) < floors["min_regions"]:
        out.append(
            f"{where}: class {c['class']!r} requires at least {floors['min_regions']} region(s), got {len(c['regions'])}. "
            f"Declare 'regions:' with one entry per region."
        )
    if len(c["regions"]) > floors["max_regions"]:
        out.append(
            f"{where}: class {c['class']!r} allows at most {floors['max_regions']} region(s), got {len(c['regions'])}. "
            f"To spread a cluster wider, move the environment to a class that permits it, or {PLATFORM_CONTACT}."
        )

    if len(c["regions"]) > 1 and tenant:
        out.append(
            f"{where}: a shared-tier cluster cannot be multi-region; {min_tier} or above is required, got {size}."
        )

    priorities = [r["priority"] for r in c["regions"]]
    if len(set(priorities)) != len(priorities):
        out.append(f"{where}: region priorities must be unique, got {priorities}. Atlas takes writes in the highest one.")
    if priorities and max(priorities) != 7:
        out.append(f"{where}: the highest region priority must be 7, got {max(priorities)}.")

    nodes = sum(r["node_count"] for r in c["regions"])
    if nodes % 2 == 0:
        out.append(f"{where}: {nodes} electable nodes is even; a replica set needs an odd count to elect a primary.")

    for a in c["online_archive"]:
        if a.get("date_field") in (a.get("partition_fields") or []):
            out.append(
                f"{where}: online archive {a.get('database')}.{a.get('collection')}: date_field "
                f"{a.get('date_field')!r} is added as partition field 0 automatically. Remove it from partition_fields."
            )

    if c["online_archive"] and tenant:
        out.append(
            f"{where}: online archive requires {min_tier} or above, got {size}. "
            f"Its collection must also already exist when it applies, which is why the seed runs between two applies."
        )

    if c["spec"].get("cloud_provider") not in guardrails["cloud_providers"]:
        out.append(
            f"{where}: cloud_provider {c['spec'].get('cloud_provider')!r} is not in {guardrails['cloud_providers']}."
        )

    import re

    if not re.match(guardrails["cluster_name_pattern"], c["name"]):
        out.append(f"{where}: cluster name {c['name']!r} does not match {guardrails['cluster_name_pattern']}.")

    return out


def check_environment(org, env_name, env, org_doc, guardrails, templates):
    import re

    where = f"orgs/{org}/{env_name}/environment.yaml"
    cls = env.get("class", guardrails["default_class"])
    out = []

    for name, cluster in env.get("clusters", {}).items():
        out += check_cluster(resolve_cluster(name, cluster, env, guardrails, templates), org, env_name, guardrails)

    for entry in env.get("network_access", []):
        if entry.get("cidr") == "0.0.0.0/0" and not guardrails["classes"][cls]["allow_open_ip"]:
            out.append(
                f"{where}: network_access 0.0.0.0/0 is not allowed in class '{cls}'. "
                f"Use a real CIDR, or PrivateLink."
            )

    arns = [u.get("aws_iam_role_arn") for u in (env.get("database_users") or [])]
    for arn in {a for a in arns if arns.count(a) > 1}:
        out.append(f"{where} -> database_users: {arn} is declared more than once. One entry per role, with all its databases.")

    for user in env.get("database_users") or []:
        arn = user.get("aws_iam_role_arn")
        for role in user.get("roles", []):
            if role["role"] not in guardrails["database_roles"]:
                out.append(
                    f"{where} -> database_users[{arn}]: role {role['role']!r} is not in "
                    f"{guardrails['database_roles']}. atlasAdmin is never team-declarable: every cluster "
                    f"already gets an audited break-glass superuser from the module."
                )

    defined_teams = {t["name"] for t in org_doc.get("teams", [])}
    for binding in env.get("team_access", []):
        if binding["team"] not in defined_teams:
            out.append(
                f"{where} -> team_access: team {binding['team']!r} is not defined in orgs/{org}/org.yaml. "
                f"Defined teams: {sorted(defined_teams)}."
            )
        for role in binding.get("project_roles", []):
            if role not in guardrails["project_roles"]:
                out.append(
                    f"{where} -> team_access.{binding['team']}: project role {role!r} is not in "
                    f"{guardrails['project_roles']}."
                )

    tags = (env.get("project") or {}).get("tags", {})
    if tags.get("owner") != org:
        out.append(f"{where}: tag 'owner' must be {org!r}, got {tags.get('owner')!r}.")
    if not re.match(guardrails["cost_center_pattern"], str(tags.get("cost_center", ""))):
        out.append(
            f"{where}: tag 'cost_center' {tags.get('cost_center')!r} does not match "
            f"{guardrails['cost_center_pattern']}."
        )

    pl = env.get("private_link") or {}
    if pl.get("enabled"):
        cluster_regions = {
            r["name"]
            for name, cluster in env.get("clusters", {}).items()
            for r in resolve_cluster(name, cluster, env, guardrails, templates)["regions"]
        }
        for r in pl.get("regions", []):
            if r["name"] not in guardrails["regions"]:
                out.append(f"{where} -> private_link: region {r['name']!r} is not in the allowlist {guardrails['regions']}.")
            elif r["name"] not in cluster_regions:
                out.append(
                    f"{where} -> private_link: region {r['name']!r} has no cluster in this environment "
                    f"(clusters run in {sorted(cluster_regions)}). An endpoint there routes to nothing."
                )

        declared = {r["name"] for r in pl.get("regions", [])}
        for name, cluster in env.get("clusters", {}).items():
            for r in resolve_cluster(name, cluster, env, guardrails, templates)["regions"]:
                if r["name"] not in declared:
                    out.append(
                        f"{where} -> private_link: cluster {name!r} runs in {r['name']} but no endpoint is declared there. "
                        f"Atlas returns no private connection string at all unless every region a cluster spans is covered — "
                        f"not a partial one for the covered region, none."
                    )

        sizes = [
            resolve_cluster(n, c, env, guardrails, templates)["spec"].get("instance_size")
            for n, c in env.get("clusters", {}).items()
        ]
        if sizes and all(s in TENANT_SIZES for s in sizes):
            out.append(
                f"{where} -> private_link: requires {guardrails['dedicated_features_min_tier']} or above; "
                f"this environment has no dedicated cluster."
            )

    sql = env.get("sql_interface") or {}
    if sql.get("enabled"):
        source = sql.get("source_cluster")
        clusters = env.get("clusters", {})
        if source not in clusters:
            out.append(
                f"{where} -> sql_interface: source_cluster {source!r} is not a cluster in this environment. "
                f"Clusters here: {sorted(clusters)}. A source that does not exist builds an instance that returns nothing."
            )
        else:
            resolved = resolve_cluster(source, clusters[source], env, guardrails, templates)
            if resolved["spec"].get("instance_size") in TENANT_SIZES:
                out.append(
                    f"{where} -> sql_interface: requires {guardrails['dedicated_features_min_tier']} or above on "
                    f"{source!r}, got {resolved['spec'].get('instance_size')}."
                )

    quota = guardrails["quotas"]["clusters_per_environment"]
    if len(env.get("clusters", {})) > quota:
        out.append(f"{where}: {len(env['clusters'])} clusters exceeds the quota of {quota}.")

    return out


def check_org(org, org_doc, environments, guardrails):
    where = f"orgs/{org}/org.yaml"
    out = []

    quota = guardrails["quotas"]["environments_per_org"]
    if len(environments) > quota:
        out.append(f"orgs/{org}/: {len(environments)} environments exceeds the quota of {quota}.")

    for team in org_doc.get("teams", []):
        for role in team.get("org_roles", []):
            if role not in guardrails["org_roles"]:
                out.append(
                    f"{where} -> teams.{team['name']}: org role {role!r} is not in {guardrails['org_roles']}. "
                    f"ORG_OWNER is reserved: it would let a team edit the settings and API keys Rain Maker runs on."
                )

    return out


def check_schemas(org, org_doc, environments):
    """Shape only. Value allowlists live in guardrails.yaml (ADR 0010)."""
    try:
        import jsonschema
    except ImportError:
        print("note: jsonschema not installed, skipping shape validation", file=sys.stderr)
        return []

    out = []
    schemas = {
        n: yaml.safe_load((ROOT / "platform/schema" / f"{n}.schema.json").read_text())
        for n in ("org", "environment")
    }
    for doc, schema, where in [(org_doc, "org", f"orgs/{org}/org.yaml")] + [
        (e, "environment", f"orgs/{org}/{n}/environment.yaml") for n, e in environments.items()
    ]:
        for err in jsonschema.Draft202012Validator(schemas[schema]).iter_errors(doc):
            path = ".".join(str(p) for p in err.absolute_path) or "<root>"
            # jsonschema's oneOf message ("not valid under any of the given
            # schemas") is useless here, and this is the mistake developers
            # actually make: half a template reference and half a custom cluster.
            if err.validator == "oneOf" and len(err.absolute_path) == 2 and err.absolute_path[0] == "clusters":
                out.append(
                    f"{where}: {path}: a cluster is either a template reference "
                    f"('template:' plus an optional 'overrides:') or a full custom spec, never both. "
                    f"Got keys {sorted(err.instance)}."
                )
            else:
                out.append(f"{where}: {path}: {err.message}")
    return out


def collect(root: Path = ROOT):
    guardrails = load(root / "platform/guardrails.yaml")
    templates = {p.stem: load(p) for p in (root / "platform/templates").glob("*.yaml")}

    problems = []
    for org_file in sorted((root / "orgs").glob("*/org.yaml")):
        org = org_file.parent.name
        org_doc = load(org_file)
        environments = {p.parent.name: load(p) for p in sorted(org_file.parent.glob("*/environment.yaml"))}

        problems += check_schemas(org, org_doc, environments)
        problems += check_org(org, org_doc, environments, guardrails)
        for env_name, env in environments.items():
            problems += check_environment(org, env_name, env, org_doc, guardrails, templates)

    return problems


# --- self-test ----------------------------------------------------------------
# One runnable check, matching the break table in docs/GUARDRAILS.md. Each case
# mutates a real declaration in memory and asserts the rule still fires.

def _multi_region(regions, size="M10"):
    return {"clusters": {"warehouse": {
        "cluster_type": "REPLICASET", "cloud_provider": "AWS", "instance_size": size,
        "backup_enabled": True, "termination_protection": True, "regions": regions}}}


SELF_TEST_CASES = [
    ("region not in allowlist", {"clusters": {"main": {"template": "sandbox-m0", "overrides": {"region": "AP_SOUTHEAST_1"}}}}, "dev", "not in the allowlist"),
    ("above the dev ceiling", {"clusters": {"main": {"template": "prod-m10", "overrides": {"instance_size": "M20"}}}}, "dev", "above the ceiling"),
    ("sealed by template", {"clusters": {"main": {"template": "prod-m10", "overrides": {"backup_enabled": False}}}}, "prod", "is sealed by template"),
    ("below the prod floor", {"clusters": {"main": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M0", "backup_enabled": True, "termination_protection": True}}}, "prod", "below the floor"),
    ("database role refused", {"clusters": {}, "database_users": [{"aws_iam_role_arn": "arn:aws:iam::111122223333:role/x", "roles": [{"database": "d", "role": "atlasAdmin"}]}]}, "dev", "is not in ['read', 'readWrite']"),
    ("duplicate IAM role", {"clusters": {}, "database_users": [{"aws_iam_role_arn": "arn:aws:iam::111122223333:role/x", "roles": [{"database": "d", "role": "read"}]}, {"aws_iam_role_arn": "arn:aws:iam::111122223333:role/x", "roles": [{"database": "e", "role": "read"}]}]}, "dev", "is declared more than once"),
    ("open ip refused in prod", {"clusters": {}, "network_access": [{"cidr": "0.0.0.0/0", "comment": "x"}]}, "prod", "not allowed in class 'prod'"),
    ("cost_center pattern", {"clusters": {}, "tags": {"cost_center": "4471"}}, "dev", "does not match"),
    ("undefined team", {"clusters": {}, "team_access": [{"team": "ghosts", "project_roles": ["GROUP_OWNER"]}]}, "dev", "is not defined in"),
    ("project role refused", {"clusters": {}, "team_access": [{"team": "payments-owners", "project_roles": ["GROUP_DATA_ACCESS_ADMIN"]}]}, "dev", "is not in ["),

    # Multi-region, online archive and Atlas SQL.
    ("even electable nodes", _multi_region([{"name": "EU_WEST_1", "node_count": 2, "priority": 7}, {"name": "US_EAST_1", "node_count": 2, "priority": 6}]), "prod", "electable nodes is even"),
    ("duplicate region priority", _multi_region([{"name": "EU_WEST_1", "node_count": 2, "priority": 7}, {"name": "US_EAST_1", "node_count": 1, "priority": 7}]), "prod", "priorities must be unique"),
    ("highest priority not 7", _multi_region([{"name": "EU_WEST_1", "node_count": 2, "priority": 5}, {"name": "US_EAST_1", "node_count": 1, "priority": 4}]), "prod", "highest region priority must be 7"),
    ("region not in allowlist, multi", _multi_region([{"name": "EU_WEST_1", "node_count": 2, "priority": 7}, {"name": "AP_SOUTHEAST_1", "node_count": 1, "priority": 6}]), "prod", "'AP_SOUTHEAST_1' is not in the allowlist"),
    ("regions over quota", _multi_region([{"name": "EU_WEST_1", "node_count": 1, "priority": 7}, {"name": "US_EAST_1", "node_count": 1, "priority": 6}, {"name": "EU_WEST_1", "node_count": 1, "priority": 5}, {"name": "US_EAST_1", "node_count": 2, "priority": 4}]), "prod", "regions exceeds the quota"),
    ("multi-region on a shared tier", _multi_region([{"name": "EU_WEST_1", "node_count": 2, "priority": 7}, {"name": "US_EAST_1", "node_count": 1, "priority": 6}], size="M0"), "dev", "cannot be multi-region"),
    ("region and regions together", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "instance_size": "M10", "backup_enabled": True, "termination_protection": True, "region": "EU_WEST_1", "regions": [{"name": "EU_WEST_1", "node_count": 3, "priority": 7}]}}}, "prod", "mutually exclusive"),
    ("date field repeated in partition_fields", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M10", "backup_enabled": True, "termination_protection": True, "online_archive": [{"database": "d", "collection": "c", "date_field": "created_at", "partition_fields": ["created_at"]}]}}}, "dev", "added as partition field 0 automatically"),
    ("online archive on a shared tier", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M0", "online_archive": [{"database": "d", "collection": "c", "date_field": "created_at"}]}}}, "dev", "online archive requires M10"),
    ("private_link region not in allowlist", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M10"}}, "private_link": {"enabled": True, "regions": [{"name": "AP_SOUTHEAST_1"}]}}, "dev", "private_link: region 'AP_SOUTHEAST_1' is not in the allowlist"),
    ("private_link region with no cluster", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M10"}}, "private_link": {"enabled": True, "regions": [{"name": "US_EAST_1"}]}}, "dev", "has no cluster in this environment"),
    ("private_link covering only one region of two", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "instance_size": "M10", "backup_enabled": True, "termination_protection": True, "regions": [{"name": "EU_WEST_1", "node_count": 2, "priority": 7}, {"name": "US_EAST_1", "node_count": 1, "priority": 6}]}}, "private_link": {"enabled": True, "regions": [{"name": "US_EAST_1"}]}}, "prod", "runs in EU_WEST_1 but no endpoint is declared there"),
    ("private_link on a shared tier", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M0"}}, "private_link": {"enabled": True, "regions": [{"name": "EU_WEST_1"}]}}, "dev", "private_link: requires M10"),
    ("sql source cluster missing", {"clusters": {}, "sql_interface": {"enabled": True, "source_cluster": "ghost"}}, "dev", "is not a cluster in this environment"),
    ("sql on a shared tier", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M0"}}, "sql_interface": {"enabled": True, "source_cluster": "warehouse"}}, "dev", "sql_interface: requires M10"),

    # How many regions each class expects: dev exactly one, prod at least two.
    ("multi-region in class dev", _multi_region([{"name": "EU_WEST_1", "node_count": 2, "priority": 7}, {"name": "US_EAST_1", "node_count": 1, "priority": 6}]), "dev", "class 'dev' allows at most 1 region"),
    ("single region in class prod", {"clusters": {"warehouse": {"cluster_type": "REPLICASET", "cloud_provider": "AWS", "region": "EU_WEST_1", "instance_size": "M10", "backup_enabled": True, "termination_protection": True}}}, "prod", "class 'prod' requires at least 2 region"),
]


def self_test(root: Path = ROOT):
    guardrails = load(root / "platform/guardrails.yaml")
    templates = {p.stem: load(p) for p in (root / "platform/templates").glob("*.yaml")}
    org_doc = load(root / "orgs/payments/org.yaml")

    failures = []
    for label, patch, cls, expected in SELF_TEST_CASES:
        env = {
            "environment": "dev",
            "class": cls,
            "project": {"tags": {"owner": "payments", "cost_center": patch.pop("tags", {}).get("cost_center", "cc-4471")}},
            **patch,
        }
        found = check_environment("payments", "dev", env, org_doc, guardrails, templates)
        if not any(expected in m for m in found):
            failures.append(f"{label}: expected a message containing {expected!r}, got {found}")

    # Shape, not values: the mistake developers actually make.
    mixed = check_schemas(
        "payments",
        org_doc,
        {"dev": {"environment": "dev", "clusters": {"main": {"template": "sandbox-m0", "instance_size": "M10"}}}},
    )
    if mixed and not any("never both" in m for m in mixed):
        failures.append(f"mixed template and custom keys: expected the either/or message, got {mixed}")

    clean = collect(root)
    if clean:
        failures.append(f"the repository as committed must be clean, got {len(clean)} problems:\n  " + "\n  ".join(clean))

    if failures:
        print("SELF-TEST FAILED\n  " + "\n  ".join(failures))
        return 1
    print(f"self-test ok: {len(SELF_TEST_CASES)} guardrails + the template/custom split fire, repository clean")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    problems = collect()
    if not problems:
        print("guardrails ok")
        return 0

    print(f"::error::{len(problems)} guardrail violation(s)")
    for p in problems:
        print(f"  - {p}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
