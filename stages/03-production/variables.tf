variable "production_account_id" {
  description = "Production account ID created by stage 01."
  type        = string
}

variable "management_profile" {
  description = "Optional AWS CLI profile used as the source credentials for the cross-account role."
  type        = string
  default     = ""
}

variable "production_region" {
  description = "AWS region for production resources."
  type        = string
  default     = "us-east-1"
}

variable "secret_name" {
  description = "Name of the baseline Secrets Manager secret."
  type        = string
  default     = "production/application"
}

variable "production_trusted_principal_arns" {
  description = "Optional principals allowed to assume the production secrets role. Leave empty until a real workload or administration principal exists."
  type        = set(string)
  default     = []
}
