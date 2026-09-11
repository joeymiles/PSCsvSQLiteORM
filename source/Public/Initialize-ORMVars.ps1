Function Initialize-ORMVars {
    <#
    .SYNOPSIS
    Initializes internal ORM state and (optionally) applies configuration.

    .DESCRIPTION
    Sets up module-wide state such as connection pools and logging defaults.
    You may configure values directly via parameters or by providing a settings
    script that returns a hashtable with keys: DbPath, LogPath, LogLevel.
    Explicit parameters take precedence over values from the settings script.
    Any connections held in the pool are closed before the pool is reset.
    Settings are validated before any module state is changed, so a failing
    call leaves the previous configuration in place.

    .PARAMETER DbPath
    Optional default database path to store in module state.

    .PARAMETER LogPath
    Path to the log file. If omitted, logs are written via Write-Verbose.

    .PARAMETER LogLevel
    Logging threshold. One of: DEBUG, INFO, WARN, ERROR.

    .PARAMETER SettingsPath
    Path to a PowerShell script that returns a hashtable of settings.
    Example:
        @{ DbPath = 'C:\data\app.db'; LogPath = 'C:\logs\db.log'; LogLevel = 'DEBUG' }
    #>
    param (
        [string]$DbPath,
        [string]$LogPath,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$LogLevel,
        [string]$SettingsPath
    )

    # BUG-025: load and validate settings BEFORE touching any module state
    $cfg = $null
    if ($SettingsPath) {
        if (-not (Test-Path -LiteralPath $SettingsPath)) { throw "SettingsPath not found: $SettingsPath" }
        try { $cfg = . $SettingsPath } catch { throw "Failed to load settings from '$SettingsPath': $($_.Exception.Message)" }
        if ($cfg -and $cfg -is [hashtable]) {
            # BUG-058: explicit parameters override the settings file, as documented
            if ($cfg.ContainsKey('DbPath') -and -not $PSBoundParameters.ContainsKey('DbPath')) { $DbPath = [string]$cfg['DbPath'] }
            if ($cfg.ContainsKey('LogPath') -and -not $PSBoundParameters.ContainsKey('LogPath')) { $LogPath = [string]$cfg['LogPath'] }
            if ($cfg.ContainsKey('LogLevel') -and -not $PSBoundParameters.ContainsKey('LogLevel')) {
                $cfgLevel = [string]$cfg['LogLevel']
                if ($cfgLevel -and (@('DEBUG','INFO','WARN','ERROR') -notcontains $cfgLevel.ToUpperInvariant())) {
                    throw "Failed to load settings from '$SettingsPath': LogLevel '$cfgLevel' is not one of DEBUG, INFO, WARN, ERROR"
                }
                if ($cfgLevel) { $LogLevel = $cfgLevel.ToUpperInvariant() }
            }
        }
    }

    # BUG-025: close pooled connections before the pool is discarded so files are not left locked
    $oldPool = $null
    try { $oldPool = Get-Variable -Name DbPool -Scope Script -ValueOnly -ErrorAction Stop } catch { $oldPool = $null }
    if ($oldPool -and $oldPool.Count -gt 0) {
        foreach ($key in @($oldPool.Keys)) {
            $conn = $oldPool[$key]
            if ($conn) {
                # E2E1-003: closing the connection rolls back a transaction the caller never completed, and
                # every write made on that database since then goes with it. Roll it back on purpose and
                # warn, so the loss is visible instead of silent.
                try { [void](Clear-DbPendingTransaction -Connection $conn -Key ([string]$key) -Reason 'Initialize-ORMVars is resetting the connection pool') } catch { }
                try { if ($conn.State -eq 'Open') { $conn.Close() } } catch { }
                try { $conn.Dispose() } catch { }
            }
        }
    }

    # Initialize base state
    $script:DbPool = @{}
    $script:DbTx = @{}
    $script:DbLogPath = $null
    $script:DbLogLevel = 'INFO'
    $script:PragmaSet = @{}
    $script:ModelTypes = @{}
    $script:ModelTypeObjects = @{}
    $script:DynamicClassScripts = [System.Collections.ArrayList]::new()

    # Apply settings (settings file and/or explicit parameters). Explicit parameters override.
    if ($LogPath) { $script:DbLogPath = $LogPath }
    if ($LogLevel) { $script:DbLogLevel = $LogLevel }
    if ($DbPath) { $script:DbDefaultPath = $DbPath }

    # Summarize configuration for users at INFO level
    try {
        $logPathDisplay = if ($script:DbLogPath) { $script:DbLogPath } else { '(none)' }
        $dbPathDisplay = if ($script:DbDefaultPath) { $script:DbDefaultPath } else { '(none)' }
        Write-DbLog -Level INFO -Message ("ORM initialized. Level={0}, LogPath={1}, DefaultDb={2}" -f $script:DbLogLevel, $logPathDisplay, $dbPathDisplay)
    } catch {
        Write-Verbose "Initialize-ORMVars summary log failed: $($_.Exception.Message)"
    }
}

# BUG-011: set module defaults directly at import time. The module file is a concatenation of the
# source files in alphabetical order, so calling Initialize-ORMVars here would run before Write-DbLog
# is defined; command discovery for the missing name then auto-loads any other PSCsvSQLiteORM copy on
# PSModulePath. Plain assignments need no function and cannot trigger auto-loading.
$script:DbPool = @{}
$script:DbTx = @{}
$script:DbLogPath = $null
$script:DbLogLevel = 'INFO'
$script:PragmaSet = @{}
$script:ModelTypes = @{}
$script:ModelTypeObjects = @{}
$script:DynamicClassScripts = [System.Collections.ArrayList]::new()
