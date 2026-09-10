class DynamicActiveRecord {
    hidden [string]$TableName
    hidden [string]$Database
    hidden [hashtable]$Attributes = @{}
    hidden [int]$Id
    hidden [string[]]$Columns
    hidden [hashtable]$Associations = @{}
    hidden [hashtable]$Validators = @{}
    hidden [hashtable]$Callbacks = @{
        BeforeSave = $null; AfterSave = $null; BeforeDelete = $null; AfterDelete = $null
    }
    hidden [string[]]$ExcludedProperties = @('RowState', 'RowError', 'HasErrors', 'Table', 'ItemArray')
    # Key column used for FindById/Save/Delete: 'id' when the table has one, otherwise 'rowid'. Resolved lazily.
    hidden [string]$KeyColumn
    # Upsert mode cache: 0 = unknown, 1 = native ON CONFLICT (SQLite 3.24+), 2 = emulated (UPDATE + conditional INSERT)
    hidden [int]$UpsertMode = 0
    # Generated model types captured by Set-DynamicORMClass, keyed "<database key>|<table>" (BUG-035). Kept on the
    # type rather than only in $script: because a re-imported module (Import-Module -Force) reuses this compiled
    # class and, on Windows PowerShell 5.1, its methods stay bound to the first import's session state where the
    # $script: registries are empty.
    static [hashtable]$DynamicModelTypes = @{}

    DynamicActiveRecord([string]$tableName, [string]$database, [string[]]$columns) {
        $this.TableName = $tableName; $this.Database = $database; $this.Columns = $columns; $this.Id = 0
    }

    # ---- Internal helpers (BUG-015 / BUG-016) ----

    # Returns 'id' when the table has an id column, otherwise 'rowid' (tables imported from a CSV without an id header).
    hidden [string]GetKeyColumn() {
        if (-not [string]::IsNullOrEmpty($this.KeyColumn)) { return $this.KeyColumn }
        $key = 'rowid'
        $info = @(Invoke-DbQuery -Database $this.Database -Query "PRAGMA table_info($(ConvertTo-Ident $($this.TableName)))")
        foreach ($c in $info) { if ($c -and $c.name -eq 'id') { $key = 'id'; break } }
        # Only cache when the table exists (PRAGMA returns rows)
        if ($info.Count -gt 0) { $this.KeyColumn = $key }
        return $key
    }

    # SELECT prefix that always exposes the key as 'id' (rowid is aliased when there is no id column).
    hidden [string]SelectSql() {
        if ($this.GetKeyColumn() -eq 'id') { return "SELECT * FROM $(ConvertTo-Ident $($this.TableName))" }
        return "SELECT rowid AS id, * FROM $(ConvertTo-Ident $($this.TableName))"
    }

    # Copies a result row into this record (Id from the 'id' column, everything else as attributes).
    hidden [void]LoadRow([object]$row) {
        if ($row.PSObject.Properties.Name -contains 'id') { $this.Id = [int]$row.id }
        foreach ($p in $row.PSObject.Properties) {
            if ($p.Name -ne 'id' -and $p.Name -notin $this.ExcludedProperties) {
                $this.SetAttribute($p.Name, $p.Value)
            }
        }
    }

    # Creates an empty record of the same model. Generated subclasses expose a (string) constructor; the base class
    # (and any other subclass without that constructor) is cloned with its table, columns and associations.
    hidden [DynamicActiveRecord]NewInstance() {
        $rec = $null
        $ctorInfo = $this.GetType().GetConstructor([type[]]@([string]))
        if ($ctorInfo) { $rec = $ctorInfo.Invoke(@($this.Database)) }
        else {
            $rec = [DynamicActiveRecord]::new($this.TableName, $this.Database, $this.Columns)
            foreach ($k in @($this.Associations.Keys)) { $rec.Associations[$k] = $this.Associations[$k] }
        }
        $rec.KeyColumn = $this.KeyColumn
        return $rec
    }

    # Creates an empty record for a related table: the registered dynamic type when one is known, otherwise a base
    # record wired with the confirmed relationships from the __fks__ catalog so navigation can continue.
    hidden [DynamicActiveRecord]NewRelatedInstance([string]$table) {
        $typeObj = $null
        # Prefer the model registered for THIS database (BUG-017); fall back to the table-keyed view
        $dbKey = Get-DynamicDatabaseKey -Database $this.Database
        # Types captured on load by Set-DynamicORMClass (BUG-035): the static store works even when this method runs
        # bound to a stale session state after a module re-import (Windows PowerShell 5.1).
        $staticKey = $dbKey + '|' + $table
        if ([DynamicActiveRecord]::DynamicModelTypes.ContainsKey($staticKey)) { $typeObj = [DynamicActiveRecord]::DynamicModelTypes[$staticKey] }
        if (-not $typeObj -and $script:ModelRegistry -and $script:ModelRegistry.ContainsKey($dbKey) -and $script:ModelRegistry[$dbKey].ContainsKey($table)) {
            $typeObj = $script:ModelRegistry[$dbKey][$table].Type
        }
        if (-not $typeObj -and $script:ModelTypeObjects -and $script:ModelTypeObjects.ContainsKey($table)) { $typeObj = $script:ModelTypeObjects[$table] }
        if ($typeObj) {
            $ctorInfo = $typeObj.GetConstructor([type[]]@([string]))
            if ($ctorInfo) { return $ctorInfo.Invoke(@($this.Database)) }
        }
        $cols = [string[]]@(Get-TableColumns -Database $this.Database -TableName $table)
        $rec = [DynamicActiveRecord]::new($table, $this.Database, $cols)
        $rec.LoadAssociationsFromCatalog()
        return $rec
    }

    # Populates Associations from confirmed rows in __fks__ (no-op when the catalog does not exist).
    hidden [void]LoadAssociationsFromCatalog() {
        $exists = @(Invoke-DbQuery -Database $this.Database -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='__fks__'")
        if ($exists.Count -eq 0) { return }
        $fksFrom = @(Invoke-DbQuery -Database $this.Database -Query "SELECT column_name, ref_table FROM __fks__ WHERE table_name=@t AND status='confirmed'" -SqlParameters @{ t = $this.TableName })
        foreach ($fk in $fksFrom) { if ($fk) { $this.BelongsTo([string]$fk.ref_table, [string]$fk.column_name) } }
        $fksTo = @(Invoke-DbQuery -Database $this.Database -Query "SELECT table_name, column_name FROM __fks__ WHERE ref_table=@t AND status='confirmed'" -SqlParameters @{ t = $this.TableName })
        foreach ($fk in $fksTo) { if ($fk) { $this.HasMany([string]$fk.table_name, [string]$fk.column_name) } }
    }

    [void]HasMany([string]$relatedTable, [string]$foreignKey) { $this.Associations["has_many_$relatedTable"] = @{ Type = "has_many"; Table = $relatedTable; ForeignKey = $foreignKey } }
    [void]BelongsTo([string]$relatedTable, [string]$foreignKey) { $this.Associations["belongs_to_$relatedTable"] = @{ Type = "belongs_to"; Table = $relatedTable; ForeignKey = $foreignKey } }

    [void]SetAttribute([string]$key, [object]$value) { $this.Attributes[$key] = $value }
    [object]GetAttribute([string]$key) { return $this.Attributes[$key] }

    [void]On([string]$EventName, [scriptblock]$Action) {
        if ($EventName -notin @('BeforeSave', 'AfterSave', 'BeforeDelete', 'AfterDelete')) { throw "Invalid event '$EventName'." }
        $this.Callbacks[$EventName] = $Action
    }

    [void]AddValidator([string]$Column, [string]$Type, [object]$Arg) {
        if ($Type -notin @('Required', 'MaxLength', 'Regex', 'Custom')) { throw "Invalid validator type '$Type'." }
        if (-not $this.Validators.ContainsKey($Column)) { $this.Validators[$Column] = @() }
        $this.Validators[$Column] += @{ Type = $Type; Arg = $Arg }
    }

    [string[]]Validate() {
        $errors = @()
        foreach ($col in $this.Validators.Keys) {
            $val = $this.Attributes[$col]
            foreach ($rule in $this.Validators[$col]) {
                try {
                    switch ($rule.Type) {
                        'Required' { if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) { $errors += '${col} is required'.Replace('${col}', $col) } }
                        'MaxLength' { if ($val -is [string] -and $val.Length -gt [int]$rule.Arg) { $errors += "$col exceeds max length $($rule.Arg)" } }
                        'Regex' { if ($val -is [string] -and ($val -notmatch $rule.Arg)) { $errors += "$col does not match pattern" } }
                        'Custom' { if (-not (& $rule.Arg $val)) { $errors += "$col failed custom validation" } }
                    }
                }
                catch { Write-DbLog ERROR "Validator for column '$col' threw." $_.Exception; $errors += "$col validation error" }
            }
        }
        return $errors
    }

    # Before* callbacks may veto the operation by throwing: the exception propagates to the caller and nothing is
    # written. After* callbacks are observers, so their errors are logged only (BUG-039).
    hidden [void]InvokeCallback([string]$Name) {
        $cb = $this.Callbacks[$Name]
        if (-not $cb) { return }
        if ($Name -like 'Before*') { & $cb $this; return }
        try { & $cb $this } catch { Write-DbLog ERROR "Callback '$Name' threw." $_.Exception }
    }

    # Maps column names to unique, SQL-safe parameter names (p0, p1, ...) so that columns containing spaces,
    # dashes or other characters that are invalid in a parameter name still bind (BASE-08). Returns an ordered
    # dictionary column -> parameter name (without the leading '@').
    hidden [System.Collections.Specialized.OrderedDictionary]GetParameterMap([string[]]$ColumnNames) {
        $map = [ordered]@{}
        $i = 0
        foreach ($c in $ColumnNames) { $map[$c] = "p$i"; $i++ }
        return $map
    }

    # Rewrites @<column> references (and, when $IncludeExcluded is set, excluded.<column> references) inside a SQL
    # clause to the positional parameter names from GetParameterMap. Single pass over the clause so that a column
    # whose name looks like a positional parameter (for example 'p0') cannot be rewritten twice.
    hidden [string]RewriteParameterReferences([string]$Clause, [System.Collections.Specialized.OrderedDictionary]$Map, [bool]$IncludeExcluded) {
        if ([string]::IsNullOrEmpty($Clause)) { return $Clause }
        $pattern = '(?<![A-Za-z0-9_@])@([A-Za-z_][A-Za-z0-9_]*)'
        if ($IncludeExcluded) { $pattern = '(?i)(?<![A-Za-z0-9_@])(?:@|excluded\.)([A-Za-z_][A-Za-z0-9_]*)' }
        $found = [regex]::Matches($Clause, $pattern)
        if ($found.Count -eq 0) { return $Clause }
        $sb = New-Object System.Text.StringBuilder
        $pos = 0
        foreach ($m in $found) {
            $name = $m.Groups[1].Value
            [void]$sb.Append($Clause.Substring($pos, $m.Index - $pos))
            if ($Map.Contains($name)) { [void]$sb.Append('@' + $Map[$name]) } else { [void]$sb.Append($m.Value) }
            $pos = $m.Index + $m.Length
        }
        [void]$sb.Append($Clause.Substring($pos))
        return $sb.ToString()
    }

    [void]Save() {
        $errs = $this.Validate(); if ($errs.Count -gt 0) { throw "Validation failed: $($errs -join '; ')" }
        $this.InvokeCallback('BeforeSave')
        try {
            $keys = [string[]]@($this.Attributes.Keys)
            if ($this.Id -eq 0) {
                if ($keys.Count -eq 0) { throw "No attributes set for insert into $($this.TableName)." }
                $map = $this.GetParameterMap($keys)
                $columnList = (($keys | ForEach-Object { ConvertTo-Ident $_ })) -join ", "
                $placeholders = (($keys | ForEach-Object { "@$($map[$_])" })) -join ", "
                $query = "INSERT INTO $(ConvertTo-Ident $($this.TableName)) ($columnList) VALUES ($placeholders); SELECT last_insert_rowid() AS id;"
                $params = @{}; foreach ($k in $keys) { $params[$map[$k]] = $this.Attributes[$k] }
                $res = @(Invoke-DbQuery -Database $this.Database -Query $query -SqlParameters $params)
                if ($res.Count -gt 0 -and $res[0] -and $res[0].id) { $this.Id = [int]$res[0].id }
                else { throw "Insert into $($this.TableName) did not return a row id." }
            }
            else {
                if ($keys.Count -eq 0) { return }
                $map = $this.GetParameterMap($keys)
                $setClause = (($keys | ForEach-Object { "$(ConvertTo-Ident $_) = @$($map[$_])" })) -join ", "
                # The key is bound under its own parameter name so that an 'id' attribute cannot replace it (BUG-037)
                $query = "UPDATE $(ConvertTo-Ident $($this.TableName)) SET $setClause WHERE $($this.GetKeyColumn()) = @pk"
                $params = @{ pk = $this.Id }; foreach ($k in $keys) { $params[$map[$k]] = $this.Attributes[$k] }
                $affected = Invoke-DbQuery -Database $this.Database -Query $query -SqlParameters $params -NonQuery
                if ($null -ne $affected -and [int]$affected -eq 0) { Write-DbLog WARN "Save updated no rows in $($this.TableName) for $($this.GetKeyColumn()) = $($this.Id)." }
                # Keep Id in step with the row when the id column itself was changed
                if ($this.GetKeyColumn() -eq 'id' -and $this.Attributes.ContainsKey('id') -and $null -ne $this.Attributes['id']) { $this.Id = [int]$this.Attributes['id'] }
            }
        }
        catch { Write-DbLog ERROR "Error saving record" $_.Exception; throw }
        $this.InvokeCallback('AfterSave')
    }

    [void]Delete() {
        # Nothing to delete for an unsaved record: no callbacks fire (BUG-039)
        if ($this.Id -eq 0) { return }
        $this.InvokeCallback('BeforeDelete')
        try {
            $query = "DELETE FROM $(ConvertTo-Ident $($this.TableName)) WHERE $($this.GetKeyColumn()) = @pk"
            [void](Invoke-DbQuery -Database $this.Database -Query $query -SqlParameters @{ pk = $this.Id } -NonQuery)
            $this.Id = 0
        }
        catch { Write-DbLog ERROR "Error deleting record" $_.Exception; throw }
        $this.InvokeCallback('AfterDelete')
    }

    [object[]]Where([string]$WhereClause, [hashtable]$Params) {
    $sql = $this.SelectSql()
        if ($WhereClause -and $WhereClause.Trim().Length -gt 0) { $sql += " WHERE $WhereClause" }
        $results = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $Params
        $records = @()
        foreach ($row in $results) {
            $rec = $this.NewInstance()
            $rec.LoadRow($row)
            $records += $rec
        }
        return $records
    }

    [psobject]FindById([int]$Id) {
    $sql = $this.SelectSql() + " WHERE $($this.GetKeyColumn()) = @id"
        $res = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters @{id = $Id }
        if (-not $res -or $res.Count -eq 0) { return $null }
        $rec = $this.NewInstance()
        $rec.LoadRow($res[0])
        return $rec
    }

    [object[]] All() {
    $query = "SELECT * FROM $(ConvertTo-Ident $($this.TableName))"
        $results = Invoke-DbQuery -Database $this.Database -Query $query
    
        $objects = @()
        foreach ($row in $results) {
            $obj = [PSCustomObject]@{}
            foreach ($property in $row.PSObject.Properties) {
                $obj | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
            }
            $objects += $obj
        }
        return $objects
    }

    # PowerShell ignores default values on class method parameters, so the no-argument form is an explicit overload (BASE-05)
    [psobject]First() { return $this.First('id ASC') }

    [psobject]First([string]$OrderBy) {
    $sql = $this.SelectSql() + " ORDER BY $OrderBy LIMIT 1"
        $res = Invoke-DbQuery -Database $this.Database -Query $sql
        if (-not $res -or $res.Count -eq 0) { return $null }
        $rec = $this.NewInstance()
        $rec.LoadRow($res[0])
        return $rec
    }

    [void]InsertMany([System.Collections.IEnumerable]$Rows) {
        $tx = Start-DbTransaction -Database $this.Database
        try {
            foreach ($row in $Rows) {
                $keys = [string[]]@($row.Keys)
                if ($keys.Count -eq 0) { throw "No columns supplied for insert into $($this.TableName)." }
                $map = $this.GetParameterMap($keys)
                $columnList = (($keys | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
                $placeholders = (($keys | ForEach-Object { "@$($map[$_])" })) -join ', '
                $sql = "INSERT INTO $(ConvertTo-Ident $($this.TableName)) ($columnList) VALUES ($placeholders)"
                $params = @{}; foreach ($k in $keys) { $params[$map[$k]] = $row[$k] }
                [void](Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $params -NonQuery -Transaction $tx)
            }
            Complete-DbTransaction -Database $this.Database -Transaction $tx
        }
        catch { Undo-DbTransaction -Database $this.Database -Transaction $tx; Write-DbLog ERROR "Bulk insert failed" $_.Exception; throw }
    }

    # True when the engine supports INSERT ... ON CONFLICT DO UPDATE (SQLite 3.24+). Cached per record.
    hidden [bool]SupportsNativeUpsert() {
        if ($this.UpsertMode -eq 0) {
            $v = Invoke-DbQuery -Database $this.Database -Query "SELECT sqlite_version() AS v;"
            $parts = ([string]$v[0].v) -split '\.'
            $major = [int]$parts[0]; $minor = 0
            if ($parts.Count -gt 1) { $minor = [int]$parts[1] }
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 24)) { $this.UpsertMode = 1 } else { $this.UpsertMode = 2 }
        }
        return ($this.UpsertMode -eq 1)
    }

    # Shared upsert implementation (BUG-001 / BUG-010). The version check runs BEFORE any schema change, native
    # ON CONFLICT is used on SQLite 3.24+, and older engines (PSSQLite on Windows PowerShell ships 3.8.8.3) get an
    # equivalent UPDATE ... WHERE keys; INSERT ... WHERE NOT EXISTS pair. $Transaction is passed through when set.
    hidden [void]UpsertRow([hashtable]$Row, [string[]]$KeyColumns, [hashtable]$UpdateSet, [object]$Transaction) {
        if (-not $Row -or $Row.Keys.Count -eq 0) { throw "No columns supplied for upsert into $($this.TableName)." }
        if (-not $KeyColumns -or $KeyColumns.Count -eq 0) { throw "KeyColumns are required for upsert into $($this.TableName)." }
        $native = $this.SupportsNativeUpsert()
        Enable-UniqueIndex -Database $this.Database -Table $this.TableName -Columns $KeyColumns | Out-Null
        $cols = [string[]]@($Row.Keys)
        foreach ($k in $KeyColumns) { if ($cols -notcontains $k) { throw "Key column '$k' is missing from the upsert row for $($this.TableName)." } }
        # Columns bind under positional parameter names (BASE-08); the row values are copied under those names
        $map = $this.GetParameterMap($cols)
        $params = @{}; foreach ($c in $cols) { $params[$map[$c]] = $Row[$c] }
        $table = ConvertTo-Ident $this.TableName
        $colList = (($cols | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
        $placeholders = (($cols | ForEach-Object { "@$($map[$_])" })) -join ', '
        $callerSet = ($null -ne $UpdateSet)
        if (-not $callerSet) { $UpdateSet = @{}; foreach ($c in $cols) { if ($KeyColumns -notcontains $c) { $UpdateSet[$c] = "@$($map[$c])" } } }
        $updateClause = (($UpdateSet.Keys | ForEach-Object { "$(ConvertTo-Ident $_) = $($UpdateSet[$_])" })) -join ', '
        $sql = ''
        if ($native) {
            # A caller-supplied UpdateSet may reference the proposed value as @<column>; rewrite it to the bound name
            if ($callerSet) { $updateClause = $this.RewriteParameterReferences($updateClause, $map, $false) }
            $onKeys = (($KeyColumns | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
            $action = 'DO NOTHING'
            if ($updateClause) { $action = "DO UPDATE SET $updateClause" }
            $sql = "INSERT INTO $table ($colList) VALUES ($placeholders) ON CONFLICT($onKeys) $action"
        }
        else {
            $keyWhere = (($KeyColumns | ForEach-Object { "$(ConvertTo-Ident $_) = @$($map[$_])" })) -join ' AND '
            if ($updateClause) {
                # excluded.<col> refers to the proposed row in ON CONFLICT syntax; map it (and @<column>) to the bound parameter
                $emulatedSet = $updateClause
                if ($callerSet) { $emulatedSet = $this.RewriteParameterReferences($updateClause, $map, $true) }
                $sql = "UPDATE $table SET $emulatedSet WHERE $keyWhere; "
            }
            $sql += "INSERT INTO $table ($colList) SELECT $placeholders WHERE NOT EXISTS (SELECT 1 FROM $table WHERE $keyWhere)"
        }
        $splat = @{ Database = $this.Database; Query = $sql; SqlParameters = $params; NonQuery = $true }
        if ($Transaction) { $splat['Transaction'] = $Transaction }
        [void](Invoke-DbQuery @splat)
    }

    [void]InsertOnConflict([hashtable]$Row, [string[]]$KeyColumns, [hashtable]$UpdateSet) {
        $this.UpsertRow($Row, $KeyColumns, $UpdateSet, $null)
    }

    [void]BulkUpsert([System.Collections.IEnumerable]$Rows, [string[]]$KeyColumns) {
        $tx = Start-DbTransaction -Database $this.Database
        try {
            foreach ($row in $Rows) { $this.UpsertRow($row, $KeyColumns, $null, $tx) }
            Complete-DbTransaction -Database $this.Database -Transaction $tx
        }
        catch {
            $err = $_
            try { Undo-DbTransaction -Database $this.Database -Transaction $tx }
            catch { Write-DbLog WARN "Bulk upsert rollback failed" $_.Exception }
            Write-DbLog ERROR "Bulk upsert failed" $err.Exception
            throw $err
        }
    }

    [object]Raw([string]$Sql, [hashtable]$Params) { return Invoke-DbQuery -Database $this.Database -Query $Sql -SqlParameters $Params }

    [object[]]GetHasMany([string]$relatedTable) {
        $assoc = $this.Associations["has_many_$relatedTable"]; if (-not $assoc) { throw "No has_many '$relatedTable' defined" }
        $proto = $this.NewRelatedInstance($assoc.Table)
    $sql = $proto.SelectSql() + " WHERE $(ConvertTo-Ident $($assoc.ForeignKey)) = @id"
        $results = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters @{id = $this.Id }
        $records = @()
        foreach ($row in $results) {
            $rec = $proto.NewInstance()
            $rec.LoadRow($row)
            $records += $rec
        }
        return $records
    }

    [DynamicActiveRecord]GetBelongsTo([string]$relatedTable) {
        $assoc = $this.Associations["belongs_to_$relatedTable"]; if (-not $assoc) { throw "No belongs_to '$relatedTable' defined" }
        $fkId = $this.Attributes[$assoc.ForeignKey]; if ($null -eq $fkId) { return $null }
        $proto = $this.NewRelatedInstance($assoc.Table)
    $sql = $proto.SelectSql() + " WHERE $($proto.GetKeyColumn()) = @id"
        $res = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters @{id = $fkId }
        if (-not $res -or $res.Count -eq 0) { return $null }
        $rec = $proto.NewInstance()
        $rec.LoadRow($res[0])
        return $rec
    }
}
