variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name, also used for the VPC and Karpenter discovery tags"
  type        = string
  default     = "opsfleet-poc"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane (latest available at the time of writing)"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block of the dedicated VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version (>= 1.13 is required for Kubernetes 1.36)"
  type        = string
  default     = "1.14.0"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "opsfleet-assignment"
    ManagedBy = "terraform"
  }
}
