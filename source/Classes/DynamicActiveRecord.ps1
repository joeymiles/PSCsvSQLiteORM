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
    # BUG-026: Invoke-DbQuery no longer emits DataRow members, so nothing is excluded; the
    # old list silently dropped genuine columns named Table, RowState, RowError, ItemArray, HasErrors.
    hidden [string[]]$ExcludedProperties = @()

    DynamicActiveRecord([string]$tableName, [string]$database, [string[]]$columns) {
        $this.TableName = $tableName; $this.Database = $database; $this.Columns = $columns; $this.Id = 0
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

    hidden [void]InvokeCallback([string]$Name) {
    $cb = $this.Callbacks[$Name]; if ($cb) { try { & $cb $this } catch { Write-DbLog ERROR "Callback '$Name' threw." $_.Exception } }
    }

    [void]Save() {
        $errs = $this.Validate(); if ($errs.Count -gt 0) { throw "Validation failed: $($errs -join '; ')" }
        $this.InvokeCallback('BeforeSave')
        try {
            if ($this.Id -eq 0) {
                $keys = $this.Attributes.Keys
                if (-not $keys -or $keys.Count -eq 0) { throw "No attributes set for insert into $($this.TableName)." }
            $this.columns = (($keys | ForEach-Object { ConvertTo-Ident $_ })) -join ", "
                $placeholders = (($keys | ForEach-Object { "@$_" })) -join ", "
            $query = "INSERT INTO $(ConvertTo-Ident $($this.TableName)) (" + $this.columns + ") VALUES ($placeholders); SELECT last_insert_rowid() AS id;"
                $params = @{}; foreach ($k in $keys) { $params[$k] = $this.Attributes[$k] }
                $res = Invoke-DbQuery -Database $this.Database -Query $query -SqlParameters $params
                if ($res -and $res[0] -and $res[0].id) { $this.Id = [int]$res[0].id }
            }
            else {
                if (-not $this.Attributes.Keys -or $this.Attributes.Keys.Count -eq 0) { return }
            $setClause = (($this.Attributes.Keys | ForEach-Object { "$(ConvertTo-Ident $_) = @$_" })) -join ", "
            $query = "UPDATE $(ConvertTo-Ident $($this.TableName)) SET $setClause WHERE id = @id"
                $params = @{ id = $this.Id }; foreach ($k in $this.Attributes.Keys) { $params[$k] = $this.Attributes[$k] }
                [void](Invoke-DbQuery -Database $this.Database -Query $query -SqlParameters $params -NonQuery)
            }
        }
        catch { Write-DbLog ERROR "Error saving record" $_.Exception; throw }
        finally { $this.InvokeCallback('AfterSave') }
    }

    [void]Delete() {
        $this.InvokeCallback('BeforeDelete')
        try {
            if ($this.Id -ne 0) {
            $query = "DELETE FROM $(ConvertTo-Ident $($this.TableName)) WHERE id = @id"
                [void](Invoke-DbQuery -Database $this.Database -Query $query -SqlParameters @{id = $this.Id } -NonQuery)
                $this.Id = 0
            }
        }
        catch { Write-DbLog ERROR "Error deleting record" $_.Exception; throw }
        finally { $this.InvokeCallback('AfterDelete') }
    }

    [object[]]Where([string]$WhereClause, [hashtable]$Params) {
    $sql = "SELECT * FROM $(ConvertTo-Ident $($this.TableName))"
        if ($WhereClause -and $WhereClause.Trim().Length -gt 0) { $sql += " WHERE $WhereClause" }
        $results = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $Params
        $type = $this.GetType()
        $ctorInfo = $type.GetConstructor([type[]]@([string]))
        $records = @()
        foreach ($row in $results) {
            $rec = $ctorInfo.Invoke(@($this.Database))
            if ($row.PSObject.Properties.Name -contains 'id') { $rec.Id = [int]$row.id }
            foreach ($p in $row.PSObject.Properties) { 
                if ($p.Name -ne 'id' -and $p.Name -notin $this.ExcludedProperties) { 
                    $rec.SetAttribute($p.Name, $p.Value) 
                } 
            }            $records += $rec
        }
        return $records
    }

    [psobject]FindById([int]$Id) {
    $sql = "SELECT * FROM $(ConvertTo-Ident $($this.TableName)) WHERE id = @id"
        $res = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters @{id = $Id }
        if (-not $res -or $res.Count -eq 0) { return $null }
        $type = $this.GetType()
        $ctorInfo = $type.GetConstructor([type[]]@([string]))
        $rec = $ctorInfo.Invoke(@($this.Database))
        $row = $res[0]
        $rec.Id = [int]$row.id
        foreach ($p in $row.PSObject.Properties) { 
            if ($p.Name -ne 'id' -and $p.Name -notin $this.ExcludedProperties) { 
                $rec.SetAttribute($p.Name, $p.Value) 
            } 
        }
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

    [psobject]First([string]$OrderBy = 'id ASC') {
    $sql = "SELECT * FROM $(ConvertTo-Ident $($this.TableName)) ORDER BY $OrderBy LIMIT 1"
        $res = Invoke-DbQuery -Database $this.Database -Query $sql
        if (-not $res -or $res.Count -eq 0) { return $null }
        $type = $this.GetType()
        $ctorInfo = $type.GetConstructor([type[]]@([string]))
        $rec = $ctorInfo.Invoke(@($this.Database))
        $row = $res[0]
        $rec.Id = [int]$row.id
        foreach ($p in $row.PSObject.Properties) { 
            if ($p.Name -ne 'id' -and $p.Name -notin $this.ExcludedProperties) { 
                $rec.SetAttribute($p.Name, $p.Value) 
            } 
        }
        return $rec
    }

    [void]InsertMany([System.Collections.IEnumerable]$Rows) {
        $tx = Start-DbTransaction -Database $this.Database
        try {
            foreach ($row in $Rows) {
            $keys = $row.Keys; $this.columns = (($keys | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
                $placeholders = (($keys | ForEach-Object { "@$_" })) -join ', '
            $sql = "INSERT INTO $(ConvertTo-Ident $($this.TableName)) (" + $($this.columns) + ") VALUES ($placeholders)"
                [void](Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $row -NonQuery -Transaction $tx)
            }
            Complete-DbTransaction -Database $this.Database -Transaction $tx
        }
        catch { Undo-DbTransaction -Database $this.Database -Transaction $tx; Write-DbLog ERROR "Bulk insert failed" $_.Exception; throw }
    }

    [void]InsertOnConflict([hashtable]$Row, [string[]]$KeyColumns, [hashtable]$UpdateSet) {
    Enable-UniqueIndex -Database $this.Database -Table $this.TableName -Columns $KeyColumns | Out-Null
        # version check
    Enable-UpsertSupported -Database $this.Database
        $cols = $Row.Keys
    $this.columns = (($cols | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
        $placeholders = (($cols | ForEach-Object { "@$_" })) -join ', '
    $onKeys = (($KeyColumns | ForEach-Object { ConvertTo-Ident $_ })) -join ', '
        if (-not $UpdateSet) { $UpdateSet = @{}; foreach ($c in $cols) { if ($KeyColumns -notcontains $c) { $UpdateSet[$c] = "@$c" } } }
    $updateClause = (($UpdateSet.Keys | ForEach-Object { "$(ConvertTo-Ident $_) = $($UpdateSet[$_])" })) -join ', '
    $sql = "INSERT INTO $(ConvertTo-Ident $($this.TableName)) (" + $($this.columns) + ") VALUES ($placeholders) ON CONFLICT($onKeys) DO UPDATE SET $updateClause"
        [void](Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters $Row -NonQuery)
    }

    [void]BulkUpsert([System.Collections.IEnumerable]$Rows, [string[]]$KeyColumns) {
    Enable-UpsertSupported -Database $this.Database
        $tx = Start-DbTransaction -Database $this.Database
        try {
            foreach ($row in $Rows) { $this.InsertOnConflict($row, $KeyColumns, $null) }
            Complete-DbTransaction -Database $this.Database -Transaction $tx
        }
        catch { Rollback-DbTransaction -Database $this.Database -Transaction $tx; throw }
    }

    [object]Raw([string]$Sql, [hashtable]$Params) { return Invoke-DbQuery -Database $this.Database -Query $Sql -SqlParameters $Params }

    [object[]]GetHasMany([string]$relatedTable) {
        $assoc = $this.Associations["has_many_$relatedTable"]; if (-not $assoc) { throw "No has_many '$relatedTable' defined" }
    $sql = "SELECT * FROM $(ConvertTo-Ident $($assoc.Table)) WHERE $(ConvertTo-Ident $($assoc.ForeignKey)) = @id"
        $results = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters @{id = $this.Id }
        $relatedTypeObj = $script:ModelTypeObjects[$assoc.Table]
        $cols = Get-TableColumns -Database $this.Database -TableName $assoc.Table
        $records = @()
        foreach ($row in $results) {
            if ($relatedTypeObj) {
                $ctorInfo = $relatedTypeObj.GetConstructor([type[]]@([string]))
                $rec = $ctorInfo.Invoke(@($this.Database))
            }
            else {
                $rec = [DynamicActiveRecord]::new($assoc.Table, $this.Database, $cols)
            }
            if ($row.PSObject.Properties.Name -contains 'id') { $rec.Id = [int]$row.id }
            foreach ($p in $row.PSObject.Properties) { 
                if ($p.Name -ne 'id' -and $p.Name -notin $this.ExcludedProperties) { 
                    $rec.SetAttribute($p.Name, $p.Value) 
                } 
            }
            $records += $rec
        }
        return $records
    }

    [DynamicActiveRecord]GetBelongsTo([string]$relatedTable) {
        $assoc = $this.Associations["belongs_to_$relatedTable"]; if (-not $assoc) { throw "No belongs_to '$relatedTable' defined" }
        $fkId = $this.Attributes[$assoc.ForeignKey]; if ($null -eq $fkId) { return $null }
    $sql = "SELECT * FROM $(ConvertTo-Ident $($assoc.Table)) WHERE id = @id"
        $res = Invoke-DbQuery -Database $this.Database -Query $sql -SqlParameters @{id = $fkId }
        if (-not $res -or $res.Count -eq 0) { return $null }
        $relatedTypeObj = $script:ModelTypeObjects[$assoc.Table]
        $cols = Get-TableColumns -Database $this.Database -TableName $assoc.Table
        $row = $res[0]
        if ($relatedTypeObj) {
            $ctorInfo = $relatedTypeObj.GetConstructor([type[]]@([string]))
            $rec = $ctorInfo.Invoke(@($this.Database))
        }
        else {
            $rec = [DynamicActiveRecord]::new($assoc.Table, $this.Database, $cols)
        }
        $rec.Id = [int]$row.id
        foreach ($p in $row.PSObject.Properties) { 
            if ($p.Name -ne 'id' -and $p.Name -notin $this.ExcludedProperties) { 
                $rec.SetAttribute($p.Name, $p.Value) 
            } 
        }        return $rec
    }
}
