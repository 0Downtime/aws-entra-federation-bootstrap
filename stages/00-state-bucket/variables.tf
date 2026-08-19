variable "management_account_id" {
  description = "AWS account ID that owns the Terraform state bucket."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "profile" {
  description = "Optional AWS CLI profile for the management account."
  type        = string
  default     = ""
}

variable "region" {
  description = "Region where the Terraform state bucket will be created."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name between 3 and 63 characters."
  }
}
