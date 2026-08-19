#requires -Version 7.2

[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Plan', 'PrepareMetadata', 'Apply')]
    [string]$Mode = 'Validate',

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [ValidateSet('Skip', 'Plan', 'Apply')]
    [string]$OrganizationMode = 'Skip',

    [string]$RequestId,
    [switch]$RequestQuota,
    [switch]$ApproveQuota,
    [switch]$ApproveOrganizationChange,
    [switch]$ContinueAfterOrganizationApply,
    [switch]$ApproveIdentitySourceChange,
    [switch]$EnsureEntraMetadata,
    [switch]$ApplyGovernance,
    [switch]$ApproveTerraform,
    [switch]$ForceManagedProfiles,
    [string]$ScimEndpoint,
    [System.Security.SecureString]$ScimToken,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''

$script:RootPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:SecretStorePath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AwsEntraFederation'
$script:QuotaScript = Join-Path $PSScriptRoot 'Ensure-AwsOrganizationsAccountQuota.ps1'
$script:OrganizationScript = Join-Path $PSScriptRoot 'Invoke-AwsOrganizationBootstrap.ps1'
$script:FederationScript = Join-Path $PSScriptRoot 'Configure-AwsEntraFederation.ps1'
$script:Result = [ordered]@{
    status = 'NotStarted'
    mode = $Mode
    organizationMode = $OrganizationMode
    phases = [ordered]@{}
    warnings = @()
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        $value = $Object[$Name]
        if ($null -eq $value) { return $Default }
        return $value
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Read-BootstrapConfig {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $aws = Get-ConfigValue -Object $config -Name 'aws'
    if ($null -eq $aws) {
        throw "Configuration section 'aws' is required."
    }
    $bootstrap = Get-ConfigValue -Object $config -Name 'bootstrap' -Default ([pscustomobject]@{})

    foreach ($name in @('managementProfile', 'region')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Object $aws -Name $name))) {
            throw "Configuration value 'aws.$name' is required."
        }
    }

    $requiredAccountCount = [int](Get-ConfigValue -Object $bootstrap -Name 'requiredAccountCount' -Default 3)
    $requestedQuota = [int](Get-ConfigValue -Object $bootstrap -Name 'requestedAccountQuota' -Default 20)

    if ($requiredAccountCount -lt 1) {
        throw 'bootstrap.requiredAccountCount must be at least 1.'
    }
    if ($requestedQuota -lt $requiredAccountCount) {
        throw 'bootstrap.requestedAccountQuota must be at least requiredAccountCount.'
    }

    $organizationStagePath = [string](Get-ConfigValue -Object $bootstrap -Name 'organizationStagePath' -Default (Join-Path $script:RootPath 'stages\01-organization'))
    if ([string]::IsNullOrWhiteSpace($organizationStagePath)) {
        $organizationStagePath = Join-Path $script:RootPath 'stages\01-organization'
    }
    elseif (-not [IO.Path]::IsPathRooted($organizationStagePath)) {
        $organizationStagePath = Join-Path $script:RootPath $organizationStagePath
    }
    if (-not (Test-Path -LiteralPath $organizationStagePath -PathType Container)) {
        throw "Organization stage path was not found: $organizationStagePath"
    }

    return [pscustomobject]@{
        Config = $config
        ManagementProfile = [string](Get-ConfigValue -Object $aws -Name 'managementProfile')
        Region = [string](Get-ConfigValue -Object $aws -Name 'region')
        RequiredAccountCount = $requiredAccountCount
        RequestedQuota = $requestedQuota
        OrganizationStagePath = (Resolve-Path -LiteralPath $organizationStagePath).Path
    }
}

function Assert-ScriptDependencies {
    foreach ($command in @('pwsh', 'aws', 'terraform')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command '$command' was not found. Run this onboarding process in PowerShell 7 on the Windows deployment host."
        }
    }

    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is required. Install-Module Microsoft.Graph -Scope CurrentUser.'
    }

    if (-not (Test-Path -LiteralPath $script:QuotaScript -PathType Leaf)) {
        throw "Quota script was not found: $script:QuotaScript"
    }
    if (-not (Test-Path -LiteralPath $script:OrganizationScript -PathType Leaf)) {
        throw "Organization bootstrap script was not found: $script:OrganizationScript"
    }
    if (-not (Test-Path -LiteralPath $script:FederationScript -PathType Leaf)) {
        throw "Federation script was not found: $script:FederationScript"
    }
}

function Get-RedactedQuotaResult {
    param($QuotaResult)

    if ($null -eq $QuotaResult) { return $null }

    return [ordered]@{
        status = [string]$QuotaResult.status
        accountCount = [int]$QuotaResult.accountCount
        requiredAccountCount = [int]$QuotaResult.requiredAccountCount
        currentQuota = [int]$QuotaResult.currentQuota
        requestedQuota = [int]$QuotaResult.requestedQuota
        quotaCode = [string]$QuotaResult.quotaCode
        requestId = if ($null -eq $QuotaResult.request) { $null } else { [string]$QuotaResult.request.Id }
        requestStatus = if ($null -eq $QuotaResult.request) { $null } else { [string]$QuotaResult.request.Status }
        caseId = if ($null -eq $QuotaResult.request) { $null } else { [string]$QuotaResult.request.CaseId }
        action = [string]$QuotaResult.action
    }
}

function Show-ManualBootstrapInstructions {
    $instructions = @'
MANUAL AWS/ENTRA BOOTSTRAP CHECKLIST

Complete these console steps before approving federation Apply:
  1. AWS IAM Identity Center: confirm the organization instance is enabled in the configured Identity Center region.
  2. AWS IAM Identity Center: download the service-provider metadata from the external identity-provider setup and place it at the configured AWS metadata path. This is the one-time AWS artifact not exposed by the public sso-admin API.
  3. Run the metadata-only preparation phase with `-Mode PrepareMetadata -EnsureEntraMetadata`; it configures SAML, creates or activates the Entra signing certificate, and downloads fresh Entra IdP metadata.
  4. AWS IAM Identity Center: Settings -> Identity source -> Change identity source -> External identity provider; upload the fresh Entra metadata and confirm the displayed ACS/issuer values before completing the cutover.
  5. Entra enterprise application: assign each configured group to the application.
  6. AWS IAM Identity Center: Settings -> Automatic provisioning; enable it and copy the SCIM endpoint and one-time token.
  7. Entra enterprise application: Provisioning -> Automatic; enter the SCIM endpoint/token, test the connection, save, start provisioning, and wait for an Active job with a successful execution.

Return to this PowerShell 7 process afterward. The SCIM token must be entered only at the secure prompt or passed as a SecureString; never paste it into a file, Terraform variable, command history, or chat.
'@
    Write-Information $instructions -InformationAction Continue
}

function Test-ManualBootstrapEvidence {
    param(
        [Parameter(Mandatory = $true)]$Federation,
        [Parameter(Mandatory = $true)]$Config
    )

    $assignments = @($Federation.assignments)
    $awsEvidence = Get-ConfigValue -Object $Federation -Name 'aws' -Default ([pscustomobject]@{})
    $entraEvidence = Get-ConfigValue -Object $Federation -Name 'entra' -Default ([pscustomobject]@{})
    $signingCertificate = Get-ConfigValue -Object $entraEvidence -Name 'signingCertificate' -Default ([pscustomobject]@{})
    $provisioning = Get-ConfigValue -Object $entraEvidence -Name 'provisioning' -Default ([pscustomobject]@{})
    $metadataEvidence = Get-ConfigValue -Object $entraEvidence -Name 'identityProviderMetadata' -Default ([pscustomobject]@{})
    $configuredMetadataPath = [string](Get-ConfigValue -Object $Config.entra -Name 'identityProviderMetadataPath')
    $freshMetadata = $null -ne $metadataEvidence -and -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Object $metadataEvidence -Name 'path'))
    if (-not $freshMetadata -and -not [string]::IsNullOrWhiteSpace($configuredMetadataPath)) {
        # The federation phase has already parsed and validated this file. Use
        # the configured path as evidence even if a Graph/AWS response omitted
        # the optional metadata summary from its result object.
        $freshMetadata = Test-Path -LiteralPath $configuredMetadataPath -PathType Leaf
    }
    $provisioningStatus = [string](Get-ConfigValue -Object $provisioning -Name 'status')
    $checks = [ordered]@{
        identityCenterInstance = -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Object $awsEvidence -Name 'instanceArn')) -and -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Object $awsEvidence -Name 'identityStoreId'))
        samlMode = [string](Get-ConfigValue -Object $entraEvidence -Name 'preferredSingleSignOnMode') -eq 'saml'
        activeSigningCertificate = [string](Get-ConfigValue -Object $signingCertificate -Name 'status') -eq 'active'
        freshEntraMetadata = $freshMetadata
        applicationGroupAssignments = $assignments.Count -gt 0 -and @($assignments | Where-Object { $_.applicationAssignment -notin @('existing', 'created') }).Count -eq 0
        provisioningJobActive = $provisioningStatus -eq 'active'
        scimGroupsPresent = $assignments.Count -gt 0 -and @($assignments | Where-Object { $_.awsGroupStatus -ne 'existing' -or [string]::IsNullOrWhiteSpace([string]$_.awsGroupId) }).Count -eq 0
    }

    $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
    $status = if ($Mode -eq 'Plan') { 'planned' } elseif ($failed.Count -eq 0) { 'verified' } else { 'failed' }
    $script:Result.phases.manualBootstrap = [ordered]@{
        status = $status
        checks = $checks
        failedChecks = $failed
        evidence = 'AWS groups resolved in the Identity Center identity store after Entra provisioning; this is the downstream proof that the external IdP/SCIM path is working.'
        limitation = 'AWS public APIs do not expose a direct external-identity-source boolean, so the console cutover is validated by fresh metadata, active Entra SAML/provisioning state, and successfully provisioned AWS groups.'
    }

    if ($Mode -ne 'Plan' -and $failed.Count -gt 0) {
        throw "Manual AWS/Entra bootstrap validation failed: $($failed -join ', '). Review the displayed checklist and rerun Validate after correcting the failed step."
    }
}

function Invoke-QuotaCheck {
    param($Bootstrap)

    $resultPath = Join-Path $script:SecretStorePath 'bootstrap-quota-result.json'
    New-Item -ItemType Directory -Path $script:SecretStorePath -Force | Out-Null

    $arguments = @{
        ManagementProfile = $Bootstrap.ManagementProfile
        Region = $Bootstrap.Region
        RequiredAccountCount = $Bootstrap.RequiredAccountCount
        Mode = 'Plan'
        OutputPath = $resultPath
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
        $arguments.RequestId = $RequestId
    }

    & $script:QuotaScript @arguments *> $null
    $quota = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json

    if ($RequestQuota -and $quota.status -notin @('Ready', 'QuotaApprovedRefreshRequired')) {
        if (-not $ApproveQuota) {
            throw 'Quota request was requested but -ApproveQuota was not supplied.'
        }

        $requestArguments = @{
            ManagementProfile = $Bootstrap.ManagementProfile
            Region = $Bootstrap.Region
            RequiredAccountCount = $Bootstrap.RequiredAccountCount
            RequestedQuota = $Bootstrap.RequestedQuota
            Mode = 'Request'
            Approve = $true
            OutputPath = $resultPath
        }
        if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
            $requestArguments.RequestId = $RequestId
        }

        & $script:QuotaScript @requestArguments *> $null
        $quota = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    }

    $script:Result.phases.quota = Get-RedactedQuotaResult -QuotaResult $quota
    return $quota
}

function Invoke-OrganizationBootstrap {
    param($Bootstrap)

    if ($Mode -eq 'PrepareMetadata' -and $OrganizationMode -ne 'Skip') {
        throw 'PrepareMetadata only supports OrganizationMode Skip; prepare federation metadata after the organization already exists.'
    }

    if ($OrganizationMode -eq 'Skip') {
        $script:Result.phases.organization = [ordered]@{
            status = 'skipped'
            reason = 'Organization bootstrap was not requested.'
        }
        return
    }

    if ($OrganizationMode -eq 'Apply' -and -not $ApproveOrganizationChange) {
        throw 'OrganizationMode Apply requires -ApproveOrganizationChange after reviewing the organization plan.'
    }

    $arguments = @{
        ManagementProfile = $Bootstrap.ManagementProfile
        Region = $Bootstrap.Region
        RequiredAccountCount = $Bootstrap.RequiredAccountCount
        Mode = $OrganizationMode
        StagePath = $Bootstrap.OrganizationStagePath
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
        $arguments.RequestId = $RequestId
    }

    & $script:OrganizationScript @arguments
    $script:Result.phases.organization = [ordered]@{
        status = $OrganizationMode.ToLowerInvariant()
        stagePath = $Bootstrap.OrganizationStagePath
    }

    if ($OrganizationMode -eq 'Apply' -and -not $ContinueAfterOrganizationApply) {
        $script:Result.warnings += 'Organization account creation completed or was invoked. Wait for member accounts to finish provisioning, then rerun with OrganizationMode Skip before federation governance.'
        throw 'Stopping after organization bootstrap. Re-run after member accounts are ACTIVE and OrganizationAccountAccessRole is usable.'
    }
}

function Resolve-ScimArguments {
    $secretPath = Join-Path $script:SecretStorePath 'scim.dpapi.txt'
    $needsSecureInput = $Mode -in @('Plan', 'Apply') -and -not (Test-Path -LiteralPath $secretPath) -and $null -eq $ScimToken

    if ($needsSecureInput) {
        if ([string]::IsNullOrWhiteSpace($ScimEndpoint)) {
            $ScimEndpoint = Read-Host 'AWS SCIM endpoint'
        }
        $ScimToken = Read-Host 'AWS SCIM token' -AsSecureString
    }

    if ($Mode -in @('Apply', 'Plan') -and $null -eq $ScimToken -and -not (Test-Path -LiteralPath $secretPath)) {
        throw 'SCIM token is not available. Enter it at the secure PowerShell 7 prompt or run Apply after the DPAPI secret has been created.'
    }

    return @{
        ScimEndpoint = $ScimEndpoint
        ScimToken = $ScimToken
    }
}

function Invoke-Federation {
    param($ScimArguments)

    $resultPath = Join-Path $script:SecretStorePath 'bootstrap-federation-result.json'
    New-Item -ItemType Directory -Path $script:SecretStorePath -Force | Out-Null

    $arguments = @{
        Mode = $Mode
        ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        ApproveIdentitySourceChange = $ApproveIdentitySourceChange
        EnsureEntraMetadata = $EnsureEntraMetadata
        ForceManagedProfiles = $ForceManagedProfiles
        OutputPath = $resultPath
    }

    if ($ApplyGovernance) {
        if ($Mode -ne 'Apply') {
            throw 'ApplyGovernance is only valid with Mode Apply.'
        }
        if (-not $ApproveTerraform) {
            throw 'ApplyGovernance requires -ApproveTerraform after reviewing the governance plan.'
        }
        $arguments.ApplyTerraform = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ScimArguments.ScimEndpoint)) {
        $arguments.ScimEndpoint = $ScimArguments.ScimEndpoint
    }
    if ($null -ne $ScimArguments.ScimToken) {
        $arguments.ScimToken = $ScimArguments.ScimToken
    }

    & $script:FederationScript @arguments *> $null
    $federation = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $script:Result.phases.federation = $federation

    if ($federation.status -ne 'Succeeded') {
        throw "Federation phase failed: $($federation.error)"
    }

    return $federation
}

function Write-OnboardingResult {
    param([string]$DefaultPath)

    $script:Result.status = 'Succeeded'
    $target = if ([string]::IsNullOrWhiteSpace($OutputPath)) { $DefaultPath } else { $OutputPath }
    $parent = Split-Path -Parent $target
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $script:Result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $target -Encoding utf8NoBOM
    $script:Result | ConvertTo-Json -Depth 30
}

try {
    Assert-ScriptDependencies
    $bootstrap = Read-BootstrapConfig

    if ($Mode -in @('Plan', 'Apply')) {
        Show-ManualBootstrapInstructions
    }
    if ($Mode -eq 'Apply' -and -not $ApproveIdentitySourceChange) {
        throw 'Manual AWS/Entra bootstrap has not been acknowledged. Complete the displayed checklist, then rerun Apply with -ApproveIdentitySourceChange.'
    }

    $quota = Invoke-QuotaCheck -Bootstrap $bootstrap

    if ($OrganizationMode -ne 'Skip' -and $quota.status -notin @('Ready', 'QuotaApprovedRefreshRequired')) {
        throw "AWS Organizations account quota is not ready: $($quota.status). Terraform organization bootstrap was not run."
    }

    if ($ApplyGovernance -and $quota.status -notin @('Ready', 'QuotaApprovedRefreshRequired')) {
        throw "AWS Organizations account quota is not ready: $($quota.status). Governance apply was not run."
    }

    if ($Mode -eq 'Validate') {
        $script:Result.phases.organization = if ($OrganizationMode -eq 'Skip') { @{ status = 'skipped' } } else { @{ status = 'validation-only' } }
    }
    else {
        Invoke-OrganizationBootstrap -Bootstrap $bootstrap
    }

    $scimArguments = Resolve-ScimArguments
    $federation = Invoke-Federation -ScimArguments $scimArguments
    if ($Mode -eq 'PrepareMetadata') {
        $script:Result.phases.manualBootstrap = [ordered]@{
            status = 'metadata-prepared'
            nextStep = 'Complete the one-time AWS external identity-source cutover, then rerun with Mode Apply and the SCIM endpoint/token.'
        }
    }
    else {
        Test-ManualBootstrapEvidence -Federation $federation -Config $bootstrap.Config
    }

    $defaultOutput = Join-Path $script:SecretStorePath 'bootstrap-last-result.json'
    Write-OnboardingResult -DefaultPath $defaultOutput
}
catch {
    $script:Result.status = 'Failed'
    $script:Result.error = $_.Exception.Message
    $target = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $script:SecretStorePath 'bootstrap-last-result.json' } else { $OutputPath }
    $parent = Split-Path -Parent $target
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $script:Result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $target -Encoding utf8NoBOM
    throw
}
