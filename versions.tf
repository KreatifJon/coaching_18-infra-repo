terraform {
  # use_lockfile (S3 native state locking) requires Terraform 1.10+
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state so CI/CD runners share state.
  backend "s3" {
    bucket       = "sctp-tfstate-ce13"
    key          = "plainjon/ecs-demo/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
