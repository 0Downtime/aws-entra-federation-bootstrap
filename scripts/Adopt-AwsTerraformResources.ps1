#requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [ValidateSet('Validate', 'Plan', 'Apply')]
    [string]$Mode = 'Plan',

    [string]$OutputPath,

    [string]$ManagementProfile,

    [string]$Region,

    [switch]$Approve
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }

    return $Default
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: $($output -join ' ')"
    }

    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json
}

function Test-AwsCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    @(& aws @Arguments 2>$null) | Out-Null
    return $LASTEXITCODE -eq 0
}

function Resolve-StagePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TerraformRoot,

        [Parameter(Mandatory = $true)]
        [string]$StageName
    )

    $path = Join-Path $TerraformRoot "stages\$StageName"
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Terraform stage directory was not found: $path"
    }

    return (Resolve-Path -LiteralPath $path).Path
}

function New-ImportItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    [pscustomobject]@{
        stage  = $Stage
        address = $Address
        id     = $Id
        status = 'existing'
        reason = $Reason
    }
}

function New-MissingItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    [pscustomobject]@{
        stage  = $Stage
        address = $Address
        id     = $null
        status = 'missing-create'
        reason = $Reason
    }
}

function Get-TerraformVariableFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TerraformConfig,

        [Parameter(Mandatory = $true)]
        [string]$TerraformRoot,

        [Parameter(Mandatory = $true)]
        [string]$StageName
    )

    $configured = Get-ConfigValue -Object $TerraformConfig -Name "${StageName}VarsFile"
    if ([string]::IsNullOrWhiteSpace([string]$configured)) {
        $configured = "stages\$StageName\terraform.tfvars"
    }

    $path = if ([IO.Path]::IsPathRooted([string]$configured)) {
        [string]$configured
    } else {
        Join-Path $TerraformRoot ([string]$configured)
    }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $path).Path
    }

    return $null
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDirectory = Split-Path -Parent $resolvedConfigPath
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

$awsConfig = Get-ConfigValue -Object $config -Name 'aws'
$configuredManagementProfile = [string](Get-ConfigValue -Object $awsConfig -Name 'managementProfile')
$configuredRegion = [string](Get-ConfigValue -Object $awsConfig -Name 'region' -Default 'us-east-1')
$managementProfile = if ([string]::IsNullOrWhiteSpace($ManagementProfile)) { $configuredManagementProfile } else { $ManagementProfile }
$region = if ([string]::IsNullOrWhiteSpace($Region)) { $configuredRegion } else { $Region }
if ([string]::IsNullOrWhiteSpace($managementProfile)) {
    throw 'aws.managementProfile is required.'
}

$terraformConfig = Get-ConfigValue -Object $config -Name 'terraform' -Default ([pscustomobject]@{})
$configuredRoot = [string](Get-ConfigValue -Object $terraformConfig -Name 'root' -Default '..')
$terraformRoot = if ([IO.Path]::IsPathRooted($configuredRoot)) {
    (Resolve-Path -LiteralPath $configuredRoot).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $configDirectory $configuredRoot)).Path
}

$stage01 = Resolve-StagePath -TerraformRoot $terraformRoot -StageName '01-organization'
$stage02 = Resolve-StagePath -TerraformRoot $terraformRoot -StageName '02-governance'
$stage01VarsFile = Get-TerraformVariableFile -TerraformConfig $terraformConfig -TerraformRoot $terraformRoot -StageName '01-organization'
$stage02VarsFile = Get-TerraformVariableFile -TerraformConfig $terraformConfig -TerraformRoot $terraformRoot -StageName '02-governance'

$awsPrefix = @('--profile', $managementProfile, '--region', $region)
$organization = Invoke-AwsJson -Arguments (@('organizations', 'describe-organization') + $awsPrefix)
$organizationConfig = Get-ConfigValue -Object $config -Name 'organization'
$configuredOrganizationId = [string](Get-ConfigValue -Object $organizationConfig -Name 'id')
$organizationId = [string]$organization.Organization.Id

if (-not [string]::IsNullOrWhiteSpace($configuredOrganizationId) -and $configuredOrganizationId -ne $organizationId) {
    throw "Configured organization ID '$configuredOrganizationId' does not match the selected AWS organization '$organizationId'."
}

$roots = Invoke-AwsJson -Arguments (@('organizations', 'list-roots') + $awsPrefix)
$rootId = [string]$roots.Roots[0].Id
$ous = @((Invoke-AwsJson -Arguments (@('organizations', 'list-organizational-units-for-parent', '--parent-id', $rootId) + $awsPrefix)).OrganizationalUnits)
$accounts = @((Invoke-AwsJson -Arguments (@('organizations', 'list-accounts') + $awsPrefix)).Accounts)

$items = [System.Collections.Generic.List[object]]::new()
$organizationStage = 'stages/01-organization'
$items.Add((New-ImportItem -Stage $organizationStage -Address 'aws_organizations_organization.this' -Id $organizationId -Reason 'Adopt the existing AWS organization.'))

$ouConfig = Get-ConfigValue -Object $organizationConfig -Name 'organizationalUnits' -Default ([pscustomobject]@{})
foreach ($ouKey in $ouConfig.PSObject.Properties.Name) {
    $desired = $ouConfig.$ouKey
    $desiredId = [string](Get-ConfigValue -Object $desired -Name 'id')
    $desiredName = if ($desired -is [string]) { [string]$desired } else { [string](Get-ConfigValue -Object $desired -Name 'name') }
    $match = @(
        if (-not [string]::IsNullOrWhiteSpace($desiredId)) {
            $ous | Where-Object Id -eq $desiredId
        } else {
            $ous | Where-Object { $_.Name -ieq $desiredName }
        }
    )

    $address = 'aws_organizations_organizational_unit.this["' + $ouKey + '"]'
    if ($match.Count -eq 1) {
        $items.Add((New-ImportItem -Stage $organizationStage -Address $address -Id ([string]$match[0].Id) -Reason "Adopt OU '$($match[0].Name)'."))
    } elseif ($match.Count -eq 0) {
        $items.Add((New-MissingItem -Stage $organizationStage -Address $address -Reason "OU '$desiredName' was not found; Terraform will create it."))
    } else {
        throw "Multiple OUs matched '$desiredName'. Specify an explicit id in organization.organizationalUnits.$ouKey."
    }
}

$accountConfig = Get-ConfigValue -Object $organizationConfig -Name 'accounts' -Default ([pscustomobject]@{})
$desiredAccountCount = 1 + @($accountConfig.PSObject.Properties).Count
$quotaScriptPath = Join-Path $PSScriptRoot 'Ensure-AwsOrganizationsAccountQuota.ps1'
$quotaArguments = @(
    '-NoProfile'
    '-File'
    $quotaScriptPath
    '-ManagementProfile'
    $managementProfile
    '-Region'
    $region
    '-RequiredAccountCount'
    ([string]$desiredAccountCount)
    '-Mode'
    'Plan'
)
$quotaRequestId = [string](Get-ConfigValue -Object $organizationConfig -Name 'accountQuotaRequestId')
if (-not [string]::IsNullOrWhiteSpace($quotaRequestId)) {
    $quotaArguments += @('-RequestId', $quotaRequestId)
}
if ($Mode -eq 'Apply') {
    $quotaArguments += '-RequireReady'
}
$quotaOutput = @(& pwsh @quotaArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "AWS Organizations account-quota preflight failed: $($quotaOutput -join ' ')"
}
$quotaResult = ($quotaOutput -join [Environment]::NewLine) | ConvertFrom-Json

foreach ($accountKey in $accountConfig.PSObject.Properties.Name) {
    $desired = $accountConfig.$accountKey
    $desiredId = [string](Get-ConfigValue -Object $desired -Name 'id')
    $desiredName = [string](Get-ConfigValue -Object $desired -Name 'name')
    $match = @(
        if (-not [string]::IsNullOrWhiteSpace($desiredId)) {
            $accounts | Where-Object Id -eq $desiredId
        } else {
            $accounts | Where-Object { $_.Name -ieq $desiredName }
        }
    )

    $address = 'aws_organizations_account.this["' + $accountKey + '"]'
    if ($match.Count -eq 1) {
        $items.Add((New-ImportItem -Stage $organizationStage -Address $address -Id ([string]$match[0].Id) -Reason "Adopt account '$($match[0].Name)'."))
    } elseif ($match.Count -eq 0) {
        $items.Add((New-MissingItem -Stage $organizationStage -Address $address -Reason "Account '$desiredName' was not found; Terraform will create it only when enabled."))
    } else {
        throw "Multiple accounts matched '$desiredName'. Specify an explicit id in organization.accounts.$accountKey."
    }
}

$governanceConfig = Get-ConfigValue -Object $config -Name 'governance' -Default ([pscustomobject]@{})
$bucketName = [string](Get-ConfigValue -Object $governanceConfig -Name 'logArchiveBucketName')
if (-not [string]::IsNullOrWhiteSpace($bucketName)) {
    $governanceStage = 'stages/02-governance'
    if (Test-AwsCommand -Arguments (@('s3api', 'head-bucket', '--bucket', $bucketName) + $awsPrefix)) {
        $items.Add((New-ImportItem -Stage $governanceStage -Address 'aws_s3_bucket.log_archive' -Id $bucketName -Reason 'Adopt the existing log archive bucket; Terraform will converge its settings.'))
    } else {
        $items.Add((New-MissingItem -Stage $governanceStage -Address 'aws_s3_bucket.log_archive' -Reason "Bucket '$bucketName' was not found; Terraform will create it."))
    }
}

$cloudTrailName = [string](Get-ConfigValue -Object $governanceConfig -Name 'cloudTrailName' -Default 'organization-cloudtrail')
$trails = @((Invoke-AwsJson -Arguments (@('cloudtrail', 'describe-trails', '--no-include-shadow-trails') + $awsPrefix)).trailList)
$trailMatch = @($trails | Where-Object Name -ieq $cloudTrailName)
if ($trailMatch.Count -eq 1) {
    $items.Add((New-ImportItem -Stage 'stages/02-governance' -Address 'aws_cloudtrail.organization' -Id $cloudTrailName -Reason 'Adopt the existing organization CloudTrail trail.'))
} elseif ($trailMatch.Count -eq 0) {
    $items.Add((New-MissingItem -Stage 'stages/02-governance' -Address 'aws_cloudtrail.organization' -Reason "Trail '$cloudTrailName' was not found; Terraform will create it."))
} else {
    throw "Multiple CloudTrail trails matched '$cloudTrailName'."
}

$permissionSets = Get-ConfigValue -Object $governanceConfig -Name 'permissionSets' -Default ([pscustomobject]@{})
$instanceList = @((Invoke-AwsJson -Arguments (@('sso-admin', 'list-instances') + $awsPrefix)).Instances)
$instanceArn = if ($instanceList.Count -eq 1) { [string]$instanceList[0].InstanceArn } else { $null }
foreach ($permissionSetKey in $permissionSets.PSObject.Properties.Name) {
    $permissionSet = $permissionSets.$permissionSetKey
    $permissionSetArn = [string](Get-ConfigValue -Object $permissionSet -Name 'arn')
    if ([string]::IsNullOrWhiteSpace($permissionSetArn) -or [string]::IsNullOrWhiteSpace($instanceArn)) {
        $items.Add((New-MissingItem -Stage 'stages/02-governance' -Address "aws_ssoadmin_permission_set.$permissionSetKey" -Reason "Provide the existing permission-set ARN and ensure exactly one IAM Identity Center instance is available."))
        continue
    }

    if (Test-AwsCommand -Arguments (@('sso-admin', 'describe-permission-set', '--instance-arn', $instanceArn, '--permission-set-arn', $permissionSetArn) + $awsPrefix)) {
        $items.Add((New-ImportItem -Stage 'stages/02-governance' -Address "aws_ssoadmin_permission_set.$permissionSetKey" -Id "$instanceArn,$permissionSetArn" -Reason "Adopt the existing IAM Identity Center permission set '$permissionSetKey'."))
    } else {
        $items.Add((New-MissingItem -Stage 'stages/02-governance' -Address "aws_ssoadmin_permission_set.$permissionSetKey" -Reason "Permission-set ARN '$permissionSetArn' was not found; provide the correct ARN before importing."))
    }
}

$plan = [pscustomobject]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    aws = [pscustomobject]@{ managementProfile = $managementProfile; region = $region; organizationId = $organizationId }
    terraformRoot = $terraformRoot
    stage01VarsFile = $stage01VarsFile
    stage02VarsFile = $stage02VarsFile
    quota = $quotaResult
    items = @($items)
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $configDirectory 'aws-terraform-adoption-plan.json'
}

$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

if ($Mode -eq 'Validate') {
    Write-Output "Validated adoption configuration. Plan written to $OutputPath"
    exit 0
}

if ($Mode -eq 'Plan') {
    $items | Format-Table stage, address, status, id -AutoSize | Out-String | Write-Output
    Write-Output "Review $OutputPath. No Terraform state or AWS resources were changed."
    exit 0
}

if (-not $Approve) {
    throw 'Apply mode only updates Terraform state through imports. Re-run with -Approve after reviewing the generated adoption plan.'
}

foreach ($item in @($items | Where-Object status -eq 'existing')) {
    $stagePath = if ($item.stage -eq 'stages/01-organization') { $stage01 } else { $stage02 }
    $varsFile = if ($item.stage -eq 'stages/01-organization') { $stage01VarsFile } else { $stage02VarsFile }
    if ([string]::IsNullOrWhiteSpace($varsFile)) {
        throw "Terraform variable file is required for importing $($item.address)."
    }

    Write-Information "Importing $($item.address) into $($item.stage)..." -InformationAction Continue
    & terraform "-chdir=$stagePath" import -input=false -var-file $varsFile $item.address $item.id
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform import failed for $($item.address)."
    }
}

Write-Output "Imported $(@($items | Where-Object status -eq 'existing').Count) existing resources into Terraform state. Run terraform plan before applying convergence changes."
