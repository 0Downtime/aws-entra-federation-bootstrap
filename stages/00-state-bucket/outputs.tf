output "bucket_name" {
  description = "Terraform state bucket name."
  value       = aws_s3_bucket.terraform_state.id
}

output "bucket_region" {
  description = "Terraform state bucket region."
  value       = var.region
}
