variable "region" {
  description = "AWS region for the all resources"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile to use for the management account"
  type        = string
  default     = ""
}

variable "org_name" {
  description = "Name of the AWS Organization"
  type        = string
  default     = "TEST-org"
}

variable "audit_bucket_name" {
  description = "Globally unique S3 bucket name for CloudTrail and AWS Config logs"
  type        = string
  default     = "test-aws-management-audit-logs"
}

variable "log_archive_bucket_name" {
  description = "Globally unique S3 bucket name for the log archive account"
  type        = string
  default     = "test-log-archive-logs"
}

variable "cloudtrail_name" {
  description = "Name of the CloudTrail trail"
  type        = string
  default     = "test-management-cloudtrail"
}
