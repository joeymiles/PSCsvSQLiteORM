# [B] Private helpers that keep track of the transaction a pooled connection is inside (E2E1-003). Not exported.
#
# Every statement for one database goes through the single System.Data.SQLite connection that
# Get-DbConnection keeps in $script:DbPool, so a transaction that is started and never completed keeps
# swallowing writes for the rest of the session: Close()/Dispose() rolls it back, and the work made since
# Start-DbTransaction disappears with no error and no warning. The module used to record nothing about the
# pending transaction, so it could neither report nor clear that state. $script:DbTx maps a pool key to the
# transaction handles started for it, outermost first (System.Data.SQLite allows a nested BeginTransaction,
# and Import-CsvToSqlite relies on that when the caller already holds a transaction).

function Get-DbTransactionMap {
    if (-not $script:DbTx) { $script:DbTx = @{} }
    return $script:DbTx
}

# A SQLiteTransaction drops its Connection reference once it has been committed, rolled back or disposed.
function Test-DbTransactionHandleLive {
    param($Transaction)
    if (-not $Transaction) { return $false }
    try { return ($null -ne $Transaction.Connection) } catch { return $false }
}

# The outermost transaction handle still open for a pool key, or $null. Completed handles are pruned.
function Get-DbPendingTransaction {
    param([Parameter(Mandatory)][string]$Key)
    $map = Get-DbTransactionMap
    if (-not $map.ContainsKey($Key)) { return $null }
    $live = @(@($map[$Key]) | Where-Object { Test-DbTransactionHandleLive -Transaction $_ })
    if ($live.Count -eq 0) { $map.Remove($Key); return $null }
    $map[$Key] = $live
    return $live[0]
}

function Register-DbTransaction {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)]$Transaction)
    $map = Get-DbTransactionMap
    $current = @()
    if ($map.ContainsKey($Key)) { $current = @(@($map[$Key]) | Where-Object { Test-DbTransactionHandleLive -Transaction $_ }) }
    $map[$Key] = @($current + $Transaction)
}

function Unregister-DbTransaction {
    param([Parameter(Mandatory)][string]$Key, $Transaction)
    $map = Get-DbTransactionMap
    if (-not $map.ContainsKey($Key)) { return }
    $remaining = @(@($map[$Key]) | Where-Object {
            (Test-DbTransactionHandleLive -Transaction $_) -and -not [object]::ReferenceEquals($_, $Transaction)
        })
    if ($remaining.Count -eq 0) { $map.Remove($Key) } else { $map[$Key] = $remaining }
}

# $true when the pooled connection is inside a transaction. SQLiteConnection.AutoCommit reports what the
# engine itself thinks, so it also sees a BEGIN issued as plain SQL; the tracked handles are the fallback
# for builds that do not expose that property.
function Test-DbConnectionInTransaction {
    param($Connection, [string]$Key)
    if ($Connection) {
        try {
            if ($Connection.State -eq 'Open') {
                $prop = $Connection.PSObject.Properties['AutoCommit']
                if ($prop) { return (-not $prop.Value) }
            }
        }
        catch {
            Write-Verbose "Test-DbConnectionInTransaction: AutoCommit unavailable: $($_.Exception.Message)"
        }
    }
    if ($Key) { return ($null -ne (Get-DbPendingTransaction -Key $Key)) }
    return $false
}

# Rolls back a transaction the caller never completed, after saying so, so that the writes it swallowed are
# not discarded silently when the connection is closed or the pool is reset. Returns $true when there was
# something to roll back. Never throws: it also runs from the module's OnRemove handler.
function Clear-DbPendingTransaction {
    param(
        $Connection,
        [Parameter(Mandatory)][string]$Key,
        [string]$Reason = 'the connection is being closed',
        # Set when the caller asked for the rollback on purpose, so only the log line is written.
        [switch]$Quiet
    )
    $map = Get-DbTransactionMap
    if (-not (Test-DbConnectionInTransaction -Connection $Connection -Key $Key)) {
        $map.Remove($Key)
        return $false
    }
    $message = "PSCsvSQLiteORM: rolling back an uncommitted transaction on '$Key' because $Reason. Every write made on that database since Start-DbTransaction is discarded; call Complete-DbTransaction to keep it."
    if (-not $Quiet) { try { Write-Warning $message } catch { } }
    try { Write-DbLog WARN $message } catch { }
    $tx = Get-DbPendingTransaction -Key $Key
    if ($tx) {
        try { $tx.Rollback() } catch { Write-Verbose "Clear-DbPendingTransaction: Rollback failed: $($_.Exception.Message)" }
        try { $tx.Dispose() } catch { }
    }
    elseif ($Connection) {
        # No handle left (for example a BEGIN issued as plain SQL): undo it on the connection itself.
        $cmd = $null
        try {
            $cmd = $Connection.CreateCommand()
            $cmd.CommandText = 'ROLLBACK;'
            [void]$cmd.ExecuteNonQuery()
        }
        catch { Write-Verbose "Clear-DbPendingTransaction: ROLLBACK failed: $($_.Exception.Message)" }
        finally { if ($cmd) { try { $cmd.Dispose() } catch { } } }
    }
    $map.Remove($Key)
    return $true
}
