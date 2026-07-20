data "aws_partition" "current" {}

# Supporting infrastructure for the Karpenter controller: controller IAM role
# wired to the service account via EKS Pod Identity, node IAM role + access
# entry, SQS interruption queue and EventBridge rules for spot interruption
# and rebalance events.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.0"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true

  # SSM access to Karpenter-launched nodes for debugging without SSH keys
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# The Karpenter controller itself. It runs on the static system node group and
# provisions every workload node. wait=false: readiness is reconciled by the
# controller, there is nothing to block the apply on.
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  wait       = false

  values = [
    yamlencode({
      serviceAccount = {
        name = module.karpenter.service_account
      }
      # Explicit requests: guaranteed scheduling for the controller and no
      # spare system-node capacity that could silently absorb workload pods
      controller = {
        resources = {
          requests = {
            cpu    = "1"
            memory = "1Gi"
          }
          limits = {
            memory = "1Gi"
          }
        }
      }
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
    })
  ]
}

# NodePool + EC2NodeClass ship as a tiny local chart so the same Helm provider
# applies them: no extra kubectl provider, correct ordering, single apply.
resource "helm_release" "karpenter_resources" {
  name      = "karpenter-resources"
  namespace = "kube-system"
  chart     = "${path.module}/charts/karpenter-resources"

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      nodeRole    = module.karpenter.node_iam_role_name
    })
  ]

  # module.eks is listed explicitly for DESTROY ordering: NodePool/EC2NodeClass
  # finalizers are cleared by the Karpenter controller, which runs on the
  # system node group inside module.eks. Without this, terraform destroy can
  # tear the node group down in parallel and the uninstall hangs on finalizers.
  depends_on = [helm_release.karpenter, module.eks]
}
