resource "aws_organizations_account" "log_archive" {
  name      = "log-archive"
  email     = "log-archive@example.com"
  role_name = "OrganizationAccountAccessRole"
  parent_id = aws_organizations_organizational_unit.Security.id
}

provider "aws" {
  alias  = "log_archive"
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${aws_organizations_account.log_archive.id}:role/OrganizationAccountAccessRole"
    session_name = "Terraform"
  }
}

output "log_archive_account_id" {
  description = "Log Archive Account ID"
  value       = aws_organizations_account.log_archive.id
}


# resource "aws_organizations_account" "security" {
#   name      = "security"
#   email     = "security@example.com"
#   role_name = "OrganizationAccountAccessRole"
#   parent_id = aws_organizations_organizational_unit.security.id
# }

# provider "aws" {
#   alias  = "security"
#   region = var.region

#   assume_role {
#     role_arn     = "arn:aws:iam::${aws_organizations_account.security.id}:role/OrganizationAccountAccessRole"
#     session_name = "Terraform"
#   }
# }

# output "security_account_id" {
#   description = "Security Account ID"
#   value       = aws_organizations_account.security.id
# }

# resource "aws_organizations_account" "shared_services" {
#   name      = "shared-services"
#   email     = "shared-services@example.com"
#   role_name = "OrganizationAccountAccessRole"
#   parent_id = aws_organizations_organizational_unit.infrastructure.id
# }

# provider "aws" {
#   alias  = "shared_services"
#   region = var.region

#   assume_role {
#     role_arn     = "arn:aws:iam::${aws_organizations_account.shared_services.id}:role/OrganizationAccountAccessRole"
#     session_name = "Terraform"
#   }
# }

# output "shared_services_account_id" {
#   description = "Shared Services Account ID"
#   value       = aws_organizations_account.shared_services.id
# }

# resource "aws_organizations_account" "non_prod" {
#   name      = "non-prod"
#   email     = "non-prod@example.com"
#   role_name = "OrganizationAccountAccessRole"
#   parent_id = aws_organizations_organizational_unit.workloads.id
# }

# provider "aws" {
#   alias  = "non_prod"
#   region = var.region

#   assume_role {
#     role_arn     = "arn:aws:iam::${aws_organizations_account.non_prod.id}:role/OrganizationAccountAccessRole"
#     session_name = "Terraform"
#   }
# }
# output "non_prod_account_id" {
#   description = "Non-Production Account ID"
#   value       = aws_organizations_account.non_prod.id
# }

resource "aws_organizations_account" "production" {
  name      = "production"
  email     = "production@example.com"
  role_name = "OrganizationAccountAccessRole"
  parent_id = aws_organizations_organizational_unit.Workloads.id
}

provider "aws" {
  alias  = "production"
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${aws_organizations_account.production.id}:role/OrganizationAccountAccessRole"
    session_name = "Terraform"
  }
}

output "production_account_id" {
  description = "Production Account ID"
  value       = aws_organizations_account.production.id
}
