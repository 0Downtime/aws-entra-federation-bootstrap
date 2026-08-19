#requires -Version 7.2

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Validate', 'Plan', 'PrepareMetadata', 'Apply', 'RotateScimToken')]
    [string]$Mode = 'Validate',

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [string]$AwsServiceProviderMetadataPath,
    [string]$EntraIdentityProviderMetadataPath,
    [string]$ScimEndpoint,
    [System.Security.SecureString]$ScimToken,
    [switch]$ApproveIdentitySourceChange,
    [switch]$EnsureEntraMetadata,
    [switch]$ApplyTerraform,
    [switch]$ForceManagedProfiles,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:AWS_PAGER = ''

$script:SecretStorePath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AwsEntraFederation'
$script:Result = [ordered]@{
    status = 'NotStarted'
    mode = $Mode
    aws = [ordered]@{}
    entra = [ordered]@{}
    assignments = @()
    profiles = @()
    warnings = @()
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        $dictionaryValue = $Object[$Name]
        if ($null -eq $dictionaryValue) {
            return $Default
        }
        return $dictionaryValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Require-Value {
    param([string]$Name, $Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Configuration value '$Name' is required."
    }
}

function Read-FederationConfig {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $aws = Get-ConfigValue -Object $config -Name 'aws'
    $entra = Get-ConfigValue -Object $config -Name 'entra'
    $mappings = @(Get-ConfigValue -Object $config -Name 'accessMappings' -Default @())

    if ($null -eq $aws) { throw "The configuration must contain an 'aws' object." }
    if ($null -eq $entra) { throw "The configuration must contain an 'entra' object." }
    if ($mappings.Count -eq 0) { throw "The configuration must contain at least one accessMappings entry." }

    foreach ($name in @('managementProfile', 'region', 'identityCenterRegion', 'startUrl', 'managedProfilePrefix')) {
        Require-Value -Name "aws.$name" -Value (Get-ConfigValue -Object $aws -Name $name)
    }

    foreach ($name in @('tenantId', 'clientId', 'certificateThumbprint', 'applicationDisplayName')) {
        Require-Value -Name "entra.$name" -Value (Get-ConfigValue -Object $entra -Name $name)
    }

    $groupNamePrefix = [string](Get-ConfigValue -Object $entra -Name 'groupNamePrefix' -Default 'AWS')
    $hasGroupSuffixMapping = @($mappings | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-ConfigValue -Object $_ -Name 'entraGroupSuffix'))
    }).Count -gt 0
    if ($hasGroupSuffixMapping) {
        Require-Value -Name 'entra.groupNamePrefix' -Value $groupNamePrefix
    }

    $seenMappingNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalizedMappings = [Collections.Generic.List[object]]::new()

    foreach ($mapping in $mappings) {
        $mappingName = [string](Get-ConfigValue -Object $mapping -Name 'name')
        $groupName = [string](Get-ConfigValue -Object $mapping -Name 'entraGroup')
        $groupSuffix = [string](Get-ConfigValue -Object $mapping -Name 'entraGroupSuffix')
        $permissionSet = [string](Get-ConfigValue -Object $mapping -Name 'permissionSet')
        $accountIds = @(Get-ConfigValue -Object $mapping -Name 'accountIds' -Default @())

        if (-not [string]::IsNullOrWhiteSpace($groupName) -and -not [string]::IsNullOrWhiteSpace($groupSuffix)) {
            throw "Access mapping '$mappingName' must use either entraGroup or entraGroupSuffix, not both."
        }
        if ([string]::IsNullOrWhiteSpace($groupName) -and -not [string]::IsNullOrWhiteSpace($groupSuffix)) {
            $groupName = "$groupNamePrefix-$groupSuffix"
        }

        Require-Value -Name 'accessMappings[].name' -Value $mappingName
        Require-Value -Name "accessMappings[$mappingName].entraGroup or entraGroupSuffix" -Value $groupName
        Require-Value -Name "accessMappings[$mappingName].permissionSet" -Value $permissionSet
        if (-not $seenMappingNames.Add($mappingName)) {
            throw "Duplicate access mapping name '$mappingName'."
        }
        if ($accountIds.Count -eq 0) {
            throw "Access mapping '$mappingName' must contain at least one accountIds entry."
        }
        if ($permissionSet -notin @('SecurityAudit', 'BillingReadOnly', 'AdministratorAccess')) {
            throw "Access mapping '$mappingName' uses unsupported permission set '$permissionSet'. Supported values are SecurityAudit, BillingReadOnly, and AdministratorAccess."
        }

        $normalizedMappings.Add([pscustomobject]@{
            Name = $mappingName
            EntraGroup = $groupName
            PermissionSet = $permissionSet
            AccountIds = @($accountIds | ForEach-Object { [string]$_ })
        })
    }

    return [pscustomobject]@{
        Aws = $aws
        Entra = $entra
        AccessMappings = @($normalizedMappings)
    }
}

function Invoke-AwsCli {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw 'AWS CLI was not found. Install AWS CLI v2 for Windows first.'
    }

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $safeOutput = ($output -join "`n") -replace '(?i)(token|secret|password|authorization)[^\r\n]*', '$1=<redacted>'
        throw "AWS CLI failed:`n$safeOutput"
    }

    return $output
}

function Invoke-AwsJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $json = (Invoke-AwsCli -Arguments ($Arguments + @('--output', 'json'))) -join "`n"
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    return $json | ConvertFrom-Json
}

function Invoke-AwsPreflight {
    param($Config)

    $managementProfile = [string]$Config.Aws.managementProfile
    $region = [string]$Config.Aws.region
    $identityCenterRegion = [string]$Config.Aws.identityCenterRegion

    Write-Information "Checking AWS profile '$managementProfile'..." -InformationAction Continue
    $caller = Invoke-AwsJson -Arguments @('sts', 'get-caller-identity', '--profile', $managementProfile, '--region', $region)
    $organization = Invoke-AwsJson -Arguments @('organizations', 'describe-organization', '--profile', $managementProfile, '--region', $region)
    $instances = Invoke-AwsJson -Arguments @('sso-admin', 'list-instances', '--profile', $managementProfile, '--region', $identityCenterRegion)

    if ($null -eq $caller.Account) { throw 'AWS caller identity did not contain an account ID.' }
    if ($null -eq $organization.Organization.Id) { throw 'The selected AWS profile cannot describe an AWS Organization.' }

    $organizationInstance = @($instances.Instances | Where-Object {
        $_.OwnerAccountId -eq $caller.Account -and $_.Status -eq 'ACTIVE'
    })

    if ($organizationInstance.Count -eq 0) {
        throw "No active IAM Identity Center instance was found in account $($caller.Account) and region $identityCenterRegion. Enable an organization instance before running this script."
    }
    if ($organizationInstance.Count -gt 1) {
        throw 'More than one active IAM Identity Center instance was returned; refuse to guess.'
    }

    $instance = $organizationInstance[0]
    $script:Result.aws = [ordered]@{
        accountId = [string]$caller.Account
        organizationId = [string]$organization.Organization.Id
        profile = $managementProfile
        region = $region
        identityCenterRegion = $identityCenterRegion
        instanceArn = [string]$instance.InstanceArn
        identityStoreId = [string]$instance.IdentityStoreId
        identitySourceBootstrapRequired = $true
    }

    return [pscustomobject]@{
        Caller = $caller
        Organization = $organization.Organization
        Instance = $instance
    }
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Value)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Save-ScimSecret {
    param([Parameter(Mandatory = $true)][string]$Endpoint, [Parameter(Mandatory = $true)][System.Security.SecureString]$Token)

    if (-not $IsWindows) {
        throw 'SCIM secret persistence requires Windows DPAPI. Run this script on the intended Windows host.'
    }

    New-Item -ItemType Directory -Path $script:SecretStorePath -Force | Out-Null
    $secretPath = Join-Path $script:SecretStorePath 'scim.dpapi.txt'
    $payload = [pscustomobject]@{
        endpoint = $Endpoint
        token = ($Token | ConvertFrom-SecureString)
    } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $secretPath -Value $payload -Encoding utf8NoBOM

    $acl = Get-Acl -LiteralPath $secretPath
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'Read,Write', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $secretPath -AclObject $acl

    return $secretPath
}

function Read-ScimSecret {
    $secretPath = Join-Path $script:SecretStorePath 'scim.dpapi.txt'
    if (-not (Test-Path -LiteralPath $secretPath)) { return $null }

    $payload = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json
    $secure = $payload.token | ConvertTo-SecureString
    return [pscustomobject]@{
        Endpoint = [string]$payload.endpoint
        Token = $secure
    }
}

function Resolve-ScimBootstrap {
    if ($Mode -eq 'RotateScimToken' -and ($null -eq $ScimToken)) {
        $ScimToken = Read-Host 'Enter the new AWS IAM Identity Center SCIM token' -AsSecureString
    }

    $stored = Read-ScimSecret
    $endpoint = if ($ScimEndpoint) { $ScimEndpoint } elseif ($stored) { $stored.Endpoint } else { $null }
    $secureToken = if ($ScimToken) { $ScimToken } elseif ($stored) { $stored.Token } else { $null }
    $token = if ($secureToken) { Convert-SecureStringToPlainText -Value $secureToken } else { $null }

    if ($Mode -in @('Plan', 'Apply', 'RotateScimToken')) {
        Require-Value -Name 'SCIM endpoint' -Value $endpoint
        Require-Value -Name 'SCIM token' -Value $token
    }

    if ($Mode -eq 'RotateScimToken' -or ($ScimToken -and $endpoint)) {
        if ($Mode -in @('Apply', 'RotateScimToken')) {
            Save-ScimSecret -Endpoint $endpoint -Token $secureToken | Out-Null
        }
    }

    return [pscustomobject]@{ Endpoint = $endpoint; Token = $token }
}

function Read-AndValidateMetadata {
    param([string]$Path, [string]$Kind)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Kind metadata file was not found: $Path"
    }

    try {
        $xml = [xml](Get-Content -LiteralPath $Path -Raw)
    }
    catch {
        throw "$Kind metadata is not valid XML: $($_.Exception.Message)"
    }

    $entity = [string]((Select-Xml -Xml $xml -XPath "/*[local-name()='EntityDescriptor']/@entityID").Node.Value)
    $acs = @(Select-Xml -Xml $xml -XPath "//*[local-name()='AssertionConsumerService']/@Location" | ForEach-Object { [string]$_.Node.Value })
    $ssoServices = @(Select-Xml -Xml $xml -XPath "//*[local-name()='SingleSignOnService']/@Location" | ForEach-Object { [string]$_.Node.Value })
    $certificates = @(Select-Xml -Xml $xml -XPath "//*[local-name()='X509Certificate']" | ForEach-Object { ([string]$_.Node.InnerText) -replace '\s', '' } | Where-Object { $_ })
    if ([string]::IsNullOrWhiteSpace([string]$entity) -and $Kind -eq 'AWS service-provider') {
        throw 'AWS service-provider metadata did not contain an entityID.'
    }
    if ($Kind -eq 'AWS service-provider' -and $acs.Count -eq 0) {
        throw 'AWS service-provider metadata did not contain an AssertionConsumerService URL.'
    }
    if ($Kind -eq 'Entra identity-provider' -and $ssoServices.Count -eq 0) {
        throw 'Entra identity-provider metadata did not contain a SingleSignOnService URL.'
    }
    if ($Kind -eq 'Entra identity-provider' -and $certificates.Count -eq 0) {
        throw 'Entra identity-provider metadata did not contain a public X.509 signing certificate. Re-download the active SAML federation metadata after enabling SAML signing in Entra.'
    }

    $certificateThumbprints = [Collections.Generic.List[string]]::new()
    foreach ($encodedCertificate in $certificates) {
        try {
            $certificateBytes = [Convert]::FromBase64String($encodedCertificate)
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
            $certificateThumbprints.Add(($certificate.Thumbprint -replace '\s', '').ToUpperInvariant())
        }
        catch {
            throw "$Kind metadata contained an invalid X.509 signing certificate: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $Path).Path
        EntityId = [string]$entity
        AssertionConsumerServices = @($acs)
        SingleSignOnServices = @($ssoServices)
        SigningCertificateThumbprints = @($certificateThumbprints)
    }
}

function Connect-EntraGraph {
    param($Config)

    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is required. Install-Module Microsoft.Graph -Scope CurrentUser.'
    }
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication does not provide Invoke-MgGraphRequest.'
    }

    Connect-MgGraph -TenantId ([string]$Config.Entra.tenantId) `
        -ClientId ([string]$Config.Entra.clientId) `
        -CertificateThumbprint ([string]$Config.Entra.certificateThumbprint) `
        -NoWelcome | Out-Null
}

function Invoke-GraphRequest {
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        $Body = $null
    )

    $attempt = 0
    do {
        try {
            $params = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
            if ($null -ne $Body) {
                $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
                $params.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @params
        }
        catch {
            $attempt++
            if ($attempt -ge 4) { throw }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    } while ($attempt -lt 4)
}

function Get-GraphCollection {
    param([string]$Uri)

    $items = [Collections.Generic.List[object]]::new()
    do {
        $page = Invoke-GraphRequest -Method GET -Uri $Uri
        @($page.value) | ForEach-Object { $items.Add($_) }
        $Uri = [string](Get-ConfigValue -Object $page -Name '@odata.nextLink')
    } while (-not [string]::IsNullOrWhiteSpace($Uri))
    return @($items)
}

function Get-GraphResourceId {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $id = [string](Get-ConfigValue -Object $Object -Name 'id')
    if ([string]::IsNullOrWhiteSpace($id)) {
        $additional = $Object.PSObject.Properties['AdditionalProperties']
        if ($null -ne $additional -and $additional.Value -is [Collections.IDictionary] -and $additional.Value.Contains('id')) {
            $id = [string]$additional.Value['id']
        }
    }
    if ([string]::IsNullOrWhiteSpace($id)) {
        $properties = @($Object.PSObject.Properties.Name) -join ', '
        throw "Graph did not return an id for $Description. Returned properties: $properties"
    }
    return $id
}

function Normalize-GraphServicePrincipal {
    param([Parameter(Mandatory = $true)]$ServicePrincipal)

    $id = Get-GraphResourceId -Object $ServicePrincipal -Description 'the Entra service principal'
    $idProperty = $ServicePrincipal.PSObject.Properties['id']
    if ($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
        $ServicePrincipal | Add-Member -MemberType NoteProperty -Name id -Value $id -Force
    }
    return $ServicePrincipal
}

function Ensure-EntraApplicationSamlUrls {
    param(
        [Parameter(Mandatory = $true)]$ServicePrincipal,
        [Parameter(Mandatory = $true)]$AwsMetadata
    )

    $appId = [string](Get-ConfigValue -Object $ServicePrincipal -Name 'appId')
    if ([string]::IsNullOrWhiteSpace($appId)) {
        throw 'The AWS Entra service principal did not expose its application ID; cannot configure SAML URLs.'
    }

    $encodedAppId = [uri]::EscapeDataString($appId)
    $applications = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId%20eq%20'$encodedAppId'&`$select=id,appId,identifierUris,web")
    if ($applications.Count -ne 1) {
        throw "Expected exactly one Entra application object for appId $appId; found $($applications.Count)."
    }

    $application = $applications[0]
    $applicationObjectId = Get-GraphResourceId -Object $application -Description "the AWS Entra application object for appId $appId"
    $entityId = [string]$AwsMetadata.EntityId
    $requiredRedirectUris = @($AwsMetadata.AssertionConsumerServices | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
    if ([string]::IsNullOrWhiteSpace($entityId) -or $requiredRedirectUris.Count -eq 0) {
        throw 'AWS service-provider metadata did not contain the SAML entity ID and at least one ACS URL required to configure the Entra application.'
    }

    $existingIdentifierUris = @(Get-ConfigValue -Object $application -Name 'identifierUris' -Default @() | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $identifierUris = [Collections.Generic.List[string]]::new()
    foreach ($uri in $existingIdentifierUris) {
        $identifierUris.Add($uri)
    }
    if (-not $identifierUris.Contains($entityId)) { $identifierUris.Add($entityId) }

    $web = Get-ConfigValue -Object $application -Name 'web' -Default ([pscustomobject]@{})
    $existingWebRedirectUris = @(Get-ConfigValue -Object $web -Name 'redirectUris' -Default @() | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $redirectUris = [Collections.Generic.List[string]]::new()
    foreach ($uri in $existingWebRedirectUris) {
        $redirectUris.Add($uri)
    }
    foreach ($uri in $requiredRedirectUris) {
        if (-not $redirectUris.Contains($uri)) { $redirectUris.Add($uri) }
    }

    $identifierChanged = $entityId -notin $existingIdentifierUris
    $redirectChanged = @($requiredRedirectUris | Where-Object { $_ -notin $existingWebRedirectUris }).Count -gt 0
    $needsUpdate = $identifierChanged -or $redirectChanged
    if ($Mode -notin @('Plan', 'Validate') -and $needsUpdate) {
        $webPatch = [ordered]@{}
        if ($web -is [Collections.IDictionary]) {
            foreach ($key in $web.Keys) {
                if ([string]$key -ne 'redirectUris' -and $null -ne $web[$key]) {
                    $webPatch[[string]$key] = $web[$key]
                }
            }
        }
        else {
            foreach ($property in @($web.PSObject.Properties)) {
                if ($property.Name -notin @('redirectUris', 'AdditionalProperties') -and $null -ne $property.Value) {
                    $webPatch[$property.Name] = $property.Value
                }
            }
            $additionalWebProperties = $web.PSObject.Properties['AdditionalProperties']
            if ($null -ne $additionalWebProperties -and $additionalWebProperties.Value -is [Collections.IDictionary]) {
                foreach ($key in $additionalWebProperties.Value.Keys) {
                    if ([string]$key -ne 'redirectUris' -and -not $webPatch.Contains([string]$key) -and $null -ne $additionalWebProperties.Value[$key]) {
                        $webPatch[[string]$key] = $additionalWebProperties.Value[$key]
                    }
                }
            }
        }
        $webPatch.redirectUris = @($redirectUris)
        Invoke-GraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$applicationObjectId" -Body @{
            identifierUris = @($identifierUris)
            web = $webPatch
        } | Out-Null
    }

    $script:Result.entra.applicationObjectId = $applicationObjectId
    $script:Result.entra.samlUrls = [ordered]@{
        identifierUri = $entityId
        redirectUriCount = $redirectUris.Count
        status = if ($needsUpdate -and $Mode -notin @('Plan', 'Validate')) { 'merged' } elseif ($needsUpdate) { 'planned' } else { 'existing' }
    }
}

function Resolve-EntraApplication {
    param($Config, $AwsMetadata)

    $name = [string]$Config.Entra.applicationDisplayName
    $encodedName = [uri]::EscapeDataString($name.Replace("'", "''"))
    $servicePrincipals = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=displayName%20eq%20'$encodedName'&`$select=id,appId,displayName,preferredSingleSignOnMode,replyUrls,appRoles,appRoleAssignmentRequired")
    if ($servicePrincipals.Count -gt 1) {
        throw "More than one Entra service principal named '$name' was found; refuse to guess. Set applicationTemplateId and remove the duplicate or supply a unique application name."
    }
    $servicePrincipal = $servicePrincipals | Select-Object -First 1

    if ($null -eq $servicePrincipal) {
        $templateId = [string](Get-ConfigValue -Object $Config.Entra -Name 'applicationTemplateId')
        if ([string]::IsNullOrWhiteSpace($templateId)) {
            $templateNames = [Collections.Generic.List[string]]::new()
            $templateNames.Add($name)
            if ($name -eq 'AWS IAM Identity Center') {
                $templateNames.Add('AWS IAM Identity Center (successor to AWS Single Sign-On)')
            }

            $templates = [Collections.Generic.List[object]]::new()
            foreach ($templateName in $templateNames) {
                $encodedTemplateName = [uri]::EscapeDataString($templateName.Replace("'", "''"))
                @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/applicationTemplates?`$filter=displayName%20eq%20'$encodedTemplateName'&`$select=id,displayName,supportedProvisioningTypes,supportedSingleSignOnModes") |
                    ForEach-Object { $templates.Add($_) }
            }

            $template = $templates |
                Where-Object {
                    @($_.supportedSingleSignOnModes) -contains 'saml' -and
                    (@($_.supportedProvisioningTypes).Count -eq 0 -or @($_.supportedProvisioningTypes) -contains 'sync')
                } |
                Sort-Object @{ Expression = { if ($_.displayName -like '*successor*') { 0 } else { 1 } } }, displayName |
                Select-Object -First 1
            $templateId = [string]$template.id
        }
        if ([string]::IsNullOrWhiteSpace($templateId)) {
            throw "The Entra application '$name' was not found and no gallery application template was found. Set entra.applicationTemplateId or instantiate the gallery application once."
        }
        if ($Mode -in @('Plan', 'Validate')) {
            return [pscustomobject]@{ Planned = $true; DisplayName = $name; TemplateId = $templateId }
        }
        $servicePrincipal = Invoke-GraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/applicationTemplates/$templateId/instantiate" -Body @{ displayName = $name }
        if ($servicePrincipal.PSObject.Properties.Name -contains 'servicePrincipal') {
            $servicePrincipal = $servicePrincipal.servicePrincipal
        }
    }

    $servicePrincipal = Normalize-GraphServicePrincipal -ServicePrincipal $servicePrincipal

    if ($null -ne $AwsMetadata) {
        Ensure-EntraApplicationSamlUrls -ServicePrincipal $servicePrincipal -AwsMetadata $AwsMetadata
    }
    $patch = @{ preferredSingleSignOnMode = 'saml' }
    if ($Mode -notin @('Plan', 'Validate')) {
        Invoke-GraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipal.id)" -Body $patch | Out-Null
    }

    $script:Result.entra = [ordered]@{
        applicationDisplayName = $name
        servicePrincipalId = [string]$servicePrincipal.id
        applicationId = [string]$servicePrincipal.appId
        preferredSingleSignOnMode = 'saml'
        provisioning = 'planned'
    }
    return $servicePrincipal
}

function Ensure-EntraSamlSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$ServicePrincipal
    )

    $select = [uri]::EscapeDataString('preferredTokenSigningKeyThumbprint,keyCredentials')
    $state = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)?`$select=$select"
    # Graph PowerShell returns a typed service-principal model here. Read the
    # property directly instead of treating it as a JSON configuration object.
    $activeThumbprint = [string]$state.preferredTokenSigningKeyThumbprint
    if (-not [string]::IsNullOrWhiteSpace($activeThumbprint)) {
        $script:Result.entra.signingCertificate = [ordered]@{
            status = 'active'
            thumbprint = $activeThumbprint.ToUpperInvariant()
            keyCredentialCount = @($state.keyCredentials).Count
        }
        return $activeThumbprint
    }

    if ($Mode -in @('Validate', 'Plan')) {
        $script:Result.entra.signingCertificate = [ordered]@{
            status = 'missing'
            remediation = 'Create and activate an Entra SAML signing certificate, then refresh the IdP metadata XML.'
        }
        if ($Mode -eq 'Validate') {
            throw 'The Entra enterprise application has no active SAML signing certificate. Enable SAML signing in Entra, then refresh the IdP metadata XML.'
        }
        return $null
    }

    $certificate = Invoke-GraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/addTokenSigningCertificate" -Body @{
        displayName = "CN=$($Config.Entra.applicationDisplayName)"
        endDateTime = (Get-Date).ToUniversalTime().AddYears(3).ToString('o')
    }
    $newThumbprint = [string](Get-ConfigValue -Object $certificate -Name 'thumbprint')
    if ([string]::IsNullOrWhiteSpace($newThumbprint)) {
        throw 'Microsoft Graph did not return a thumbprint for the new Entra SAML signing certificate.'
    }

    Invoke-GraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)" -Body @{
        preferredTokenSigningKeyThumbprint = $newThumbprint
    } | Out-Null

    $script:Result.entra.signingCertificate = [ordered]@{
        status = 'created-and-activated'
        thumbprint = $newThumbprint.ToUpperInvariant()
        metadataRefreshRequired = $true
    }
    return $newThumbprint
}

function Ensure-EntraIdentityProviderMetadata {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$ServicePrincipal,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$ServicePrincipal.appId)) {
        throw 'The AWS Entra enterprise application did not expose an application ID for federation metadata retrieval.'
    }

    $metadataUri = "https://login.microsoftonline.com/$($Config.Entra.tenantId)/federationmetadata/2007-06/federationmetadata.xml?appid=$($ServicePrincipal.appId)"
    if ($Mode -in @('Validate', 'Plan')) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return Read-AndValidateMetadata -Path $Path -Kind 'Entra identity-provider'
        }
        if ($Mode -eq 'Plan') {
            $script:Result.warnings += "Entra identity-provider metadata would be downloaded to $Path from the tenant federation metadata endpoint."
            return $null
        }
        throw "Entra identity-provider metadata was not found: $Path. Rerun Apply with -EnsureEntraMetadata after the SAML application and signing certificate are configured."
    }

    if (-not $EnsureEntraMetadata) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return Read-AndValidateMetadata -Path $Path -Kind 'Entra identity-provider'
        }
        throw "Entra identity-provider metadata was not found: $Path. Rerun Apply with -EnsureEntraMetadata to download it automatically."
    }

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporaryPath = Join-Path $env:TEMP ("entra-idp-metadata-{0}.xml" -f ([guid]::NewGuid().ToString('N')))
    try {
        Write-Information "Downloading Entra identity-provider metadata for '$($Config.Entra.applicationDisplayName)'..." -InformationAction Continue
        $metadata = $null
        $downloadError = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Invoke-WebRequest -Uri $metadataUri -OutFile $temporaryPath -ErrorAction Stop
                $metadata = Read-AndValidateMetadata -Path $temporaryPath -Kind 'Entra identity-provider'
                break
            }
            catch {
                $downloadError = $_.Exception
                if ($attempt -eq 5) { throw }
                $delay = [int][Math]::Pow(2, $attempt - 1)
                Write-Information "Entra metadata is not ready yet; retrying in $delay second(s)..." -InformationAction Continue
                Start-Sleep -Seconds $delay
            }
        }
        if ($null -eq $metadata) {
            throw $downloadError
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        $metadata.Path = (Resolve-Path -LiteralPath $Path).Path
        $script:Result.entra.identityProviderMetadata = [ordered]@{
            path = $metadata.Path
            source = $metadataUri
            singleSignOnServiceCount = @($metadata.SingleSignOnServices).Count
            refreshed = $true
        }
        return $metadata
    }
    catch {
        throw "Could not download or validate Entra identity-provider metadata from ${metadataUri}: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-EntraGroups {
    param($Config)

    $resolved = [Collections.Generic.List[object]]::new()
    foreach ($mapping in $Config.AccessMappings) {
        $name = [string]$mapping.EntraGroup
        $encodedName = [uri]::EscapeDataString($name.Replace("'", "''"))
        $groups = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName%20eq%20'$encodedName'&`$select=id,displayName,securityEnabled")
        if ($groups.Count -ne 1) {
            throw "Expected exactly one Entra group named '$name'; found $($groups.Count)."
        }
        $resolved.Add([pscustomobject]@{
            Mapping = $mapping
            Group = $groups[0]
        })
    }
    return @($resolved)
}

function Ensure-EntraGroupAssignments {
    param($ServicePrincipal, $ResolvedGroups)

    $appRole = @($ServicePrincipal.appRoles | Where-Object { $_.isEnabled -eq $true } | Select-Object -First 1)
    $appRoleId = if ($appRole.Count -eq 1) { [string]$appRole[0].id } else { '00000000-0000-0000-0000-000000000000' }
    $assignments = [Collections.Generic.List[object]]::new()

    foreach ($entry in $ResolvedGroups) {
        $group = $entry.Group
        # Some Microsoft Graph tenants reject principalId filtering on this relationship
        # (for example with EntitlementGrant-backed assignments). Fetch the relationship
        # once and compare GUIDs locally so reruns remain idempotent across tenants.
        $uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/appRoleAssignedTo"
        $existing = @(Get-GraphCollection -Uri $uri | Where-Object {
            [string]::Equals([string]$_.principalId, [string]$group.id, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($existing.Count -eq 0 -and $Mode -notin @('Plan', 'Validate')) {
            Invoke-GraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/appRoleAssignedTo" -Body @{
                principalId = [string]$group.id
                resourceId = [string]$ServicePrincipal.id
                appRoleId = $appRoleId
            } | Out-Null
        }
        $assignments.Add([pscustomobject]@{
            entraGroup = [string]$group.displayName
            entraGroupId = [string]$group.id
            awsGroupId = $null
            awsGroupStatus = 'pending'
            permissionSet = [string]$entry.Mapping.PermissionSet
            accountIds = @($entry.Mapping.AccountIds)
            applicationAssignment = if ($existing.Count -gt 0) { 'existing' } elseif ($Mode -eq 'Plan') { 'planned' } else { 'created' }
        })
    }

    $script:Result.assignments = @($assignments)
    return @($assignments)
}

function Configure-EntraProvisioning {
    param($ServicePrincipal, $Scim)

    if ($null -eq $ServicePrincipal.id) { return $null }

    if ($Mode -notin @('Plan', 'Validate')) {
        $secretBody = @{ value = @(
            @{ '@odata.type' = 'microsoft.graph.synchronizationSecretKeyStringValuePair'; key = 'BaseAddress'; value = $Scim.Endpoint },
            @{ '@odata.type' = 'microsoft.graph.synchronizationSecretKeyStringValuePair'; key = 'SecretToken'; value = $Scim.Token }
        ) }
        Invoke-GraphRequest -Method PUT -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/synchronization/secrets" -Body $secretBody | Out-Null
    }

    $jobs = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/synchronization/jobs")
    $job = $jobs | Select-Object -First 1
    $templates = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/synchronization/templates")
    $templateId = [string](Get-ConfigValue -Object $templates[0] -Name 'id')
    if ([string]::IsNullOrWhiteSpace($templateId) -and $null -ne $job) {
        # AWS-created jobs can expose the usable template only on the existing job,
        # while the service-principal templates collection is empty in some tenants.
        $templateId = [string](Get-ConfigValue -Object $job -Name 'templateId')
    }
    if ([string]::IsNullOrWhiteSpace($templateId)) {
        throw "No Microsoft Graph synchronization template or existing job template was found for service principal $($ServicePrincipal.id)."
    }

    if ($null -eq $job -and $Mode -eq 'Validate') {
        $script:Result.entra.provisioning = [ordered]@{
            status = 'missing'
            remediation = 'Complete Entra automatic provisioning setup and start the synchronization job.'
        }
        throw 'No Microsoft Graph synchronization job exists for the AWS enterprise application. Complete the Entra provisioning setup, then rerun Validate.'
    }

    if ($null -ne $job -and $Mode -eq 'Validate') {
        $jobState = [string](Get-ConfigValue -Object $job.schedule -Name 'state')
        if ($jobState -ne 'Active') {
            $script:Result.entra.provisioning = [ordered]@{
                status = if ([string]::IsNullOrWhiteSpace($jobState)) { 'inactive' } else { $jobState }
                jobId = [string]$job.id
                remediation = 'Start the Entra provisioning job and wait for a successful execution.'
            }
            throw "The Entra synchronization job is not Active (state: $jobState). Start provisioning, then rerun Validate."
        }

        $script:Result.entra.provisioning = [ordered]@{
            status = 'active'
            jobId = [string]$job.id
            templateId = [string](Get-ConfigValue -Object $job -Name 'templateId')
        }
        return $job
    }

    if ($null -eq $job -and $Mode -notin @('Plan', 'Validate')) {
        $job = Invoke-GraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/synchronization/jobs" -Body @{ templateId = $templateId }
    }
    if ($null -ne $job -and $Mode -notin @('Plan', 'Validate') -and (Get-ConfigValue -Object $job.schedule -Name 'state') -ne 'Active') {
        Invoke-GraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($ServicePrincipal.id)/synchronization/jobs/$($job.id)/start" | Out-Null
    }

    $script:Result.entra.provisioning = if ($Mode -eq 'Plan') {
        [ordered]@{ status = 'planned'; templateId = $templateId }
    } else {
        [ordered]@{ status = 'active'; jobId = [string]$job.id; templateId = $templateId }
    }
    return $job
}

function Resolve-AwsIdentityStoreGroups {
    param($Config, $Assignments)

    $identityStoreId = [string]$script:Result.aws.identityStoreId
    if ([string]::IsNullOrWhiteSpace($identityStoreId)) {
        throw 'IAM Identity Center identity store ID was not available from AWS preflight.'
    }

    $attempts = if ($Mode -eq 'Apply') { 6 } else { 1 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $groups = @((Invoke-AwsJson -Arguments @(
            'identitystore', 'list-groups',
            '--identity-store-id', $identityStoreId,
            '--profile', [string]$Config.Aws.managementProfile,
            '--region', [string]$Config.Aws.identityCenterRegion
        )).Groups)

        $unresolved = [Collections.Generic.List[object]]::new()
        foreach ($assignment in $Assignments) {
            $matches = @($groups | Where-Object {
                [string]::Equals([string]$_.DisplayName, [string]$assignment.entraGroup, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($matches.Count -gt 1) {
                throw "Multiple IAM Identity Center groups named '$($assignment.entraGroup)' were found; refuse to guess."
            }
            if ($matches.Count -eq 1) {
                $assignment.awsGroupId = [string]$matches[0].GroupId
                $assignment.awsGroupStatus = 'existing'
            }
            else {
                $assignment.awsGroupStatus = 'pending'
                $unresolved.Add($assignment)
            }
        }

        if ($unresolved.Count -eq 0) {
            $script:Result.assignments = @($Assignments)
            return $Assignments
        }
        if ($Mode -ne 'Apply' -or $attempt -eq $attempts) { break }

        Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
    }

    if ($Mode -ne 'Apply') {
        $script:Result.assignments = @($Assignments)
        return $Assignments
    }

    $missing = @($Assignments | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.awsGroupId) } | ForEach-Object { $_.entraGroup })
    throw "SCIM did not provision IAM Identity Center groups: $($missing -join ', '). Confirm the identity-source cutover and provisioning job, then rerun Apply."
}

function Resolve-AccountIds {
    param($Config, $Assignments)

    $activeAccounts = $null
    foreach ($assignment in $Assignments) {
        if ($assignment.accountIds -contains 'all-active-accounts') {
            if ($null -eq $activeAccounts) {
                $activeAccounts = @(Invoke-AwsJson -Arguments @('organizations', 'list-accounts', '--profile', $Config.Aws.managementProfile, '--region', $Config.Aws.region)).Accounts |
                    Where-Object { $_.Status -eq 'ACTIVE' } |
                    ForEach-Object { [string]$_.Id }
            }
            $assignment.accountIds = @($activeAccounts)
        }
    }
    return $Assignments
}

function Write-TerraformFederationVariables {
    param($Config, $Assignments)

    $path = Join-Path $PSScriptRoot '..\stages\02-governance\federation.auto.tfvars.json'
    $relative = [IO.Path]::GetFullPath($path)
    $payload = [ordered]@{
        sso_group_assignments = [ordered]@{}
    }
    foreach ($assignment in $Assignments) {
        if ([string]::IsNullOrWhiteSpace([string]$assignment.awsGroupId)) {
            throw "IAM Identity Center group ID for '$($assignment.entraGroup)' is not resolved. Do not write Terraform assignments until SCIM provisioning completes."
        }
        $payload.sso_group_assignments[$assignment.entraGroup] = [ordered]@{
            group_id = $assignment.awsGroupId
            permission_set = $assignment.permissionSet
            target_account_ids = @($assignment.accountIds)
        }
    }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $relative -Encoding utf8NoBOM
    return $relative
}

function Add-ManagedAwsCliProfiles {
    param($Config, $Assignments)

    $configPath = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE } else { Join-Path $HOME '.aws\config' }
    $configDirectory = Split-Path -Parent $configPath
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $existing = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw } else { '' }
    $prefix = [string]$Config.Aws.managedProfilePrefix
    $sessionName = "$prefix-session"
    $startMarker = "# BEGIN AWS ENTRA FEDERATION $prefix"
    $endMarker = "# END AWS ENTRA FEDERATION $prefix"
    $block = [Collections.Generic.List[string]]::new()
    $block.Add($startMarker)
    $block.Add('')
    $block.Add("[sso-session $sessionName]")
    $block.Add("sso_start_url = $($Config.Aws.startUrl)")
    $block.Add("sso_region = $($Config.Aws.identityCenterRegion)")
    $block.Add('sso_registration_scopes = sso:account:access')

    $profiles = [Collections.Generic.List[object]]::new()
    $seenProfiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in $Assignments) {
        foreach ($accountId in $assignment.accountIds) {
            $profileName = "$prefix-$accountId-$($assignment.permissionSet)".ToLowerInvariant()
            if (-not $seenProfiles.Add($profileName)) { continue }
            if ($Mode -in @('Apply', 'RotateScimToken') -and -not $ForceManagedProfiles -and $existing -match "(?m)^\[profile\s+$([regex]::Escape($profileName))\]\s*$") {
                throw "Managed AWS profile '$profileName' already exists. Use -ForceManagedProfiles only after reviewing its current settings."
            }
            $block.Add('')
            $block.Add("[profile $profileName]")
            $block.Add("sso_session = $sessionName")
            $block.Add("sso_account_id = $accountId")
            $block.Add("sso_role_name = $($assignment.permissionSet)")
            $block.Add("region = $($Config.Aws.region)")
            $block.Add('output = json')
            $profiles.Add([pscustomobject]@{
                name = $profileName
                accountId = [string]$accountId
                roleName = [string]$assignment.permissionSet
            })
        }
    }
    $block.Add('')
    $block.Add($endMarker)

    $pattern = "(?ms)^" + [regex]::Escape($startMarker) + '.*?^' + [regex]::Escape($endMarker) + '\s*'
    $updated = [regex]::Replace($existing, $pattern, '')
    $updated = $updated.TrimEnd() + "`r`n`r`n" + (($block -join "`r`n").TrimEnd()) + "`r`n"
    if ($Mode -notin @('Plan', 'Validate')) {
        if (Test-Path -LiteralPath $configPath) {
            Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
        }
        Set-Content -LiteralPath $configPath -Value $updated -Encoding utf8NoBOM
    }

    $script:Result.profiles = @($profiles)
    return @($profiles)
}

function Write-Result {
    param([string]$DefaultPath)

    $script:Result.status = 'Succeeded'
    $target = if ($OutputPath) { $OutputPath } else { $DefaultPath }
    if ($target) {
        $parent = Split-Path -Parent $target
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $script:Result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $target -Encoding utf8NoBOM
    }
    $script:Result | ConvertTo-Json -Depth 20
}

try {
    $config = Read-FederationConfig
    $bootstrap = Resolve-ScimBootstrap
    $aws = Invoke-AwsPreflight -Config $config

    $awsMetadataPath = if ($AwsServiceProviderMetadataPath) { $AwsServiceProviderMetadataPath } else { [string](Get-ConfigValue -Object $config.Aws -Name 'serviceProviderMetadataPath') }
    $entraMetadataPath = if ($EntraIdentityProviderMetadataPath) { $EntraIdentityProviderMetadataPath } else { [string](Get-ConfigValue -Object $config.Entra -Name 'identityProviderMetadataPath') }
    if ($Mode -in @('Validate', 'Plan', 'PrepareMetadata', 'Apply')) {
        Require-Value -Name 'AWS service-provider metadata path' -Value $awsMetadataPath
        Require-Value -Name 'Entra identity-provider metadata path' -Value $entraMetadataPath
    }
    if (-not (Test-Path -LiteralPath $awsMetadataPath -PathType Leaf)) {
        throw "AWS service-provider metadata was not found: $awsMetadataPath. Download it once from IAM Identity Center's external identity provider setup under Service provider metadata, then place it at this path. AWS does not expose this download through the public sso-admin API."
    }
    $awsMetadata = Read-AndValidateMetadata -Path $awsMetadataPath -Kind 'AWS service-provider'
    $entraMetadata = $null
    if (Test-Path -LiteralPath $entraMetadataPath -PathType Leaf) {
        $entraMetadata = Read-AndValidateMetadata -Path $entraMetadataPath -Kind 'Entra identity-provider'
    }

    if ($Mode -in @('Apply', 'RotateScimToken') -and -not $ApproveIdentitySourceChange) {
        throw 'The AWS identity-source/bootstrap boundary has not been acknowledged. Complete the one-time IAM Identity Center console setup and rerun with -ApproveIdentitySourceChange.'
    }

    Connect-EntraGraph -Config $config
    $servicePrincipal = Resolve-EntraApplication -Config $config -AwsMetadata $awsMetadata
    if ($servicePrincipal.PSObject.Properties.Name -contains 'Planned') {
        $script:Result.warnings += 'Entra gallery application creation is planned; rerun Apply after the application exists.'
        if ($null -eq $entraMetadata) {
            $script:Result.warnings += "Entra identity-provider metadata will be downloaded to $entraMetadataPath during Apply with -EnsureEntraMetadata."
        }
    }
    else {
        $null = Ensure-EntraSamlSigningCertificate -Config $config -ServicePrincipal $servicePrincipal
        $entraMetadata = Ensure-EntraIdentityProviderMetadata -Config $config -ServicePrincipal $servicePrincipal -Path $entraMetadataPath
        if ($null -ne $entraMetadata) {
            $script:Result.entra.identityProviderMetadata = [ordered]@{
                path = $entraMetadata.Path
                singleSignOnServiceCount = @($entraMetadata.SingleSignOnServices).Count
            }
        }
        if ($Mode -eq 'PrepareMetadata') {
            $script:Result.warnings += 'Metadata preparation complete. Complete the one-time AWS external identity-source cutover, then rerun Apply with the SCIM endpoint and SecureString token.'
        }
        else {
            $groups = Resolve-EntraGroups -Config $config
            $assignments = Ensure-EntraGroupAssignments -ServicePrincipal $servicePrincipal -ResolvedGroups $groups
            $null = Configure-EntraProvisioning -ServicePrincipal $servicePrincipal -Scim $bootstrap
            $assignments = Resolve-AwsIdentityStoreGroups -Config $config -Assignments $assignments
            $assignments = Resolve-AccountIds -Config $config -Assignments $assignments

            if ($ApplyTerraform -and $Mode -eq 'Apply') {
                $tfvars = Write-TerraformFederationVariables -Config $config -Assignments $assignments
                Write-Information "Applying governance federation assignments from $tfvars..." -InformationAction Continue
                & terraform -chdir=(Join-Path $PSScriptRoot '..\stages\02-governance') apply -auto-approve
                if ($LASTEXITCODE -ne 0) { throw 'Terraform governance apply failed.' }
            }
            Add-ManagedAwsCliProfiles -Config $config -Assignments $assignments | Out-Null
        }
    }

    if ($Mode -in @('Apply', 'RotateScimToken')) {
        $script:Result.warnings += 'AWS IAM Identity Center identity-source cutover remains a one-time console operation; this run validated the supplied metadata and configured Entra provisioning.'
    }

    $defaultOutput = Join-Path $script:SecretStorePath 'last-result.json'
    Write-Result -DefaultPath $defaultOutput
}
catch {
    $script:Result.status = 'Failed'
    $script:Result.error = $_.Exception.Message
    if ($OutputPath) {
        $script:Result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    }
    throw
}
finally {
    if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}
