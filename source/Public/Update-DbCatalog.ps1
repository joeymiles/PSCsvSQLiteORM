function Update-DbCatalog {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)]
        [string]$Database,
        [string]$SourceCsvPath,
        [string]$Table
    )

    # Honor -WhatIf/-Confirm before anything touches the database: Initialize-Db creates the
    # bookkeeping tables and every statement below writes to them (BUG-044). ConfirmImpact is
    # Medium so internal callers (Import-CsvToSqlite, Find-DbRelationships,
    # Export-DynamicModelsFromCatalog) never prompt under the default $ConfirmPreference.
    if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($Database, 'Update catalog tables (__tables__, __columns__, __fks__)')) { return }
    Initialize-Db -Database $Database
    $tables = Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    # User tables only: the bookkeeping tables are never cataloged (BUG-032).
    $userTables = @($tables | ForEach-Object { $_.name } | Where-Object { -not (Test-DbInternalTable -Name $_) })

    foreach ($tn in $userTables) {
        # A table created by another tool may carry a name ConvertTo-Ident refuses to quote.
        # Skip it instead of failing the whole catalog refresh (BUG-043).
        try { $ident = ConvertTo-Ident $tn } catch { Write-DbLog WARN "Update-DbCatalog: skipping table '$tn' ($($_.Exception.Message))"; continue }
        $rowcount = (Invoke-DbQuery -Database $Database -Query "SELECT COUNT(*) AS c FROM $ident")[0].c
        # Source path and hash apply only to the table that was just imported; every other
        # table keeps the provenance it already has (BUG-012).
        $src = $null; $csvHash = $null
        if (-not [string]::IsNullOrEmpty($SourceCsvPath) -and $Table -eq $tn) {
            $src = $SourceCsvPath
            if (Test-Path -LiteralPath $SourceCsvPath) { $csvHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourceCsvPath).Hash }
        }
        # Check if record exists first (compatible with older SQLite)
        $existing = Invoke-DbQuery -Database $Database -Query "SELECT table_name FROM __tables__ WHERE table_name=@t" -SqlParameters @{ t = $tn }
        if ($existing) {
            # Update existing record
            Invoke-DbQuery -Database $Database -Query @"
UPDATE __tables__ SET
  source=COALESCE(NULLIF(@s,''), source),
  csv_hash=COALESCE(@h, csv_hash),
  rowcount=@c
WHERE table_name=@t
"@ -SqlParameters @{ t = $tn; s = $src; h = $csvHash; c = $rowcount } -NonQuery | Out-Null
        } else {
            # Insert new record
            Invoke-DbQuery -Database $Database -Query @"
INSERT INTO __tables__(table_name,source,created_at,csv_hash,rowcount,sample_json)
VALUES(@t,@s,datetime('now'),@h,@c,@j)
"@ -SqlParameters @{ t = $tn; s = $src; h = $csvHash; c = $rowcount; j = $null } -NonQuery | Out-Null
        }

        $cols = @(Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($ident)")
        $colNames = @($cols | ForEach-Object { $_.name })
        # Remove catalog rows for columns that no longer exist (BUG-031)
        $catCols = @(Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __columns__ WHERE table_name=@t" -SqlParameters @{ t = $tn })
        foreach ($cc in $catCols) {
            if ($colNames -notcontains $cc.column_name) {
                Invoke-DbQuery -Database $Database -Query "DELETE FROM __columns__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $tn; c = $cc.column_name } -NonQuery | Out-Null
                Invoke-DbQuery -Database $Database -Query "DELETE FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $tn; c = $cc.column_name } -NonQuery | Out-Null
            }
        }
        foreach ($c in $cols) {
            # Check if column record exists
            $existingCol = Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __columns__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $tn; c = $c.name }
            if ($existingCol) {
                # Update existing column record
                Invoke-DbQuery -Database $Database -Query @"
UPDATE __columns__ SET 
  data_type=@dt,
  nullable=@n,
  pk=@pk
WHERE table_name=@t AND column_name=@c
"@ -SqlParameters @{ t = $tn; c = $c.name; dt = $c.type; n = [int](-not [bool]$c.notnull); pk = [int]$c.pk } -NonQuery | Out-Null
            } else {
                # Insert new column record
                Invoke-DbQuery -Database $Database -Query @"
INSERT INTO __columns__(table_name,column_name,data_type,nullable,pk,example_values_json)
VALUES(@t,@c,@dt,@n,@pk,@ex)
"@ -SqlParameters @{ t = $tn; c = $c.name; dt = $c.type; n = [int](-not [bool]$c.notnull); pk = [int]$c.pk; ex = $null } -NonQuery | Out-Null
            }
        }

        $fks = Invoke-DbQuery -Database $Database -Query "PRAGMA foreign_key_list($ident)"
        foreach ($fk in $fks) {
            # Check if FK record exists
            $existingFk = Invoke-DbQuery -Database $Database -Query "SELECT column_name FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $tn; c = $fk."from" }
            if ($existingFk) {
                # Update existing FK record
                Invoke-DbQuery -Database $Database -Query @"
UPDATE __fks__ SET 
  ref_table=@rt,
  ref_column=@rc,
  status='confirmed'
WHERE table_name=@t AND column_name=@c
"@ -SqlParameters @{ t = $tn; c = $fk."from"; rt = $fk."table"; rc = $fk."to" } -NonQuery | Out-Null
            } else {
                # Insert new FK record
                Invoke-DbQuery -Database $Database -Query @"
INSERT INTO __fks__(table_name,column_name,ref_table,ref_column,confidence,status,on_delete,on_update)
VALUES(@t,@c,@rt,@rc,1.0,'confirmed',@od,@ou)
"@ -SqlParameters @{ t = $tn; c = $fk."from"; rt = $fk."table"; rc = $fk."to"; od = $fk.on_delete; ou = $fk.on_update } -NonQuery | Out-Null
            }
        }
    }

    # Remove catalog rows for tables that were dropped, and any rows a previous version
    # recorded for the bookkeeping tables themselves (BUG-031, BUG-032).
    $cataloged = @(Invoke-DbQuery -Database $Database -Query "SELECT table_name FROM __tables__ UNION SELECT table_name FROM __columns__ UNION SELECT table_name FROM __fks__")
    foreach ($row in $cataloged) {
        $name = $row.table_name
        if ($userTables -contains $name) { continue }
        foreach ($catTable in @('__tables__', '__columns__', '__fks__')) {
            Invoke-DbQuery -Database $Database -Query "DELETE FROM $catTable WHERE table_name=@t" -SqlParameters @{ t = $name } -NonQuery | Out-Null
        }
    }
}
