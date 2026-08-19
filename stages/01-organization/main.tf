resource "aws_organizations_organization" "this" {
  feature_set = var.organization_feature_set

  enabled_policy_types = var.organization_enabled_policy_types

  aws_service_access_principals = var.organization_service_access_principals
}

locals {
  legacy_accounts = {
    log_archive = {
      name   = "log-archive"
      email  = var.log_archive_account_email
      ou_key = "security"
      tags   = {}
    }
    production = {
      name   = "production"
      email  = var.production_account_email
      ou_key = "workloads"
      tags   = {}
    }
  }

  accounts = length(var.member_accounts) > 0 ? var.member_accounts : local.legacy_accounts
}

resource "aws_organizations_organizational_unit" "this" {
  for_each  = var.organizational_units
  name      = each.value
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_account" "this" {
  for_each = var.create_member_accounts ? local.accounts : {}

  name                       = each.value.name
  email                      = each.value.email
  role_name                  = "OrganizationAccountAccessRole"
  parent_id                  = aws_organizations_organizational_unit.this[each.value.ou_key].id
  close_on_deletion          = false
  iam_user_access_to_billing = "DENY"

  tags = merge({
    AccountType  = each.key
    ManagedBy    = "Terraform"
    Organization = var.organization_name
  }, each.value.tags)

  depends_on = [aws_organizations_organization.this]
}
