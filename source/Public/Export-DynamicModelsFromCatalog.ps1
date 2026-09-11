function Export-DynamicModelsFromCatalog {
    param([Parameter(Mandatory)][string]$Database)

    Initialize-Db -Database $Database
    Update-DbCatalog -Database $Database

    if (-not $script:ModelTypes) { $script:ModelTypes = @{} }
    if (-not $script:ModelTypeObjects) { $script:ModelTypeObjects = @{} }

    # Result for THIS database only (a fresh hashtable, not the shared module registry) (BUG-017)
    $result = @{}
    $tables = Invoke-DbQuery -Database $Database -Query "SELECT table_name FROM __tables__"
    foreach ($t in $tables) {
        $tn = $t.table_name
        if ($tn -like 'sqlite_%' -or $tn -in @('__tables__', '__columns__', '__fks__', 'schema_migrations')) { continue }

        $cols = Invoke-DbQuery -Database $Database -Query "PRAGMA table_info($(ConvertTo-Ident $tn))" | Sort-Object -Property cid
        $colNames = [string[]]@($cols | ForEach-Object { $_.name })
        if (-not $colNames -or $colNames.Count -eq 0) { continue }

        # One association per __fks__ row: a related table maps to the ordered list of its foreign key columns, so a
        # table with two foreign keys to the same parent keeps both and both sides agree on the default (BUG-019).
        # Each entry carries the referenced column as well, so a foreign key pointing at a non-id column still
        # navigates through the generated class (E2E1-006).
        $hasMany = @{}; $belongsTo = @{}
        $fksFrom = @(Invoke-DbQuery -Database $Database -Query "SELECT column_name, ref_table, ref_column FROM __fks__ WHERE table_name=@t AND status='confirmed' ORDER BY column_name" -SqlParameters @{ t = $tn })
        foreach ($fk in $fksFrom) {
            if (-not $fk) { continue }
            if ([string]::IsNullOrEmpty([string]$fk.column_name)) { continue }
            $entry = @{ Column = [string]$fk.column_name; RefColumn = [string]$fk.ref_column }
            $belongsTo[[string]$fk.ref_table] = @(@($belongsTo[[string]$fk.ref_table]) + @($entry) | Where-Object { $_ })
        }
        $fksTo = @(Invoke-DbQuery -Database $Database -Query "SELECT table_name, column_name, ref_column FROM __fks__ WHERE ref_table=@t AND status='confirmed' ORDER BY table_name, column_name" -SqlParameters @{ t = $tn })
        foreach ($fk in $fksTo) {
            if (-not $fk) { continue }
            if ([string]::IsNullOrEmpty([string]$fk.column_name)) { continue }
            $entry = @{ Column = [string]$fk.column_name; RefColumn = [string]$fk.ref_column }
            $hasMany[[string]$fk.table_name] = @(@($hasMany[[string]$fk.table_name]) + @($entry) | Where-Object { $_ })
        }

        # New-DynamicModel derives the type name (BUG-036) and (re)generates the class file for this database (BUG-017)
        $typeName = New-DynamicModel -TableName $tn -Database $Database -Columns $colNames -HasMany $hasMany -BelongsTo $belongsTo
        $result[$tn] = $typeName
        $script:ModelTypes[$tn] = $typeName
        $script:ModelTypeObjects[$tn] = ([System.Management.Automation.PSTypeName]$typeName).Type
    }

    return $result
}
