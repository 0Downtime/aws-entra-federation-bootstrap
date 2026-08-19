# Entra ID federation for AWS IAM Identity Center

This runbook records the sequence that advanced the Windows test environment and is intended for repeating the setup in a production tenant or AWS Organization.

It covers Entra SAML federation, Entra-to-AWS SCIM provisioning, certificate-backed Microsoft Graph automation from Windows PowerShell 7, Terraform-managed permission sets and assignments, and managed AWS CLI SSO profiles.

The runbook deliberately contains no SCIM token, Graph token, private key, password, or certificate private material.

## Important boundaries

These operations require explicit review:

- AWS IAM Identity Center identity-source cutover.
- Creation or activation of an Entra SAML signing certificate.
- SCIM endpoint/token creation or rotation.
- Terraform changes to organization accounts, CloudTrail, permission sets, or assignments.

The automation refuses mutating federation modes unless the -ApproveIdentitySourceChange switch is supplied. Review the AWS account, organization, region, Identity Center instance, and existing assignments before supplying it.

## 1. Prepare the Windows host

Run the repository prerequisite bootstrap first. It is safe to run `Validate` repeatedly. `Install` uses winget for the command-line tools and installs the Graph authentication and Pester modules for the current user:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-AwsEntraFederationPrerequisites.ps1 -Mode Validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-AwsEntraFederationPrerequisites.ps1 -Mode Install -WingetScope User
pwsh -NoProfile -File .\scripts\Install-AwsEntraFederationPrerequisites.ps1 -Mode Validate
~~~

For machine-wide winget installs, use an elevated PowerShell prompt and `-WingetScope Machine`. If `winget` is unavailable, install Microsoft's App Installer package first. The script does not create AWS credentials, Entra app registrations, certificates, SCIM tokens, or IAM Identity Center assignments.

## 1b. Generate the local configuration

Use the initializer to discover non-secret values and write the ignored local configuration. It verifies the selected AWS profile through STS and Organizations, searches for the IAM Identity Center instance, uses Azure CLI for the Entra tenant and Graph app when available, finds a unique valid private-key certificate, creates the metadata directory, and derives group names from `entra.groupNamePrefix` and mapping suffixes. It prompts for values that are ambiguous or not exposed by the APIs, especially the AWS access portal start URL.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-AwsEntraFederationConfig.ps1 -Mode Plan -ManagementProfile management-prod -GroupNamePrefix PROD-AWS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-AwsEntraFederationConfig.ps1 -Mode Initialize -ManagementProfile management-prod -ManagementAccountId 000000000000 -GroupNamePrefix PROD-AWS
~~~

Add `-IncludeAdministratorAccess` only when full administrator access is explicitly approved. The initializer writes `scripts\entra-aws-federation.local.json`, which is ignored by Git, and never writes SCIM tokens or private keys.

The Windows host needs AWS CLI v2, Terraform, PowerShell 7, Microsoft.Graph PowerShell modules, Pester, an AWS profile with management-account Organizations and IAM Identity Center permissions, and a certificate-backed Entra automation app with its private key in the Windows certificate store.

For the local test VM, the AWS profile was management-girsnoopy. Production should use the intended management-account profile instead.

## 1a. Clear the Organizations account-quota gate

The canonical production entry point is `scripts\Invoke-AwsEntraFederationBootstrap.ps1`. It composes the quota check, optional organization bootstrap, federation configuration, managed AWS CLI profile generation, and optional governance handoff. The individual scripts remain available for troubleshooting and targeted recovery.

Copy the example configuration to the ignored local path and set the non-secret `bootstrap.requiredAccountCount`, `bootstrap.requestedAccountQuota`, and optional `bootstrap.organizationStagePath` values along with the AWS, Entra, and mapping values below. For an existing enterprise organization, keep `-OrganizationMode Skip`; the orchestrator will still run the quota preflight and federation validation.

Read-only existing-organization preflight:

~~~powershell
pwsh -NoProfile -File .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 -Mode Validate -OrganizationMode Skip -ConfigPath .\scripts\entra-aws-federation.local.json
~~~

New organization plan and gated apply:

~~~powershell
pwsh -NoProfile -File .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 -Mode Plan -OrganizationMode Plan -ConfigPath .\scripts\entra-aws-federation.local.json
pwsh -NoProfile -File .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 -Mode Apply -OrganizationMode Apply -ConfigPath .\scripts\entra-aws-federation.local.json -ApproveOrganizationChange
~~~

The organization Apply intentionally stops after Terraform account creation. Wait for accounts to become `ACTIVE` and for `OrganizationAccountAccessRole` to be usable, then rerun with `-OrganizationMode Skip`.

If the quota preflight reports `QuotaIncreaseRequired` and no open request exists, submit one through the same orchestrator with an explicit quota approval. If it reports `Pending` or `CASE_OPENED`, do not repeat this command:

~~~powershell
pwsh -NoProfile -File .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 -Mode Validate -OrganizationMode Skip -ConfigPath .\scripts\entra-aws-federation.local.json -RequestQuota -ApproveQuota
~~~

Before creating the log-archive and production member accounts, run the repository preflight. It now discovers an existing open Service Quotas request automatically when RequestId is omitted:

Run this in PowerShell 7 inside the Windows VM, not in the Mac zsh shell. PowerShell uses the backtick for line continuation; zsh does not. A one-line command avoids shell-specific continuation errors.

~~~powershell
pwsh -NoProfile -File .\scripts\Ensure-AwsOrganizationsAccountQuota.ps1 -ManagementProfile management-girsnoopy -Region us-east-1 -RequiredAccountCount 3 -Mode Plan
~~~

If the result is QuotaIncreaseRequired and no request is open, submit one explicitly:

~~~powershell
pwsh -NoProfile -File .\scripts\Ensure-AwsOrganizationsAccountQuota.ps1 -ManagementProfile management-girsnoopy -Region us-east-1 -RequiredAccountCount 3 -RequestedQuota 20 -Mode Request -Approve
~~~

Do not submit a duplicate request if the result is Pending or CASE_OPENED. Rerun the Plan command until the result is Ready or QuotaApprovedRefreshRequired, then run the organization bootstrap wrapper with the same management profile. The test environment currently has one active account, a quota of one, and an existing CASE_OPENED request for 20 accounts; member-account creation must wait for AWS approval.

## 2. Prepare the repository and local configuration

Keep the local configuration outside source control, or use a repository-ignored filename:

~~~powershell
Copy-Item .\scripts\entra-aws-federation.example.json .\scripts\entra-aws-federation.local.json
notepad .\scripts\entra-aws-federation.local.json
~~~

Set these values for the target environment:

- aws.managementProfile, aws.region, and aws.identityCenterRegion.
- aws.startUrl and aws.managedProfilePrefix.
- entra.tenantId, entra.clientId, and entra.certificateThumbprint.
- entra.applicationDisplayName, normally AWS IAM Identity Center.
- entra.applicationTemplateId, if the current AWS gallery template ID is known.
- entra.groupNamePrefix plus accessMappings: use `entraGroupSuffix` to derive unique Entra group names, Terraform permission-set names, and explicit account IDs or all-active-accounts. Existing configurations may continue using an explicit `entraGroup`.

Do not put a SCIM token, private key, Graph secret, or password in this JSON file.

## 3. Create the certificate-backed Graph app

Create or reuse a dedicated Entra app registration for automation. The private key must remain on the Windows host. A certificate-backed app is preferred over a client secret.

The app needs these Microsoft Graph application permissions:

- Application.ReadWrite.All
- AppRoleAssignment.ReadWrite.All
- Group.Read.All
- Synchronization.ReadWrite.All

Grant tenant-wide admin consent in Entra under the app registration's API permissions page. Verify the certificate thumbprint in the local JSON matches the certificate containing the private key:

~~~powershell
Get-ChildItem Cert:\CurrentUser\My |
  Where-Object Subject -like '*AWS Entra Federation Automation*' |
  Select-Object Subject, Thumbprint, NotAfter, HasPrivateKey
~~~

HasPrivateKey must be True. Never export or commit the private key.

If Azure CLI reports permissions but Graph calls still return Insufficient privileges, inspect the automation service principal's Microsoft Graph app-role assignments. An admin must complete the missing grants; do not work around this with delegated user tokens in the repository.

## 4. Configure Entra SAML federation

1. In Entra, instantiate or open the AWS IAM Identity Center gallery application.
2. Set the application to SAML single sign-on.
3. Configure the AWS IAM Identity Center ACS/reply URL and issuer/entity ID from the AWS external-IdP setup screen.
4. Create or activate an Entra SAML token-signing certificate.
5. Assign the intended Entra groups to the enterprise application.
6. Download fresh Entra IdP SAML metadata after the signing certificate is active.

The metadata must contain an X509Certificate element. An older metadata file without the certificate produced the AWS error "IdP signing certificate cannot be null". The orchestrator now validates this locally and stops before making an AWS change if the certificate is absent or invalid.

Store metadata in a secure bootstrap directory, for example C:\SecureBootstrap\entra-idp-metadata.xml. Do not commit metadata or certificate files unless the organization explicitly treats them as non-sensitive deployment artifacts.

## 5. Perform the AWS one-time identity-source cutover

The initial AWS identity-source change remains console-gated:

1. Open IAM Identity Center in the configured Identity Center region.
2. Open Settings and the identity-source change workflow.
3. Select External identity provider.
4. Upload the freshly downloaded Entra IdP metadata XML.
5. Confirm the certificate is recognized and review the displayed ACS and issuer values.
6. Explicitly confirm the cutover.
7. Download the AWS service-provider metadata shown after the change if it is needed for Entra configuration.

After the cutover, verify the AWS instance is active and reports an external identity provider. Do not repeat the cutover casually; existing native IAM Identity Center assignments can be affected.

## 6. Enable and verify SCIM provisioning

In AWS IAM Identity Center:

1. Open Settings → Automatic provisioning.
2. Enable provisioning.
3. Copy the SCIM endpoint and token. The token is shown only once; generate a replacement if it was lost or expired.

In the Entra enterprise application:

1. Open Provisioning.
2. Select Automatic provisioning.
3. Enter the AWS SCIM endpoint and token.
4. Test the connection, save, and start provisioning.
5. Confirm the job reaches Active and has a successful execution.

The test environment reached a successful job with groups exported to AWS. Allow a provisioning cycle to complete before declaring that a group is missing.

## 7. Store the SCIM token on Windows and run Apply

If the DPAPI secret file is absent, run this locally in PowerShell 7 inside the Windows VM. The token is hidden while entered and is never sent through chat. Create and consume the SecureString inside the same PowerShell 7 process; passing a SecureString from Windows PowerShell to a new pwsh process converts it to a String and causes parameter binding to fail.

~~~powershell
Set-Location "$env:USERPROFILE\Downloads\AWS-Terraform"
pwsh -NoProfile
Set-Location "$env:USERPROFILE\Downloads\AWS-Terraform"
$scimEndpoint = Read-Host "AWS SCIM endpoint"
$scimToken = Read-Host "AWS SCIM token" -AsSecureString
& .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 -Mode Apply -OrganizationMode Skip -ConfigPath .\scripts\entra-aws-federation.local.json -ScimEndpoint $scimEndpoint -ScimToken $scimToken -ApproveIdentitySourceChange
exit
~~~

The script stores the token only in C:\ProgramData\AwsEntraFederation\scim.dpapi.txt. The file is encrypted for the Windows user/context that created it and has a restricted ACL. Do not copy it between hosts.

Future rotations use:

~~~powershell
pwsh -NoProfile -File .\scripts\Configure-AwsEntraFederation.ps1 -Mode RotateScimToken -ConfigPath .\scripts\entra-aws-federation.local.json
~~~

Never put the token in Terraform variables, command history, or chat.

## 8. Validate before Terraform

Run the read-only preflight:

~~~powershell
pwsh -NoProfile -File .\scripts\Configure-AwsEntraFederation.ps1 -Mode Validate -ConfigPath .\scripts\entra-aws-federation.local.json
~~~

A successful result should confirm the AWS profile targets the expected management account and organization, the IAM Identity Center instance and identity store are active, Entra SAML mode and an active signing certificate exist, each configured Entra group resolves uniquely and is assigned to the application, SCIM-provisioned AWS group IDs resolve, and generated profile names are deterministic.

The orchestrator additionally writes `phases.manualBootstrap.status`. It must be `verified` for Validate or Apply. The associated checks cover the Identity Center instance, SAML mode, active signing certificate, fresh metadata, Entra application assignments, an Active provisioning job, and AWS groups present in the identity store. If a check fails, the script names the failed checks and stops. The AWS API does not expose a direct external-identity-source flag, so successful SCIM-provisioned groups are the downstream proof that the manual cutover is functioning.

Run the repository tests on Windows:

~~~powershell
Invoke-Pester -Path .\tests\Configure-AwsEntraFederation.Tests.ps1 -Output Detailed
~~~

The current test checkpoint reached in the VM is 11 passing tests and zero failures.

## 9. Terraform governance and AWS CLI profiles

Terraform remains the owner of permission-set definitions and AWS account assignments. The federation script only generates the group IDs and mapping consumed by the governance stage.

For full AWS administrator access, set `entra.groupNamePrefix` (for example, `AWS`) and use an `entraGroupSuffix` of `Administrators` to derive a dedicated group such as `AWS-Administrators`. Assign the group to the AWS enterprise application so assignment-based SCIM provisioning includes it, then configure an access mapping with `permissionSet: "AdministratorAccess"` and the desired account selector. The governance stage creates or adopts the `AdministratorAccess` permission set and attaches the AWS-managed `arn:aws:iam::aws:policy/AdministratorAccess` policy. Keep this group separate from read-only groups and require an explicit approval for membership changes. `all-active-accounts` expands at runtime; rerun the bootstrap after new organization accounts become active.

When the required log-archive/member-account foundation exists, run the orchestrator with the explicit governance approval:

~~~powershell
pwsh -NoProfile -File .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 -Mode Apply -OrganizationMode Skip -ConfigPath .\scripts\entra-aws-federation.local.json -ApproveIdentitySourceChange -ApplyGovernance -ApproveTerraform
~~~

Review the generated ignored file at stages\02-governance\federation.auto.tfvars.json.

Do not use -ApplyTerraform while the organization lacks the accounts and inputs required by stage 02-governance. In the test environment there was one active management account and zero permission sets, so the full governance apply was intentionally deferred.

The script writes only its managed AWS CLI SSO block and preserves unrelated profiles. After Terraform creates the permission sets and assignments:

~~~powershell
aws sso login --profile <managed-profile>
aws sts get-caller-identity --profile <managed-profile>
~~~

## 10. End-to-end acceptance test

Use a dedicated test user, not a production administrator:

1. Add the test user to one configured Entra group.
2. Confirm the user/group is assigned to the AWS enterprise application.
3. Wait for the provisioning job to export the user and group.
4. Confirm the AWS identity store contains the user and group.
5. Run Terraform plan and apply for the intended permission-set assignment.
6. Run aws sso login --profile <managed-profile>.
7. Run aws sts get-caller-identity --profile <managed-profile>.
8. Confirm the account ID and role match the mapping.

The test environment had groups provisioned successfully but no AWS identity-store users yet; adding a test user to an assigned Entra group is a required final checkpoint.

## 11. Recovery and troubleshooting

### AWS rejects metadata with a null signing certificate

Activate the Entra SAML signing certificate, download fresh metadata, and confirm the XML contains X509Certificate. Do not reuse the old metadata file.

### Graph returns 403 or Insufficient privileges

Verify the certificate-backed app, tenant ID, client ID, certificate thumbprint, and tenant-wide admin consent. Confirm all four Graph application roles are assigned to the automation service principal. Re-run Validate after consent propagation.

Some AWS gallery provisioning applications expose the synchronization template and existing job as dictionary-shaped Graph responses. The orchestrator supports this response shape and reuses the existing job's template ID instead of creating a duplicate provisioning job.

### SCIM token is missing or expired

Generate a new token in AWS Automatic provisioning, enter it locally with Mode RotateScimToken or Mode Apply, and verify the Entra provisioning job. Never paste it into chat, Terraform, or a repository file.

### Groups are not found in AWS

Confirm the AWS identity source is external, the Entra provisioning job is active, the groups are assigned to the enterprise application, and display names exactly match the local configuration. Wait for a successful provisioning cycle and rerun Apply.

### PowerShell script execution is blocked

Use a process-scoped bypass; do not weaken the machine policy permanently:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Configure-AwsEntraFederation.ps1 -Mode Validate -ConfigPath .\scripts\entra-aws-federation.local.json
~~~

### OpenSSH Windows capability installation fails

Use the repository's pinned GitHub OpenSSH installer instead of Windows Features-on-Demand when the VM cannot obtain matching ARM64 source files. This is only for VM administration and is not part of the federation trust chain.

## 12. Production handoff checklist

- [ ] Production AWS management profile tested with sts get-caller-identity.
- [ ] Correct AWS Organization and Identity Center region verified.
- [ ] Identity Center instance already enabled.
- [ ] Entra SAML app and active signing certificate verified.
- [ ] Fresh Entra metadata contains a public X.509 certificate.
- [ ] AWS external IdP cutover reviewed and approved.
- [ ] SCIM endpoint/token entered locally and DPAPI file created.
- [ ] Provisioning job active with a successful execution.
- [ ] Entra groups assigned to the enterprise application.
- [ ] Member accounts and log-archive inputs available before governance apply.
- [ ] Terraform plan reviewed for permission sets and assignments.
- [ ] Dedicated test user completed aws sso login and sts get-caller-identity.
- [ ] No secret, private key, local config, metadata bootstrap file, or DPAPI file committed.
