terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Local state on purpose. This stack creates the very bucket the ephemeral
  # stack stores its state in, so it cannot store its state there on the first
  # apply. It is applied once and then left alone.
  #
  # If you would rather keep it remote, apply once, then uncomment the block
  # below and run: terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket       = "web-store-tfstate-<account-id>"
  #   key          = "persistent/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "persistent"
      Lifecycle = "permanent"
    }
  }
}
