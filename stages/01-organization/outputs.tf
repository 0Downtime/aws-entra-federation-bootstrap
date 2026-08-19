output "organization_id" {
  description = "AWS Organizations ID."
  value       = aws_organizations_organization.this.id
}

output "organization_arn" {
  description = "AWS Organizations ARN."
  value       = aws_organizations_organization.this.arn
}

output "account_ids" {
  description = "Member account IDs keyed by account role."
  value       = { for key, account in aws_organizations_account.this : key => account.id }
}

output "organizational_unit_ids" {
  description = "Organizational unit IDs keyed by logical name."
  value       = { for key, ou in aws_organizations_organizational_unit.this : key => ou.id }
}
