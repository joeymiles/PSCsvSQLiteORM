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
        their references to the table name. The whole rebuild is one transaction
        and is rolled back if any statement fails, so a failure never leaves the
        table dropped or the connection inside an aborted transaction.
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
        $identPattern = '(?:"' + [regex]::Escape($col) + '"|' + [regex]::Escape($col) + ')'
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
    $tableIdentPattern = '(?i)(?:"' + [regex]::Escape($Table) + '"|(?<!\w)' + [regex]::Escape($Table) + '(?!\w))'
    $foreignTriggers = @(Invoke-DbQuery -Database $Database -Query "SELECT name, sql FROM sqlite_master WHERE type='trigger' AND sql IS NOT NULL AND tbl_name<>@t" -SqlParameters @{ t = $Table } |
            Where-Object { ([string]$_.sql) -match $tableIdentPattern })

    $steps = New-Object System.Collections.Generic.List[string]
    $steps.Add('PRAGMA foreign_keys = OFF;')
    # Belt and braces for the same reparse: legacy_alter_table exists in exactly the SQLite versions
    # that reparse on rename, and older builds ignore an unknown pragma silently.
    $steps.Add('PRAGMA legacy_alter_table = ON;')
    $steps.Add('BEGIN;')
    $steps.Add("DROP TABLE IF EXISTS $quotedTmp;")
    foreach ($f in $foreignTriggers) { $steps.Add("DROP TRIGGER IF EXISTS $(ConvertTo-Ident ([string]$f.name));") }
    $steps.Add($createTmp + ';')
    $steps.Add("INSERT INTO $quotedTmp ($colList) SELECT $colList FROM $quotedTable;")
    $steps.Add("DROP TABLE $quotedTable;")
    $steps.Add("ALTER TABLE $quotedTmp RENAME TO $quotedTable;")
    foreach ($d in $dependents) { $steps.Add(([string]$d.sql) + ';') }
    foreach ($f in $foreignTriggers) { $steps.Add(([string]$f.sql) + ';') }
    $steps.Add('COMMIT;')
    $steps.Add('PRAGMA legacy_alter_table = OFF;')
    $steps.Add('PRAGMA foreign_keys = ON;')
    $script = $steps -join "`n"
    Write-DbLog INFO "Rebuilding table $Table to widen columns: $(($ColumnTypes.Keys | ForEach-Object { "$_=$($ColumnTypes[$_])" }) -join ', ')"
    try {
        Invoke-DbQuery -Database $Database -Query $script -NonQuery | Out-Null
    }
    catch {
        # E2E1-001: the batch aborts at the failing statement, which is past BEGIN and possibly past
        # "DROP TABLE <original>". Without an explicit ROLLBACK the pooled connection stays inside an
        # open transaction, so every later statement in the session silently joins it and is thrown
        # away when the connection closes, and the original table stays missing for the rest of the
        # session. Reset-DbRebuildState rolls back and restores the two pragmas.
        $rebuildError = $_
        Reset-DbRebuildState -Database $Database
        Write-DbLog ERROR "Rebuild of table $Table failed; the transaction was rolled back" $rebuildError.Exception
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
# the transaction the batch opened with BEGIN: every later statement on that connection silently
# joins the doomed transaction and is discarded when the connection is closed. Roll the transaction
# back and restore the two pragmas the batch changed before the error reaches the caller. Each
# statement is best effort - ROLLBACK fails when no transaction is open, which is the normal case
# when the batch failed before BEGIN - and the PSSQLite fallback path has no persistent connection
# to clean up (its per-call connection is closed, and therefore rolled back, by PSSQLite itself).
function Reset-DbRebuildState {
    param([Parameter(Mandatory)][string]$Database)
    $conn = $null
    try { $conn = Get-DbConnection -Database $Database } catch { $conn = $null }
    if (-not $conn -or $conn.State -ne 'Open') { return }
    foreach ($stmt in @('ROLLBACK;', 'PRAGMA legacy_alter_table = OFF;', 'PRAGMA foreign_keys = ON;')) {
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
