function Update-DbColumnType {
    <#
    .SYNOPSIS
        Widens the declared type of one or more columns by rebuilding the table.
    .DESCRIPTION
        SQLite cannot ALTER a column type, so the table is rebuilt in place:
        a copy with the new column types is created, the rows are copied, the
        old table is dropped and the copy is renamed. Indexes and triggers that
        belong to the table - and triggers on other tables that reference it by
        name, such as the ON DELETE triggers Confirm-DbForeignKey puts on the
        parent - are re-created afterwards. Foreign key enforcement is switched
        off for the duration of the rebuild so child tables keep their rows and
        their references to the table name. The rebuild runs inside a SAVEPOINT
        and is rolled back to that savepoint if any statement fails, so a failure
        never leaves the table dropped or the connection inside an aborted
        transaction. A savepoint is used instead of BEGIN/COMMIT so the rebuild
        also works when the caller already has a transaction open, and so that a
        failure undoes only the rebuild's own work, never the caller's.
        ColumnTypes maps column name to the new storage type (for example
        @{ zip = 'TEXT' }). A PRIMARY KEY column loses AUTOINCREMENT when it
        stops being INTEGER.
    #>
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][hashtable]$ColumnTypes
    )
    $quotedTable = ConvertTo-Ident $Table
    $meta = @(Invoke-DbQuery -Database $Database -Query "SELECT sql FROM sqlite_master WHERE type='table' AND name=@t" -SqlParameters @{ t = $Table })
    if ($meta.Count -eq 0 -or -not $meta[0].sql) { throw "Cannot widen columns of table '$Table': table definition not found" }
    $originalSql = [string]$meta[0].sql
    $newSql = $originalSql

    foreach ($col in @($ColumnTypes.Keys)) {
        $newType = [string]$ColumnTypes[$col]
        if ($newType -notmatch '^[A-Za-z]+$') { throw "Cannot widen column '$col' of table '$Table': invalid type '$newType'" }
        # E2E1-021: inside the stored CREATE TABLE text an embedded double quote is doubled (the
        # column co"l is written as "co""l"), because ConvertTo-Ident quotes it that way and such
        # names are accepted now. Match the doubled form, not the raw one, or the widen throws
        # "column definition not recognised" for any column whose name contains a quote. For a
        # name without a quote both forms are identical, so nothing else changes.
        $identPattern = '(?:"' + [regex]::Escape(($col -replace '"', '""')) + '"|' + [regex]::Escape($col) + ')'
        # "<col> <type>" right after "(" or "," at the start of a column definition
        $defPattern = '(?i)([(,]\s*)(' + $identPattern + ')\s+([A-Za-z]+(?:\s*\([^)]*\))?)'
        $m = [regex]::Match($newSql, $defPattern)
        if (-not $m.Success) { throw "Cannot widen column '$col' of table '$Table': column definition not recognised in: $originalSql" }
        $replacement = $m.Groups[1].Value + $m.Groups[2].Value + ' ' + $newType
        $newSql = $newSql.Substring(0, $m.Index) + $replacement + $newSql.Substring($m.Index + $m.Length)
        if ($newType -notmatch '(?i)INT') {
            # AUTOINCREMENT is only legal on INTEGER PRIMARY KEY
            $autoPattern = '(?i)(' + $identPattern + '\s+' + [regex]::Escape($newType) + '\s+PRIMARY\s+KEY)\s+AUTOINCREMENT'
            $newSql = [regex]::Replace($newSql, $autoPattern, '$1')
        }
    }

    $tmpName = $Table + '__widen_tmp'
    $quotedTmp = ConvertTo-Ident $tmpName
    $headPattern = '(?i)^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"(?:[^"]|"")+"|\[[^\]]+\]|`[^`]+`|[^\s(]+)'
    if ($newSql -notmatch $headPattern) { throw "Cannot widen columns of table '$Table': table definition not recognised in: $originalSql" }
    $createTmp = [regex]::Replace($newSql, $headPattern, ('CREATE TABLE ' + $quotedTmp), 1)

    $columns = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTable)" | ForEach-Object { ConvertTo-Ident $_.name })
    $colList = $columns -join ', '
    $dependents = @(Invoke-DbQuery -Database $Database -Query "SELECT sql FROM sqlite_master WHERE tbl_name=@t AND type IN ('index','trigger') AND sql IS NOT NULL" -SqlParameters @{ t = $Table })

    # E2E1-001: triggers that live on ANOTHER table but reference this one by name are not covered by
    # the query above - Confirm-DbForeignKey puts exactly such an ON DELETE trigger on the parent
    # table. On SQLite 3.25+ "ALTER TABLE ... RENAME TO" reparses every trigger in the schema, so a
    # trigger naming a table that is dropped at that moment aborts the whole rebuild. Drop those
    # triggers for the duration of the rebuild and recreate them from their stored SQL afterwards.
    # E2E1-021: same doubling rule as $identPattern above - a table name carrying a double quote is
    # stored as "a""b", so the quoted alternative has to look for the doubled form.
    $tableIdentPattern = '(?i)(?:"' + [regex]::Escape(($Table -replace '"', '""')) + '"|(?<!\w)' + [regex]::Escape($Table) + '(?!\w))'
    $foreignTriggers = @(Invoke-DbQuery -Database $Database -Query "SELECT name, sql FROM sqlite_master WHERE type='trigger' AND sql IS NOT NULL AND tbl_name<>@t" -SqlParameters @{ t = $Table } |
            Where-Object { ([string]$_.sql) -match $tableIdentPattern })

    # E2E1-001: the rebuild is wrapped in a SAVEPOINT rather than BEGIN/COMMIT. Outside a transaction
    # a savepoint behaves exactly like BEGIN/COMMIT; inside one - the caller may hold a transaction
    # from Start-DbTransaction - BEGIN would fail outright ("cannot start a transaction within a
    # transaction") and a plain ROLLBACK in the failure path would throw the caller's uncommitted
    # work away. ROLLBACK TO only undoes what the rebuild itself did.
    $savepoint = ConvertTo-Ident 'psorm_widen_rebuild'
    # Restore foreign_keys to whatever the connection had rather than forcing it ON.
    $fkBefore = Invoke-DbQuery -Database $Database -Query 'PRAGMA foreign_keys' | Select-Object -First 1
    $fkRestore = 'ON'
    if ($fkBefore -and "$($fkBefore.foreign_keys)" -eq '0') { $fkRestore = 'OFF' }

    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('PRAGMA foreign_keys = OFF;')
    # Belt and braces for the same reparse: legacy_alter_table exists in exactly the SQLite versions
    # that reparse on rename, and older builds ignore an unknown pragma silently.
    $steps.Add('PRAGMA legacy_alter_table = ON;')
    $steps.Add("SAVEPOINT $savepoint;")
    $steps.Add("DROP TABLE IF EXISTS $quotedTmp;")
    foreach ($f in $foreignTriggers) { $steps.Add("DROP TRIGGER IF EXISTS $(ConvertTo-Ident ([string]$f.name));") }
    $steps.Add($createTmp + ';')
    $steps.Add("INSERT INTO $quotedTmp ($colList) SELECT $colList FROM $quotedTable;")
    $steps.Add("DROP TABLE $quotedTable;")
    $steps.Add("ALTER TABLE $quotedTmp RENAME TO $quotedTable;")
    foreach ($d in $dependents) { $steps.Add(([string]$d.sql) + ';') }
    foreach ($f in $foreignTriggers) { $steps.Add(([string]$f.sql) + ';') }
    $steps.Add("RELEASE $savepoint;")
    $steps.Add('PRAGMA legacy_alter_table = OFF;')
    $steps.Add("PRAGMA foreign_keys = $fkRestore;")
    $script = $steps -join "`n"
    Write-DbLog INFO "Rebuilding table $Table to widen columns: $(($ColumnTypes.Keys | ForEach-Object { "$_=$($ColumnTypes[$_])" }) -join ', ')"
    try {
        Invoke-DbQuery -Database $Database -Query $script -NonQuery | Out-Null
    }
    catch {
        # E2E1-001: the batch aborts at the failing statement, which is past SAVEPOINT and possibly
        # past "DROP TABLE <original>". Without an explicit rollback the pooled connection stays
        # inside the transaction the savepoint opened, so every later statement in the session
        # silently joins it and is thrown away when the connection closes, and the original table
        # stays missing for the rest of the session. Reset-DbRebuildState rolls back to the savepoint
        # (never further, so a caller-owned transaction survives) and restores the two pragmas.
        $rebuildError = $_
        Reset-DbRebuildState -Database $Database -Savepoint $savepoint -ForeignKeys $fkRestore
        Write-DbLog ERROR "Rebuild of table $Table failed; it was rolled back to its savepoint" $rebuildError.Exception
        throw $rebuildError
    }

    # Verify (on Windows PowerShell 5.1 the PSSQLite fallback reports SQL errors non-terminatingly)
    $after = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($quotedTable)")
    foreach ($col in @($ColumnTypes.Keys)) {
        $info = $after | Where-Object { $_.name -eq $col } | Select-Object -First 1
        if (-not $info -or "$($info.type)" -ne [string]$ColumnTypes[$col]) {
            throw "Failed to widen column '$col' of table '$Table' to $($ColumnTypes[$col])"
        }
    }
}

# [B] Private helper for Update-DbColumnType (E2E1-001). Not exported.
#
# A rebuild batch that fails part way through leaves the pooled System.Data.SQLite connection inside
# the transaction the batch's SAVEPOINT opened: every later statement on that connection silently
# joins the doomed transaction and is discarded when the connection is closed. Undo the rebuild and
# restore the two pragmas the batch changed before the error reaches the caller.
#
# "ROLLBACK TO <sp>" undoes the rebuild's own statements and nothing else, and the following
# "RELEASE <sp>" discards the savepoint - which commits (an empty) transaction when the rebuild
# opened it, and leaves the caller's transaction open and intact when the caller opened it. A plain
# unqualified ROLLBACK must never be used here: when the batch fails on its very first statement
# because the caller already holds a transaction, it would discard the caller's uncommitted work.
#
# Each statement is best effort - the savepoint does not exist when the batch failed before reaching
# it, or when SQLite already unwound the transaction itself - and the PSSQLite fallback path has no
# persistent connection to clean up (its per-call connection is closed, and therefore rolled back,
# by PSSQLite itself).
function Reset-DbRebuildState {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Savepoint,
        [ValidateSet('ON', 'OFF')][string]$ForeignKeys = 'ON'
    )
    $conn = $null
    try { $conn = Get-DbConnection -Database $Database } catch { $conn = $null }
    if (-not $conn -or $conn.State -ne 'Open') { return }
    $statements = @(
        "ROLLBACK TO $Savepoint;",
        "RELEASE $Savepoint;",
        'PRAGMA legacy_alter_table = OFF;',
        "PRAGMA foreign_keys = $ForeignKeys;"
    )
    foreach ($stmt in $statements) {
        $cmd = $null
        try {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $stmt
            [void]$cmd.ExecuteNonQuery()
        }
        catch {
            Write-DbLog DEBUG "Reset-DbRebuildState: '$stmt' did not apply: $($_.Exception.Message)"
        }
        finally { if ($cmd) { $cmd.Dispose() } }
    }
}
