# One `terraform apply` stands up everything the demo needs on AWS:
#
#   1. A single EKS Auto Mode cluster (nodes, networking, load balancing, and
#      storage are managed by EKS itself -- no node groups to run).
#   2. The ECR repository the chart pulls from.
#   3. Argo CD, installed with Helm and exposed on an internet-facing NLB.
#   4. Kyverno, installed with Helm, so the policy gate can enforce at admission.
#
# What it deliberately leaves to `make`: applying the Argo CD Application and the
# Kyverno policies, because both reference your Git repository URL and belong in
# a step you run after editing argocd/*.yaml.
#
# The EKS module is copied from a tested standalone cluster repo; it provisions
# one VPC + one Auto Mode cluster with a public+private API endpoint.

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  cluster_name = "${var.name_prefix}-demo"
}

# -----------------------------------------------------------------------------
# EKS Auto Mode cluster
# -----------------------------------------------------------------------------
module "cluster" {
  source = "./modules/eks-cluster"

  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  azs                = local.azs
  vpc_cidr           = var.vpc_cidr
  private_subnets    = var.private_subnets
  public_subnets     = var.public_subnets
  single_nat_gateway = true

  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Kubernetes + Helm providers, authenticated against the cluster above.
#
# aws_eks_cluster_auth mints a short-lived token each apply, so no kubeconfig
# file is involved. The depends_on ties provider use to a fully-created cluster.
# -----------------------------------------------------------------------------
data "aws_eks_cluster_auth" "this" {
  name = module.cluster.cluster_name
}

provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# -----------------------------------------------------------------------------
# ECR repository for the parcel-tracker image
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "parcel_tracker" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "parcel_tracker" {
  repository = aws_ecr_repository.parcel_tracker.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 20 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# Argo CD (Helm), exposed on an internet-facing NLB.
#
# No TLS certificate is involved. argocd-server runs in insecure mode and serves
# plain HTTP; the NLB forwards 80/443 to it. You reach the UI over HTTP at the
# load balancer's DNS name. That is fine for a throwaway demo cluster and wrong
# for anything else -- see the note in outputs.tf.
# -----------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true
  timeout          = 900

  # Serve plain HTTP -- no cert to terminate.
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  # Expose argocd-server through an internet-facing NLB. EKS Auto Mode's managed
  # load balancing reconciles this Service into an NLB with no extra controller.
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "external"
  }
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
    value = "ip"
  }

  depends_on = [module.cluster]
}

# -----------------------------------------------------------------------------
# Kyverno (Helm) -- the admission half of the policy gate. Policies themselves
# are applied by `make install-kyverno` / `kubectl apply -f policy/`.
# -----------------------------------------------------------------------------
resource "helm_release" "kyverno" {
  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.kyverno_chart_version
  wait             = true
  timeout          = 600

  depends_on = [module.cluster]
}

# -----------------------------------------------------------------------------
# Read-only IAM role for the triage agent (optional). Attach via EKS Pod
# Identity against the triage-agent ServiceAccount if the agent should also read
# CloudWatch. Nothing here can change infrastructure.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "triage_agent" {
  count = var.create_agent_role ? 1 : 0
  name  = "${local.cluster_name}-triage-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "triage_agent_read" {
  count = var.create_agent_role ? 1 : 0
  name  = "read-observability"
  role  = aws_iam_role.triage_agent[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:GetLogEvents",
        "logs:FilterLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics",
      ]
      Resource = "*"
    }]
  })
}
