variable "region" {
  description = "AWS region for the cluster and the ECR repository."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the cluster name (<prefix>-demo)."
  type        = string
  default     = "agentic-gitops"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.35"
}

variable "repository_name" {
  description = "ECR repository name for the parcel-tracker image."
  type        = string
  default     = "parcel-tracker"
}

# ⚠️ Restrict this to your own public IP in CIDR form, e.g. ["203.0.113.10/32"].
# Left open so a first apply works, but a demo cluster with a world-reachable
# API endpoint is exactly the kind of thing this talk is about.
variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vpc_cidr" {
  description = "CIDR block for the cluster VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks (one per AZ)."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version."
  type        = string
  default     = "7.7.11"
}

variable "kyverno_chart_version" {
  description = "kyverno Helm chart version."
  type        = string
  default     = "3.3.4"
}

variable "create_agent_role" {
  description = "Create a read-only IAM role for the triage agent (CloudWatch access)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project   = "agentic-gitops-demo"
    Terraform = "true"
  }
}
