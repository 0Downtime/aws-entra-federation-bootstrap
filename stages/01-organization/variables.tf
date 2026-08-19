variable "management_account_id" {
  description = "The AWS account ID that will manage the organization."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "management_profile" {
  description = "Optional AWS CLI profile for the management account."
  type        = string
  default     = ""
}

variable "management_region" {
  description = "AWS provider region for the management account."
  type        = string
  default     = "us-east-1"
}

variable "organization_name" {
  description = "Human-readable name used in account tags."
  type        = string
  default     = "production-organization"
}

variable "organization_feature_set" {
  description = "AWS Organizations feature set. ALL is required for IAM Identity Center account assignments and SCP governance."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "CONSOLIDATED_BILLING"], var.organization_feature_set)
    error_message = "organization_feature_set must be ALL or CONSOLIDATED_BILLING."
  }
}

variable "organization_enabled_policy_types" {
  description = "AWS Organizations policy types to enable."
  type        = set(string)
  default     = ["SERVICE_CONTROL_POLICY"]

  validation {
    condition     = alltrue([for policy_type in var.organization_enabled_policy_types : contains(["SERVICE_CONTROL_POLICY", "TAG_POLICY", "BACKUP_POLICY", "AISERVICES_OPT_OUT_POLICY", "DECLARATIVE_POLICY_EC2"], policy_type)])
    error_message = "organization_enabled_policy_types contains an unsupported AWS Organizations policy type."
  }
}

variable "organization_service_access_principals" {
  description = "AWS service principals enabled for trusted access in the organization."
  type        = set(string)
  default     = ["cloudtrail.amazonaws.com", "sso.amazonaws.com"]
}

variable "organizational_units" {
  description = "Logical OU keys mapped to the AWS OU names to manage. Existing OUs can be adopted with the generated import plan."
  type        = map(string)
  default = {
    security       = "Security"
    infrastructure = "Infrastructure"
    workloads      = "Workloads"
  }

  validation {
    condition     = length(var.organizational_units) > 0 && alltrue([for name in values(var.organizational_units) : can(regex("^.{1,128}$", name))])
    error_message = "organizational_units must contain at least one OU name of 1-128 characters."
  }
}

variable "member_accounts" {
  description = "Member accounts to manage, keyed by a stable logical name. Existing accounts can be adopted with the generated import plan."
  type = map(object({
    name   = string
    email  = string
    ou_key = string
    tags   = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = length(var.member_accounts) == 0 || alltrue([for account in values(var.member_accounts) : contains(keys(var.organizational_units), account.ou_key)])
    error_message = "Each member_accounts entry must reference a key in organizational_units."
  }

  validation {
    condition = !var.create_member_accounts || length(var.member_accounts) == 0 || alltrue([
      for account in values(var.member_accounts) : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", account.email))
    ])
    error_message = "Each member account must have a valid unique root email address when create_member_accounts is true."
  }
}

variable "create_member_accounts" {
  description = "Whether Stage 01 should create the log archive and production member accounts. Set false while importing an existing organization or staging the OUs."
  type        = bool
  default     = true
}

variable "log_archive_account_email" {
  description = "Unique, valid root email address for the log archive account."
  type        = string
  default     = ""

  validation {
    condition     = !var.create_member_accounts || length(var.member_accounts) > 0 || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.log_archive_account_email))
    error_message = "Provide a valid email address for the log archive account when create_member_accounts is true."
  }
}

variable "production_account_email" {
  description = "Unique, valid root email address for the production account."
  type        = string
  default     = ""

  validation {
    condition     = !var.create_member_accounts || length(var.member_accounts) > 0 || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.production_account_email))
    error_message = "Provide a valid email address for the production account when create_member_accounts is true."
  }
}
