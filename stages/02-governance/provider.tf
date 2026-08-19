provider "aws" {
  region  = var.management_region
  profile = var.management_profile != "" ? var.management_profile : null

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Stage     = "governance"
    }
  }
}

provider "aws" {
  alias   = "log_archive"
  region  = var.management_region
  profile = var.management_profile != "" ? var.management_profile : null

  allowed_account_ids = [var.log_archive_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
    session_name = "terraform-governance"
  }
}

provider "aws" {
  alias   = "identity_center"
  region  = var.identity_center_region
  profile = var.management_profile != "" ? var.management_profile : null

  allowed_account_ids = [var.management_account_id]
}

data "aws_caller_identity" "management" {}

check "management_account" {
  assert {
    condition     = data.aws_caller_identity.management.account_id == var.management_account_id
    error_message = "The selected AWS credentials are not for management_account_id."
  }
}
