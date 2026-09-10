function Write-DbLog {
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
    if ($script:DbLogPath) { Add-Content -LiteralPath $script:DbLogPath -Value $line } else { Write-Verbose $line }
}
