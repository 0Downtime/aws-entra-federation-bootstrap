BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\scripts\Configure-AwsEntraFederation.ps1'
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
}

Describe 'Configure-AwsEntraFederation.ps1 static safety checks' {
    It 'uses strict error handling and does not contain literal secrets' {
        $scriptText | Should -Match "ErrorActionPreference\s*=\s*'Stop'"
        $scriptText | Should -Match 'Set-StrictMode'
        $scriptText | Should -Not -Match '(?i)(aws_secret_access_key|client_secret\s*=|password\s*=\s*[''\"]\w+)'
    }

    It 'requires an explicit identity-source acknowledgement for mutating modes' {
        $scriptText | Should -Match 'ApproveIdentitySourceChange'
        $scriptText | Should -Match "Mode -in @\('Apply', 'RotateScimToken'\)"
        $scriptText | Should -Match 'not \$ApproveIdentitySourceChange'
    }

    It 'uses DPAPI-backed secure storage and redacted output' {
        $scriptText | Should -Match 'ConvertFrom-SecureString'
        $scriptText | Should -Match 'SecretStorePath'
        $scriptText | Should -Match 'redacted'
    }

    It 'preserves unrelated AWS configuration with a managed block' {
        $scriptText | Should -Match 'BEGIN AWS ENTRA FEDERATION'
        $scriptText | Should -Match 'END AWS ENTRA FEDERATION'
        $scriptText | Should -Match '\.bak'
    }
}

Describe 'Install-AwsEntraFederationPrerequisites.ps1' {
    BeforeAll {
        $prerequisitePath = Join-Path $PSScriptRoot '..\scripts\Install-AwsEntraFederationPrerequisites.ps1'
        $prerequisiteText = Get-Content -LiteralPath $prerequisitePath -Raw
    }

    It 'has read-only validation and explicit installation modes' {
        $prerequisiteText | Should -Match "ValidateSet\('Validate', 'Install'\)"
        $prerequisiteText | Should -Match 'Install-WingetPackage'
        $prerequisiteText | Should -Match 'Microsoft.PowerShell'
        $prerequisiteText | Should -Match 'Amazon.AWSCLI'
        $prerequisiteText | Should -Match 'Hashicorp.Terraform'
        $prerequisiteText | Should -Match 'Microsoft.Graph.Authentication'
        $prerequisiteText | Should -Match 'Pester'
    }

    It 'does not handle or persist credentials' {
        $prerequisiteText | Should -Not -Match '(?im)^\s*\$?(scimToken|clientSecret|privateKey|aws_secret_access_key|password)\s*='
    }
}

Describe 'Initialize-AwsEntraFederationConfig.ps1' {
    BeforeAll {
        $initializerPath = Join-Path $PSScriptRoot '..\scripts\Initialize-AwsEntraFederationConfig.ps1'
        $initializerText = Get-Content -LiteralPath $initializerPath -Raw
    }

    It 'discovers and writes only non-secret configuration values' {
        $initializerText | Should -Match 'Get-ManagementProfile'
        $initializerText | Should -Match 'sso-admin.*list-instances'
        $initializerText | Should -Match 'az.*account.*show'
        $initializerText | Should -Match 'CertificateSubjectPattern'
        $initializerText | Should -Match 'MetadataDirectory'
        $initializerText | Should -Match 'IncludeAdministratorAccess'
        $initializerText | Should -Match 'EnsureCertificate'
        $initializerText | Should -Match 'CertificateYears'
        $initializerText | Should -Match '--append'
        $initializerText | Should -Match 'New-SelfSignedCertificate'
        $initializerText | Should -Not -Match '(?im)^\s*\$?(scimToken|clientSecret|privateKey|aws_secret_access_key|password)\s*='
    }
}

Describe 'Federation configuration examples' {
    It 'contains the required top-level sections' {
        $configPath = Join-Path $PSScriptRoot '..\scripts\entra-aws-federation.example.json'
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.aws | Should -Not -BeNullOrEmpty
        $config.bootstrap | Should -Not -BeNullOrEmpty
        $config.bootstrap.requiredAccountCount | Should -BeGreaterThan 0
        $config.bootstrap.requestedAccountQuota | Should -BeGreaterOrEqual $config.bootstrap.requiredAccountCount
        $config.entra | Should -Not -BeNullOrEmpty
        $config.entra.groupNamePrefix | Should -Be 'AWS'
        @($config.accessMappings).Count | Should -BeGreaterThan 0
        @($config.accessMappings | Where-Object { $_.permissionSet -eq 'AdministratorAccess' }).Count | Should -Be 1
        @($config.accessMappings | Where-Object { $_.entraGroupSuffix -eq 'Administrators' }).Count | Should -Be 1
    }

    It 'does not include a SCIM token or private key' {
        $configPath = Join-Path $PSScriptRoot '..\scripts\entra-aws-federation.example.json'
        $configText = Get-Content -LiteralPath $configPath -Raw
        $configText | Should -Not -Match '(?i)(scim.*token|clientSecret|privateKey|password)'
    }

    It 'supports configurable Entra group prefixes and suffix mappings' {
        $scriptText | Should -Match 'groupNamePrefix'
        $scriptText | Should -Match 'entraGroupSuffix'
        $scriptText | Should -Match 'must use either entraGroup or entraGroupSuffix'
    }
}

Describe 'Invoke-AwsEntraFederationBootstrap.ps1 onboarding orchestrator' {
    BeforeAll {
        $orchestratorPath = Join-Path $PSScriptRoot '..\scripts\Invoke-AwsEntraFederationBootstrap.ps1'
        $orchestratorText = Get-Content -LiteralPath $orchestratorPath -Raw
    }

    It 'coordinates the quota, organization, and federation phases' {
        $orchestratorText | Should -Match 'Ensure-AwsOrganizationsAccountQuota\.ps1'
        $orchestratorText | Should -Match 'Invoke-AwsOrganizationBootstrap\.ps1'
        $orchestratorText | Should -Match 'Configure-AwsEntraFederation\.ps1'
        $orchestratorText | Should -Match 'Invoke-QuotaCheck'
        $orchestratorText | Should -Match 'Invoke-OrganizationBootstrap'
        $orchestratorText | Should -Match 'Invoke-Federation'
    }

    It 'requires explicit approvals for every mutating boundary' {
        $orchestratorText | Should -Match 'ApproveQuota'
        $orchestratorText | Should -Match 'ApproveOrganizationChange'
        $orchestratorText | Should -Match 'ApproveIdentitySourceChange'
        $orchestratorText | Should -Match 'ApproveTerraform'
        $orchestratorText | Should -Match 'RequestQuota'
        $orchestratorText | Should -Match 'ApproveQuota'
    }

    It 'keeps SCIM entry inside the PowerShell 7 process and writes redacted results' {
        $orchestratorText | Should -Match "Read-Host 'AWS SCIM token' -AsSecureString"
        $orchestratorText | Should -Match 'bootstrap-last-result\.json'
        $orchestratorText | Should -Not -Match '(?i)ConvertTo-PlainText|clientSecret\s*=|privateKey\s*='
    }

    It 'spells out the manual AWS and Entra bootstrap steps and validates evidence afterward' {
        $orchestratorText | Should -Match 'MANUAL AWS/ENTRA BOOTSTRAP CHECKLIST'
        $orchestratorText | Should -Match 'External identity provider'
        $orchestratorText | Should -Match 'Automatic provisioning'
        $orchestratorText | Should -Match 'Test-ManualBootstrapEvidence'
        $orchestratorText | Should -Match 'configuredMetadataPath'
        $orchestratorText | Should -Match 'scimGroupsPresent'
        $orchestratorText | Should -Match 'public APIs do not expose a direct external-identity-source boolean'
    }

    It 'requires the manual acknowledgement before Apply' {
        $orchestratorText | Should -Match 'Mode -eq ''Apply'' -and -not \$ApproveIdentitySourceChange'
        $orchestratorText | Should -Match 'Complete the displayed checklist'
    }
}

Describe 'Ensure-AwsOrganizationsAccountQuota.ps1 request handling' {
    BeforeAll {
        $quotaPath = Join-Path $PSScriptRoot '..\scripts\Ensure-AwsOrganizationsAccountQuota.ps1'
        $quotaText = Get-Content -LiteralPath $quotaPath -Raw
    }

    It 'discovers an existing open request when no request ID is supplied' {
        $quotaText | Should -Match 'list-requested-service-quota-change-history-by-quota'
        $quotaText | Should -Match "Status -in @\('PENDING', 'CASE_OPENED', 'APPROVED'\)"
        $quotaText | Should -Match 'AllowEmptyString'
    }

    It 'does not submit duplicate requests while one is open' {
        $quotaText | Should -Match 'Existing request remains pending; no duplicate request submitted\.'
    }
}
