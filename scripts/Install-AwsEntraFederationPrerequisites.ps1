#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Validate', 'Install')]
    [string]$Mode = 'Validate',

    [ValidateSet('User', 'Machine')]
    [string]$WingetScope = 'User',

    [switch]$SkipGit,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$script:Requirements = @(
    [pscustomobject]@{ Name = 'PowerShell 7.2+'; Kind = 'Command'; Command = 'pwsh'; WingetId = 'Microsoft.PowerShell'; Required = $true },
    [pscustomobject]@{ Name = 'AWS CLI v2'; Kind = 'Command'; Command = 'aws'; WingetId = 'Amazon.AWSCLI'; Required = $true },
    [pscustomobject]@{ Name = 'Terraform 1.5+'; Kind = 'Command'; Command = 'terraform'; WingetId = 'Hashicorp.Terraform'; Required = $true },
    [pscustomobject]@{ Name = 'Git'; Kind = 'Command'; Command = 'git'; WingetId = 'Git.Git'; Required = $true },
    [pscustomobject]@{ Name = 'Microsoft Graph Authentication module'; Kind = 'Module'; Module = 'Microsoft.Graph.Authentication'; Required = $true },
    [pscustomobject]@{ Name = 'Pester module'; Kind = 'Module'; Module = 'Pester'; Required = $true }
)

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Get-CommandStatus {
    param([Parameter(Mandatory = $true)]$Requirement)

    $command = Get-Command -Name $Requirement.Command -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject]@{ name = $Requirement.Name; status = 'missing'; detail = "Command '$($Requirement.Command)' was not found." }
    }

    $detail = [string]$command.Source
    $status = 'ready'
    if ($Requirement.Command -eq 'pwsh') {
        $versionText = (& $Requirement.Command -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1).Trim()
        $version = $null
        if ([version]::TryParse($versionText, [ref]$version) -and $version -lt [version]'7.2') {
            $status = 'needs-upgrade'
            $detail = "Found PowerShell $versionText; version 7.2 or later is required."
        }
        elseif (-not [string]::IsNullOrWhiteSpace($versionText)) {
            $detail = "PowerShell $versionText"
        }
    }
    elseif ($Requirement.Command -eq 'aws') {
        $versionText = (& $Requirement.Command --version 2>&1 | Out-String).Trim()
        if ($versionText -notmatch 'aws-cli/2\.') {
            $status = 'needs-upgrade'
            $detail = "Found '$versionText'; AWS CLI v2 is required."
        }
        else {
            $detail = $versionText
        }
    }
    elseif ($Requirement.Command -eq 'terraform') {
        $versionText = (& $Requirement.Command version 2>&1 | Out-String).Trim()
        $match = [regex]::Match($versionText, 'Terraform v(?<version>\d+\.\d+\.\d+)')
        if (-not $match.Success -or [version]$match.Groups['version'].Value -lt [version]'1.5') {
            $status = 'needs-upgrade'
            $detail = "Found '$versionText'; Terraform 1.5 or later is required."
        }
        else {
            $detail = $match.Value
        }
    }

    return [pscustomobject]@{ name = $Requirement.Name; status = $status; detail = $detail }
}

function Get-ModuleStatus {
    param([Parameter(Mandatory = $true)]$Requirement)

    $module = Get-Module -ListAvailable -Name $Requirement.Module |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $module) {
        return [pscustomobject]@{ name = $Requirement.Name; status = 'missing'; detail = "PowerShell module '$($Requirement.Module)' was not found." }
    }

    return [pscustomobject]@{ name = $Requirement.Name; status = 'ready'; detail = "Version $($module.Version)" }
}

function Get-RequirementStatus {
    param([Parameter(Mandatory = $true)]$Requirement)

    if ($Requirement.Kind -eq 'Command') {
        return Get-CommandStatus -Requirement $Requirement
    }
    return Get-ModuleStatus -Requirement $Requirement
}

function Install-WingetPackage {
    param([Parameter(Mandatory = $true)]$Requirement)

    if ($null -eq (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is required to install $($Requirement.Name). Install Microsoft's App Installer package, then rerun this script."
    }

    if (-not $PSCmdlet.ShouldProcess($Requirement.Name, "Install winget package $($Requirement.WingetId)")) {
        return
    }

    & winget install --id $Requirement.WingetId --exact --scope $WingetScope --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $($Requirement.Name) ($($Requirement.WingetId)); exit code $LASTEXITCODE."
    }
    Refresh-ProcessPath
}

function Install-PowerShellModules {
    $moduleNames = @('Microsoft.Graph.Authentication', 'Pester')
    if (-not $PSCmdlet.ShouldProcess(($moduleNames -join ', '), 'Install PowerShell modules for the current user')) {
        return
    }

    $installCommand = "Install-Module -Name $($moduleNames -join ',') -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Confirm:`$false"
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $pwsh -and $PSVersionTable.PSVersion.Major -lt 7) {
        & $pwsh.Source -NoProfile -NonInteractive -Command $installCommand
    }
    else {
        Install-Module -Name $moduleNames -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Confirm:$false
    }
}

function Write-Result {
    param([Parameter(Mandatory = $true)]$Checks)

    $failed = @($Checks | Where-Object { $_.status -ne 'ready' })
    $result = [ordered]@{
        status = if ($failed.Count -eq 0) { 'Ready' } else { 'NeedsAttention' }
        mode = $Mode
        checks = @($Checks)
        notes = @(
            'This script does not create AWS credentials, Entra app registrations, certificates, SCIM tokens, or IAM Identity Center assignments.',
            'The certificate private key must be installed separately in the Windows certificate store and must never be committed.'
        )
    }
    $json = $result | ConvertTo-Json -Depth 10
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
    }
    Write-Output $json
    return $failed.Count -eq 0
}

try {
    if ($SkipGit) {
        $script:Requirements = @($script:Requirements | Where-Object { $_.Command -ne 'git' })
    }

    $checks = @($script:Requirements | ForEach-Object { Get-RequirementStatus -Requirement $_ })
    if ($Mode -eq 'Install') {
        foreach ($requirement in $script:Requirements) {
            $check = $checks | Where-Object { $_.name -eq $requirement.Name } | Select-Object -First 1
            if ($check.status -ne 'ready' -and $requirement.Kind -eq 'Command') {
                Install-WingetPackage -Requirement $requirement
            }
        }

        if (@($checks | Where-Object { $_.name -in @('Microsoft Graph Authentication module', 'Pester module') -and $_.status -ne 'ready' }).Count -gt 0) {
            Install-PowerShellModules
        }

        Refresh-ProcessPath
        $checks = @($script:Requirements | ForEach-Object { Get-RequirementStatus -Requirement $_ })
    }

    $ready = Write-Result -Checks $checks
    if (-not $ready) {
        throw 'Prerequisite validation did not pass. Review the JSON checks and install or repair the reported items.'
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
