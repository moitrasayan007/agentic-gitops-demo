output "ecr_repository_url" {
  description = "Set chart/values.yaml image.repository to this value."
  value       = aws_ecr_repository.parcel_tracker.repository_url
}

output "ecr_login_command" {
  description = "Authenticate Docker against the registry."
  value = format(
    "aws ecr get-login-password --region %s | docker login --username AWS --password-stdin %s.dkr.ecr.%s.amazonaws.com",
    var.region,
    data.aws_caller_identity.current.account_id,
    var.region,
  )
}

output "kubeconfig_command" {
  description = "Point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.cluster_name}"
}

# The NLB address is provisioned asynchronously after the Service is created, so
# it is usually empty on the apply that creates Argo CD. Run the command below a
# minute later to read it. The UI is plain HTTP -- no certificate.
output "argocd_url_command" {
  description = "Fetch the Argo CD URL once the NLB has an address (plain HTTP, no cert)."
  value       = "echo http://$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
}

output "argocd_admin_password_command" {
  description = "Read the initial Argo CD admin password."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "triage_agent_role_arn" {
  description = "IAM role for the triage agent, if created."
  value       = var.create_agent_role ? aws_iam_role.triage_agent[0].arn : null
}
