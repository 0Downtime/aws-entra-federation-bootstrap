provider "aws" {
  region  = var.production_region
  profile = var.management_profile != "" ? var.management_profile : null

  allowed_account_ids = [var.production_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.production_account_id}:role/OrganizationAccountAccessRole"
    session_name = "terraform-production"
  }

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Stage     = "production"
    }
  }
}

data "aws_caller_identity" "production" {}

check "production_account" {
  assert {
    condition     = data.aws_caller_identity.production.account_id == var.production_account_id
    error_message = "The selected credentials cannot assume the configured production account role."
  }
}
