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

        $hasMany = @{}; $belongsTo = @{}
        $fksFrom = Invoke-DbQuery -Database $Database -Query "SELECT column_name, ref_table FROM __fks__ WHERE table_name=@t AND status='confirmed'" -SqlParameters @{ t = $tn }
        foreach ($fk in $fksFrom) { $belongsTo[$fk.ref_table] = $fk.column_name }
        $fksTo = Invoke-DbQuery -Database $Database -Query "SELECT table_name, column_name FROM __fks__ WHERE ref_table=@t AND status='confirmed'" -SqlParameters @{ t = $tn }
        foreach ($fk in $fksTo) { $hasMany[$fk.table_name] = $fk.column_name }

        # New-DynamicModel derives the type name (BUG-036) and (re)generates the class file for this database (BUG-017)
        $typeName = New-DynamicModel -TableName $tn -Database $Database -Columns $colNames -HasMany $hasMany -BelongsTo $belongsTo
        $result[$tn] = $typeName
        $script:ModelTypes[$tn] = $typeName
        $script:ModelTypeObjects[$tn] = ([System.Management.Automation.PSTypeName]$typeName).Type
    }

    return $result
}
