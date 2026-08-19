#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Initialize')]
    [string]$Mode = 'Plan',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'entra-aws-federation.local.json'),

    [string]$ManagementProfile,
    [string]$ManagementAccountId,
    [string]$AwsRegion,
    [string]$IdentityCenterRegion,
    [string]$StartUrl,
    [string]$TenantId,
    [string]$GraphClientId,
    [string]$GraphAutomationAppDisplayName = 'AWS Entra Federation Automation',
    [string]$CertificateSubjectPattern = 'AWS Entra Federation Automation',
    [string]$GroupNamePrefix = 'AWS',
    [string]$MetadataDirectory = 'C:\SecureBootstrap',
    [switch]$IncludeAdministratorAccess,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Read-OptionalCommandOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & $Command @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($output | Out-String).Trim())
}

function Invoke-AwsJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: $($output -join ' ')"
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

function Get-ManagementProfile {
    param([string]$RequestedProfile)

    if (-not [string]::IsNullOrWhiteSpace($RequestedProfile)) {
        $identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity', '--profile', $RequestedProfile, '--output', 'json')
        return [pscustomobject]@{ Name = $RequestedProfile; AccountId = [string]$identity.Account }
    }

    $profiles = @(aws configure list-profiles 2>$null)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($profile in $profiles) {
        if ([string]::IsNullOrWhiteSpace([string]$profile)) { continue }
        try {
            $identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity', '--profile', [string]$profile, '--output', 'json')
            $organization = Invoke-AwsJson -Arguments @('organizations', 'describe-organization', '--profile', [string]$profile, '--output', 'json')
            $candidates.Add([pscustomobject]@{
                Name = [string]$profile
                AccountId = [string]$identity.Account
                OrganizationId = [string]$organization.Organization.Id
            })
        }
        catch {
            continue
        }
    }

    if ($candidates.Count -eq 0) {
        throw 'No AWS profile with usable management-account Organizations access was discovered. Supply -ManagementProfile and verify aws sts get-caller-identity first.'
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    Write-Host 'Multiple AWS management-capable profiles were discovered:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("[{0}] {1} ({2})" -f ($i + 1), $candidates[$i].Name, $candidates[$i].AccountId)
    }
    $selection = [int](Read-Host 'Select the production management profile number')
    if ($selection -lt 1 -or $selection -gt $candidates.Count) {
        throw 'The selected AWS profile number was invalid.'
    }
    return $candidates[$selection - 1]
}

function Get-ConfiguredRegion {
    param([string]$Profile)

    $region = Read-OptionalCommandOutput -Command 'aws' -Arguments @('configure', 'get', 'region', '--profile', $Profile)
    if (-not [string]::IsNullOrWhiteSpace($region)) { return $region }
    return (Read-Host 'AWS management region')
}

function Get-IdentityCenterRegion {
    param(
        [string]$Profile,
        [string]$FallbackRegion
    )

    if (-not [string]::IsNullOrWhiteSpace($IdentityCenterRegion)) { return $IdentityCenterRegion }

    $regions = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($FallbackRegion)) { $regions.Add($FallbackRegion) }
    try {
        $available = Invoke-AwsJson -Arguments @('ec2', 'describe-regions', '--all-regions', '--profile', $Profile, '--region', $FallbackRegion, '--output', 'json')
        foreach ($region in @($available.Regions | ForEach-Object { [string]$_.RegionName })) {
            if (-not $regions.Contains($region)) { $regions.Add($region) }
        }
    }
    catch {
        foreach ($region in @('us-east-1', 'us-west-2', 'eu-west-1', 'eu-central-1')) {
            if (-not $regions.Contains($region)) { $regions.Add($region) }
        }
    }

    $instances = [Collections.Generic.List[object]]::new()
    foreach ($region in $regions) {
        try {
            $response = Invoke-AwsJson -Arguments @('sso-admin', 'list-instances', '--profile', $Profile, '--region', $region, '--output', 'json')
            foreach ($instance in @($response.Instances)) {
                $instances.Add([pscustomobject]@{ Region = $region; InstanceArn = [string]$instance.InstanceArn; IdentityStoreId = [string]$instance.IdentityStoreId })
            }
        }
        catch {
            continue
        }
    }

    if ($instances.Count -eq 1) { return $instances[0].Region }
    if ($instances.Count -gt 1) {
        $distinct = @($instances | Select-Object -ExpandProperty Region -Unique)
        if ($distinct.Count -eq 1) { return $distinct[0] }
        throw 'Multiple IAM Identity Center regions were discovered. Supply -IdentityCenterRegion explicitly.'
    }
    return (Read-Host 'IAM Identity Center region')
}

function Get-StartUrlValue {
    param([string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($StartUrl)) { return $StartUrl }
    $configured = Read-OptionalCommandOutput -Command 'aws' -Arguments @('configure', 'get', 'sso_start_url', '--profile', $Profile)
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }

    $configFile = Join-Path $HOME '.aws\config'
    if (Test-Path -LiteralPath $configFile -PathType Leaf) {
        $matches = @(Select-String -LiteralPath $configFile -Pattern '^\s*sso_start_url\s*=\s*(\S+)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
        if ($matches.Count -eq 1) { return $matches[0] }
    }
    return (Read-Host 'AWS IAM Identity Center access portal start URL')
}

function Get-TenantIdValue {
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) { return $TenantId }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $tenant = Read-OptionalCommandOutput -Command 'az' -Arguments @('account', 'show', '--query', 'tenantId', '--output', 'tsv')
        if (-not [string]::IsNullOrWhiteSpace($tenant)) { return $tenant }
    }
    return (Read-Host 'Microsoft Entra tenant ID')
}

function Get-GraphClientIdValue {
    if (-not [string]::IsNullOrWhiteSpace($GraphClientId)) { return $GraphClientId }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $appsJson = Read-OptionalCommandOutput -Command 'az' -Arguments @('ad', 'app', 'list', '--display-name', $GraphAutomationAppDisplayName, '--output', 'json')
        if (-not [string]::IsNullOrWhiteSpace($appsJson)) {
            $apps = @($appsJson | ConvertFrom-Json)
            if ($apps.Count -eq 1) { return [string]$apps[0].appId }
            if ($apps.Count -gt 1) { throw "Multiple Entra app registrations named '$GraphAutomationAppDisplayName' were found. Supply -GraphClientId explicitly." }
        }
    }
    return (Read-Host 'Graph automation application client ID')
}

function Get-CertificateThumbprintValue {
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) { return $CertificateThumbprint }

    $certificates = @(
        Get-ChildItem -Path 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
                ($_.Subject -like "*$CertificateSubjectPattern*" -or $_.FriendlyName -like "*$CertificateSubjectPattern*")
            } |
            Sort-Object Thumbprint -Unique
    )
    if ($certificates.Count -eq 1) { return ([string]$certificates[0].Thumbprint).Replace(' ', '').ToUpperInvariant() }
    if ($certificates.Count -gt 1) { throw "Multiple valid private-key certificates matched '$CertificateSubjectPattern'. Supply -CertificateThumbprint explicitly." }
    return (Read-Host 'Certificate thumbprint')
}

function New-AccessMappings {
    $mappings = @(
        [pscustomobject]@{ name = 'security-audit'; entraGroupSuffix = 'SecurityAudit'; permissionSet = 'SecurityAudit'; accountIds = @('all-active-accounts') },
        [pscustomobject]@{ name = 'billing-read-only'; entraGroupSuffix = 'BillingReadOnly'; permissionSet = 'BillingReadOnly'; accountIds = @('all-active-accounts') }
    )
    if ($IncludeAdministratorAccess) {
        $mappings += [pscustomobject]@{ name = 'administrators'; entraGroupSuffix = 'Administrators'; permissionSet = 'AdministratorAccess'; accountIds = @('all-active-accounts') }
    }
    return $mappings
}

try {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'AWS CLI is required. Run Install-AwsEntraFederationPrerequisites.ps1 first.' }

    $profile = Get-ManagementProfile -RequestedProfile $ManagementProfile
    if (-not [string]::IsNullOrWhiteSpace($ManagementAccountId) -and $ManagementAccountId -ne $profile.AccountId) {
        throw "AWS profile '$($profile.Name)' resolved to account $($profile.AccountId), not the requested management account $ManagementAccountId."
    }
    $awsRegionValue = if ([string]::IsNullOrWhiteSpace($AwsRegion)) { Get-ConfiguredRegion -Profile $profile.Name } else { $AwsRegion }
    $identityCenterRegionValue = Get-IdentityCenterRegion -Profile $profile.Name -FallbackRegion $awsRegionValue
    $startUrlValue = Get-StartUrlValue -Profile $profile.Name
    $tenantValue = Get-TenantIdValue
    $clientValue = Get-GraphClientIdValue
    $thumbprintValue = Get-CertificateThumbprintValue

    if ([string]::IsNullOrWhiteSpace($GroupNamePrefix)) { throw 'GroupNamePrefix cannot be empty.' }
    if (-not (Test-Path -LiteralPath $MetadataDirectory -PathType Container)) {
        if ($Mode -eq 'Initialize') {
            New-Item -ItemType Directory -Path $MetadataDirectory -Force | Out-Null
        }
        else {
            Write-Output "Metadata directory will be created during Initialize: $MetadataDirectory"
        }
    }

    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'entra-aws-federation.example.json') -Raw | ConvertFrom-Json
    $config.aws.managementProfile = $profile.Name
    $config.aws.region = $awsRegionValue
    $config.aws.identityCenterRegion = $identityCenterRegionValue
    $config.aws.startUrl = $startUrlValue
    $config.aws.serviceProviderMetadataPath = Join-Path $MetadataDirectory 'aws-iam-identity-center-sp.xml'
    $config.entra.tenantId = $tenantValue
    $config.entra.clientId = $clientValue
    $config.entra.certificateThumbprint = $thumbprintValue
    $config.entra.groupNamePrefix = $GroupNamePrefix
    $config.entra.identityProviderMetadataPath = Join-Path $MetadataDirectory 'entra-idp-metadata.xml'
    $config.accessMappings = @(New-AccessMappings)

    $json = $config | ConvertTo-Json -Depth 20
    Write-Output "Management profile: $($profile.Name) ($($profile.AccountId))"
    Write-Output "AWS region: $awsRegionValue"
    Write-Output "Identity Center region: $identityCenterRegionValue"
    Write-Output "Start URL: $startUrlValue"
    Write-Output "Entra tenant: $tenantValue"
    Write-Output "Graph client ID: $clientValue"
    Write-Output "Certificate thumbprint: $thumbprintValue"
    Write-Output "Group prefix: $GroupNamePrefix"
    Write-Output "Metadata directory: $MetadataDirectory"
    Write-Output "Mappings: $(@($config.accessMappings | ForEach-Object { "$GroupNamePrefix-$($_.entraGroupSuffix)" }) -join ', ')"

    if ($Mode -eq 'Initialize') {
        if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and -not $Force) {
            throw "Configuration already exists at $ConfigPath. Use -Force only after reviewing the existing file."
        }
        $parent = Split-Path -Parent $ConfigPath
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -LiteralPath $ConfigPath -Value $json -Encoding UTF8
        Write-Output "Wrote local configuration: $ConfigPath"
        Write-Output 'The file is ignored by the repository pattern scripts/*.local.json; verify with git check-ignore before committing.'
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
