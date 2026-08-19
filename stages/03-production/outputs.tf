output "secret_arn" {
  description = "Baseline production secret ARN."
  value       = aws_secretsmanager_secret.production.arn
}

output "production_secrets_role_arn" {
  description = "Optional least-privilege production secret role ARN."
  value       = try(aws_iam_role.production_secrets[0].arn, null)
}
