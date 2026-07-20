data "aws_availability_zones" "available" {
  # Exclude opt-in zones (local/wavelength) that lack the instance types we use
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# Dedicated VPC across three AZs: private subnets for nodes, public subnets for
# load balancers and the NAT gateway, intra (no-egress) subnets for the EKS
# control plane ENIs. A single NAT gateway keeps the POC cost down - production
# would run one per AZ for zone fault isolation.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter's EC2NodeClass discovers node subnets by this tag
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}
