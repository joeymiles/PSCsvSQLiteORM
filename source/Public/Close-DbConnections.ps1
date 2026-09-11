function Close-DbConnections {
    # E2E1-003: declared as an advanced function (it takes no arguments and never did) so that callers can
    # use -WarningAction/-WarningVariable on the warning about an uncommitted transaction below.
    [CmdletBinding()]
    param()
    # Closes and disposes every pooled connection whatever its state (BUG-048): a connection that is Broken or
    # was closed without being disposed still holds native handles, so the database file stays locked.
    # Never throws: this also runs from the module's OnRemove handler (Remove-Module / Import-Module -Force).
    if (-not $script:DbPool) { $script:DbPool = @{}; if ($script:DbTx) { $script:DbTx.Clear() }; return }
    foreach ($key in @($script:DbPool.Keys)) {
        $conn = $script:DbPool[$key]
        if (-not $conn) { continue }
        # E2E1-003: Close()/Dispose() rolls an unfinished transaction back, and every statement made on this
        # database since it was started joined that transaction, so the work is about to be thrown away.
        # Do it deliberately and say so rather than letting the writes disappear without a word.
        try { [void](Clear-DbPendingTransaction -Connection $conn -Key $key -Reason 'Close-DbConnections is closing the connection') }
        catch { Write-Verbose "Close-DbConnections: pending transaction check failed: $($_.Exception.Message)" }
        try { if ($conn.State -ne 'Closed') { $conn.Close() } } catch { Write-Verbose "Close-DbConnections: Close failed: $($_.Exception.Message)" }
        try { $conn.Dispose() } catch { Write-Verbose "Close-DbConnections: Dispose failed: $($_.Exception.Message)" }
    }
    $script:DbPool.Clear()
    if ($script:DbTx) { $script:DbTx.Clear() }
}