############################################################
# modules/eks-cluster
# Provisions one VPC + one EKS cluster in Auto Mode (public+
# private API endpoint, auto-managed nodes/networking/storage,
# VPC endpoints). Instantiated twice from the root module
# (hub + spoke).
############################################################

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------
# VPC
# -----------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name                  = "${var.cluster_name}-vpc"
  cidr                  = var.vpc_cidr
  secondary_cidr_blocks = var.secondary_cidr_blocks

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

# -----------------------------
# EKS Cluster
# -----------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # DO NOT leave this as 0.0.0.0/0 in anything long-lived.
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Create-time-only flag, inert after the cluster exists - pin it to the
  # value already recorded in state so enabling Auto Mode below is an
  # in-place update instead of forcing full cluster replacement.
  bootstrap_self_managed_addons = true

  # Root user has no EKS access by default (AWS console "Unauthorized" when
  # browsing cluster resources as root) - grant it cluster-admin explicitly.
  access_entries = {
    root = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  enable_irsa = false

  # Auto Mode provisions and scales nodes itself (via the built-in
  # "system" and "general-purpose" node pools) and natively manages
  # networking (VPC CNI, kube-proxy equivalents), load balancing,
  # cluster DNS, EBS-backed storage, and the Pod Identity Agent as
  # core components rather than add-ons - so with no self-managed
  # node groups in the mix, none of eks_managed_node_groups,
  # coredns/vpc-cni/kube-proxy/eks-pod-identity-agent addons, or a
  # hand-rolled EBS CSI role are needed.
  cluster_compute_config = {
    enabled    = true
    node_pools = ["system", "general-purpose"]
  }

  tags = var.tags
}

# -----------------------------
# Interface VPC Endpoint SG
# -----------------------------
resource "aws_security_group" "vpce" {
  name        = "${var.cluster_name}-vpce-sg"
  description = "Allow EKS nodes to reach Interface VPC Endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTPS from EKS nodes"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [module.eks.cluster_primary_security_group_id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# -----------------------------
# VPC Endpoints
# -----------------------------
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    ec2 = {
      service             = "ec2"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      security_group_ids  = [aws_security_group.vpce.id]
    }

    sts = {
      service             = "sts"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      security_group_ids  = [aws_security_group.vpce.id]
    }

    kms = {
      service             = "kms"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      security_group_ids  = [aws_security_group.vpce.id]
    }

    ecr_api = {
      service             = "ecr.api"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      security_group_ids  = [aws_security_group.vpce.id]
    }

    ecr_dkr = {
      service             = "ecr.dkr"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      security_group_ids  = [aws_security_group.vpce.id]
    }

    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }

  tags = var.tags
}
