# One region's half of the PrivateLink handshake: a VPC, a subnet, a security
# group, and the interface endpoint that connects to the Atlas endpoint service
# Rain Maker published.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" { type = string }
variable "vpc_cidr" { type = string }

variable "atlas_endpoint_service_name" {
  type        = string
  description = "From the Rain Maker workspace output `private_link`, for this region."
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required for an interface endpoint. Without them the endpoint is
  # created and resolves to nothing.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_subnet" "this" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = var.name }
}

# Atlas answers on 27017 and, for a replica set, on 1024-65535. Inbound is scoped
# to the VPC because the only clients are inside it.
resource "aws_security_group" "endpoint" {
  name        = "${var.name}-atlas-endpoint"
  description = "Client access to the Atlas PrivateLink endpoint"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = var.name }
}

resource "aws_vpc_endpoint" "atlas" {
  vpc_id            = aws_vpc.this.id
  service_name      = var.atlas_endpoint_service_name
  vpc_endpoint_type = "Interface"

  subnet_ids         = [aws_subnet.this.id]
  security_group_ids = [aws_security_group.endpoint.id]

  # Leave this off. Atlas hands back an SRV connection string and resolves the
  # private hostnames itself; turning private DNS on breaks that resolution.
  private_dns_enabled = false

  tags = { Name = "${var.name}-atlas" }
}

output "vpc_endpoint_id" {
  value = aws_vpc_endpoint.atlas.id
}
