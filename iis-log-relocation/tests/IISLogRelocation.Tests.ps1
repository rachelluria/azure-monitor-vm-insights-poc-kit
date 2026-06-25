#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the IISLogRelocation module. These mock all IIS / filesystem side effects
    (appcmd, robocopy, ACLs, event log) so the decision logic can be verified on any machine
    with no IIS installed. Run with:  Invoke-Pester -Path .\iis-log-relocation\tests
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\module\IISLogRelocation.psm1'
    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module IISLogRelocation -Force -ErrorAction SilentlyContinue
}

Describe 'Get-IISLogRelocationState' {

    It 'returns NotApplicable when IIS is not installed' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $false }
            Mock Test-Path { $true }

            $state = Get-IISLogRelocationState -TargetLogRoot 'E:\inetpub\logs'

            $state.Status         | Should -Be 'NotApplicable'
            $state.IISInstalled   | Should -BeFalse
            $state.Compliant      | Should -BeTrue
            $state.ActionRequired | Should -BeFalse
        }
    }

    It 'returns NeedsRelocation when logs are on C: and the target drive exists' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @([PSCustomObject]@{ Name = 'Default Web Site'; LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' })
                }
            }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\' }

            $state = Get-IISLogRelocationState -TargetLogRoot 'E:\inetpub\logs'

            $state.Status         | Should -Be 'NeedsRelocation'
            $state.Compliant      | Should -BeFalse
            $state.ActionRequired | Should -BeTrue
            @($state.LogDirectories | Where-Object OnSystemDrive).Count | Should -Be 4
        }
    }

    It 'returns Compliant when logs are already on the target drive' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'E:\inetpub\logs\LogFiles'; FailedReq = 'E:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @([PSCustomObject]@{ Name = 'Default Web Site'; LogFiles = 'E:\inetpub\logs\LogFiles'; FailedReq = 'E:\inetpub\logs\FailedReqLogFiles' })
                }
            }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\' }

            $state = Get-IISLogRelocationState -TargetLogRoot 'E:\inetpub\logs'

            $state.Status    | Should -Be 'Compliant'
            $state.Compliant | Should -BeTrue
        }
    }

    It 'returns SkippedNoTargetDrive when logs are on C: but the target drive is missing' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @()
                }
            }
            Mock Test-Path { $true }
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'E:\' }

            $state = Get-IISLogRelocationState -TargetLogRoot 'E:\inetpub\logs'

            $state.Status             | Should -Be 'SkippedNoTargetDrive'
            $state.TargetDrivePresent | Should -BeFalse
            # Counts as compliant for enforcement so a policy does not churn.
            $state.Compliant          | Should -BeTrue
            $state.ActionRequired     | Should -BeFalse
        }
    }

    It 'expands environment variables in configured paths' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = '%SystemDrive%\inetpub\logs\LogFiles'; FailedReq = '%SystemDrive%\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @()
                }
            }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\' }

            $state   = Get-IISLogRelocationState -TargetLogRoot 'E:\inetpub\logs'
            $logFile = $state.LogDirectories | Where-Object { $_.Type -eq 'LogFiles' }

            $logFile.Resolved      | Should -Be "$env:SystemDrive\inetpub\logs\LogFiles"
            $logFile.OnSystemDrive | Should -BeTrue
        }
    }
}

Describe 'Test-IISLogRelocationCompliance' {

    It 'is false when relocation is required' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @()
                }
            }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\' }

            Test-IISLogRelocationCompliance -TargetLogRoot 'E:\inetpub\logs' | Should -BeFalse
        }
    }

    It 'is true when IIS is not installed' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $false }
            Mock Test-Path { $true }

            Test-IISLogRelocationCompliance -TargetLogRoot 'E:\inetpub\logs' | Should -BeTrue
        }
    }
}

Describe 'Set-IISLogRelocation' {

    BeforeEach {
        InModuleScope IISLogRelocation {
            Mock Get-AppCmdPath { 'C:\Windows\System32\inetsrv\appcmd.exe' }
            Mock New-LogDirectoryWithAcl { }
            Mock Move-LogTree { }
            Mock Set-IISSiteDefaultLogDir { }
            Mock Set-IISSiteLogDir { }
            Mock Write-RelocationEvent { }
        }
    }

    It 'creates dirs, moves logs, repoints config and logs event 1000 when relocation is needed' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @([PSCustomObject]@{ Name = 'Default Web Site'; LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' })
                }
            }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\' }

            Set-IISLogRelocation -TargetLogRoot 'E:\inetpub\logs' -Confirm:$false

            Should -Invoke New-LogDirectoryWithAcl  -Times 2 -Exactly
            Should -Invoke Move-LogTree             -Times 2 -Exactly   # 1 unique LogFiles + 1 unique FailedReq source
            Should -Invoke Set-IISSiteDefaultLogDir -Times 1 -Exactly
            Should -Invoke Set-IISSiteLogDir        -Times 1 -Exactly   # the one affected site
            Should -Invoke Write-RelocationEvent    -Times 1 -Exactly -ParameterFilter { $EventId -eq 1000 }
        }
    }

    It 'makes no changes under -WhatIf' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @()
                }
            }
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\' }

            Set-IISLogRelocation -TargetLogRoot 'E:\inetpub\logs' -WhatIf

            Should -Invoke New-LogDirectoryWithAcl  -Times 0 -Exactly
            Should -Invoke Move-LogTree             -Times 0 -Exactly
            Should -Invoke Set-IISSiteDefaultLogDir -Times 0 -Exactly
            Should -Invoke Write-RelocationEvent    -Times 0 -Exactly
        }
    }

    It 'soft-skips and logs event 1001 when the target drive is missing' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $true }
            Mock Get-IISLogConfig {
                [PSCustomObject]@{
                    SiteDefaults = [PSCustomObject]@{ LogFiles = 'C:\inetpub\logs\LogFiles'; FailedReq = 'C:\inetpub\logs\FailedReqLogFiles' }
                    Sites        = @()
                }
            }
            Mock Test-Path { $true }
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'E:\' }

            Set-IISLogRelocation -TargetLogRoot 'E:\inetpub\logs' -Confirm:$false

            Should -Invoke Move-LogTree          -Times 0 -Exactly
            Should -Invoke Write-RelocationEvent -Times 1 -Exactly -ParameterFilter { $EventId -eq 1001 }
        }
    }

    It 'does nothing when IIS is not installed' {
        InModuleScope IISLogRelocation {
            Mock Test-IISInstalled { $false }
            Mock Test-Path { $true }

            Set-IISLogRelocation -TargetLogRoot 'E:\inetpub\logs' -Confirm:$false

            Should -Invoke Move-LogTree          -Times 0 -Exactly
            Should -Invoke Write-RelocationEvent -Times 0 -Exactly
        }
    }
}
