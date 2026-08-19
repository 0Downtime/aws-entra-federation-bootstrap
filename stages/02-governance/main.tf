data "aws_ssoadmin_instances" "this" {
  provider = aws.identity_center
}

locals {
  identity_center_instance_arn = try(tolist(data.aws_ssoadmin_instances.this.arns)[0], null)
  billing_permission_set_enabled = var.billing_group_id != null || anytrue([
    for assignment in values(var.sso_group_assignments) : assignment.permission_set == "BillingReadOnly"
  ])
  administrator_permission_set_enabled = anytrue([
    for assignment in values(var.sso_group_assignments) : assignment.permission_set == "AdministratorAccess"
  ])
  configured_sso_assignments = flatten([
    for assignment_name, assignment in var.sso_group_assignments : [
      for account_id in assignment.target_account_ids : {
        assignment_name = assignment_name
        group_id        = assignment.group_id
        permission_set  = assignment.permission_set
        account_id      = account_id
      }
    ]
  ])
  configured_sso_assignment_map = {
    for assignment in local.configured_sso_assignments :
    "${assignment.assignment_name}:${assignment.account_id}" => assignment
  }
  permission_set_arns = {
    SecurityAudit       = aws_ssoadmin_permission_set.security.arn
    BillingReadOnly     = try(aws_ssoadmin_permission_set.billing[0].arn, null)
    AdministratorAccess = try(aws_ssoadmin_permission_set.administrator[0].arn, null)
  }
}

check "identity_center_enabled" {
  assert {
    condition     = local.identity_center_instance_arn != null
    error_message = "Enable an IAM Identity Center organization instance in identity_center_region before applying stage 02."
  }
}

resource "aws_s3_bucket" "log_archive" {
  provider      = aws.log_archive
  bucket        = var.log_archive_bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "log_archive" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.log_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "log_archive" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.log_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "log_archive" {
  provider                = aws.log_archive
  bucket                  = aws_s3_bucket.log_archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "log_archive" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.log_archive.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

data "aws_iam_policy_document" "log_archive" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.log_archive.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.management_region}:${var.management_account_id}:trail/${var.cloudtrail_name}"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWriteOrganization"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log_archive.arn}/AWSLogs/${var.organization_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.management_region}:${var.management_account_id}:trail/${var.cloudtrail_name}"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.log_archive.arn, "${aws_s3_bucket.log_archive.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "log_archive" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.log_archive.id
  policy   = data.aws_iam_policy_document.log_archive.json

  depends_on = [
    aws_s3_bucket_public_access_block.log_archive,
    aws_s3_bucket_ownership_controls.log_archive,
  ]
}

resource "aws_cloudtrail" "organization" {
  name                          = var.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.log_archive.id
  include_global_service_events = true
  is_multi_region_trail         = true
  is_organization_trail         = true
  enable_logging                = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.log_archive]
}

resource "aws_ssoadmin_permission_set" "security" {
  provider         = aws.identity_center
  instance_arn     = local.identity_center_instance_arn
  name             = var.sso_security_permission_set_name
  description      = "Read-only security visibility across the organization."
  session_duration = "PT4H"

  lifecycle {
    precondition {
      condition     = local.identity_center_instance_arn != null
      error_message = "IAM Identity Center must be enabled before creating permission sets."
    }
  }
}

resource "aws_ssoadmin_managed_policy_attachment" "security" {
  for_each           = var.sso_security_managed_policy_arns
  provider           = aws.identity_center
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.security.arn
  managed_policy_arn = each.value
}

resource "aws_ssoadmin_account_assignment" "security" {
  for_each = var.sso_group_id == null ? toset([]) : var.sso_target_account_ids

  provider           = aws.identity_center
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.security.arn
  principal_id       = var.sso_group_id
  principal_type     = "GROUP"
  target_id          = each.value
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_permission_set" "billing" {
  count = local.billing_permission_set_enabled ? 1 : 0

  provider         = aws.identity_center
  instance_arn     = local.identity_center_instance_arn
  name             = "BillingReadOnly"
  description      = "Read-only billing and cost visibility in the management account."
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "billing" {
  count = local.billing_permission_set_enabled ? 1 : 0

  provider           = aws.identity_center
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.billing[0].arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aws-portal:ViewBilling",
        "aws-portal:ViewUsage",
        "aws-portal:ViewPaymentMethods",
        "aws-portal:ViewAccount",
        "budgets:ViewBudget",
        "budgets:DescribeBudgets",
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetDimensionValues",
        "ce:GetTags",
        "ce:GetCostCategories"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_ssoadmin_account_assignment" "billing" {
  for_each = var.billing_group_id == null ? toset([]) : var.billing_target_account_ids

  provider           = aws.identity_center
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.billing[0].arn
  principal_id       = var.billing_group_id
  principal_type     = "GROUP"
  target_id          = each.value
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_permission_set" "administrator" {
  count = local.administrator_permission_set_enabled ? 1 : 0

  provider         = aws.identity_center
  instance_arn     = local.identity_center_instance_arn
  name             = "AdministratorAccess"
  description      = "Full AWS administrator access managed through the Entra AWS-Administrators group."
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "administrator" {
  count = local.administrator_permission_set_enabled ? 1 : 0

  provider           = aws.identity_center
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_account_assignment" "configured" {
  for_each = length(var.sso_group_assignments) == 0 ? {} : local.configured_sso_assignment_map

  provider           = aws.identity_center
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = local.permission_set_arns[each.value.permission_set]
  principal_id       = each.value.group_id
  principal_type     = "GROUP"
  target_id          = each.value.account_id
  target_type        = "AWS_ACCOUNT"
}
