# example-dev-account

The development team's side of the PrivateLink handshake. **Rain Maker does not manage any of this**, and could not: there is no `aws` provider anywhere in `terraform/`, and no credentials for your account ([ADR 0006](../docs/adr/0006-atlas-only-ownership-boundary.md)).

In a real setup this is a separate repository, owned by the development team, with its own state and its own reviewers. It sits in this one so the article has something to point at. Treat the directory boundary as standing in for a repository boundary: nothing here is read by any Rain Maker workspace, and nothing here shares state with them.

Run it from a laptop, against your own AWS account.

## What it creates

Per region: a VPC with both DNS attributes enabled, one subnet, a security group allowing 27017 and 1024-65535 from inside the VPC, and the interface endpoint itself with `private_dns_enabled = false`. Once, globally: the IAM role your application assumes.

A multi-region cluster needs **one endpoint per region** — the endpoint is regional, and so is the Atlas endpoint service behind it.

## Running it

Phase 1 has to have happened first: `private_link` declared in `environment.yaml` and merged, so Atlas has created the endpoint services.

```bash
# In the Rain Maker workspace, read what phase 1 published:
terraform output -json private_link

cd example-dev-account
terraform init
terraform apply -var 'endpoint_service_names={
  EU_WEST_1 = "com.amazonaws.vpce.eu-west-1.vpce-svc-0123456789abcdef0"
  US_EAST_1 = "com.amazonaws.vpce.us-east-1.vpce-svc-0fedcba9876543210"
}'
```

Then take the outputs back to Rain Maker as phase 2 — `aws_vpc_endpoint_ids` into `private_link.regions[].aws_vpc_endpoint_id`, and `iam_role_arn` into `database_users[].aws_iam_role_arn`. That copy-paste is not friction to be automated away; it is the boundary, and it is reviewed on both sides.

**Phase 2 is not optional.** AWS bills an interface endpoint sitting in `pendingAcceptance`, so an abandoned phase 1 costs money and connects nothing.

## Teardown

`terraform destroy` here, and only after the Atlas side is gone or the endpoint is detached. Two hazards, both from research ticket 04:

- A security group will not delete while it is still attached to an endpoint. Terraform orders this correctly because the endpoint references the group, but a partial destroy can leave the group orphaned.
- Atlas's own PrivateLink delete blocks until every cluster in the project reaches `IDLE`, up to two hours. `terraform/org-root/private_link.tf` sets a 20 minute delete timeout so it fails loudly instead of hanging.

## Adding a region

Terraform cannot iterate provider configurations. `for_each` inside a `provider` block is a reserved argument name, held for a future version, and nothing can reference `aws.by_region[each.key]` — not a resource, not a module's `providers` map. Verified on 1.15.5 and on 1.16.1, the version Terraform Cloud runs, so this is not something a version bump fixes.

Each region is therefore an explicit provider alias and module block in `main.tf`. Adding one to `platform/guardrails.yaml` means adding both here, and the `validation` on `endpoint_service_names` will refuse a region that has neither.
