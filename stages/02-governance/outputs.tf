output "cloudtrail_name" {
  description = "Organization CloudTrail trail name."
  value       = aws_cloudtrail.organization.name
}

output "log_archive_bucket_name" {
  description = "Protected CloudTrail destination bucket."
  value       = aws_s3_bucket.log_archive.id
}

output "security_permission_set_arn" {
  description = "Security permission set ARN."
  value       = aws_ssoadmin_permission_set.security.arn
}

output "billing_permission_set_arn" {
  description = "Billing permission set ARN, when billing_group_id is configured."
  value       = try(aws_ssoadmin_permission_set.billing[0].arn, null)
}
