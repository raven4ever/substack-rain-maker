# Both of these are pasted into the Rain Maker repository by hand, in a pull
# request the development team owns. That copy is the ownership boundary: two
# accounts, two states, two reviews, and a string passed between them.

output "aws_vpc_endpoint_ids" {
  description = "Phase 2. Add each to the matching private_link.regions[] entry in environment.yaml."
  value = merge(
    { for m in module.eu_west_1 : "EU_WEST_1" => m.vpc_endpoint_id },
    { for m in module.us_east_1 : "US_EAST_1" => m.vpc_endpoint_id },
    { for m in module.eu_north_1 : "EU_NORTH_1" => m.vpc_endpoint_id },
  )
}

output "iam_role_arn" {
  description = "Add this to database_users[].aws_iam_role_arn in environment.yaml."
  value       = aws_iam_role.app.arn
}
