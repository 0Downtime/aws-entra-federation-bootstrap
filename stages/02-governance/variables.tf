variable "management_account_id" {
  description = "AWS Organizations management account ID."
  type        = string
}

variable "log_archive_account_id" {
  description = "Account ID created by stage 01."
  type        = string
}

variable "organization_id" {
  description = "AWS Organizations ID created by stage 01."
  type        = string
}

variable "management_profile" {
  description = "Optional AWS CLI profile for the management account."
  type        = string
  default     = ""
}

variable "management_region" {
  description = "Region used for management-account resources and CloudTrail."
  type        = string
  default     = "us-east-1"
}

variable "identity_center_region" {
  description = "Region where the IAM Identity Center organization instance is enabled."
  type        = string
  default     = "us-east-1"
}

variable "log_archive_bucket_name" {
  description = "Globally unique name for the protected CloudTrail destination bucket."
  type        = string
}

variable "cloudtrail_name" {
  description = "Name of the organization CloudTrail trail."
  type        = string
  default     = "organization-cloudtrail"
}

variable "sso_security_permission_set_name" {
  description = "Name of the security permission set."
  type        = string
  default     = "SecurityAudit"
}

variable "sso_security_managed_policy_arns" {
  description = "AWS managed policy ARNs attached to the security permission set."
  type        = set(string)
  default     = ["arn:aws:iam::aws:policy/SecurityAudit"]
}

variable "sso_group_id" {
  description = "Optional IAM Identity Center group ID to receive the security permission set."
  type        = string
  default     = null
  nullable    = true
}

variable "sso_target_account_ids" {
  description = "Accounts receiving the security permission set when sso_group_id is set."
  type        = set(string)
  default     = []
}

variable "billing_group_id" {
  description = "Optional IAM Identity Center group ID to receive billing read access."
  type        = string
  default     = null
  nullable    = true
}

variable "billing_target_account_ids" {
  description = "Accounts receiving billing read access when billing_group_id is set."
  type        = set(string)
  default     = []
}

variable "sso_group_assignments" {
  description = "Generated or manually supplied IAM Identity Center group assignments. Permission sets are the permission sets managed by this stage."
  type = map(object({
    group_id           = string
    permission_set     = string
    target_account_ids = set(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for assignment in values(var.sso_group_assignments) : contains(["SecurityAudit", "BillingReadOnly"], assignment.permission_set)
    ])
    error_message = "sso_group_assignments.permission_set must be SecurityAudit or BillingReadOnly."
  }
}
