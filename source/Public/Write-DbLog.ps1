function Write-DbLog {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Message,
        [System.Exception]$Exception
    )
    $levels = @('DEBUG', 'INFO', 'WARN', 'ERROR')
    # An omitted or unrecognised -Level means INFO. Without this the level index is -1, which sorts below every
    # threshold, so a message logged without a level was dropped with no error at all (E2E1-028).
    if ($levels.IndexOf($Level) -lt 0) { $Level = 'INFO' }
    if ($levels.IndexOf($Level) -lt $levels.IndexOf($script:DbLogLevel)) { return }
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$ts][$Level] $Message"
    if ($Exception) { $line += " :: " + $Exception.Message }
    # Write-DbLogLine (private) creates the log directory, writes UTF-8, serialises concurrent writers and never
    # throws, so a bad LogPath cannot abort the database operation that is being logged (BUG-046, BUG-070).
    if ($script:DbLogPath) { Write-DbLogLine -Path $script:DbLogPath -Line $line | Out-Null } else { Write-Verbose $line }
}
