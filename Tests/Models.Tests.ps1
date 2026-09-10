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
        $entry = & $m { param($t) $script:DynamicClassScripts | Where-Object { $_.Table -eq $t } | Select-Object -Last 1 } $Table
        $typeName = & $m { param($t) $script:ModelTypes[$t] } $Table
        return (& $m { param($p, $d, $tn) . $p; New-Object -TypeName $tn -ArgumentList $d } ([string]$entry.ModelPath) ([string]$Database) ([string]$typeName))
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
