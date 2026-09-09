variable "name" {
  type        = string
  description = "Name prefix for everything created here."
  default     = "analytics-prod"
}

variable "endpoint_service_names" {
  type        = map(string)
  description = <<-EOT
    Atlas endpoint service name per Atlas region, from the Rain Maker workspace
    output. One entry per region the cluster spans and PrivateLink is declared in:

      terraform output -json private_link

    For example:

      {
        EU_WEST_1  = "com.amazonaws.vpce.eu-west-1.vpce-svc-0123456789abcdef0"
        EU_NORTH_1 = "com.amazonaws.vpce.eu-north-1.vpce-svc-0fedcba9876543210"
      }

    Leave a region out and nothing is created for it.
  EOT
  default = {
    EU_NORTH_1 = "com.amazonaws.vpce.eu-north-1.vpce-svc-027f81756be297f42"
  }

  validation {
    condition = alltrue([
      for r in keys(var.endpoint_service_names) : contains(["EU_WEST_1", "US_EAST_1", "EU_NORTH_1"], r)
    ])
    error_message = "Regions must be in the Rain Maker allowlist: EU_WEST_1, US_EAST_1, EU_NORTH_1. Adding another means adding a provider alias and a module block here too."
  }
}

variable "vpc_cidrs" {
  type        = map(string)
  description = "CIDR per Atlas region. Separate VPCs, so these only have to differ for your own sanity."
  default = {
    EU_WEST_1  = "10.31.0.0/16"
    US_EAST_1  = "10.33.0.0/16"
    EU_NORTH_1 = "10.32.0.0/16"
  }
}
