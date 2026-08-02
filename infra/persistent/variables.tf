variable "project" {
  description = "Name prefix for every resource in this stack."
  type        = string
  default     = "web-store"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the CI role, as owner/name."
  type        = string
  default     = "danohlin/web-store"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/name form."
  }
}

variable "github_allowed_subjects" {
  description = <<-EOT
    OIDC subjects permitted to assume the CI role.

    Defaults to the main branch of github_repository only, because that is the
    only ref that deploys. Pull request builds run tests and need no AWS access.

    Never widen this to a bare "repo:*" — the subject condition is the only
    thing stopping a workflow in someone else's repository from assuming this
    role.
  EOT
  type        = list(string)
  default     = null
}

variable "image_retention_count" {
  description = "How many tagged images to keep per repository before the oldest are expired."
  type        = number
  default     = 10
}
