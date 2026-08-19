#requires -RunAsAdministrator
#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AuthorizedKey,

    [string]$UserName = ([Security.Principal.WindowsIdentity]::GetCurrent().Name),

    [ValidateSet('Auto', 'ARM64', 'x64')]
    [string]$Architecture = 'Auto',

    [ValidateSet('Domain', 'Private', 'Public', 'Any')]
    [string]$FirewallProfile = 'Private',

    [switch]$DisablePasswordAuthentication,

    [switch]$KeepInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Pinned official PowerShell/Win32-OpenSSH release. The current release is a
# preview; keeping the tag and hash here makes the download auditable.
$releaseTag = '10.0.0.0p2-Preview'
$releaseVersion = '10.0.0.0'
$releaseAssets = @{
    ARM64 = @{
        Name = "OpenSSH-ARM64-v$releaseVersion.msi"
        Sha256 = '7a17d0e22d004fb47ca4bfd8fef926fa305de4ebf70a6f3c7a29c39aabef0023'
    }
    x64 = @{
        Name = "OpenSSH-Win64-v$releaseVersion.msi"
        Sha256 = 'ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9'
    }
}

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

function Test-TargetAdministrator {
    param([Parameter(Mandatory = $true)][string]$Sid)

    $adminGroupSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($Sid -eq $current.User.Value) {
        return ([Security.Principal.WindowsPrincipal]::new($current)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }

    $members = Get-LocalGroupMember -SID $adminGroupSid -ErrorAction Stop
    return @($members | Where-Object { $_.SID.Value -eq $Sid }).Count -gt 0
}

function Set-RestrictedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Identities
    )

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

function Get-NativeArchitecture {
    $architectureValue = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if ([string]::IsNullOrWhiteSpace($architectureValue)) {
        $architectureValue = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    }

    if ($architectureValue -match 'ARM64') {
        return 'ARM64'
    }
    return 'x64'
}

function Ensure-SshdConfiguration {
    param([Parameter(Mandatory = $true)][string]$SshdPath)

    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "OpenSSH configuration was not found at $configPath."
    }

    $original = Get-Content -LiteralPath $configPath -Raw
    $updated = $original
    if ($DisablePasswordAuthentication) {
        if ($updated -match '(?m)^\s*#?\s*PasswordAuthentication\s+') {
            $updated = [regex]::Replace(
                $updated,
                '(?m)^\s*#?\s*PasswordAuthentication\s+.*$',
                'PasswordAuthentication no'
            )
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

    $validationOutput = & $SshdPath '-t' '-f' $configPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "sshd configuration validation failed: $validationOutput"
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

$targetSid = Get-TargetIdentity
$targetIsAdministrator = Test-TargetAdministrator -Sid $targetSid
$selectedArchitecture = if ($Architecture -eq 'Auto') { Get-NativeArchitecture } else { $Architecture }
$asset = $releaseAssets[$selectedArchitecture]
$downloadUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/$releaseTag/$($asset.Name)"
$downloadPath = Join-Path ([IO.Path]::GetTempPath()) $asset.Name

if (-not $PSCmdlet.ShouldProcess($downloadUrl, "Download and verify Win32-OpenSSH $selectedArchitecture")) {
    return
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $asset.Sha256) {
        throw "SHA-256 verification failed for $($asset.Name). Expected $($asset.Sha256), received $actualHash."
    }

    $msiArguments = @('/i', $downloadPath, 'ADDLOCAL=Server', '/qn', '/norestart')
    $installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru
    if ($installer.ExitCode -notin @(0, 3010)) {
        throw "OpenSSH MSI installation failed with exit code $($installer.ExitCode)."
    }
}
finally {
    if (-not $KeepInstaller -and (Test-Path -LiteralPath $downloadPath)) {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
}

$sshd = @(
    (Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe'),
    (Join-Path $env:ProgramFiles 'OpenSSH-Win64\sshd.exe'),
    (Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($sshd)) {
    throw 'The OpenSSH server executable was not found after MSI installation.'
}

$sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($null -eq $sshService) {
    $installScript = Join-Path (Split-Path -Parent $sshd) 'install-sshd.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "The sshd service is missing and the service installer was not found at $installScript."
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
    $profilePath = Join-Path $env:SystemDrive (Join-Path 'Users' $UserName.Split('\')[-1])
    $sshUserDirectory = Join-Path $profilePath '.ssh'
    New-Item -ItemType Directory -Path $sshUserDirectory -Force | Out-Null
    $authorizedKeysPath = Join-Path $sshUserDirectory 'authorized_keys'
}

$normalizedKey = $AuthorizedKey.Trim()
if ($normalizedKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+\S+(\s+.*)?$') {
    throw 'AuthorizedKey is not a recognized OpenSSH public-key line. Provide only the .pub line, never the private key.'
}

New-Item -ItemType File -Path $authorizedKeysPath -Force | Out-Null
$existingKeys = @(Get-Content -LiteralPath $authorizedKeysPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($existingKeys -notcontains $normalizedKey) {
    Add-Content -LiteralPath $authorizedKeysPath -Value $normalizedKey -Encoding utf8
}

$aclIdentities = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')
if (-not $targetIsAdministrator) {
    $aclIdentities += $UserName
}
Set-RestrictedAcl -Path $authorizedKeysPath -Identities $aclIdentities

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
Write-Information "Win32-OpenSSH $releaseVersion installed from the official GitHub release." -InformationAction Continue
Write-Information "Architecture: $selectedArchitecture" -InformationAction Continue
Write-Information "User: $UserName" -InformationAction Continue
Write-Information "Authorized key file: $authorizedKeysPath" -InformationAction Continue
Write-Information "Password authentication disabled: $DisablePasswordAuthentication" -InformationAction Continue
Write-Information "VM IPv4 address(es): $($addresses -join ', ')" -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Test from the Mac with:' -InformationAction Continue
if ($addresses.Count -gt 0) {
    Write-Information "ssh $($UserName.Split('\')[-1])@$($addresses[0])" -InformationAction Continue
}
