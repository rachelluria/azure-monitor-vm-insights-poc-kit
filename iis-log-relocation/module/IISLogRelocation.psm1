#requires -Version 5.1
<#
.SYNOPSIS
    Detects IIS and relocates the inetpub\logs folder (W3C site logs + FailedReqLogFiles)
    off the OS/system drive (C:) to a target drive (default E:\inetpub\logs).

.DESCRIPTION
    This module is the SINGLE SOURCE OF TRUTH for the relocation logic. It exposes three
    functions that follow the DSC Get/Test/Set contract:

        Get-IISLogRelocationState        -> rich state object (read-only)
        Test-IISLogRelocationCompliance  -> [bool] (read-only)
        Set-IISLogRelocation             -> performs the relocation (supports -WhatIf)

    The same module also defines the class-based DSC resource [IISLogRelocation] whose
    Get()/Test()/Set() methods simply delegate to those functions. That means the exact
    same code that you test interactively via Azure Run Command / an Automation runbook is
    what gets packaged by New-GuestConfigurationPackage for an Azure Machine Configuration
    policy -- no logic is rewritten between the two.

    Only sandbox-safe primitives are used (appcmd.exe, robocopy.exe, Get-Service,
    Get-Acl/Set-Acl) so behaviour is identical under Run Command and the Guest
    Configuration agent (which runs as SYSTEM).
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function Get-AppCmdPath {
    [CmdletBinding()]
    param()
    $path = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "appcmd.exe not found at '$path'. IIS does not appear to be installed."
    }
    $path
}

function Test-IISInstalled {
    [CmdletBinding()]
    param()
    # Primary check: appcmd present AND the W3SVC service exists. This avoids a hard
    # dependency on the ServerManager / WebAdministration modules, which are not always
    # installed alongside the Web-Server role.
    $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    if (Test-Path -LiteralPath $appcmd) {
        if (Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue) { return $true }
    }
    # Fallback: feature inventory on Windows Server.
    if (Get-Command -Name 'Get-WindowsFeature' -ErrorAction SilentlyContinue) {
        try {
            $feature = Get-WindowsFeature -Name 'Web-Server' -ErrorAction SilentlyContinue
            if ($feature -and $feature.Installed) { return $true }
        } catch {
            # Get-WindowsFeature unavailable/errored (e.g. client SKU); fall through to $false.
            Write-Verbose "Get-WindowsFeature check failed: $($_.Exception.Message)"
        }
    }
    return $false
}

function Test-PathOnSystemDrive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path).Trim()
    $systemDrive = $env:SystemDrive   # e.g. 'C:'
    return $expanded.ToUpperInvariant().StartsWith($systemDrive.ToUpperInvariant())
}

function New-LogDirRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Raw
    )
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Raw)
    [PSCustomObject]@{
        Scope         = $Scope
        Type          = $Type
        Configured    = $Raw
        Resolved      = $expanded
        OnSystemDrive = (Test-PathOnSystemDrive -Path $expanded)
    }
}

function Get-IISLogConfig {
    <#
        Reads the IIS sites configuration via appcmd and returns the configured (raw,
        possibly environment-variable) log directories for siteDefaults and each site.
        Missing attributes fall back to the IIS schema default under %SystemDrive%.
    #>
    [CmdletBinding()]
    param()

    $appcmd     = Get-AppCmdPath
    $defaultLog = '%SystemDrive%\inetpub\logs\LogFiles'
    $defaultFrt = '%SystemDrive%\inetpub\logs\FailedReqLogFiles'

    $sdLog = $defaultLog
    $sdFrt = $defaultFrt
    $sites = @()

    $raw = & $appcmd 'list' 'config' '-section:system.applicationHost/sites' '/xml' 2>$null
    $xml = $null
    if ($raw) {
        try { $xml = [xml]($raw -join "`n") } catch { $xml = $null }
    }

    if ($xml) {
        $siteDefaults = $xml.SelectSingleNode('//siteDefaults')
        if ($siteDefaults) {
            $node = $siteDefaults.SelectSingleNode('logFile')
            if ($node) { $value = $node.GetAttribute('directory'); if ($value) { $sdLog = $value } }
            $node = $siteDefaults.SelectSingleNode('traceFailedRequestsLogging')
            if ($node) { $value = $node.GetAttribute('directory'); if ($value) { $sdFrt = $value } }
        }

        foreach ($site in $xml.SelectNodes('//site[@name]')) {
            $name = $site.GetAttribute('name')
            if (-not $name) { continue }
            $log = $sdLog
            $frt = $sdFrt
            $node = $site.SelectSingleNode('logFile')
            if ($node) { $value = $node.GetAttribute('directory'); if ($value) { $log = $value } }
            $node = $site.SelectSingleNode('traceFailedRequestsLogging')
            if ($node) { $value = $node.GetAttribute('directory'); if ($value) { $frt = $value } }
            $sites += [PSCustomObject]@{ Name = $name; LogFiles = $log; FailedReq = $frt }
        }
    }

    [PSCustomObject]@{
        SiteDefaults = [PSCustomObject]@{ LogFiles = $sdLog; FailedReq = $sdFrt }
        Sites        = $sites
    }
}

function New-LogDirectoryWithAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$GrantIISUsersModify
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    try {
        $acl     = Get-Acl -LiteralPath $Path
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        $prop    = [System.Security.AccessControl.PropagationFlags]::None
        $allow   = [System.Security.AccessControl.AccessControlType]::Allow

        $rules = @(
            New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM', 'FullControl', $inherit, $prop, $allow)
            New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators', 'FullControl', $inherit, $prop, $allow)
        )
        if ($GrantIISUsersModify) {
            # Failed-request trace logs are written by the worker process (app pool identity),
            # which is a member of IIS_IUSRS, so it needs write access to that folder.
            $rules += New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\IIS_IUSRS', 'Modify', $inherit, $prop, $allow)
        }
        foreach ($rule in $rules) { $acl.AddAccessRule($rule) }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-Warning "Could not set ACLs on '$Path': $($_.Exception.Message)"
    }
}

function Move-LogTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Verbose "Source '$Source' does not exist; nothing to move."
        return
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $robocopy = Join-Path $env:windir 'system32\robocopy.exe'
    & $robocopy $Source $Destination '/E' '/MOVE' '/COPYALL' '/R:1' '/W:1' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        Write-Warning "robocopy reported errors (exit $code) moving '$Source' to '$Destination'. The active log file may be locked and left in place; it will roll over to the new location on the next log period."
    } else {
        Write-Verbose "Moved '$Source' -> '$Destination' (robocopy exit $code)."
    }
}

function Set-IISSiteDefaultLogDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppCmd,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$FrtDir
    )
    & $AppCmd 'set' 'config' '-section:system.applicationHost/sites' "/siteDefaults.logFile.directory:$LogDir" '/commit:apphost' | Out-Null
    & $AppCmd 'set' 'config' '-section:system.applicationHost/sites' "/siteDefaults.traceFailedRequestsLogging.directory:$FrtDir" '/commit:apphost' | Out-Null
}

function Set-IISSiteLogDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppCmd,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$FrtDir
    )
    & $AppCmd 'set' 'site' "$Name" "/logFile.directory:$LogDir" | Out-Null
    & $AppCmd 'set' 'site' "$Name" "/traceFailedRequestsLogging.directory:$FrtDir" | Out-Null
}

function Write-RelocationEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$EventId,
        [ValidateSet('Information', 'Warning', 'Error')][string]$EntryType = 'Information',
        [Parameter(Mandatory)][string]$Message
    )
    $source = 'IISLogRelocation'
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
            New-EventLog -LogName 'Application' -Source $source -ErrorAction Stop
        }
        Write-EventLog -LogName 'Application' -Source $source -EventId $EventId -EntryType $EntryType -Message $Message -ErrorAction Stop
    } catch {
        Write-Verbose "Could not write Application event log entry ($EventId): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Public functions (Get / Test / Set)
# ---------------------------------------------------------------------------

function Get-IISLogRelocationState {
    <#
    .SYNOPSIS
        Returns the current IIS log relocation state for this machine. Read-only.
    .OUTPUTS
        PSCustomObject with: Status, IISInstalled, TargetLogRoot, TargetDrive,
        TargetDrivePresent, Compliant, ActionRequired, Reason, LogDirectories.
        Status is one of: NotApplicable | Compliant | NeedsRelocation | SkippedNoTargetDrive.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TargetLogRoot = 'E:\inetpub\logs'
    )

    $targetDrive  = Split-Path -Qualifier $TargetLogRoot   # e.g. 'E:'
    $drivePresent = Test-Path -LiteralPath ("$targetDrive\")
    $systemDrive  = $env:SystemDrive

    if (-not (Test-IISInstalled)) {
        return [PSCustomObject]@{
            Status             = 'NotApplicable'
            IISInstalled       = $false
            TargetLogRoot      = $TargetLogRoot
            TargetDrive        = $targetDrive
            TargetDrivePresent = $drivePresent
            Compliant          = $true
            ActionRequired     = $false
            Reason             = 'IIS feature not installed; nothing to relocate.'
            LogDirectories     = @()
        }
    }

    $config  = Get-IISLogConfig
    $logDirs = @()
    $logDirs += New-LogDirRecord -Scope 'siteDefaults' -Type 'LogFiles'          -Raw $config.SiteDefaults.LogFiles
    $logDirs += New-LogDirRecord -Scope 'siteDefaults' -Type 'FailedReqLogFiles' -Raw $config.SiteDefaults.FailedReq
    foreach ($site in $config.Sites) {
        $logDirs += New-LogDirRecord -Scope $site.Name -Type 'LogFiles'          -Raw $site.LogFiles
        $logDirs += New-LogDirRecord -Scope $site.Name -Type 'FailedReqLogFiles' -Raw $site.FailedReq
    }

    $onSystem = @($logDirs | Where-Object { $_.OnSystemDrive })

    if ($onSystem.Count -eq 0) {
        $status = 'Compliant'
        $reason = "All IIS log directories are already off the system drive ($systemDrive)."
    } elseif (-not $drivePresent) {
        $status = 'SkippedNoTargetDrive'
        $reason = "Target drive $targetDrive is not present on this server. $($onSystem.Count) IIS log path(s) remain on $systemDrive and require manual action (no auto-relocation)."
    } else {
        $status = 'NeedsRelocation'
        $reason = "$($onSystem.Count) IIS log path(s) on $systemDrive will be relocated to $TargetLogRoot."
    }

    [PSCustomObject]@{
        Status             = $status
        IISInstalled       = $true
        TargetLogRoot      = $TargetLogRoot
        TargetDrive        = $targetDrive
        TargetDrivePresent = $drivePresent
        # SkippedNoTargetDrive counts as compliant for enforcement purposes so an
        # ApplyAndAutoCorrect policy does not churn on servers that lack the target drive.
        Compliant          = ($status -in @('Compliant', 'NotApplicable', 'SkippedNoTargetDrive'))
        ActionRequired     = ($status -eq 'NeedsRelocation')
        Reason             = $reason
        LogDirectories     = $logDirs
    }
}

function Test-IISLogRelocationCompliance {
    <#
    .SYNOPSIS
        Returns $true when no enforcement action is needed (or possible) on this machine.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TargetLogRoot = 'E:\inetpub\logs'
    )
    (Get-IISLogRelocationState -TargetLogRoot $TargetLogRoot).Compliant
}

function Set-IISLogRelocation {
    <#
    .SYNOPSIS
        Relocates IIS logs to the target drive. Idempotent and -WhatIf aware.
    .DESCRIPTION
        - IIS not installed or already compliant: no-op.
        - Target drive missing: soft-skip and log Application event 1001 (no error, no
          fallback to the system drive).
        - Otherwise: create the target folders with ACLs, move existing logs, and repoint
          siteDefaults plus any affected site, then log Application event 1000.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TargetLogRoot = 'E:\inetpub\logs'
    )

    $state = Get-IISLogRelocationState -TargetLogRoot $TargetLogRoot

    switch ($state.Status) {
        'NotApplicable' { Write-Verbose $state.Reason; return }
        'Compliant'     { Write-Verbose $state.Reason; return }
        'SkippedNoTargetDrive' {
            Write-Warning $state.Reason
            if (-not $WhatIfPreference) {
                Write-RelocationEvent -EventId 1001 -EntryType 'Warning' -Message $state.Reason
            }
            return
        }
    }

    # --- Status is NeedsRelocation ---
    $appcmd    = Get-AppCmdPath
    # [IO.Path]::Combine is string-only; Join-Path resolves the drive qualifier and would
    # throw "drive does not exist" on a server genuinely missing the target drive.
    $targetLog = [System.IO.Path]::Combine($TargetLogRoot, 'LogFiles')
    $targetFrt = [System.IO.Path]::Combine($TargetLogRoot, 'FailedReqLogFiles')

    if ($PSCmdlet.ShouldProcess($targetLog, 'Create IIS log directory with ACLs')) {
        New-LogDirectoryWithAcl -Path $targetLog
    }
    if ($PSCmdlet.ShouldProcess($targetFrt, 'Create failed-request log directory with ACLs')) {
        New-LogDirectoryWithAcl -Path $targetFrt -GrantIISUsersModify
    }

    $logSources = @($state.LogDirectories | Where-Object { $_.OnSystemDrive -and $_.Type -eq 'LogFiles' } | Select-Object -ExpandProperty Resolved -Unique)
    foreach ($source in $logSources) {
        if ($PSCmdlet.ShouldProcess("$source -> $targetLog", 'Move IIS site logs')) {
            Move-LogTree -Source $source -Destination $targetLog
        }
    }

    $frtSources = @($state.LogDirectories | Where-Object { $_.OnSystemDrive -and $_.Type -eq 'FailedReqLogFiles' } | Select-Object -ExpandProperty Resolved -Unique)
    foreach ($source in $frtSources) {
        if ($PSCmdlet.ShouldProcess("$source -> $targetFrt", 'Move failed-request logs')) {
            Move-LogTree -Source $source -Destination $targetFrt
        }
    }

    if ($PSCmdlet.ShouldProcess('IIS siteDefaults', "Repoint log directories to $TargetLogRoot")) {
        Set-IISSiteDefaultLogDir -AppCmd $appcmd -LogDir $targetLog -FrtDir $targetFrt
    }

    $affectedSites = @($state.LogDirectories | Where-Object { $_.OnSystemDrive -and $_.Scope -ne 'siteDefaults' } | Select-Object -ExpandProperty Scope -Unique)
    foreach ($site in $affectedSites) {
        if ($PSCmdlet.ShouldProcess("site '$site'", "Repoint log directories to $TargetLogRoot")) {
            Set-IISSiteLogDir -AppCmd $appcmd -Name $site -LogDir $targetLog -FrtDir $targetFrt
        }
    }

    $message = "Relocated IIS logs to $TargetLogRoot. Repointed siteDefaults" +
        $(if ($affectedSites.Count) { " and $($affectedSites.Count) site(s)" } else { '' }) +
        "; moved $($logSources.Count) log path(s) and $($frtSources.Count) failed-request path(s) from $($env:SystemDrive)."
    if (-not $WhatIfPreference) {
        Write-RelocationEvent -EventId 1000 -EntryType 'Information' -Message $message
    }
    Write-Verbose $message
}

# ---------------------------------------------------------------------------
# Class-based DSC resource (used when packaged for Azure Machine Configuration).
# Its methods delegate to the functions above so the logic is never duplicated.
# ---------------------------------------------------------------------------

[DscResource()]
class IISLogRelocation {

    [DscProperty(Key)]
    [string] $TargetLogRoot = 'E:\inetpub\logs'

    [DscProperty(NotConfigurable)]
    [string] $Status

    [DscProperty(NotConfigurable)]
    [string] $Reason

    [IISLogRelocation] Get() {
        $state        = Get-IISLogRelocationState -TargetLogRoot $this.TargetLogRoot
        $this.Status  = $state.Status
        $this.Reason  = $state.Reason
        return $this
    }

    [bool] Test() {
        return (Test-IISLogRelocationCompliance -TargetLogRoot $this.TargetLogRoot)
    }

    [void] Set() {
        Set-IISLogRelocation -TargetLogRoot $this.TargetLogRoot -Confirm:$false
    }
}

Export-ModuleMember -Function 'Get-IISLogRelocationState', 'Test-IISLogRelocationCompliance', 'Set-IISLogRelocation'
