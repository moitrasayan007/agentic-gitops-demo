variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block for this cluster's VPC"
  type        = string
}

variable "secondary_cidr_blocks" {
  description = "Secondary CIDR blocks for the VPC (extra pod IP space, e.g. for custom networking)"
  type        = list(string)
  default     = []
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks (one per AZ)"
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks (one per AZ)"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway instead of one per AZ (cheaper, less HA - fine for a test cluster)"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to access the public EKS API endpoint (DO NOT leave open in prod)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
