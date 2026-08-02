output "state_bucket" {
  description = "S3 bucket holding Terraform state. Feed this to the ephemeral stack's backend config."
  value       = aws_s3_bucket.state.id
}

output "region" {
  description = "Region these resources live in."
  value       = var.region
}

output "ecr_repository_urls" {
  description = "Repository URIs, keyed by component. Used by CI and by the Helm values."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "ecr_registry" {
  description = "Registry hostname to authenticate docker against."
  value       = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "backend_config" {
  description = "Ready-made -backend-config values for the ephemeral stack."
  value = {
    bucket       = aws_s3_bucket.state.id
    key          = "ephemeral/terraform.tfstate"
    region       = var.region
    encrypt      = true
    use_lockfile = true
  }
}
