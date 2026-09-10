# Regression tests for DynamicActiveRecord (dynamic models).
# Runs on Windows PowerShell 5.1 and PowerShell 7. Databases are created under a unique directory inside $env:TEMP.

# Join two pieces at a time: the three-argument Join-Path form does not exist on Windows PowerShell 5.1
$script:ModuleFolder = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM'
Import-Module $script:ModuleFolder -Force

BeforeAll {
    $script:ModuleFolder = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM'
    Import-Module $script:ModuleFolder -Force
    $script:Orm = Get-Module PSCsvSQLiteORM | Where-Object { $_.ModuleBase -like ((Split-Path -Parent $PSScriptRoot) + '*') } | Select-Object -First 1
    if (-not $script:Orm) { $script:Orm = Get-Module PSCsvSQLiteORM | Select-Object -First 1 }
    $script:TestRoot = Join-Path $env:TEMP ("orm_models_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    Initialize-ORMVars -LogLevel ERROR

    function New-TestDbPath([string]$Name) {
        return (Join-Path $script:TestRoot ("{0}_{1}.db" -f $Name, ([guid]::NewGuid().ToString('N').Substring(0, 8))))
    }

    function New-TestCsv([string]$Name, [string]$Content) {
        $f = Join-Path $script:TestRoot $Name
        Set-Content -LiteralPath $f -Value $Content -Encoding ASCII
        return $f
    }

    # Creates an instance of the generated model for $Table. The generated class is only resolvable in the scope
    # that dot-sources it, so the file is loaded and instantiated inside a module-scope scriptblock.
    function New-TestModel([string]$Table, [string]$Database) {
        $m = $script:Orm
        # Models are registered per database (BUG-017): look the entry up by database and table
        $entry = Get-ModelEntry $Table $Database
        return (& $m { param($p, $d, $tn) . $p; New-Object -TypeName $tn -ArgumentList $d } ([string]$entry.ModelPath) ([string]$Database) ([string]$entry.TypeName))
    }

    # Returns the module's registry entry (TypeName, ModelPath, Columns, Members) for a (database, table) pair.
    function Get-ModelEntry([string]$Table, [string]$Database) {
        return (& $script:Orm { param($t, $d) $script:ModelRegistry[(Get-DynamicDatabaseKey -Database $d)][$t] } $Table $Database)
    }

    function Get-ClassScripts {
        return @(& $script:Orm { @($script:DynamicClassScripts) })
    }

    function Get-MethodNames([object]$Record) {
        return @($Record | Get-Member -MemberType Method | ForEach-Object { $_.Name } | Sort-Object -Unique)
    }

    # Creates a plain base DynamicActiveRecord (no generated subclass) through reflection.
    function New-BaseRecord([string]$Table, [string]$Database, [string[]]$Columns) {
        $baseType = & $script:Orm { [DynamicActiveRecord] }
        $ctor = $baseType.GetConstructor([type[]]@([string], [string], [string[]]))
        return $ctor.Invoke([object[]]@([string]$Table, [string]$Database, [string[]]$Columns))
    }

    function Get-Count([string]$Database, [string]$Sql) {
        $r = Invoke-DbQuery -Database $Database -Query $Sql
        return [int]($r | Select-Object -First 1).c
    }

    function Initialize-AssetsDb([string]$Database) {
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -Database $Database -TableName 'assets' | Out-Null
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -Database $Database -TableName 'vulns' | Out-Null
        Confirm-DbForeignKey -Database $Database -From 'vulns' -Column 'asset_id' -To 'assets' -OnDelete 'CASCADE'
        Export-DynamicModelsFromCatalog -Database $Database | Out-Null
        Set-DynamicORMClass
    }
}

AfterAll {
    Close-DbConnections
}

Describe 'BUG-001 BulkUpsert failure rolls back and leaves no dangling transaction' -Tag 'BUG-001' {
    BeforeAll {
        $script:db001 = New-TestDbPath 'bug001'
        Initialize-AssetsDb $script:db001
        $script:a001 = New-TestModel 'assets' $script:db001
    }
    AfterAll { Close-DbConnections }

    It 'does not surface a missing Rollback-DbTransaction command' {
        $message = ''
        try { $script:a001.BulkUpsert(@(@{ hostname = 'bx1'; ip = '1.1.1.1' }, @{ hostname = 'bx2'; nosuchcol = 'x' }), @('hostname')); 'no throw' } catch { $message = $_.Exception.Message }
        $message | Should -Not -Match 'Rollback-DbTransaction'
    }

    It 'leaves the pooled connection in auto-commit mode' {
        $conn = Get-DbConnection -Database $script:db001
        if ($conn) { $conn.AutoCommit | Should -BeTrue } else { $true | Should -BeTrue }
    }

    It 'keeps later writes durable after Close-DbConnections' {
        Invoke-DbQuery -Database $script:db001 -Query 'CREATE TABLE later(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db001 -Query "INSERT INTO later(name) VALUES('x')" -NonQuery | Out-Null
        $rec = $script:a001.FindById(1); $rec.SetAttribute('ip', '7.7.7.7'); $rec.Save()
        Close-DbConnections
        $rows = Invoke-SqliteQuery -DataSource $script:db001 -Query 'SELECT COUNT(*) AS c FROM later' -ErrorAction Stop
        [int]($rows | Select-Object -First 1).c | Should -Be 1
        $ip = Invoke-SqliteQuery -DataSource $script:db001 -Query 'SELECT ip FROM assets WHERE id = 1' -ErrorAction Stop
        ($ip | Select-Object -First 1).ip | Should -Be '7.7.7.7'
    }

    It 'still commits a successful BulkUpsert' {
        $script:a001.BulkUpsert(@(@{ hostname = 'ok1'; ip = '2.2.2.2' }, @{ hostname = 'ok1'; ip = '3.3.3.3' }), @('hostname'))
        Close-DbConnections
        $rows = Invoke-SqliteQuery -DataSource $script:db001 -Query "SELECT ip FROM assets WHERE hostname = 'ok1'" -ErrorAction Stop
        @($rows).Count | Should -Be 1
        ($rows | Select-Object -First 1).ip | Should -Be '3.3.3.3'
    }
}

Describe 'BUG-010 InsertOnConflict works on every supported SQLite version' -Tag 'BUG-010' {
    BeforeAll {
        $script:db010 = New-TestDbPath 'bug010'
        Initialize-AssetsDb $script:db010
        $script:a010 = New-TestModel 'assets' $script:db010
    }
    AfterAll { Close-DbConnections }

    It 'inserts a new row and updates on conflict (native or emulated upsert)' {
        $script:a010.InsertOnConflict(@{ hostname = 'up1'; ip = '1.1.1.1' }, @('hostname'), $null)
        (Get-Count $script:db010 "SELECT COUNT(*) AS c FROM assets WHERE hostname = 'up1'") | Should -Be 1
        $script:a010.InsertOnConflict(@{ hostname = 'up1'; ip = '9.9.9.9' }, @('hostname'), $null)
        (Get-Count $script:db010 "SELECT COUNT(*) AS c FROM assets WHERE hostname = 'up1'") | Should -Be 1
        (Invoke-DbQuery -Database $script:db010 -Query "SELECT ip FROM assets WHERE hostname = 'up1'" | Select-Object -First 1).ip | Should -Be '9.9.9.9'
    }

    It 'honours an explicit UpdateSet using excluded.<column>' {
        $script:a010.InsertOnConflict(@{ hostname = 'up1'; ip = '5.5.5.5' }, @('hostname'), @{ ip = 'excluded.ip' })
        (Invoke-DbQuery -Database $script:db010 -Query "SELECT ip FROM assets WHERE hostname = 'up1'" | Select-Object -First 1).ip | Should -Be '5.5.5.5'
    }

    It 'accepts a row that contains only key columns' {
        $script:a010.InsertOnConflict(@{ hostname = 'up1' }, @('hostname'), $null)
        (Get-Count $script:db010 "SELECT COUNT(*) AS c FROM assets WHERE hostname = 'up1'") | Should -Be 1
    }

    It 'BulkUpsert applies every row' {
        $script:a010.BulkUpsert(@(@{ hostname = 'up2'; ip = '8.8.8.8' }, @{ hostname = 'up1'; ip = '7.7.7.7' }), @('hostname'))
        (Get-Count $script:db010 "SELECT COUNT(*) AS c FROM assets WHERE hostname IN ('up1','up2')") | Should -Be 2
        (Invoke-DbQuery -Database $script:db010 -Query "SELECT ip FROM assets WHERE hostname = 'up1'" | Select-Object -First 1).ip | Should -Be '7.7.7.7'
    }
}

Describe 'BUG-015 base records and related records can keep navigating' -Tag 'BUG-015' {
    BeforeAll {
        $script:db015 = New-TestDbPath 'bug015'
        Initialize-AssetsDb $script:db015
        $script:a015 = New-TestModel 'assets' $script:db015
        $script:v015 = New-TestModel 'vulns' $script:db015
    }
    AfterAll { Close-DbConnections }

    It 'has_many records can call FindById' {
        $children = @($script:a015.FindById(1).GetHasMany('vulns'))
        $children.Count | Should -BeGreaterThan 0
        $child = $children[0]
        $found = $child.FindById($child.Id)
        $found | Should -Not -BeNullOrEmpty
        $found.GetAttribute('title') | Should -Be $child.GetAttribute('title')
    }

    It 'has_many records know their belongs_to association' {
        $child = @($script:a015.FindById(1).GetHasMany('vulns'))[0]
        $parent = $child.GetBelongsTo('assets')
        $parent | Should -Not -BeNullOrEmpty
        $parent.GetAttribute('hostname') | Should -Be $script:a015.FindById(1).GetAttribute('hostname')
    }

    It 'belongs_to records can call Where and First' {
        $parent = $script:v015.FindById(1).GetBelongsTo('assets')
        @($parent.Where('1 = 1', $null)).Count | Should -BeGreaterThan 0
        $parent.First('id ASC') | Should -Not -BeNullOrEmpty
        @($parent.GetHasMany('vulns')).Count | Should -BeGreaterThan 0
    }

    It 'a plain DynamicActiveRecord instance can call FindById, Where and First' {
        $base = New-BaseRecord 'assets' $script:db015 @('id', 'hostname', 'ip')
        $base.FindById(1).GetAttribute('hostname') | Should -Not -BeNullOrEmpty
        @($base.Where('id = @id', @{ id = 1 })).Count | Should -Be 1
        $base.First('id ASC').Id | Should -Be 1
    }
}

Describe 'BUG-016 tables without an id column use rowid as the record key' -Tag 'BUG-016' {
    BeforeAll {
        $script:db016 = New-TestDbPath 'bug016'
        $csv = New-TestCsv 'noid.csv' "code,label`r`nA,one`r`nB,two"
        Import-CsvToSqlite -CsvPath $csv -Database $script:db016 -TableName 'noid' | Out-Null
        Export-DynamicModelsFromCatalog -Database $script:db016 | Out-Null
        Set-DynamicORMClass
        $script:x016 = New-TestModel 'noid' $script:db016
    }
    AfterAll { Close-DbConnections }

    It 'Where() returns records with a non-zero Id' {
        $rec = @($script:x016.Where('code = @c', @{ c = 'A' }))[0]
        $rec.Id | Should -BeGreaterThan 0
        $rec.GetAttribute('code') | Should -Be 'A'
    }

    It 'Save() on a Where() record updates instead of inserting a duplicate' {
        $rec = @($script:x016.Where('code = @c', @{ c = 'A' }))[0]
        $rec.SetAttribute('label', 'ONE')
        $rec.Save()
        (Get-Count $script:db016 "SELECT COUNT(*) AS c FROM noid WHERE code = 'A'") | Should -Be 1
        (Invoke-DbQuery -Database $script:db016 -Query "SELECT label FROM noid WHERE code = 'A'" | Select-Object -First 1).label | Should -Be 'ONE'
    }

    It 'FindById() and First() work' {
        $rec = @($script:x016.Where('code = @c', @{ c = 'A' }))[0]
        $script:x016.FindById($rec.Id).GetAttribute('label') | Should -Be 'ONE'
        $first = $script:x016.First('code ASC')
        $first.Id | Should -BeGreaterThan 0
        $first.GetAttribute('code') | Should -Be 'A'
    }

    It 'a new record can be inserted and then updated' {
        $n = New-TestModel 'noid' $script:db016
        $n.SetAttribute('code', 'C'); $n.SetAttribute('label', 'three'); $n.Save()
        $n.Id | Should -BeGreaterThan 0
        $n.SetAttribute('label', 'THREE'); $n.Save()
        (Get-Count $script:db016 "SELECT COUNT(*) AS c FROM noid WHERE code = 'C'") | Should -Be 1
        (Invoke-DbQuery -Database $script:db016 -Query "SELECT label FROM noid WHERE code = 'C'" | Select-Object -First 1).label | Should -Be 'THREE'
    }

    It 'Delete() removes the row' {
        $rec = @($script:x016.Where('code = @c', @{ c = 'B' }))[0]
        $rec.Delete()
        (Get-Count $script:db016 "SELECT COUNT(*) AS c FROM noid WHERE code = 'B'") | Should -Be 0
    }
}

Describe 'BUG-002 columns named after base members do not hide Save/Delete' -Tag 'BUG-002' {
    BeforeAll {
        $script:db002 = New-TestDbPath 'bug002'
        $csv = New-TestCsv 'sv.csv' "id,Save,Delete,note`r`n1,y,n,first"
        Import-CsvToSqlite -CsvPath $csv -Database $script:db002 -TableName 'sv' | Out-Null
        Export-DynamicModelsFromCatalog -Database $script:db002 | Out-Null
        Set-DynamicORMClass
    }
    AfterAll { Close-DbConnections }

    It 'Save() on a new record inserts a row' {
        $r = New-TestModel 'sv' $script:db002
        $r.SetAttribute('note', 'second'); $r.SetAttribute('Save', 'y')
        $r.Save()
        $r.Id | Should -BeGreaterThan 0
        (Get-Count $script:db002 'SELECT COUNT(*) AS c FROM sv') | Should -Be 2
    }

    It 'Delete() on a found record removes the row' {
        $r = (New-TestModel 'sv' $script:db002).FindById(1)
        $r | Should -Not -BeNullOrEmpty
        $r.Delete()
        (Get-Count $script:db002 'SELECT COUNT(*) AS c FROM sv WHERE id = 1') | Should -Be 0
    }

    It 'exposes the colliding columns through Col_ accessors and keeps the base signatures' {
        $r = New-TestModel 'sv' $script:db002
        $r.SetAttribute('Save', 'v1')
        $r.Col_Save() | Should -Be 'v1'
        $r.Col_Delete('v2')
        $r.GetAttribute('Delete') | Should -Be 'v2'
        $defs = @($r | Get-Member -MemberType Method | Where-Object { $_.Name -eq 'Save' -or $_.Name -eq 'Delete' } | ForEach-Object { $_.Definition }) -join ';'
        $defs | Should -Match 'void Save\(\)'
        $defs | Should -Match 'void Delete\(\)'
        $defs | Should -Not -Match 'Object Save\(\)'
        $defs | Should -Not -Match 'Object Delete\(\)'
        $entry = Get-ModelEntry 'sv' $script:db002
        @($entry.Members | Where-Object { $_.Column -eq 'Save' })[0].Member | Should -Be 'Col_Save'
    }

    It 'never emits an accessor that hides a DynamicActiveRecord or System.Object member' {
        $cols = @('id', 'Where', 'All', 'First', 'FindById', 'Validate', 'GetAttribute', 'SetAttribute', 'HasMany', 'GetType', 'ToString', 'Equals', 'GetHashCode', 'Columns', 'Database', 'TableName', 'Attributes', 'Id')
        $typeName = New-DynamicModel -TableName 'members002' -Database $script:db002 -Columns $cols
        $r = New-TestModel 'members002' $script:db002
        $names = Get-MethodNames $r
        foreach ($c in ($cols | Where-Object { $_ -ne 'id' })) { $names | Should -Contain ('Col_' + $c) }
        $r.ToString() | Should -Be $typeName
        ($r | Get-Member -Name 'Where').Definition | Should -Match 'Where\(string'
        $r.Columns.Count | Should -Be $cols.Count
        $r.Database | Should -Be $script:db002
    }
}

Describe 'BUG-018 generated classes always parse and load' -Tag 'BUG-018' {
    BeforeAll {
        $script:db018 = New-TestDbPath 'bug018'
        Invoke-DbQuery -Database $script:db018 -Query 'CREATE TABLE dup(id INTEGER PRIMARY KEY, "a b" TEXT, a_b TEXT, "a-b" TEXT, "a.b" TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db018 -Query 'CREATE TABLE q(id INTEGER PRIMARY KEY, "it''s" TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db018 -Query 'CREATE TABLE kw(id INTEGER PRIMARY KEY, class TEXT, function TEXT)' -NonQuery | Out-Null
        $script:e018 = [string][char]0x00E9; $script:u018 = [string][char]0x00FC
        Invoke-DbQuery -Database $script:db018 -Query ('CREATE TABLE intl(id INTEGER PRIMARY KEY, "{0}" TEXT, "{1}" TEXT)' -f $script:e018, $script:u018) -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db018 -Query 'CREATE TABLE zz_last(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        $script:t018 = Export-DynamicModelsFromCatalog -Database $script:db018
    }
    AfterAll { Close-DbConnections }

    It 'Set-DynamicORMClass loads every model without error' {
        $script:t018.Keys.Count | Should -Be 5
        { Set-DynamicORMClass } | Should -Not -Throw
    }

    It 'columns whose sanitized names collide get unique member names' {
        $r = New-TestModel 'dup' $script:db018
        $entry = Get-ModelEntry 'dup' $script:db018
        $members = @($entry.Members | ForEach-Object { $_.Member })
        $members.Count | Should -Be 4
        @($members | Sort-Object -Unique).Count | Should -Be 4
        $names = Get-MethodNames $r
        foreach ($mname in $members) { $names | Should -Contain $mname }
        foreach ($col in @('a b', 'a_b', 'a-b', 'a.b')) {
            $mname = @($entry.Members | Where-Object { $_.Column -eq $col })[0].Member
            $r.$mname("value of $col")
            $r.GetAttribute($col) | Should -Be "value of $col"
        }
    }

    It 'a column containing a quote is escaped in the generated class' {
        $r = New-TestModel 'q' $script:db018
        $r.it_s('v')
        $r.GetAttribute("it's") | Should -Be 'v'
        $r.Columns | Should -Contain "it's"
    }

    It 'columns named after PowerShell keywords load on every host' {
        $r = New-TestModel 'kw' $script:db018
        $names = Get-MethodNames $r
        $names | Should -Contain 'Col_class'
        $names | Should -Contain 'Col_function'
        $r.SetAttribute('class', 'c1'); $r.SetAttribute('function', 'f1')
        $r.Save()
        $r.Id | Should -BeGreaterThan 0
        $r.Col_class() | Should -Be 'c1'
    }

    It 'non-ASCII column names do not collide' {
        $r = New-TestModel 'intl' $script:db018
        $entry = Get-ModelEntry 'intl' $script:db018
        $members = @($entry.Members | ForEach-Object { $_.Member })
        @($members | Sort-Object -Unique).Count | Should -Be 2
        $r.$($members[0])('first'); $r.$($members[1])('second')
        $r.GetAttribute($script:e018) | Should -Be 'first'
        $r.GetAttribute($script:u018) | Should -Be 'second'
    }

    It 'a broken model file is reported by path and does not stop the other models from loading' {
        $entry = Get-ModelEntry 'dup' $script:db018
        $backup = Get-Content -LiteralPath $entry.ModelPath -Raw
        try {
            Set-Content -LiteralPath $entry.ModelPath -Value 'class Broken018 : DynamicActiveRecord { this is not valid' -Encoding UTF8
            $message = $null
            try { Set-DynamicORMClass } catch { $message = $_.Exception.Message }
            $message | Should -Not -BeNullOrEmpty
            $message | Should -Match 'could not load 1 dynamic model file'
            $message | Should -Match ([regex]::Escape($entry.ModelPath))
        }
        finally {
            Set-Content -LiteralPath $entry.ModelPath -Value $backup -Encoding UTF8
        }
        { Set-DynamicORMClass } | Should -Not -Throw
    }
}

Describe 'BUG-017 models are registered per database' -Tag 'BUG-017' {
    BeforeAll {
        $script:db017a = New-TestDbPath 'bug017a'
        $script:db017b = New-TestDbPath 'bug017b'
        $c1 = New-TestCsv 'one017.csv' "id,hostname,ip`r`n1,h1,1.1.1.1"
        $c2 = New-TestCsv 'two017.csv' "id,name,owner`r`n1,n1,o1"
        Import-CsvToSqlite -CsvPath $c1 -Database $script:db017a -TableName 'assets' | Out-Null
        Import-CsvToSqlite -CsvPath $c2 -Database $script:db017b -TableName 'assets' | Out-Null
        $script:t017a = Export-DynamicModelsFromCatalog -Database $script:db017a
        $script:t017b = Export-DynamicModelsFromCatalog -Database $script:db017b
        Set-DynamicORMClass
    }
    AfterAll { Close-DbConnections }

    It 'returns a separate result per database with distinct type names' {
        [object]::ReferenceEquals($script:t017a, $script:t017b) | Should -BeFalse
        @($script:t017a.Keys).Count | Should -Be 1
        @($script:t017b.Keys).Count | Should -Be 1
        # Earlier tests may already own the plain DynamicAssets name; both names derive from it and must differ
        $script:t017a['assets'] | Should -Match '^DynamicAssets(_[0-9a-f]{8})?$'
        $script:t017b['assets'] | Should -Match '^DynamicAssets_[0-9a-f]{8}$'
        $script:t017b['assets'] | Should -Not -Be $script:t017a['assets']
    }

    It 'each database keeps its own columns, accessors and data' {
        $a = New-TestModel 'assets' $script:db017a
        $b = New-TestModel 'assets' $script:db017b
        ($a.Columns -join '|') | Should -Be 'id|hostname|ip'
        ($b.Columns -join '|') | Should -Be 'id|name|owner'
        $a.FindById(1).hostname() | Should -Be 'h1'
        $b.FindById(1).name() | Should -Be 'n1'
        (Get-MethodNames $a) | Should -Not -Contain 'name'
        (Get-MethodNames $b) | Should -Not -Contain 'hostname'
    }

    It 'does not accumulate registry entries on repeated export' {
        $before = (Get-ClassScripts).Count
        Export-DynamicModelsFromCatalog -Database $script:db017a | Out-Null
        Export-DynamicModelsFromCatalog -Database $script:db017a | Out-Null
        (Get-ClassScripts).Count | Should -Be $before
        $entryA = Get-ModelEntry 'assets' $script:db017a
        @(Get-ClassScripts | Where-Object { $_.ModelPath -eq $entryA.ModelPath }).Count | Should -Be 1
        $entryA.TypeName | Should -Be $script:t017a['assets']
    }

    It 'writes generated files into a per-session directory' {
        $entryA = Get-ModelEntry 'assets' $script:db017a
        $entryB = Get-ModelEntry 'assets' $script:db017b
        $entryA.ModelPath | Should -Not -Be $entryB.ModelPath
        (Split-Path -Parent $entryA.ModelPath) | Should -Match ('PSCsvSQLiteORM_' + $PID + '_')
        Test-Path -LiteralPath $entryA.ModelPath | Should -BeTrue
        Test-Path -LiteralPath $entryB.ModelPath | Should -BeTrue
    }

    It 'Set-DynamicORMClass reports a registered file that is missing' {
        $entry = Get-ModelEntry 'assets' $script:db017b
        $moved = $entry.ModelPath + '.moved'
        Move-Item -LiteralPath $entry.ModelPath -Destination $moved
        try {
            $message = $null
            try { Set-DynamicORMClass } catch { $message = $_.Exception.Message }
            $message | Should -Match 'file not found'
            $message | Should -Match ([regex]::Escape($entry.ModelPath))
        }
        finally { Move-Item -LiteralPath $moved -Destination $entry.ModelPath }
        { Set-DynamicORMClass } | Should -Not -Throw
    }
}

Describe 'BUG-036 type names are unique per table and never an existing type' -Tag 'BUG-036' {
    BeforeAll {
        $script:db036 = New-TestDbPath 'bug036'
        $script:tables036 = @('user_assets', 'user-assets', 'active_record', '__', 'model')
        foreach ($t in $script:tables036) {
            Invoke-DbQuery -Database $script:db036 -Query ('CREATE TABLE {0}(id INTEGER PRIMARY KEY, val TEXT)' -f (ConvertTo-Ident $t)) -NonQuery | Out-Null
        }
        $script:t036 = Export-DynamicModelsFromCatalog -Database $script:db036
        Set-DynamicORMClass
    }
    AfterAll { Close-DbConnections }

    It 'assigns a distinct type name to every table' {
        @($script:t036.Keys).Count | Should -Be $script:tables036.Count
        @($script:t036.Values | Sort-Object -Unique).Count | Should -Be $script:tables036.Count
    }

    It 'keeps the readable PascalCase name for simple table names' {
        $script:t036['user_assets'] | Should -Be 'DynamicUserAssets'
        $script:t036['model'] | Should -Be 'DynamicModel'
        $script:t036['user-assets'] | Should -Match '^DynamicUserAssets_[0-9a-f]{8}$'
    }

    It 'never resolves to DynamicActiveRecord, DbQuery or DbJoinSpec' {
        foreach ($v in $script:t036.Values) {
            $v | Should -Not -BeIn @('DynamicActiveRecord', 'DbQuery', 'DbJoinSpec')
            $v | Should -Match '^Dynamic'
        }
    }

    It 'binds each model to its own table' {
        foreach ($t in $script:tables036) {
            $r = New-TestModel $t $script:db036
            $r.GetType().Name | Should -Be $script:t036[$t]
            $r.TableName | Should -Be $t
        }
    }

    It 'a table named active_record gets a real subclass that can save' {
        $r = New-TestModel 'active_record' $script:db036
        $r.GetType().Name | Should -Not -Be 'DynamicActiveRecord'
        $r.GetType().BaseType.Name | Should -Be 'DynamicActiveRecord'
        $r.SetAttribute('val', 'x'); $r.Save()
        $r.Id | Should -BeGreaterThan 0
        $r.val() | Should -Be 'x'
    }

    It 'New-DynamicModel derives the same name as Export-DynamicModelsFromCatalog' {
        (New-DynamicModel -TableName 'user-assets' -Database $script:db036 -Columns @('id', 'val')) | Should -Be $script:t036['user-assets']
        (New-DynamicModel -TableName 'user_assets' -Database $script:db036 -Columns @('id', 'val')) | Should -Be 'DynamicUserAssets'
    }
}

Describe 'BUG-035 generated types are captured on load and exposed through New-DynamicRecord' -Tag 'BUG-035' {
    BeforeAll {
        $script:db035 = New-TestDbPath 'bug035'
        Initialize-AssetsDb $script:db035
        $script:t035 = & $script:Orm { param($d) $script:ModelRegistry[(Get-DynamicDatabaseKey -Database $d)]['assets'].TypeName } $script:db035
    }
    AfterAll { Close-DbConnections }

    It 'Set-DynamicORMClass records the [type] of every loaded model' {
        $captured = & $script:Orm { $script:ModelTypeObjects['assets'] }
        $captured | Should -Not -BeNullOrEmpty
        $captured.Name | Should -Be $script:t035
        $captured.BaseType.Name | Should -Be 'DynamicActiveRecord'
        $entry = Get-ModelEntry 'assets' $script:db035
        $entry.Type | Should -Not -BeNullOrEmpty
        $entry.Type.Name | Should -Be $script:t035
        (Get-ModelEntry 'vulns' $script:db035).Type | Should -Not -BeNullOrEmpty
    }

    It 'New-DynamicRecord is exported and builds an instance of the generated class from the caller scope' {
        (Get-Command New-DynamicRecord -Module PSCsvSQLiteORM) | Should -Not -BeNullOrEmpty
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db035
        $rec | Should -Not -BeNullOrEmpty
        $rec.GetType().Name | Should -Be $script:t035
        $rec.TableName | Should -Be 'assets'
        $rec.Database | Should -Be $script:db035
        (Get-MethodNames $rec) | Should -Contain 'hostname'
        $rec.FindById(1).hostname() | Should -Be 'server01'
    }

    It 'a record from New-DynamicRecord can insert, update and delete rows' {
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db035
        $rec.hostname('server-new'); $rec.ip('10.9.9.9')
        $rec.Save()
        $rec.Id | Should -BeGreaterThan 0
        $again = (New-DynamicRecord -Table 'assets' -Database $script:db035).FindById($rec.Id)
        $again.hostname() | Should -Be 'server-new'
        $again.ip('10.9.9.10'); $again.Save()
        (Get-Count $script:db035 ("SELECT COUNT(*) AS c FROM assets WHERE ip = '10.9.9.10' AND id = {0}" -f $rec.Id)) | Should -Be 1
        $again.Delete()
        (Get-Count $script:db035 ("SELECT COUNT(*) AS c FROM assets WHERE id = {0}" -f $rec.Id)) | Should -Be 0
    }

    # This file imports the module twice (-Force): on 5.1 the reused compiled class then runs bound to the first
    # import's session state, so this also covers the static type store used by NewRelatedInstance.
    It 'related records are instances of the generated class for their table' {
        $asset = (New-DynamicRecord -Table 'assets' -Database $script:db035).FindById(1)
        $children = @($asset.GetHasMany('vulns'))
        $children.Count | Should -BeGreaterThan 0
        $children[0].GetType().Name | Should -Be (Get-ModelEntry 'vulns' $script:db035).TypeName
        (Get-MethodNames $children[0]) | Should -Contain 'severity'
        $parent = $children[0].GetBelongsTo('assets')
        $parent.GetType().Name | Should -Be $script:t035
        $parent.hostname() | Should -Be 'server01'
    }

    It 'New-DynamicRecord loads the classes itself when Set-DynamicORMClass has not run yet' {
        $db = New-TestDbPath 'bug035b'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO notes(body) VALUES ('hello')" -NonQuery | Out-Null
        $types = Export-DynamicModelsFromCatalog -Database $db
        $rec = New-DynamicRecord -Table 'notes' -Database $db
        $rec.GetType().Name | Should -Be $types['notes']
        $rec.FindById(1).body() | Should -Be 'hello'
        (Get-ModelEntry 'notes' $db).Type | Should -Not -BeNullOrEmpty
    }

    It 'New-DynamicRecord throws for a table with no registered model' {
        { New-DynamicRecord -Table 'no_such_table' -Database $script:db035 } | Should -Throw '*No dynamic model is registered*'
    }

    It 'a regenerated model is usable again after Set-DynamicORMClass' {
        Export-DynamicModelsFromCatalog -Database $script:db035 | Out-Null
        Set-DynamicORMClass
        (Get-ModelEntry 'assets' $script:db035).Type | Should -Not -BeNullOrEmpty
        (New-DynamicRecord -Table 'assets' -Database $script:db035).FindById(2).hostname() | Should -Be 'server02'
    }
}

Describe 'BASE-05 First() can be called without an argument' -Tag 'BASE-05' {
    BeforeAll {
        $script:db005 = New-TestDbPath 'base005'
        Initialize-AssetsDb $script:db005
        $script:a005 = New-DynamicRecord -Table 'assets' -Database $script:db005
    }
    AfterAll { Close-DbConnections }

    It 'First() returns the row with the lowest id' {
        $first = $script:a005.First()
        $first | Should -Not -BeNullOrEmpty
        $first.Id | Should -Be 1
        $first.hostname() | Should -Be 'server01'
    }

    It 'First(OrderBy) still honours an explicit ordering' {
        $last = $script:a005.First('id DESC')
        $last.Id | Should -BeGreaterThan 1
        $last.Id | Should -Be (Get-Count $script:db005 'SELECT MAX(id) AS c FROM assets')
    }

    It 'First() returns null for an empty table' {
        $db = New-TestDbPath 'base005b'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE empty_t(id INTEGER PRIMARY KEY, val TEXT)' -NonQuery | Out-Null
        $rec = New-BaseRecord 'empty_t' $db @('id', 'val')
        $rec.First() | Should -BeNullOrEmpty
    }
}

Describe 'BASE-08 columns with spaces or dashes save through the record' -Tag 'BASE-08' {
    BeforeAll {
        $script:db008 = New-TestDbPath 'base008'
        $csv = New-TestCsv 'people_base008.csv' "First Name,Last-Name`nAda,Lovelace"
        Import-CsvToSqlite -CsvPath $csv -Database $script:db008 -TableName 'people' | Out-Null
        Export-DynamicModelsFromCatalog -Database $script:db008 | Out-Null
        Set-DynamicORMClass
        $script:p008 = New-DynamicRecord -Table 'people' -Database $script:db008
    }
    AfterAll { Close-DbConnections }

    It 'the imported table keeps the raw header names as columns' {
        $cols = @(Invoke-DbQuery -Database $script:db008 -Query 'PRAGMA table_info(people)' | ForEach-Object { $_.name })
        $cols | Should -Contain 'First Name'
        $cols | Should -Contain 'Last-Name'
    }

    It 'Save() inserts a row with spaced and dashed columns and keeps Columns as an array' {
        $rec = New-DynamicRecord -Table 'people' -Database $script:db008
        $rec.SetAttribute('First Name', 'Grace'); $rec.SetAttribute('Last-Name', 'Hopper')
        { $rec.Save() } | Should -Not -Throw
        $rec.Id | Should -BeGreaterThan 0
        @($rec.Columns).Count | Should -Be 2
        @($rec.Columns) | Should -Contain 'First Name'
        $again = $script:p008.FindById($rec.Id)
        $again.GetAttribute('First Name') | Should -Be 'Grace'
        $again.GetAttribute('Last-Name') | Should -Be 'Hopper'
    }

    It 'Save() updates a row with spaced and dashed columns' {
        $rec = $script:p008.FindById(1)
        $rec.SetAttribute('Last-Name', 'Byron'); $rec.Save()
        (Invoke-DbQuery -Database $script:db008 -Query 'SELECT "Last-Name" AS ln FROM people WHERE rowid = 1' | Select-Object -First 1).ln | Should -Be 'Byron'
        (Invoke-DbQuery -Database $script:db008 -Query 'SELECT "First Name" AS fn FROM people WHERE rowid = 1' | Select-Object -First 1).fn | Should -Be 'Ada'
    }

    It 'InsertMany() binds spaced and dashed columns' {
        { $script:p008.InsertMany(@(@{ 'First Name' = 'Alan'; 'Last-Name' = 'Turing' }, @{ 'First Name' = 'Edsger'; 'Last-Name' = 'Dijkstra' })) } | Should -Not -Throw
        (Get-Count $script:db008 "SELECT COUNT(*) AS c FROM people WHERE ""First Name"" IN ('Alan', 'Edsger')") | Should -Be 2
        @($script:p008.Columns).Count | Should -Be 2
    }

    It 'InsertOnConflict() binds spaced and dashed columns and updates on conflict' {
        { $script:p008.InsertOnConflict(@{ 'First Name' = 'Alan'; 'Last-Name' = 'Mathison' }, @('First Name'), $null) } | Should -Not -Throw
        (Get-Count $script:db008 "SELECT COUNT(*) AS c FROM people WHERE ""First Name"" = 'Alan'") | Should -Be 1
        (Invoke-DbQuery -Database $script:db008 -Query 'SELECT "Last-Name" AS ln FROM people WHERE "First Name" = ''Alan''' | Select-Object -First 1).ln | Should -Be 'Mathison'
    }

    It 'InsertOnConflict() still accepts an UpdateSet that references @<column>' {
        $db = New-TestDbPath 'base008b'
        Initialize-AssetsDb $db
        $a = New-DynamicRecord -Table 'assets' -Database $db
        $a.InsertOnConflict(@{ hostname = 'legacy1'; ip = '1.1.1.1' }, @('hostname'), $null)
        $a.InsertOnConflict(@{ hostname = 'legacy1'; ip = '2.2.2.2' }, @('hostname'), @{ ip = '@ip' })
        (Invoke-DbQuery -Database $db -Query "SELECT ip FROM assets WHERE hostname = 'legacy1'" | Select-Object -First 1).ip | Should -Be '2.2.2.2'
    }

    It 'a column named like a positional parameter does not collide' {
        $db = New-TestDbPath 'base008c'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE odd(id INTEGER PRIMARY KEY, p0 TEXT, "p 1" TEXT)' -NonQuery | Out-Null
        $rec = New-BaseRecord 'odd' $db @('id', 'p0', 'p 1')
        $rec.SetAttribute('p 1', 'space'); $rec.SetAttribute('p0', 'zero')
        $rec.Save()
        $row = Invoke-DbQuery -Database $db -Query 'SELECT p0, "p 1" AS p1 FROM odd WHERE id = 1' | Select-Object -First 1
        $row.p0 | Should -Be 'zero'
        $row.p1 | Should -Be 'space'
    }
}

Describe 'BUG-037 Save() UPDATE keeps its WHERE key separate from an id attribute' -Tag 'BUG-037' {
    BeforeAll {
        $script:db037 = New-TestDbPath 'bug037'
        Initialize-AssetsDb $script:db037
        $script:a037 = New-DynamicRecord -Table 'assets' -Database $script:db037
    }
    AfterAll { Close-DbConnections }

    It 'an update without an id attribute changes the loaded row' {
        $rec = $script:a037.FindById(1)
        $rec.SetAttribute('ip', '5.5.5.5'); $rec.Save()
        (Invoke-DbQuery -Database $script:db037 -Query 'SELECT ip FROM assets WHERE id = 1' | Select-Object -First 1).ip | Should -Be '5.5.5.5'
    }

    It 'an id attribute is applied to the loaded row instead of matching nothing' {
        $rec = $script:a037.FindById(1)
        $rec.SetAttribute('id', 77); $rec.SetAttribute('ip', '7.7.7.7')
        $rec.Save()
        (Get-Count $script:db037 'SELECT COUNT(*) AS c FROM assets WHERE id = 1') | Should -Be 0
        (Invoke-DbQuery -Database $script:db037 -Query 'SELECT ip FROM assets WHERE id = 77' | Select-Object -First 1).ip | Should -Be '7.7.7.7'
        $rec.Id | Should -Be 77
    }

    It 'the record keeps working after the key change' {
        $rec = $script:a037.FindById(77)
        $rec.SetAttribute('ip', '8.8.8.8'); $rec.Save()
        (Invoke-DbQuery -Database $script:db037 -Query 'SELECT ip FROM assets WHERE id = 77' | Select-Object -First 1).ip | Should -Be '8.8.8.8'
    }
}

Describe 'BUG-039 Before* callbacks can veto and After* callbacks only run on success' -Tag 'BUG-039' {
    BeforeAll {
        $script:db039 = New-TestDbPath 'bug039'
        Initialize-AssetsDb $script:db039
        $script:a039 = New-DynamicRecord -Table 'assets' -Database $script:db039
    }
    AfterAll { Close-DbConnections }

    It 'a throwing BeforeSave aborts the save and propagates the error' {
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db039
        $rec.SetAttribute('hostname', 'veto-save'); $rec.SetAttribute('ip', '1.2.3.4')
        $rec.On('BeforeSave', { throw 'save vetoed' })
        { $rec.Save() } | Should -Throw '*save vetoed*'
        $rec.Id | Should -Be 0
        (Get-Count $script:db039 "SELECT COUNT(*) AS c FROM assets WHERE hostname = 'veto-save'") | Should -Be 0
    }

    It 'a throwing BeforeDelete aborts the delete and propagates the error' {
        $rec = $script:a039.FindById(2)
        $rec.On('BeforeDelete', { throw 'delete vetoed' })
        { $rec.Delete() } | Should -Throw '*delete vetoed*'
        $rec.Id | Should -Be 2
        (Get-Count $script:db039 'SELECT COUNT(*) AS c FROM assets WHERE id = 2') | Should -Be 1
    }

    It 'AfterSave does not run when the insert fails' {
        $script:flag039 = ''
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db039
        $rec.SetAttribute('nosuchcol', 'x')
        $rec.On('AfterSave', { $script:flag039 = 'AfterSave RAN' })
        { $rec.Save() } | Should -Throw
        $rec.Id | Should -Be 0
        $script:flag039 | Should -Be ''
    }

    It 'AfterSave runs after a successful save' {
        $script:flag039 = ''
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db039
        $rec.SetAttribute('hostname', 'after-ok'); $rec.SetAttribute('ip', '4.4.4.4')
        $rec.On('AfterSave', { param($r) $script:flag039 = "AfterSave RAN $($r.Id)" })
        $rec.Save()
        $script:flag039 | Should -Be "AfterSave RAN $($rec.Id)"
    }

    It 'a throwing AfterSave is logged, not propagated' {
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db039
        $rec.SetAttribute('hostname', 'after-throw'); $rec.SetAttribute('ip', '4.4.4.5')
        $rec.On('AfterSave', { throw 'observer failed' })
        { $rec.Save() } | Should -Not -Throw
        $rec.Id | Should -BeGreaterThan 0
    }

    It 'Delete on an unsaved record fires no callbacks' {
        $script:flag039 = ''
        $rec = New-DynamicRecord -Table 'assets' -Database $script:db039
        $rec.On('BeforeDelete', { $script:flag039 += 'Before;' })
        $rec.On('AfterDelete', { $script:flag039 += 'After;' })
        $rec.Delete()
        $script:flag039 | Should -Be ''
    }

    It 'AfterDelete runs after a successful delete' {
        $script:flag039 = ''
        $rec = $script:a039.FindById(3)
        $rec.On('AfterDelete', { $script:flag039 = 'AfterDelete RAN' })
        $rec.Delete()
        $script:flag039 | Should -Be 'AfterDelete RAN'
        (Get-Count $script:db039 'SELECT COUNT(*) AS c FROM assets WHERE id = 3') | Should -Be 0
    }
}
