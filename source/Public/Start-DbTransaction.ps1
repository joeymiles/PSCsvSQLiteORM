function Start-DbTransaction {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$Database)
    $conn = Get-DbConnection -Database $Database
    if ($conn -and $conn.State -eq 'Open') {
        $proceed = $true
        if ($PSCmdlet) { $proceed = $PSCmdlet.ShouldProcess($Database, 'Begin SQLite transaction') }
        if ($proceed) { return $conn.BeginTransaction() } else { return $null }
    }
    # Fallback path (PSSQLite): no persistent transaction support is guaranteed
    # BUG-049: make the degraded (auto-commit) mode visible instead of silently returning $null
    Write-DbLog WARN "Start-DbTransaction: System.Data.SQLite connection unavailable for '$Database'; statements will auto-commit."
    Write-Warning "Start-DbTransaction: no System.Data.SQLite connection for '$Database'; statements will auto-commit (no transaction)."
    Enable-ForeignKeysPragma -Database $Database
    return $null
}
