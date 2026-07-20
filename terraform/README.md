# EKS + Karpenter POC - Graviton and Spot ready

Terraform that stands up a complete proof of concept:

- A dedicated VPC across 3 AZs (private subnets for nodes, public for load
  balancers and NAT, isolated intra subnets for the control plane ENIs)
- An EKS cluster on Kubernetes 1.36 (latest available at the time of writing)
- Karpenter 1.14 installed via Helm, with controller IAM wired through EKS Pod
  Identity and spot interruption handling via SQS
- One multi-arch NodePool that launches both x86 (amd64) and Graviton (arm64)
  instances, preferring Spot with automatic on-demand fallback
- A small static Graviton node group that hosts only the cluster-critical layer
  (Karpenter controller, CoreDNS) - every workload node comes from Karpenter

## Prerequisites

| Tool | Notes |
|---|---|
| Terraform | >= 1.5.7 |
| AWS CLI v2 | authenticated; the caller identity becomes cluster admin |
| kubectl | within one minor of the cluster version |

The AWS credentials need permissions to create VPC, EKS, IAM, SQS and
EventBridge resources. No local Helm binary is required - the Terraform Helm
provider embeds Helm as a library.

## Deploy

```bash
terraform init
terraform plan
terraform apply   # ~15 minutes
```

Point kubectl at the cluster (the exact command is also printed as the
`configure_kubectl` output) and check that Karpenter is up:

```bash
aws eks update-kubeconfig --region eu-west-1 --name opsfleet-poc
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl get nodepools,ec2nodeclasses
```

Region, cluster name and versions are variables with sensible defaults - see
`variables.tf`. State is local for POC simplicity; for team use put an S3
backend in front of this.

## Running workloads on x86 or Graviton

The cluster runs a single Karpenter NodePool that can launch **both**
architectures. A developer picks the CPU architecture with a standard
`nodeSelector` in the pod spec - no taints, tolerations or custom labels
involved:

```yaml
spec:
  nodeSelector:
    kubernetes.io/arch: arm64   # Graviton; use amd64 for x86
```

Omit the selector entirely and Karpenter simply launches whatever is cheapest
for the pod's resource requests (with multi-arch images that is usually
Graviton spot).

Try the bundled examples:

```bash
kubectl apply -f examples/graviton-deployment.yaml   # pinned to arm64
kubectl apply -f examples/x86-deployment.yaml        # pinned to amd64
kubectl apply -f examples/multiarch-deployment.yaml  # no pin - cheapest wins
```

Watch Karpenter react - instances appear in about a minute:

```bash
kubectl get nodeclaims -w
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

Captured from a live run of this exact configuration (EKS 1.36, eu-west-1):

```
NAME                                        STATUS   ROLES    AGE     VERSION               ARCH    CAPACITY-TYPE   INSTANCE-TYPE
ip-10-0-14-11.eu-west-1.compute.internal    Ready    <none>   4m23s   v1.36.2-eks-8f14419   arm64                   t4g.medium
ip-10-0-17-129.eu-west-1.compute.internal   Ready    <none>   4m22s   v1.36.2-eks-8f14419   arm64                   t4g.medium
ip-10-0-21-249.eu-west-1.compute.internal   Ready    <none>   36s     v1.36.2-eks-8f14419   arm64   spot            c6g.xlarge
ip-10-0-30-147.eu-west-1.compute.internal   Ready    <none>   114s    v1.36.2-eks-8f14419   amd64   spot            c8i-flex.2xlarge
```

The two `t4g.medium` are the static system nodes. The `c6g.xlarge` (Graviton)
and `c8i-flex.2xlarge` (x86) are spot instances Karpenter launched for the
example deployments - both from the same NodePool, each Ready within about a
minute of its NodeClaim. Deleting the deployments drains both spot nodes again
within ~2 minutes (consolidation), leaving only the system pair.

Notes for developers:

- Container images must be built for the architecture they run on. Build
  multi-arch images by default (`docker buildx build --platform
  linux/amd64,linux/arm64`) and the scheduling choice stays free.
- Spot is preferred automatically; when spot capacity is unavailable Karpenter
  falls back to on-demand on its own. Nothing to configure per workload.
- When pods disappear, Karpenter consolidates and removes now-empty nodes.
- The example manifests are scheduling demos. Production workloads add a
  restricted `securityContext` (non-root, read-only filesystem) and pin
  images by digest rather than a mutable tag.

## Tear down

```bash
kubectl delete -f examples/ --ignore-not-found   # let Karpenter scale to zero
terraform destroy
```

A plain `terraform destroy` is also safe with workloads still running: the
NodePool is removed first (explicit dependency ordering), which makes Karpenter
drain and terminate its nodes while the controller is still alive.

## Cost notes

The always-on POC footprint is the EKS control plane, one NAT gateway and two
`t4g.medium` system nodes. Workload nodes exist only while pods need them -
Karpenter consolidates aggressively (see the NodePool's disruption settings).
