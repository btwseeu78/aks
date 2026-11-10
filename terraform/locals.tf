data "aws_availability_zones" "available" {
  state = "available"
}
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  # /20 private and public subnets
  private_subnets = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 4, i) }
  public_subnets  = { for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, 48 + i) }

  # /18 pods from the secondary CIDR
  pod_subnets = { for i, az in local.azs : az => cidrsubnet(var.pod_cidr, 2, i) }
}
