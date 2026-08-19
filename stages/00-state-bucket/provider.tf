provider "aws" {
  region  = var.region
  profile = var.profile != "" ? var.profile : null

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Purpose   = "TerraformState"
      Stage     = "state-bootstrap"
    }
  }
}

data "aws_caller_identity" "management" {}

check "management_account" {
  assert {
    condition     = data.aws_caller_identity.management.account_id == var.management_account_id
    error_message = "The selected AWS credentials are not for management_account_id."
  }
}
