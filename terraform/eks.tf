module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # POC access model: public API endpoint, caller becomes cluster admin.
  # Production would restrict the endpoint to known CIDRs or go fully private.
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  # Small static Graviton node group that hosts only the cluster-critical layer
  # (Karpenter controller, CoreDNS). All workload capacity is provisioned by
  # Karpenter, so this group stays fixed-size and on-demand.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["t4g.medium"]

      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }

  # Karpenter's EC2NodeClass discovers the node security group by this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}
