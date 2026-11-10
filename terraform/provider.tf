terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "terraform-base"
  assume_role {
    role_arn     = "arn:aws:iam::xxxxxx:role/tf-role"
    session_name = "TerraformDeploymentSession"
  }
}
