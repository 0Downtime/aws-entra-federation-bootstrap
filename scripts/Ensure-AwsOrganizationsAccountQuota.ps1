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

    [ValidateSet('Validate', 'Plan', 'Request')]
    [string]$Mode = 'Plan',

    [ValidateRange(11, 10000)]
    [int]$RequestedQuota = 20,

    [string]$RequestId,

    [string]$OutputPath,

    [switch]$RequireReady,

    [switch]$Approve
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$quotaCode = 'L-E619E033'

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: $($output -join ' ')"
    }

    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Get-Request {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string[]]$AwsArguments
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        try {
            $history = Invoke-AwsJson -Arguments (@('service-quotas', 'list-requested-service-quota-change-history-by-quota', '--service-code', 'organizations', '--quota-code', $quotaCode) + $AwsArguments)
            $openRequest = @($history.RequestedQuotas) |
                Where-Object { $_.Status -in @('PENDING', 'CASE_OPENED', 'APPROVED') } |
                Sort-Object LastUpdated -Descending |
                Select-Object -First 1
            if ($null -ne $openRequest) {
                return [pscustomobject]@{ RequestedQuota = $openRequest }
            }
        } catch {
            # No request ID is a valid first-run state; let the caller report
            # QuotaIncreaseRequired if AWS has no discoverable open request.
        }
        return $null
    }

    try {
        return Invoke-AwsJson -Arguments (@('service-quotas', 'get-requested-service-quota-change', '--request-id', $Id) + $AwsArguments)
    } catch {
        throw "The configured AWS Organizations quota request '$Id' could not be read: $($_.Exception.Message)"
    }
}

$awsArguments = @('--profile', $ManagementProfile, '--region', $Region)
$caller = Invoke-AwsJson -Arguments (@('sts', 'get-caller-identity') + $awsArguments)
$organization = Invoke-AwsJson -Arguments (@('organizations', 'describe-organization') + $awsArguments)
$accounts = @(Invoke-AwsJson -Arguments (@('organizations', 'list-accounts') + $awsArguments)).Accounts
$quota = Invoke-AwsJson -Arguments (@('service-quotas', 'get-service-quota', '--service-code', 'organizations', '--quota-code', $quotaCode) + $awsArguments)
$request = Get-Request -Id $RequestId -AwsArguments $awsArguments

$currentQuota = [int][math]::Floor([double]$quota.Quota.Value)
$accountCount = @($accounts).Count
$isReady = $currentQuota -ge $RequiredAccountCount
$status = if ($isReady) {
    'Ready'
} elseif ($null -ne $request -and $request.RequestedQuota.Status -eq 'PENDING') {
    'Pending'
} elseif ($null -ne $request -and $request.RequestedQuota.Status -eq 'CASE_OPENED') {
    'Pending'
} elseif ($null -ne $request -and $request.RequestedQuota.Status -eq 'APPROVED') {
    'QuotaApprovedRefreshRequired'
} else {
    'QuotaIncreaseRequired'
}

$result = [ordered]@{
    status               = $status
    accountId            = [string]$caller.Account
    organizationId       = [string]$organization.Organization.Id
    managementProfile    = $ManagementProfile
    region               = $Region
    accountCount         = $accountCount
    requiredAccountCount = $RequiredAccountCount
    currentQuota         = $currentQuota
    requestedQuota       = $RequestedQuota
    quotaCode            = $quotaCode
    request              = if ($null -eq $request) { $null } else { $request.RequestedQuota }
    action               = 'No change'
}

if ($Mode -eq 'Request' -and -not $isReady) {
    if (-not $Approve) {
        throw 'Request mode requires -Approve because it submits an AWS Service Quotas request.'
    }

    if ($null -ne $request -and $request.RequestedQuota.Status -in @('PENDING', 'CASE_OPENED')) {
        $result.action = 'Existing request remains pending; no duplicate request submitted.'
    } elseif ($null -ne $request -and $request.RequestedQuota.Status -eq 'APPROVED') {
        $result.action = 'Request is approved; refresh the quota and rerun the preflight.'
    } else {
        $newRequest = Invoke-AwsJson -Arguments (@('service-quotas', 'request-service-quota-increase', '--service-code', 'organizations', '--quota-code', $quotaCode, '--desired-value', [string]$RequestedQuota) + $awsArguments)
        $result.request = $newRequest.RequestedQuota
        $result.action = 'Submitted a new quota increase request.'
        $result.status = 'Pending'
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
}

$result | ConvertTo-Json -Depth 10 | Write-Output

if ($RequireReady -and $result.status -notin @('Ready', 'QuotaApprovedRefreshRequired')) {
    throw "AWS Organizations account quota is not ready. Status: $($result.status)."
}
