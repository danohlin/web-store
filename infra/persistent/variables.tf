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

variable "image_retention_count" {
  description = "How many tagged images to keep per repository before the oldest are expired."
  type        = number
  default     = 10
}
