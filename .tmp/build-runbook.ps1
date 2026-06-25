# Generates a SELF-CONTAINED Azure Automation runbook from the shared module so there is
# no logic drift: the relocation functions are copied verbatim from IISLogRelocation.psm1.
$ErrorActionPreference = 'Stop'

$repo    = Split-Path -Parent $PSScriptRoot
$psm1    = Join-Path $repo 'iis-log-relocation\module\IISLogRelocation.psm1'
$outDir  = Join-Path $repo 'iis-log-relocation\runbook'
$outFile = Join-Path $outDir 'Relocate-IISLogs.runbook.ps1'

$src = Get-Content -Raw -LiteralPath $psm1

# Take everything BEFORE the class-based DSC resource (functions + helpers only).
$marker = '# Class-based DSC resource'
$idx = $src.IndexOf($marker)
if ($idx -lt 0) { throw "Marker '$marker' not found in module." }
$funcs = $src.Substring(0, $idx).TrimEnd()

# Strip the module's leading #requires line and its comment-based help block; the runbook
# supplies its own header + a single #requires at the very top.
$funcs = $funcs -replace '(?ms)^\#requires[^\r\n]*\r?\n', ''
$funcs = $funcs -replace '(?ms)\A\s*<\#.*?\#>\r?\n', ''
$funcs = $funcs.TrimStart()

$header = @'
#requires -Version 5.1
<#
.SYNOPSIS
    Azure Automation runbook: relocate IIS logs (inetpub\logs) off the system drive (C:)
    to a target drive (default E:\inetpub\logs). Self-contained - import this single file
    into an Automation Account and run it ad-hoc.

.DESCRIPTION
    This runbook is GENERATED from iis-log-relocation\module\IISLogRelocation.psm1 (the
    single source of truth). The relocation functions below are copied verbatim; do not
    edit them here - change the module and re-run .tmp\build-runbook.ps1.

    The runbook is non-interactive and self-gating:
      * No IIS              -> NotApplicable (no-op).
      * Already on target   -> Compliant (no-op).
      * Target drive absent -> SkippedNoTargetDrive (logs Application event 1001).
      * Logs on C:          -> NeedsRelocation -> moves logs, repoints IIS, logs event 1000.

.PARAMETER TargetLogRoot
    Destination root for IIS logs. Default 'E:\inetpub\logs'.

.PARAMETER AuditOnly
    When $true, report state only and make no changes.

.NOTES
    HOW TO RUN AD-HOC (show this to the client):
      1. Azure Automation Account -> Process Automation -> Runbooks -> Import a runbook.
         Import this .ps1 as a "PowerShell" runbook (5.1), then Publish.
      2. The relocation must run ON the IIS server, so the runbook executes on a
         Hybrid Runbook Worker. Onboard the Arc-enabled IIS server to a Hybrid Worker
         Group (Automation Account -> Hybrid worker groups). It runs locally as SYSTEM.
      3. Click Start. Set "Run on" = Hybrid Worker, pick the group. Optionally set
         AuditOnly = true for a dry run. View the result in the job Output pane.
#>
param(
    [ValidateNotNullOrEmpty()]
    [string]$TargetLogRoot = 'E:\inetpub\logs',

    [bool]$AuditOnly = $false
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
#  GENERATED from IISLogRelocation.psm1 - do not edit below by hand.
# ===========================================================================

'@

$body = @'

# ===========================================================================
#  Runbook entry point
# ===========================================================================

$state = Get-IISLogRelocationState -TargetLogRoot $TargetLogRoot

Write-Output ''
Write-Output '=== IIS Log Relocation - current state ==='
try {
    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
} catch {
    $fqdn = $env:COMPUTERNAME
}
Write-Output ("Server            : {0}  (FQDN: {1})" -f $env:COMPUTERNAME, $fqdn)
Write-Output ("Run at            : {0}" -f (Get-Date -Format 'u'))
Write-Output ("Status            : {0}" -f $state.Status)
Write-Output ("IISInstalled      : {0}" -f $state.IISInstalled)
Write-Output ("TargetLogRoot     : {0}" -f $state.TargetLogRoot)
Write-Output ("TargetDrivePresent: {0}" -f $state.TargetDrivePresent)
Write-Output ("Compliant         : {0}" -f $state.Compliant)
Write-Output ("ActionRequired    : {0}" -f $state.ActionRequired)
Write-Output ("Reason            : {0}" -f $state.Reason)

if ($state.LogDirectories) {
    Write-Output ''
    Write-Output '--- Log directories ---'
    foreach ($d in $state.LogDirectories) {
        Write-Output ("  [{0}] {1} -> {2} (OnSystemDrive={3})" -f $d.Scope, $d.Type, $d.Resolved, $d.OnSystemDrive)
    }
}

if ($AuditOnly) {
    Write-Output ''
    Write-Output 'AuditOnly = true - no changes were made.'
    return
}

# --- Act -------------------------------------------------------------------
switch ($state.Status) {
    'NotApplicable' {
        Write-Output 'IIS is not installed - nothing to do.'
    }
    'Compliant' {
        Write-Output 'Already compliant - nothing to do.'
    }
    'SkippedNoTargetDrive' {
        Write-Warning $state.Reason
        # Logs Application event 1001 so scheduled runs surface skipped servers.
        Set-IISLogRelocation -TargetLogRoot $TargetLogRoot -Confirm:$false
    }
    'NeedsRelocation' {
        Set-IISLogRelocation -TargetLogRoot $TargetLogRoot -Confirm:$false
        $after = Get-IISLogRelocationState -TargetLogRoot $TargetLogRoot
        Write-Output ''
        Write-Output ("=== After remediation: {0} ===" -f $after.Status)
        Write-Output $after.Reason
    }
}
'@

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$content = $header + "`r`n" + $funcs + "`r`n" + $body
Set-Content -LiteralPath $outFile -Value $content -Encoding UTF8

# Parse-check the generated runbook.
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($outFile, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count) {
    Write-Output "PARSE ERRORS:"
    $errors | ForEach-Object { Write-Output ("  {0}" -f $_.Message) }
    exit 1
}
Write-Output ("Generated OK: {0} ({1} bytes), parsed with 0 errors." -f $outFile, (Get-Item $outFile).Length)
