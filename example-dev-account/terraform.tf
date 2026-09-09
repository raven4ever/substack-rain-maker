terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# One aliased provider per region in platform/guardrails.yaml.
#
# Terraform cannot iterate provider configurations. `for_each` in a provider
# block is a reserved argument — "reserved for use by Terraform in a future
# version" — and neither a resource nor a module can reference
# aws.by_region[each.key]. Checked on 1.15.5 and on 1.16.1, which is what
# Terraform Cloud runs; upgrading does not fix it.
#
# So the regions are spelled out. Adding one to the allowlist means adding an
# alias and a module block here.
provider "aws" {
  alias  = "eu_west_1"
  region = "eu-west-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "eu_north_1"
  region = "eu-north-1"
}
