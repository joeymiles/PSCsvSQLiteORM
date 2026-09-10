function Write-DbLog {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Message,
        [System.Exception]$Exception
    )
    $levels = @('DEBUG', 'INFO', 'WARN', 'ERROR')
    if ($levels.IndexOf($Level) -lt $levels.IndexOf($script:DbLogLevel)) { return }
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$ts][$Level] $Message"
    if ($Exception) { $line += " :: " + $Exception.Message }
    # Write-DbLogLine (private) creates the log directory, writes UTF-8, serialises concurrent writers and never
    # throws, so a bad LogPath cannot abort the database operation that is being logged (BUG-046, BUG-070).
    if ($script:DbLogPath) { Write-DbLogLine -Path $script:DbLogPath -Line $line | Out-Null } else { Write-Verbose $line }
}
