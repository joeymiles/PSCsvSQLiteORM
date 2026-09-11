function Complete-DbTransaction {
    <#
    .SYNOPSIS
    Commits a transaction started with Start-DbTransaction.

    .DESCRIPTION
    Pass the handle returned by Start-DbTransaction. When -Transaction is omitted
    (E2E1-003), the transaction the module recorded for -Database is committed, so a
    script that no longer has the handle can still finish the transaction instead of
    losing its writes when the connection closes. On the PSSQLite fallback path, where
    Start-DbTransaction returns nothing and statements auto-commit, this is a no-op.
    #>
    param([Parameter(Mandatory)][string]$Database, [System.Data.SQLite.SQLiteTransaction]$Transaction)
    $key = Resolve-DbPath -Database $Database
    if ($Transaction) {
        $Transaction.Commit(); $Transaction.Dispose()
        Unregister-DbTransaction -Key $key -Transaction $Transaction
        return
    }
    # E2E1-003: -Transaction left out altogether (as opposed to a caller passing the $null that
    # Start-DbTransaction returns on the fallback path): commit the transaction the module started
    # for this database, when one is still open.
    if (-not $PSBoundParameters.ContainsKey('Transaction')) {
        $pending = Get-DbPendingTransaction -Key $key
        if ($pending) {
            $pending.Commit(); $pending.Dispose()
            Unregister-DbTransaction -Key $key -Transaction $pending
            return
        }
    }
    # Fallback path without transaction object: no-op
}

