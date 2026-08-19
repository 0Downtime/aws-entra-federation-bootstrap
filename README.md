# AWS Organization baseline

This repository is a staged deployment for the architecture in the reference diagram:

- management account with AWS Organizations and trusted service access
- Security, Infrastructure, and Workloads organizational units
- log-archive account under Security
- production account under Workloads
- organization-wide CloudTrail delivered to the log-archive account
- IAM Identity Center permission sets with group assignments, including optional full administrator access
- a Windows PowerShell Entra ID federation orchestrator for IAM Identity Center
- an empty, protected Secrets Manager secret in the production account

The stages are intentional. Account creation and cross-account role assumption are separate operations in AWS, so child-account resources are not placed in the same Terraform state as account creation.

## Before deployment

1. Decide whether the management account already owns an AWS Organization. For an existing organization, import and review the organization resource rather than creating a second organization.
2. Prepare two unique, valid root-email addresses for the member accounts.
3. Enable an organization instance of IAM Identity Center in the region you will use for SSO. Create the Entra groups you need, such as `AWS-SecurityAudit`, `AWS-BillingReadOnly`, and (only when explicitly approved) `AWS-Administrators`. Set `entra.groupNamePrefix` once and use `entraGroupSuffix` in mappings; the federation configuration derives the full group names and resolves their IAM Identity Center group IDs after SCIM provisioning.

## Deployment

Run each stage from its own directory and state. Stage 00 uses local state because it creates the remote backend used by the later stages. Use the same management-account profile for all stages; the cross-account providers use that profile as their source credentials.

First create the Terraform state bucket:

```powershell
cd stages/00-state-bucket
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

Choose any globally unique lowercase S3 bucket name in `terraform.tfvars`.

```bash
cd stages/01-organization
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with real unique account emails.
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
terraform output
```

If the organization was created outside Terraform, import it before planning. To stage the organization and OUs without creating member accounts yet, set `create_member_accounts = false` and leave the account-email variables empty. After the OUs are managed, set it back to `true`, provide the two unique root-email addresses, and run a new plan before creating the accounts:

```powershell
terraform import `
  -var management_account_id=000000000000 `
  -var management_profile=management `
  -var management_region=us-east-1 `
  -var create_member_accounts=false `
  aws_organizations_organization.this o-example1234
```

Create `backend.hcl` in each stage by copying its `backend.hcl.example` and setting the state bucket name created by stage 00. The state bucket is encrypted, versioned, private, and protected against Terraform destruction.

Wait for both member accounts to finish provisioning and verify that `OrganizationAccountAccessRole` can be assumed. Then configure the account IDs in the next stage:

```bash
cd ../02-governance
cp terraform.tfvars.example terraform.tfvars
# Set organization_id, management_account_id, and log_archive_account_id.
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Finally deploy the production-account baseline:

```bash
cd ../03-production
cp terraform.tfvars.example terraform.tfvars
# Set production_account_id.
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Do not commit `terraform.tfvars` or backend credentials. Review every plan, especially changes to the organization, account parents, CloudTrail bucket policy, IAM Identity Center assignments, and the protected log bucket.

## Adopting an existing enterprise foundation

The organization stage is configuration-driven. Set `organizational_units` and `member_accounts` to your enterprise naming and account map; the original Security/Infrastructure/Workloads and log-archive/production defaults remain available. Existing AWS resources must be imported into the matching Terraform state before Terraform can converge them.

Before creating member accounts, run the account-quota preflight. Put any existing Service Quotas request ID in `organization.accountQuotaRequestId`; the preflight will report `Pending` and prevent an account-creation apply until AWS updates the quota:

```powershell
pwsh .\scripts\Ensure-AwsOrganizationsAccountQuota.ps1 `
  -ManagementProfile management `
  -Region us-east-1 `
  -RequiredAccountCount 3 `
  -RequestId <service-quotas-request-id> `
  -Mode Plan `
  -RequireReady
```

To submit a new request, use `-Mode Request -Approve`. This is intentionally separate from Terraform apply so quota increases are explicit and are not duplicated.

For the normal organization bootstrap, use the gated wrapper so Terraform cannot start account creation while the quota request is pending:

```powershell
pwsh .\scripts\Invoke-AwsOrganizationBootstrap.ps1 `
  -ManagementProfile management `
  -Region us-east-1 `
  -RequiredAccountCount 3 `
  -RequestId <service-quotas-request-id> `
  -Mode Plan

pwsh .\scripts\Invoke-AwsOrganizationBootstrap.ps1 `
  -ManagementProfile management `
  -Region us-east-1 `
  -RequiredAccountCount 3 `
  -RequestId <service-quotas-request-id> `
  -Mode Apply
```

Generate a read-only adoption plan from the Windows host:

```powershell
pwsh .\scripts\Adopt-AwsTerraformResources.ps1 `
  -ConfigPath .\scripts\aws-terraform-adoption.local.json `
  -Mode Plan
```

The plan discovers the existing organization, direct-child OUs, accounts, log archive bucket, CloudTrail trail, and explicitly supplied permission-set ARNs. It writes only redacted resource identifiers and proposed import addresses. After reviewing it, run with `-Mode Apply -Approve` to import existing resources into Terraform state; this does not modify AWS resources. Run `terraform plan` afterward and review the convergence changes before applying them. Resources that are absent are reported as `missing-create` and remain subject to normal Terraform plan review.

## Entra ID federation on Windows

For the complete repeatable production procedure, see [docs/entra-aws-federation-production-runbook.md](docs/entra-aws-federation-production-runbook.md). The canonical entry point is `scripts/Invoke-AwsEntraFederationBootstrap.ps1`; it runs the quota gate, optional organization bootstrap, federation automation, managed AWS CLI profile generation, and optional governance handoff in the correct order.

The repository includes `scripts/Configure-AwsEntraFederation.ps1` and an example configuration at `scripts/entra-aws-federation.example.json`. The script uses the existing AWS management profile for AWS discovery and a certificate-backed Microsoft Graph application for Entra automation.

Bootstrap or validate the Windows prerequisites. `Validate` is read-only; `Install` uses winget for AWS CLI v2, Terraform, PowerShell 7, and Git, then installs the required PowerShell modules for the current user. Run `Install` from an elevated prompt with `-WingetScope Machine` if machine-wide installation is preferred:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-AwsEntraFederationPrerequisites.ps1 -Mode Validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-AwsEntraFederationPrerequisites.ps1 -Mode Install -WingetScope User
pwsh -NoProfile -File .\scripts\Install-AwsEntraFederationPrerequisites.ps1 -Mode Validate
```

The prerequisite script does not create AWS credentials, Entra app registrations, certificates, SCIM tokens, or IAM Identity Center assignments. Those are intentionally validated or performed by the onboarding workflow.

Generate the ignored production configuration instead of hand-editing every field. The initializer discovers management-capable AWS profiles, the organization account, the IAM Identity Center region, the Entra tenant from Azure CLI, a uniquely named Graph app, and a matching private-key certificate. It prompts only when discovery is ambiguous or an API cannot expose the value, such as the access portal start URL:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Initialize-AwsEntraFederationConfig.ps1 `
  -Mode Plan `
  -ManagementProfile management-prod `
  -GroupNamePrefix PROD-AWS

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Initialize-AwsEntraFederationConfig.ps1 `
  -Mode Initialize `
  -ManagementProfile management-prod `
  -ManagementAccountId 000000000000 `
  -GroupNamePrefix PROD-AWS `
  -EnsureCertificate
```

`-EnsureCertificate` creates a 3-year self-signed certificate in `Cert:\CurrentUser\My` and appends only its public certificate to the Entra app. Use `-CertificateYears 2` or `-CertificateYears 3` to choose the lifetime. Existing valid certificates are reused, and existing app credentials are preserved. Use `-IncludeAdministratorAccess` only when full administrator access is explicitly approved. The initializer writes `scripts\entra-aws-federation.local.json`, which is ignored by Git; it never writes SCIM tokens or private keys.

Copy the example configuration outside the repository or to a local ignored file, then set the tenant, Graph application, certificate thumbprint, AWS access portal URL, metadata paths, and group mappings. The certificate private key must already be present in the Windows certificate store and must not be committed.

The first AWS setup still requires the IAM Identity Center organization instance, the external-identity-provider wizard, and the one-time SCIM endpoint/token retrieval. Supply the SCIM token through the bootstrap script's secure prompt or `-ScimToken`; the script stores it only as a Windows DPAPI-protected value under `%ProgramData%\AwsEntraFederation`. The Entra metadata XML and AWS service-provider metadata XML are validated locally but are not placed in Terraform state.

Use the orchestrator for production onboarding. Set the non-secret `bootstrap` values in the JSON example, then run a read-only federation and quota preflight against the existing organization:

```powershell
pwsh .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 `
  -Mode Validate `
  -ConfigPath .\scripts\entra-aws-federation.local.json
```

For a new organization foundation, review the account-creation plan first, then apply it only with the explicit organization approval. The process stops after account creation so member-account provisioning can complete:

```powershell
pwsh .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 `
  -Mode Plan -OrganizationMode Plan `
  -ConfigPath .\scripts\entra-aws-federation.local.json

pwsh .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 `
  -Mode Apply -OrganizationMode Apply `
  -ConfigPath .\scripts\entra-aws-federation.local.json `
  -ApproveOrganizationChange
```

For an existing enterprise organization, use `-OrganizationMode Skip`. After the one-time AWS console steps and SCIM bootstrap are complete, Apply configures Entra, provisioning, Terraform inputs, and managed profiles. `-ApproveIdentitySourceChange` is still required because the first cutover can affect assignments:

```powershell
pwsh .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 `
  -Mode Apply -OrganizationMode Skip `
  -ConfigPath .\scripts\entra-aws-federation.local.json `
  -ApproveIdentitySourceChange
```

Add `-ApplyGovernance -ApproveTerraform` only after the member accounts, permission-set inputs, and Terraform plan are ready. The orchestrator refuses governance when the AWS account quota is pending and never submits a duplicate quota request without `-RequestQuota -ApproveQuota`.

If the quota preflight reports `QuotaIncreaseRequired` and no request is open, add `-RequestQuota -ApproveQuota` to the Validate command to submit one. Do not use those switches again while the result is `Pending` or `CASE_OPENED`.

The lower-level `Configure-AwsEntraFederation.ps1` commands below remain available for targeted SCIM rotation or recovery; use the bootstrap orchestrator for the normal production onboarding path.

On successful Validate or Apply, inspect `phases.manualBootstrap.status` in `%ProgramData%\AwsEntraFederation\bootstrap-last-result.json`; it must be `verified`. The result includes the individual manual-step checks and failed-check names when validation cannot prove the cutover is working.

### Targeted direct federation recovery

Use these lower-level commands only when the orchestrator is not the right recovery path:

Run a read-only preflight first:

```powershell
pwsh .\scripts\Configure-AwsEntraFederation.ps1 `
  -Mode Validate `
  -ConfigPath .\scripts\entra-aws-federation.local.json
```

After completing the one-time AWS console bootstrap and reviewing the result, a direct targeted Apply can configure Entra, SCIM, managed AWS CLI profiles, and optional Terraform assignments:

```powershell
pwsh .\scripts\Configure-AwsEntraFederation.ps1 `
  -Mode Apply `
  -ConfigPath .\scripts\entra-aws-federation.local.json `
  -ApproveIdentitySourceChange `
  -ApplyTerraform
```

The script creates only profiles in its managed block and preserves unrelated AWS profiles. Generated governance assignment variables are written to the ignored `stages/02-governance/federation.auto.tfvars.json` file. Human AWS CLI authentication remains interactive through `aws sso login`.

`AdministratorAccess` is supported as an explicit access mapping. It creates or adopts an AWS permission set backed by the AWS-managed `AdministratorAccess` policy and assigns it to the derived administrator group for the configured account selector. `all-active-accounts` is evaluated when the bootstrap runs; rerun the onboarding process after a new account becomes active so the new account receives the assignment.

### Enabling SSH access to the Windows VM

The normal Windows Features-on-Demand route can fail when the VM cannot reach Windows Update or lacks matching ARM64 Features-on-Demand media. For this VM, use the official open-source Microsoft `PowerShell/Win32-OpenSSH` GitHub MSI instead. The pinned installer supports Windows 11 ARM64 and is SHA-256 verified by `scripts/Install-WindowsOpenSSHFromGitHub.ps1`.

From an elevated PowerShell window inside the Windows VM, run the GitHub installer script with an OpenSSH public key. Generate the key on the Mac if needed; copy only the `.pub` line into the VM:

```powershell
.\scripts\Install-WindowsOpenSSHFromGitHub.ps1 `
  -UserName "$env:USERDOMAIN\$env:USERNAME" `
  -AuthorizedKey "ssh-ed25519 AAAA... workstation-key"
```

First test the key-based connection from the Mac. If it works, rerun the command with `-DisablePasswordAuthentication`. The script downloads only the pinned official GitHub release, verifies its hash, installs and starts OpenSSH Server, creates a TCP/22 firewall rule for the selected profile, restricts the authorized-key file ACL, validates `sshd_config`, and prints the VM address. It does not create, request, or store a private key. Use `-FirewallProfile Any` only when the VM network is intentionally host-only/NAT and the broader Windows firewall profile is understood. The existing `Enable-WindowsOpenSSHForCodex.ps1` remains available for systems where the built-in Windows capability works.

## Validation

```bash
terraform fmt -check -recursive
terraform -chdir=stages/01-organization init -backend=false
terraform -chdir=stages/01-organization validate
terraform -chdir=stages/02-governance init -backend=false
terraform -chdir=stages/02-governance validate
terraform -chdir=stages/03-production init -backend=false
terraform -chdir=stages/03-production validate
```
