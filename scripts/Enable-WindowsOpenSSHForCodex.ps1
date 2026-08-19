#requires -RunAsAdministrator
#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AuthorizedKey,

    [string]$UserName = ([Security.Principal.WindowsIdentity]::GetCurrent().Name),

    [ValidateSet('Domain', 'Private', 'Public', 'Any')]
    [string]$FirewallProfile = 'Private',

    [switch]$DisablePasswordAuthentication
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetIdentity {
    try {
        return ([Security.Principal.NTAccount]$UserName).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "Windows user '$UserName' could not be resolved. Use a local or domain account name recognized by this VM."
    }
}

function Test-IsTargetAdministrator {
    param([string]$Sid)

    $adminGroupSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $token = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Sid -eq $token.User.Value) {
        $principal = [Security.Principal.WindowsPrincipal]::new($token)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # For a different target user, use the local Administrators group membership.
    $members = Get-LocalGroupMember -SID $adminGroupSid -ErrorAction Stop
    return @($members | Where-Object { $_.SID.Value -eq $Sid }).Count -gt 0
}

function Set-RestrictedAcl {
    param([string]$Path, [string[]]$Identities)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    foreach ($identity in $Identities) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Ensure-OpenSshCapability {
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($capability.State -ne 'Installed') {
        if (-not $PSCmdlet.ShouldProcess('Windows', 'Install OpenSSH Server capability')) {
            return
        }
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
}

function Ensure-SshdConfiguration {
    param([string]$SshdPath)

    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenSSH configuration was not found at $configPath."
    }

    $original = Get-Content -LiteralPath $configPath -Raw
    $updated = $original

    if ($DisablePasswordAuthentication) {
        if ($updated -match '(?m)^\s*#?\s*PasswordAuthentication\s+') {
            $updated = [regex]::Replace($updated, '(?m)^\s*#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication no')
        }
        else {
            $updated = $updated.TrimEnd() + "`r`nPasswordAuthentication no`r`n"
        }
    }

    if ($updated -ne $original) {
        $backupPath = "$configPath.bak.$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
        Set-Content -LiteralPath $configPath -Value $updated -Encoding utf8
        Write-Information "Backed up sshd_config to $backupPath" -InformationAction Continue
    }

    & $SshdPath '-t' '-f' $configPath 2>&1 | Out-String | ForEach-Object {
        if ($LASTEXITCODE -ne 0) { throw "sshd configuration validation failed: $_" }
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

$targetSid = Get-TargetIdentity
$targetIsAdministrator = Test-IsTargetAdministrator -Sid $targetSid
Ensure-OpenSshCapability

$sshd = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
if (-not (Test-Path -LiteralPath $sshd)) {
    throw "OpenSSH server executable was not found at $sshd after installation."
}

$sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($null -eq $sshService) {
    if (-not $PSCmdlet.ShouldProcess('sshd', 'Register OpenSSH Server service')) {
        return
    }
    $installScript = Join-Path (Split-Path -Parent $sshd) 'install-sshd.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "The sshd service is missing and the OpenSSH service installer was not found at $installScript."
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSSH service registration failed with exit code $LASTEXITCODE."
    }
    $sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
}
if ($null -eq $sshService) {
    throw 'The sshd service could not be found or registered.'
}

Set-Service -Name sshd -StartupType Automatic
Ensure-SshdConfiguration -SshdPath $sshd

$sshRoot = Join-Path $env:ProgramData 'ssh'
if ($targetIsAdministrator) {
    $authorizedKeysPath = Join-Path $sshRoot 'administrators_authorized_keys'
}
else {
    $profilePath = [Environment]::ExpandEnvironmentVariables("%SystemDrive%\Users\$($UserName.Split('\')[-1])")
    $sshUserDirectory = Join-Path $profilePath '.ssh'
    New-Item -ItemType Directory -Path $sshUserDirectory -Force | Out-Null
    $authorizedKeysPath = Join-Path $sshUserDirectory 'authorized_keys'
}

$normalizedKey = $AuthorizedKey.Trim()
if ($normalizedKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+\S+(\s+.*)?$') {
    throw 'AuthorizedKey is not a recognized OpenSSH public-key line. Provide only the .pub line, never the private key.'
}

$existingKeys = if (Test-Path -LiteralPath $authorizedKeysPath) {
    @(Get-Content -LiteralPath $authorizedKeysPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
else {
    @()
}

if ($existingKeys -notcontains $normalizedKey) {
    Add-Content -LiteralPath $authorizedKeysPath -Value $normalizedKey -Encoding utf8
}

$systemIdentity = 'NT AUTHORITY\SYSTEM'
$administratorsIdentity = 'BUILTIN\Administrators'
if ($targetIsAdministrator) {
    Set-RestrictedAcl -Path $authorizedKeysPath -Identities @($systemIdentity, $administratorsIdentity)
}
else {
    Set-RestrictedAcl -Path $authorizedKeysPath -Identities @($systemIdentity, $administratorsIdentity, $UserName)
}

$firewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($null -eq $firewallRule) {
    if ($PSCmdlet.ShouldProcess("TCP/22 ($FirewallProfile profile)", 'Create inbound Windows Firewall rule')) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
            -DisplayName 'OpenSSH Server (TCP-In)' `
            -Description 'Local SSH access for the Windows VM' `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 22 `
            -Action Allow `
            -Profile $FirewallProfile | Out-Null
    }
}

if ((Get-Service -Name sshd).Status -ne 'Running') {
    Start-Service -Name sshd
}
else {
    Restart-Service -Name sshd -Force
}

$addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'
} | Select-Object -ExpandProperty IPAddress)

Write-Information '' -InformationAction Continue
Write-Information 'OpenSSH Server is enabled.' -InformationAction Continue
Write-Information "User: $UserName" -InformationAction Continue
Write-Information "Authorized key file: $authorizedKeysPath" -InformationAction Continue
Write-Information "Password authentication disabled: $DisablePasswordAuthentication" -InformationAction Continue
Write-Information "VM IPv4 address(es): $($addresses -join ', ')" -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Test from the Mac with:' -InformationAction Continue
Write-Information "ssh $($UserName.Split('\')[-1])@$($addresses[0])" -InformationAction Continue
