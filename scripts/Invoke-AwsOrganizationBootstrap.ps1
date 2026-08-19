#requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagementProfile,

    [string]$Region = 'us-east-1',

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 10000)]
    [int]$RequiredAccountCount,

    [string]$RequestId,

    [ValidateSet('Plan', 'Apply')]
    [string]$Mode = 'Plan',

    [string]$StagePath,

    [string]$PlanPath = 'organization-bootstrap.tfplan'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$terraformRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$stage = if ([string]::IsNullOrWhiteSpace($StagePath)) {
    (Resolve-Path -LiteralPath (Join-Path $terraformRoot 'stages\01-organization')).Path
} else {
    (Resolve-Path -LiteralPath $StagePath).Path
}
$quotaScript = Join-Path $PSScriptRoot 'Ensure-AwsOrganizationsAccountQuota.ps1'

$quotaArguments = @(
    '-NoProfile'
    '-File'
    $quotaScript
    '-ManagementProfile'
    $ManagementProfile
    '-Region'
    $Region
    '-RequiredAccountCount'
    ([string]$RequiredAccountCount)
    '-Mode'
    'Plan'
    '-RequireReady'
)
if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
    $quotaArguments += @('-RequestId', $RequestId)
}

Write-Information 'Checking AWS Organizations account quota before Terraform...' -InformationAction Continue
$quotaOutput = @(& pwsh @quotaArguments 2>&1)
$quotaExitCode = $LASTEXITCODE
$quotaOutput | Write-Output
if ($quotaExitCode -ne 0) {
    throw 'AWS Organizations account quota is not ready. Terraform was not run.'
}

$planFile = if ([IO.Path]::IsPathRooted($PlanPath)) {
    $PlanPath
} else {
    Join-Path $stage $PlanPath
}

if ($Mode -eq 'Plan') {
    & terraform "-chdir=$stage" plan -input=false -out $planFile
    if ($LASTEXITCODE -ne 0) {
        throw 'Terraform plan failed.'
    }

    Write-Output "Plan saved to $planFile. Review it before running this script with -Mode Apply."
    exit 0
}

if (-not (Test-Path -LiteralPath $planFile -PathType Leaf)) {
    throw "Terraform plan file was not found: $planFile"
}

& terraform "-chdir=$stage" apply -input=false $planFile
if ($LASTEXITCODE -ne 0) {
    throw 'Terraform apply failed.'
}
