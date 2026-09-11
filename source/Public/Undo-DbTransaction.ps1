function Undo-DbTransaction {
    <#
    .SYNOPSIS
    Rolls back a transaction started with Start-DbTransaction.

    .DESCRIPTION
    Pass the handle returned by Start-DbTransaction. When -Transaction is omitted
    (E2E1-003), the transaction that is still open on the pooled connection for
    -Database is rolled back, which is how a script clears a transaction whose handle
    it no longer has before its statements start joining that transaction unnoticed.
    On the PSSQLite fallback path, where Start-DbTransaction returns nothing and
    statements auto-commit, this is a no-op.
    #>
    param([Parameter(Mandatory)][string]$Database, [System.Data.SQLite.SQLiteTransaction]$Transaction)
    $key = Resolve-DbPath -Database $Database
    if ($Transaction) {
        $Transaction.Rollback(); $Transaction.Dispose()
        Unregister-DbTransaction -Key $key -Transaction $Transaction
        return
    }
    # E2E1-003: -Transaction left out altogether (as opposed to a caller passing the $null that
    # Start-DbTransaction returns on the fallback path): roll back whatever transaction is still
    # open on the pooled connection for this database.
    if (-not $PSBoundParameters.ContainsKey('Transaction')) {
        $conn = $null
        if ($script:DbPool -and $script:DbPool.ContainsKey($key)) { $conn = $script:DbPool[$key] }
        if (Test-DbConnectionInTransaction -Connection $conn -Key $key) {
            [void](Clear-DbPendingTransaction -Connection $conn -Key $key -Reason 'Undo-DbTransaction was called for it' -Quiet)
            return
        }
    }
    # Fallback path without transaction object: no-op
}

