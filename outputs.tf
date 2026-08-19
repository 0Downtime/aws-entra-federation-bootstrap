output "organization_id" {
  description = "AWS Organizations ID"
  value       = aws_organizations_organization.organization.id
}

output "organization_arn" {
  description = "AWS Organizations ARN"
  value       = aws_organizations_organization.organization.arn
}

output "cloudtrail_name" {
  description = "CloudTrail trail name"
  value       = aws_cloudtrail.this.name
}

output "audit_bucket_name" {
  description = "S3 bucket used for audit logs"
  value       = aws_s3_bucket.log_archive.id
}

output "sso_permission_set_arn" {
  description = "IAM Identity Center permission set ARN"
  value       = aws_ssoadmin_permission_set.security_admin.arn
}
