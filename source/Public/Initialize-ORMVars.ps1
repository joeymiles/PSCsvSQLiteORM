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
    A call with no parameters resets everything it manages back to the built-in
    defaults: the connection pool, the pending-transaction map, the pragma cache,
    the log path, the log level, the default database path and every dynamic
    model registration (E2E1-029). Re-run Export-DynamicModelsFromCatalog or
    New-DynamicModel afterwards to register models again. Type names already
    handed out stay reserved for the lifetime of the session, because a
    PowerShell class cannot be unloaded once it has been defined.

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
    The script may write other things to the success stream (for example
    New-Item to create its own log directory); the last hashtable it emits is
    used. If it emits no hashtable at all the call throws instead of silently
    dropping the configuration (E2E1-023).
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
        # E2E1-023: dot-sourcing captures the script's whole success stream, so a settings script that emits
        # anything before its hashtable (the common New-Item that creates its own log directory, a stray
        # Write-Output) produced an Object[] and every configured key was dropped without a word. Pick the
        # settings hashtable out of whatever was emitted, and fail loudly when the script produced none.
        $cfg = @($cfg) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        if ($null -eq $cfg) {
            throw "Failed to load settings from '$SettingsPath': the script did not return a hashtable with keys DbPath, LogPath, LogLevel"
        }
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
    # E2E1-029: the reset must cover every piece of state this function owns. DbDefaultPath used to survive
    # (so a bare call wiped the logging configuration but kept a stale default database), DbLogFailedPaths kept
    # the warn-once markers of a log file that is no longer configured, and ModelRegistry outlived
    # DynamicClassScripts/ModelTypes/ModelTypeObjects, leaving the two halves of the dynamic-model state
    # disagreeing: Set-DynamicORMClass had nothing to load while New-DynamicRecord still answered from the
    # stale registry. DynamicTypeOwners is deliberately NOT cleared: a PowerShell class cannot be unloaded, so
    # a name handed out in this session stays reserved (BUG-036), and re-registering the same table after a
    # re-init gets its original readable type name back. DynamicModelDir is left alone too; the generated files
    # are removed by the module's OnRemove handler.
    $script:DbPool = @{}
    $script:DbTx = @{}
    $script:DbLogPath = $null
    $script:DbLogLevel = 'INFO'
    $script:DbDefaultPath = $null
    $script:DbLogFailedPaths = @{}
    $script:PragmaSet = @{}
    $script:ModelTypes = @{}
    $script:ModelTypeObjects = @{}
    $script:ModelRegistry = @{}
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
$script:DbDefaultPath = $null
$script:DbLogFailedPaths = @{}
$script:PragmaSet = @{}
$script:ModelTypes = @{}
$script:ModelTypeObjects = @{}
$script:ModelRegistry = @{}
$script:DynamicTypeOwners = @{}
$script:DynamicClassScripts = [System.Collections.ArrayList]::new()
