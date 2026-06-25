<#
.SYNOPSIS
    Test wrapper for the IIS log relocation logic. Imports the shared module and reports /
    optionally remediates the current machine. This is the interactive / Run Command / runbook
    vehicle for validating the logic on ONE server before rolling it out as a policy.

.DESCRIPTION
    The actual logic lives entirely in module\IISLogRelocation.psm1. This wrapper just:
      1. Imports that module.
      2. Prints the current relocation state.
      3. Unless -AuditOnly, remediates (NeedsRelocation) or soft-skips (SkippedNoTargetDrive).

    Because the module supports -WhatIf, run this wrapper with -WhatIf first for a dry run.

.PARAMETER TargetLogRoot
    Destination root for IIS logs. Default 'E:\inetpub\logs'.

.PARAMETER AuditOnly
    Report state only; make no changes.

.PARAMETER ModulePath
    Optional explicit path to IISLogRelocation.psm1. By default the script looks for the
    module next to itself (..\module\) or in the same directory.

.EXAMPLE
    # Dry run on the local machine (shows what would change, touches nothing)
    .\Invoke-IISLogRelocation.ps1 -WhatIf

.EXAMPLE
    # Report only
    .\Invoke-IISLogRelocation.ps1 -AuditOnly

.EXAMPLE
    # Remediate
    .\Invoke-IISLogRelocation.ps1

.EXAMPLE
    # Push to a single Azure Arc-enabled server via Run Command (audit first)
    az connectedmachine run-command create `
        --name iis-log-audit `
        --machine-name <server> `
        --resource-group azure-arc `
        --location westus2 `
        --script "@iis-log-relocation/scripts/Invoke-IISLogRelocation.ps1" `
        --parameters "AuditOnly=true"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$TargetLogRoot = 'E:\inetpub\logs',

    [switch]$AuditOnly,

    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'

# --- Resolve the shared module ---------------------------------------------
$candidates = @()
if ($ModulePath) { $candidates += $ModulePath }
if ($PSScriptRoot) {
    $candidates += (Join-Path $PSScriptRoot '..\module\IISLogRelocation.psm1')
    $candidates += (Join-Path $PSScriptRoot 'IISLogRelocation.psm1')
}
$module = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $module) {
    throw "IISLogRelocation.psm1 not found. Pass -ModulePath or place the module next to this script. Searched: $($candidates -join '; ')"
}
Import-Module -Name $module -Force

# --- Report current state ---------------------------------------------------
$state = Get-IISLogRelocationState -TargetLogRoot $TargetLogRoot

Write-Host ''
Write-Host '=== IIS Log Relocation - current state ===' -ForegroundColor Cyan
try {
    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
} catch {
    $fqdn = $env:COMPUTERNAME
}
Write-Host ("Server : {0}  (FQDN: {1})" -f $env:COMPUTERNAME, $fqdn) -ForegroundColor Cyan
Write-Host ("Run at : {0}" -f (Get-Date -Format 'u'))
$state |
    Select-Object Status, IISInstalled, TargetLogRoot, TargetDrivePresent, Compliant, ActionRequired, Reason |
    Format-List | Out-String | Write-Host

if ($state.LogDirectories) {
    $state.LogDirectories |
        Format-Table Scope, Type, Resolved, OnSystemDrive -AutoSize | Out-String | Write-Host
}

if ($AuditOnly) {
    Write-Host 'AuditOnly specified - no changes were made.' -ForegroundColor Yellow
    return
}

# --- Act --------------------------------------------------------------------
switch ($state.Status) {
    'NotApplicable' {
        Write-Host 'IIS is not installed - nothing to do.' -ForegroundColor Green
    }
    'Compliant' {
        Write-Host 'Already compliant - nothing to do.' -ForegroundColor Green
    }
    'SkippedNoTargetDrive' {
        Write-Warning $state.Reason
        # Set logs Application event 1001 so scheduled runs surface skipped servers.
        Set-IISLogRelocation -TargetLogRoot $TargetLogRoot
    }
    'NeedsRelocation' {
        Set-IISLogRelocation -TargetLogRoot $TargetLogRoot
        if (-not $WhatIfPreference) {
            $after = Get-IISLogRelocationState -TargetLogRoot $TargetLogRoot
            Write-Host ''
            Write-Host "=== After remediation: $($after.Status) ===" -ForegroundColor Cyan
            Write-Host $after.Reason
        }
    }
}
