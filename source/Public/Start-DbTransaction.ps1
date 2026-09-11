function Start-DbTransaction {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][string]$Database)
    $key = Resolve-DbPath -Database $Database
    $conn = Get-DbConnection -Database $Database
    if ($conn -and $conn.State -eq 'Open') {
        $proceed = $true
        if ($PSCmdlet) { $proceed = $PSCmdlet.ShouldProcess($Database, 'Begin SQLite transaction') }
        if (-not $proceed) { return $null }
        # E2E1-003: record the transaction against the pool key. Every statement for this database goes
        # through the same pooled connection and therefore joins this transaction, so the module has to be
        # able to see it: Test-DbTransaction reports it, Complete-/Undo-DbTransaction can finish it without
        # the handle, and Close-DbConnections warns instead of discarding the work silently.
        if (Get-DbPendingTransaction -Key $key) {
            # System.Data.SQLite nests: an inner handle only decrements the transaction level and the
            # outermost one commits. Import-CsvToSqlite relies on that when the caller already holds a
            # transaction, so nesting is allowed here - but it is worth a log line.
            Write-DbLog DEBUG "Start-DbTransaction: '$key' already has an open transaction; nesting."
        }
        $tx = $conn.BeginTransaction()
        Register-DbTransaction -Key $key -Transaction $tx
        return $tx
    }
    # Fallback path (PSSQLite): no persistent transaction support is guaranteed
    # BUG-049: make the degraded (auto-commit) mode visible instead of silently returning $null
    Write-DbLog WARN "Start-DbTransaction: System.Data.SQLite connection unavailable for '$Database'; statements will auto-commit."
    Write-Warning "Start-DbTransaction: no System.Data.SQLite connection for '$Database'; statements will auto-commit (no transaction)."
    Enable-ForeignKeysPragma -Database $Database
    return $null
}
