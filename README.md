# Rain Maker

A GitOps control plane for MongoDB Atlas. Organizations, projects, clusters, database users, network access, teams and role bindings are declared in YAML here and applied by Terraform Cloud on every merge.

Supporting repository for the Substack article _[Rain Maker: A GitOps Control Plane for MongoDB Atlas](https://driftdetected.substack.com/p/rain-maker-a-gitops-control-plane)_.

Mantra: when it rains, the Mongo leaves grow.

## Concepts

### Ownership

| Role             | Owns                                                                           | Bound by                                                                  |
| ---------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Platform team    | Everything outside [`orgs/`](orgs): modules, templates, guardrails, onboarding | Nothing; it sets the limits                                               |
| Development team | One directory, `orgs/<org>/`                                                   | Every guardrail in [`platform/guardrails.yaml`](platform/guardrails.yaml) |

Nobody clicks in the Atlas UI, with two exceptions: creating the Atlas organization, and pasting its API key into a Terraform Cloud variable set.

### Scope

Rain Maker manages Atlas and Terraform Cloud. It manages nothing in any AWS account — there is no `aws` provider here. A team's IAM role ARNs and VPC endpoint ids are opaque strings in that team's YAML; their AWS side lives in their own repository, shown here as [`example-dev-account/`](example-dev-account). Hence PrivateLink takes two pull requests: two-party handshake, one party owned.

### Credentials

| Plane   | Who                                 | Credential                                                                                                              |
| ------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Control | Terraform reaching Atlas            | One `ORG_OWNER` API key per organization, in that workspace's variable set only                                         |
| Data    | An application reaching its cluster | Its AWS IAM role: `aws_iam_type = "ROLE"`, role ARN as username, against `$external`. Nothing issued, stored or rotated |
| CI      | GitHub Actions                      | None. It only reads the repository                                                                                      |

An organization key is blind to every other organization, so a leak reaches one tenant. The workspace holds exactly one, which is why [`terraform/org-root`](terraform/org-root) declares a bare `provider "mongodbatlas" {}` — no alias, no `org_id`. The cost: no cross-organization Terraform, and rotation is one paste per organization.

### Break-glass superuser

Every cluster gets an implicit `atlasAdmin` user. **Its password lives in Terraform state and in every historical version, readable by anyone with read access to that workspace.** State access control is the control; blast radius is one organization.

## Repository layout

```
platform/
  guardrails.yaml            every limit, in one file
  templates/*.yaml           platform-owned cluster templates
  schema/*.json              shape only; values live in guardrails.yaml
orgs/
  <org>/org.yaml             organization id, Atlas Teams, members
  <org>/<env>/environment.yaml   projects, clusters, users, access
terraform/
  bootstrap/                 creates one workspace per org directory
  org-root/                  the whole control plane; every workspace runs this
scripts/
  validate.py                guardrails, fast, local and in CI
  seed.sh                    demo data; Terraform does not own data
example-dev-account/         the development team's AWS side, not managed here
```

No Terraform inside [`orgs/`](orgs). One fixed root module serves every organization, told which one by `var.org_name`.

## Requirements

### Accounts

| Account         | Needed for                                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| MongoDB Atlas   | One organization per tenant, created by hand, each with its own `ORG_OWNER` API key. This repository ships `analytics` and `payments` |
| Terraform Cloud | One organization; runs every apply. Free tier is enough — quotas are sized for 500 managed resources and one concurrent run           |
| GitHub          | Holds this repository. Connect it over the GitHub **OAuth** provider, not the GitHub App                                              |
| AWS             | Optional, for [`example-dev-account/`](example-dev-account) only. Rain Maker never touches it                                         |

### Tools

| Tool            | Version                               | Needed for                                                                                             |
| --------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Terraform       | >= 1.11 (Terraform Cloud runs 1.16.x) | `fmt`, `validate`, [`example-dev-account/`](example-dev-account). Atlas runs happen in Terraform Cloud |
| Python          | 3.12+, `pyyaml`, `jsonschema`         | [`scripts/validate.py`](scripts/validate.py)                                                           |
| curl            | any                                   | The Administration API `PATCH` in [Teardown](#teardown)                                                |
| mongosh         | any                                   | [`scripts/seed.sh`](scripts/seed.sh)                                                                   |
| AWS credentials | —                                     | [`example-dev-account/`](example-dev-account)                                                          |

### Before the first bootstrap apply

1. Push this repository to GitHub. Put real handles in [`.github/CODEOWNERS`](.github/CODEOWNERS).
2. Create one Atlas organization per directory under [`orgs/`](orgs), and put each id into `orgs/<org>/org.yaml` as `atlas_org_id`.
3. Create an `ORG_OWNER` API key per Atlas organization. Both halves stay out of the repository.
4. Connect GitHub to Terraform Cloud over OAuth. The bootstrap resolves it with `data "tfe_oauth_client"`, so no id is copied by hand.
5. Create the bootstrap workspace by hand — the only one a human creates. VCS-driven, working directory [`terraform/bootstrap`](terraform/bootstrap), auto-apply **off**.
6. Set its variables:

   | Variable           | Category       | Value                                                |
   | ------------------ | -------------- | ---------------------------------------------------- |
   | `tfc_organization` | terraform      | Terraform Cloud organization name                    |
   | `github_repo`      | terraform      | `owner/name` of this repository                      |
   | `TFE_TOKEN`        | env, sensitive | Token allowed to create workspaces and variable sets |

## Bootstrap

Queue a plan on the bootstrap workspace, read it, confirm the apply. Per directory under [`orgs/`](orgs) it creates:

- workspace `rain-maker-<org>` — VCS-driven, working directory [`terraform/org-root`](terraform/org-root), `auto_apply = true`, `queue_all_runs = false`, `trigger_patterns` of `orgs/<org>/**/*`, `terraform/org-root/**/*`, `platform/**/*`;
- the `org_name` variable, the only per-organization Terraform artifact;
- variable set `atlas-<org>`, empty, attached to that workspace alone.

Then paste the keys. Each set holds `MONGODB_ATLAS_PUBLIC_KEY` and `MONGODB_ATLAS_PRIVATE_KEY` as sensitive environment variables, pre-filled with `PASTE-THE-<ORG>-PUBLIC-KEY-HERE` and `PASTE-THE-<ORG>-PRIVATE-KEY-HERE`. `lifecycle { ignore_changes = [value] }` keeps Terraform out of them afterwards.

A key pasted into the wrong organization plans perfectly — an empty-state plan makes no authenticated Atlas call — and fails at the first create with `HTTP 401 USER_CANNOT_ACCESS_ORG`. Match the placeholder to the organization before overwriting it.

**Onboarding another organization** is the same two stages, because a new organization cannot plan on its own onboarding pull request: add `orgs/<org>/org.yaml` and its CODEOWNERS line, merge, apply the bootstrap, paste that key.

## Deploying the organizations

| Directory                           | Shape                                                                                                                                  |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| [`orgs/payments/`](orgs/payments)   | `dev` and `prod`, both `sandbox-m0` template, both class `dev`. Free tier. `prod` carries `class: dev` deliberately; the file says why |
| [`orgs/analytics/`](orgs/analytics) | `dev` is a custom M0. `prod` is the showpiece: multi-region M10, backups, online archive, Atlas SQL, PrivateLink                       |

1. Check `atlas_org_id` in each `org.yaml` against the key in that workspace's variable set.
2. Run [`scripts/validate.py`](scripts/validate.py).
3. Open **one pull request per organization**. CI refuses a pull request touching two: separate workspaces, state and reviewers, and the free tier applies one run at a time.
4. Merge. **Merging applies**, no second confirmation. Only the workspace matched by `trigger_patterns` runs.
5. Read the outputs.

| Output                | Contents                                                                    |
| --------------------- | --------------------------------------------------------------------------- |
| `clusters`            | Resolved specification per cluster, plus the connection string              |
| `superuser_passwords` | `atlasAdmin` username and password per cluster. Sensitive                   |
| `private_link`        | Atlas endpoint service name and status per environment and region — phase 1 |
| `projects`            | Atlas project ids, keyed by environment                                     |

For `analytics/prod`: PrivateLink is two merges with the [`example-dev-account/`](example-dev-account) work between them, and the online archive needs no existing collection — Atlas parks it in `PENDING`, so [`scripts/seed.sh`](scripts/seed.sh) can run any time after the cluster is up.

## Cluster configuration

Clusters live in `orgs/<org>/<env>/environment.yaml`, on one of two paths. Both are bound by the class floors in [`platform/guardrails.yaml`](platform/guardrails.yaml).

**Template path** — change only the keys the template's `overridable` allowlist names. Every other key is sealed; overriding one is a violation, not a silent win.

```yaml
clusters:
  main:
    template: prod-m10
    overrides:
      region: EU_WEST_1
      disk_size_gb: 20
```

**Custom path** — the cluster in full. Freedom of shape, none from the limits. `regions:` replaces `region:`; priorities are unique, the highest is 7, electable nodes total odd.

```yaml
clusters:
  warehouse:
    cluster_type: REPLICASET
    cloud_provider: AWS
    instance_size: M10
    backup_enabled: true
    termination_protection: true
    regions:
      - name: EU_WEST_1
        node_count: 2
        priority: 7
      - name: US_EAST_1
        node_count: 1
        priority: 6
```

**Online archive and Atlas SQL** both need a dedicated cluster, M10 or above; [`validate.py`](scripts/validate.py) and the plan precondition refuse either on M0, M2 or M5.

An archive is a list on the cluster — template path or custom, but never inside the template file. `database`, `collection` and `date_field` are required; `expire_after_days` and extra `partition_fields` are not. The date field becomes partition field 0 automatically, so repeating it in `partition_fields` is an error, and the data region is derived from the priority 7 region because Atlas refuses to guess for a multi-region cluster. The collection need not exist: Atlas parks the archive in `PENDING` and activates it when data arrives.

```yaml
clusters:
  warehouse:
    # ... as above
    online_archive:
      - database: analytics
        collection: events
        date_field: created_at
        expire_after_days: 30
        partition_fields: [kind] # optional, after the date field
```

Atlas SQL is declared per environment, beside `clusters:` rather than inside one. `enabled` and `source_cluster` are required, and `source_cluster` must name a cluster in the same environment; `databases[]` lists what the instance exposes. Rain Maker creates one federated database instance per environment, named `<org>-<env>-sql`, and derives the store wiring from `source_cluster`.

```yaml
sql_interface:
  enabled: true
  source_cluster: warehouse
  databases:
    - name: analytics
      collections: [events]
```

Reaching either one privately needs its own endpoint against a MongoDB-owned service — `data_federation_vpc_endpoint_id` under `private_link`, described in [PrivateLink](#privatelink).

**Database users** are a list of IAM roles, not one per cluster: several workloads reach one cluster with different reach. `"*"` means every database. The ARN is the identity and therefore the Terraform key, so a repeated ARN is refused rather than collapsed.

```yaml
database_users:
  - aws_iam_role_arn: "arn:aws:iam::111122223333:role/analytics-prod-app"
    roles:
      - database: analytics
        role: readWrite
  - aws_iam_role_arn: "arn:aws:iam::111122223333:role/analytics-prod-bi"
    roles:
      - database: "*" # readAnyDatabase on admin, in Atlas terms
        role: read
```

`class:` picks the floor set; omit it and the strictest applies. The class also fixes region count — `dev` single-region, `prod` at least two. Quotas: three clusters per environment, four environments per organization, three regions per cluster. Renaming a cluster is a destroy and a create.

## Guardrails

Every limit is in [`platform/guardrails.yaml`](platform/guardrails.yaml), sealed by CODEOWNERS. Both enforcement passes read that one file — [`scripts/validate.py`](scripts/validate.py) and [`terraform/org-root/locals.tf`](terraform/org-root/locals.tf) — so one edit moves both.

| Key                                            | Controls                                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------------------- |
| `tier_order`, `dedicated_features_min_tier`    | Tier comparison; floor for multi-region, online archive, Atlas SQL              |
| `default_class`                                | Class applied when an environment omits `class:`                                |
| `cloud_providers`, `regions`, `database_roles` | Static enums, enforced in the JSON Schema                                       |
| `org_roles`, `project_roles`                   | Roles a team may grant itself                                                   |
| `cluster_name_pattern`, `cost_center_pattern`  | Naming and tagging                                                              |
| `quotas`                                       | Clusters per environment, environments per organization, regions per cluster    |
| `classes.<class>`                              | Floors: `min`, `max`, `required`, `allow_open_ip`, `min_regions`, `max_regions` |

Edit the file, check it, open a pull request against `/platform/`:

```shell
pip install pyyaml jsonschema
scripts/validate.py              # the repository still satisfies the limits
scripts/validate.py --self-test  # every rule still fires
```

A tightened guardrail can break an existing environment, and this is where that shows up rather than in a queued run. The same rules run again as Terraform preconditions, because a check a developer can skip is not a guardrail.

- **New class**: a block under `classes` carrying all six keys.
- **New region**: the `regions` enum, plus — if PrivateLink is in play — a provider alias and module block in [`example-dev-account/main.tf`](example-dev-account/main.tf), because Terraform cannot iterate provider configurations.
- **Templates**: [`platform/templates/*.yaml`](platform/templates), each with a `spec`, an `overridable` allowlist, and `min`/`required` floors that may tighten a class floor but never loosen it. Unversioned, so editing one changes every cluster referencing it on its next apply.
- **Schemas**: [`platform/schema/*.json`](platform/schema) describe shape only. Values live in `guardrails.yaml`.

## PrivateLink

Two-party handshake. Rain Maker owns the Atlas side; the interface endpoint lives in the team's own AWS account and repository.

**Phase 1** — declare the region and merge. Rain Maker creates the Atlas endpoint service and publishes its name in the `private_link` output; the team creates their interface endpoint against it.

```yaml
private_link:
  enabled: true
  regions:
    - name: EU_WEST_1
```

**Phase 2** — add the id their account produced, merge again, and Rain Maker accepts the connection.

```yaml
- name: EU_WEST_1
  aws_vpc_endpoint_id: "vpce-0aaaabbbbccccdddd"
```

**Phase 2 is not optional.** AWS bills an endpoint sitting in `pendingAcceptance`, so an abandoned phase 1 costs money and connects nothing.

Atlas SQL and the online archive reach a MongoDB-owned service rather than the cluster, so they need their own endpoint: `data_federation_vpc_endpoint_id`, same two-phase shape.

## Teardown

Order matters. A destroy run that reports failure is not evidence that anything survived — the cluster state in the Atlas API is the truth, the run status is not.

**1. Clear termination protection, out of band, before queueing any destroy.** Class `prod` requires it, and the configuration cannot turn it off: [`validate.py`](scripts/validate.py) and the `terraform_data.guardrails` precondition both refuse `termination_protection: false` in that class. Protection guards the dedicated clusters, which are the ones that cost money, so a destroy that fails on it reaps the free clusters and leaves the M10 running.

Wait for `IDLE`.

**2. Unwind PrivateLink, Atlas side first.** That delete blocks until every cluster in the project reaches `IDLE`, up to two hours; [`private_link.tf`](terraform/org-root/private_link.tf) sets a 20 minute delete timeout so it fails loudly instead of hanging. Then `terraform destroy` in [`example-dev-account/`](example-dev-account), which removes the endpoint before the security group attached to it.

**3. Destroy each organization workspace.** Expect more than one run: cluster deletion is asynchronous, and a second run re-issues the DELETE, gets `HTTP 400 CLUSTER_ALREADY_REQUESTED_DELETION`, and reports as errored while the deletion succeeds. Re-queue once the cluster is gone; the last run removes the projects.

**4. Destroy the bootstrap last.** It deletes the organization workspaces, their state and the variable sets, so those workspaces must be empty of Atlas resources first. Then remove the hand-created bootstrap workspace, the API keys and the Atlas organizations.

**5. Verify by API that nothing billable survives**, and record what the check was:

- no cluster and no federated database instance in any project;
- no online archive;
- no Atlas network container left by an implicit creation;
- no VPC endpoint in **any** state — AWS bills one in `pendingAcceptance`;
- no security group orphaned by a failed detach;
- no Atlas project, and no Terraform Cloud workspace still holding state.

## Known limits

- No `backend` or `cloud` block here. The workspaces are VCS-driven, so Terraform Cloud owns the state and the trigger, and no plan runs against real state from a laptop.
- Policy-as-code (Sentinel, OPA) needs the Standard tier. The rules are written twice instead: [`scripts/validate.py`](scripts/validate.py), and a Terraform precondition.
- Drift detection is Standard tier too, so `assessments_enabled` is false.
- Federated authentication (SSO) is out of scope: the provider's resources are import-only and domain verification has no Terraform resource at all. Access groups come from Atlas Teams and role bindings instead.
- `mongodbatlas_project` must carry `lifecycle { ignore_changes = [teams] }`, or every project update silently deletes the role bindings `mongodbatlas_team_project_assignment` created.
- Renaming a cluster is a destroy and a create.
