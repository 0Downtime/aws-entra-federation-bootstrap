provider "aws" {
  region  = var.region
  profile = var.profile != "" ? var.profile : null

  default_tags {
    tags = {
      Terraform   = "true"
      Environment = "management"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_organizations_organization" "organization" {
  feature_set          = "ALL"
  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "sso.amazonaws.com",
  ]
}

data "aws_iam_policy_document" "audit_logs_bucket_policy" {
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
      values   = ["arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.cloudtrail_name}"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log_archive.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.cloudtrail_name}"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit_logs" {
  bucket = aws_s3_bucket.log_archive.id
  policy = data.aws_iam_policy_document.audit_logs_bucket_policy.json
}

resource "aws_cloudtrail" "this" {
  name                          = var.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.log_archive.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.audit_logs, aws_s3_bucket.log_archive]
}

data "aws_ssoadmin_instances" "this" {}

resource "aws_ssoadmin_permission_set" "security_admin" {
  instance_arn     = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  name             = "SecurityAdministrator"
  description      = "Security administration access for the management account"
  session_duration = "PT4H"
}
