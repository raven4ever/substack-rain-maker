# The development team's half of the PrivateLink handshake.
#
# Rain Maker creates the Atlas endpoint service and publishes its name. This
# creates the interface endpoint that connects to it, in an account Rain Maker
# has no credentials for and no opinion about.
#
# A multi-region cluster needs one endpoint per region: the endpoint is regional
# and so is the Atlas endpoint service behind it. One module call per region,
# each present only if that region appears in endpoint_service_names.

module "eu_west_1" {
  count  = contains(keys(var.endpoint_service_names), "EU_WEST_1") ? 1 : 0
  source = "./modules/atlas-endpoint"

  providers = { aws = aws.eu_west_1 }

  name                        = "${var.name}-eu-west-1"
  vpc_cidr                    = var.vpc_cidrs["EU_WEST_1"]
  atlas_endpoint_service_name = var.endpoint_service_names["EU_WEST_1"]
}

module "us_east_1" {
  count  = contains(keys(var.endpoint_service_names), "US_EAST_1") ? 1 : 0
  source = "./modules/atlas-endpoint"

  providers = { aws = aws.us_east_1 }

  name                        = "${var.name}-us-east-1"
  vpc_cidr                    = var.vpc_cidrs["US_EAST_1"]
  atlas_endpoint_service_name = var.endpoint_service_names["US_EAST_1"]
}

module "eu_north_1" {
  count  = contains(keys(var.endpoint_service_names), "EU_NORTH_1") ? 1 : 0
  source = "./modules/atlas-endpoint"

  providers = { aws = aws.eu_north_1 }

  name                        = "${var.name}-eu-north-1"
  vpc_cidr                    = var.vpc_cidrs["EU_NORTH_1"]
  atlas_endpoint_service_name = var.endpoint_service_names["EU_NORTH_1"]
}

# The application's identity. IAM is global, so there is one role however many
# regions the cluster spans. Atlas authenticates the role itself — no password
# exists anywhere — so this role needs no Atlas-side permissions at all.
resource "aws_iam_role" "app" {
  provider = aws.eu_west_1

  name = "${var.name}-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = var.name }
}
