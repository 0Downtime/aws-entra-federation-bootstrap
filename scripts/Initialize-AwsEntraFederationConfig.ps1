#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Initialize')]
    [string]$Mode = 'Plan',

    [string]$ConfigPath,

    [string]$ManagementProfile,
    [string]$ManagementAccountId,
    [string]$AwsRegion,
    [string]$IdentityCenterRegion,
    [string]$StartUrl,
    [string]$TenantId,
    [string]$GraphClientId,
    [string]$GraphAutomationAppDisplayName = 'AWS Entra Federation Automation',
    [switch]$EnsureGraphApp,
    [switch]$ApproveGraphAppChange,
    [string]$CertificateThumbprint,
    [string]$CertificateSubjectPattern = 'AWS Entra Federation Automation',
    [ValidateRange(2, 3)]
    [int]$CertificateYears = 3,
    [string]$GroupNamePrefix = 'AWS',
    [string]$MetadataDirectory = 'C:\SecureBootstrap',
    [switch]$EnsureCertificate,
    [switch]$IncludeAdministratorAccess,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$env:AWS_PAGER = ''

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'entra-aws-federation.local.json'
}

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

function Invoke-AzJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join ' ')"
    }
    $raw = ($output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Invoke-AzJsonWithRetry {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 6)][int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-AzJson -Arguments $Arguments
        }
        catch {
            if ($attempt -eq $MaxAttempts) { throw }
            $delay = [int][Math]::Pow(2, $attempt - 1)
            Write-Host "Azure CLI operation was not ready; retrying in $delay second(s)..."
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-AzNoOutput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join ' ')"
    }
}

function Ensure-GraphAutomationApp {
    $graphResourceAppId = '00000003-0000-0000-c000-000000000000'
    $requiredPermissions = @(
        'Application.ReadWrite.All',
        'AppRoleAssignment.ReadWrite.All',
        'Group.Read.All',
        'Synchronization.ReadWrite.All'
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required for Graph app bootstrap. Run az login, then rerun Initialize.'
    }

    if ($Mode -eq 'Initialize' -and -not $ApproveGraphAppChange) {
        throw "Graph app bootstrap requires explicit approval. Re-run with -ApproveGraphAppChange. This will create or reuse '$GraphAutomationAppDisplayName', create its service principal, grant Graph application permissions [$($requiredPermissions -join ', ')], and request tenant-wide admin consent."
    }

    $app = $null
    if (-not [string]::IsNullOrWhiteSpace($GraphClientId)) {
        Write-Host "Loading the specified Graph app '$GraphClientId'..."
        $app = Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $GraphClientId, '--output', 'json')
    }
    else {
        Write-Host "Discovering Graph app '$GraphAutomationAppDisplayName'..."
        $apps = @(Invoke-AzJson -Arguments @('ad', 'app', 'list', '--display-name', $GraphAutomationAppDisplayName, '--output', 'json'))
        if ($apps.Count -gt 1) {
            throw "Multiple Entra app registrations named '$GraphAutomationAppDisplayName' were found. Supply -GraphClientId explicitly."
        }
        if ($apps.Count -eq 1) { $app = $apps[0] }
    }

    if ($null -eq $app) {
        if ($Mode -ne 'Initialize') {
            Write-Host "Plan: create Entra app '$GraphAutomationAppDisplayName'."
            return [pscustomobject]@{ AppId = '<graph-app-created-during-initialize>'; ObjectId = $null; RequiredPermissions = $requiredPermissions; Created = $true }
        }

        Write-Host "Creating Entra app '$GraphAutomationAppDisplayName'..."
        $app = Invoke-AzJson -Arguments @(
            'ad', 'app', 'create',
            '--display-name', $GraphAutomationAppDisplayName,
            '--sign-in-audience', 'AzureADMyOrg',
            '--output', 'json'
        )
    }

    $appId = [string]$app.appId
    if ([string]::IsNullOrWhiteSpace($appId)) { throw 'The Entra app response did not contain an appId.' }

    $servicePrincipal = $null
    try {
        $servicePrincipal = Invoke-AzJson -Arguments @('ad', 'sp', 'show', '--id', $appId, '--output', 'json')
    }
    catch {
        if ($Mode -ne 'Initialize') {
            Write-Host "Plan: create the service principal for app $appId."
        }
        else {
            Write-Host "Creating the service principal for app $appId..."
            $servicePrincipal = Invoke-AzJsonWithRetry -Arguments @('ad', 'sp', 'create', '--id', $appId, '--output', 'json')
        }
    }

    if ($Mode -ne 'Initialize') {
        try {
            $graphServicePrincipal = Invoke-AzJson -Arguments @('ad', 'sp', 'show', '--id', $graphResourceAppId, '--output', 'json')
            $roleNames = @($graphServicePrincipal.appRoles | Where-Object { $_.value -in $requiredPermissions -and $_.allowedMemberTypes -contains 'Application' } | ForEach-Object { [string]$_.value })
            $missingRoleNames = @($requiredPermissions | Where-Object { $_ -notin $roleNames })
            if ($missingRoleNames.Count -gt 0) { throw "Microsoft Graph does not expose the expected app roles: $($missingRoleNames -join ', ')." }
            Write-Host "Plan: ensure Graph application permissions [$($requiredPermissions -join ', ')] and tenant-wide admin consent."
        }
        catch {
            Write-Host "Plan: Graph permission discovery will run during Initialize ($($_.Exception.Message))."
        }
        return [pscustomobject]@{ AppId = $appId; ObjectId = [string]$app.id; RequiredPermissions = $requiredPermissions; Created = $false }
    }

    Write-Host 'Resolving Microsoft Graph application-role IDs...'
    $graphServicePrincipal = Invoke-AzJsonWithRetry -Arguments @('ad', 'sp', 'show', '--id', $graphResourceAppId, '--output', 'json')
    $roles = @($graphServicePrincipal.appRoles | Where-Object { $_.value -in $requiredPermissions -and $_.allowedMemberTypes -contains 'Application' } | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.value; Id = [string]$_.id }
    })
    $missingRoleNames = @($requiredPermissions | Where-Object { $_ -notin @($roles | Select-Object -ExpandProperty Name) })
    if ($missingRoleNames.Count -gt 0) {
        throw "Microsoft Graph did not expose these application roles: $($missingRoleNames -join ', ')."
    }

    $permissionRequests = $null
    try {
        $permissionRequests = @(Invoke-AzJson -Arguments @('ad', 'app', 'permission', 'list', '--id', $appId, '--output', 'json'))
    }
    catch {
        $permissionRequests = @()
    }
    $existingResourceAccess = @($permissionRequests | Where-Object { [string]$_.resourceAppId -eq $graphResourceAppId } | ForEach-Object { @($_.resourceAccess) })
    $missingRoles = @($roles | Where-Object { $roleId = [string]$_.Id; $existingResourceAccess.id -notcontains $roleId })

    if ($missingRoles.Count -gt 0) {
        $permissionArguments = @('ad', 'app', 'permission', 'add', '--id', $appId, '--api', $graphResourceAppId, '--api-permissions')
        $permissionArguments += @($missingRoles | ForEach-Object { "{0}=Role" -f $_.Id })
        $permissionArguments += @('--output', 'none')
        Write-Host "Adding missing Graph application permissions: $($missingRoles.Name -join ', ')..."
        Invoke-AzNoOutput -Arguments $permissionArguments
    }
    else {
        Write-Host 'All required Graph application permissions are already requested.'
    }

    Write-Host 'Granting tenant-wide admin consent for the Graph application permissions...'
    Invoke-AzNoOutput -Arguments @('ad', 'app', 'permission', 'admin-consent', '--id', $appId, '--output', 'none')
    Write-Host "Graph app bootstrap complete. Client ID: $appId"
    return [pscustomobject]@{ AppId = $appId; ObjectId = [string]$app.id; RequiredPermissions = $requiredPermissions; Created = $false }
}

function Get-ManagementProfile {
    param([string]$RequestedProfile)

    if (-not [string]::IsNullOrWhiteSpace($RequestedProfile)) {
        Write-Host "Validating AWS management profile '$RequestedProfile'..."
        $identity = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity', '--profile', $RequestedProfile, '--output', 'json')
        return [pscustomobject]@{ Name = $RequestedProfile; AccountId = [string]$identity.Account }
    }

    Write-Host 'Discovering AWS profiles with Organizations access...'
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

    if (-not [string]::IsNullOrWhiteSpace($IdentityCenterRegion)) {
        Write-Host "Using configured IAM Identity Center region '$IdentityCenterRegion'."
        return $IdentityCenterRegion
    }

    Write-Host 'Searching AWS regions for the IAM Identity Center instance...'
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
        Write-Host "  Checking $region..."
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

    if (-not [string]::IsNullOrWhiteSpace($StartUrl)) {
        Write-Host 'Using configured IAM Identity Center start URL.'
        return $StartUrl
    }
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
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        Write-Host 'Using configured Entra tenant ID.'
        return $TenantId
    }
    Write-Host 'Discovering Entra tenant ID...'
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $tenant = Read-OptionalCommandOutput -Command 'az' -Arguments @('account', 'show', '--query', 'tenantId', '--output', 'tsv')
        if (-not [string]::IsNullOrWhiteSpace($tenant)) { return $tenant }
    }
    return (Read-Host 'Microsoft Entra tenant ID')
}

function Get-GraphClientIdValue {
    if ($EnsureGraphApp) {
        $graphApp = Ensure-GraphAutomationApp
        return [string]$graphApp.AppId
    }
    if (-not [string]::IsNullOrWhiteSpace($GraphClientId)) {
        Write-Host 'Using configured Graph automation client ID.'
        return $GraphClientId
    }
    Write-Host "Discovering Graph app '$GraphAutomationAppDisplayName'..."
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
    param([string]$ResolvedGraphClientId)

    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        Write-Host 'Using configured certificate thumbprint.'
        return $CertificateThumbprint
    }
    Write-Host "Searching the Windows certificate stores for '$CertificateSubjectPattern'..."

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
    if ($EnsureCertificate) {
        if ($Mode -ne 'Initialize') {
            Write-Host "No matching certificate was found; Initialize will create a $CertificateYears-year certificate and append its public key to the Entra app."
            return '<certificate-created-during-initialize>'
        }
        if (-not (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
            throw 'New-SelfSignedCertificate is unavailable. Run this initializer on Windows PowerShell or PowerShell 7 on Windows.'
        }
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required to append the public certificate to the Entra app. Run az login, then rerun Initialize.'
        }
        if ([string]::IsNullOrWhiteSpace($ResolvedGraphClientId) -or $ResolvedGraphClientId -like '<*') {
            throw 'GraphClientId is required to register the generated certificate.'
        }

        Write-Host "Creating a $CertificateYears-year certificate in Cert:\CurrentUser\My..."
        $certificate = New-SelfSignedCertificate `
            -Subject "CN=$CertificateSubjectPattern" `
            -FriendlyName $CertificateSubjectPattern `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -KeySpec Signature `
            -NotAfter (Get-Date).AddYears($CertificateYears)

        $pemPath = Join-Path $env:TEMP ("aws-entra-graph-{0}.pem" -f ([guid]::NewGuid().ToString('N')))
        try {
            $base64 = [Convert]::ToBase64String($certificate.RawData)
            $lines = for ($offset = 0; $offset -lt $base64.Length; $offset += 64) {
                $length = [Math]::Min(64, $base64.Length - $offset)
                $base64.Substring($offset, $length)
            }
            $pem = "-----BEGIN CERTIFICATE-----`r`n$($lines -join "`r`n")`r`n-----END CERTIFICATE-----`r`n"
            Set-Content -LiteralPath $pemPath -Value $pem -Encoding ASCII

            Write-Host 'Appending the public certificate to the Entra app without removing existing credentials...'
            & az ad app credential reset `
                --id $ResolvedGraphClientId `
                --cert "@$pemPath" `
                --append `
                --years $CertificateYears `
                --display-name $CertificateSubjectPattern `
                --output none
            if ($LASTEXITCODE -ne 0) {
                throw 'Azure CLI could not append the certificate. Verify az login and that the signed-in identity can manage credentials on the app registration.'
            }
        }
        finally {
            Remove-Item -LiteralPath $pemPath -Force -ErrorAction SilentlyContinue
        }
        return ([string]$certificate.Thumbprint).Replace(' ', '').ToUpperInvariant()
    }
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
    $thumbprintValue = Get-CertificateThumbprintValue -ResolvedGraphClientId $clientValue

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
