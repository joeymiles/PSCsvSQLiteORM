# Regression tests for Import-CsvToSqlite (TASK B1: BUG-003, BUG-006, BUG-050, BUG-051)

$moduleFolder = Join-Path (Join-Path $PSScriptRoot '..') 'output\PSCsvSQLiteORM'
Import-Module $moduleFolder -Force

BeforeAll {
    $script:workDir = Join-Path $env:TEMP ("orm_import_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $script:workDir | Out-Null
    function New-TestCsv {
        param([string]$Name, [string[]]$Lines)
        $path = Join-Path $script:workDir $Name
        ($Lines -join "`r`n") | Set-Content -LiteralPath $path -Encoding ASCII
        return $path
    }
    function New-TestDbPath {
        param([string]$Name)
        return (Join-Path $script:workDir ("{0}_{1}.db" -f $Name, ([guid]::NewGuid().ToString('N'))))
    }
}

AfterAll {
    Close-DbConnections
}

Describe 'Import-CsvToSqlite parameter names' -Tag 'BUG-003' {
    It 'keeps distinct values for headers that sanitize to the same parameter name' {
        $csv = New-TestCsv -Name 'b003.csv' -Lines @('id,a b,a_b,a-b', '1,SPACE,UNDER,DASH')
        $db = New-TestDbPath -Name 'b003'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $row = Invoke-DbQuery -Database $db -Query 'SELECT * FROM t' | Select-Object -First 1
        $row.'a b' | Should -Be 'SPACE'
        $row.'a_b' | Should -Be 'UNDER'
        $row.'a-b' | Should -Be 'DASH'
    }
}

Describe 'Import-CsvToSqlite bool tokens' -Tag 'BUG-006' {
    BeforeAll {
        $script:csv006 = New-TestCsv -Name 'b006.csv' -Lines @(
            'id,country,grade,answer,flag,initial',
            '1,US,A,yes,true,J',
            '2,NO,N,no,false,Y',
            '3,DE,B,maybe,true,N')
        $script:db006 = New-TestDbPath -Name 'b006'
        Import-CsvToSqlite -CsvPath $script:csv006 -Database $script:db006 -TableName 't' | Out-Null
        $script:rows006 = @(Invoke-DbQuery -Database $script:db006 -Query 'SELECT * FROM t ORDER BY id')
    }
    It 'does not rewrite text cells that merely look like bool tokens' {
        $script:rows006[1].country | Should -Be 'NO'
        $script:rows006[1].grade | Should -Be 'N'
        $script:rows006[1].initial | Should -Be 'Y'
        $script:rows006[2].initial | Should -Be 'N'
    }
    It 'leaves a mixed column untouched when not every value is a bool token' {
        $script:rows006[0].answer | Should -Be 'yes'
        $script:rows006[1].answer | Should -Be 'no'
        $script:rows006[2].answer | Should -Be 'maybe'
    }
    It 'converts a column whose every value is a bool token to INTEGER 1/0' {
        [int]$script:rows006[0].flag | Should -Be 1
        [int]$script:rows006[1].flag | Should -Be 0
        [int]$script:rows006[2].flag | Should -Be 1
        $info = @(Invoke-DbQuery -Database $script:db006 -Query 'PRAGMA table_info(t)')
        ($info | Where-Object { $_.name -eq 'flag' }).type | Should -Be 'INTEGER'
        ($info | Where-Object { $_.name -eq 'country' }).type | Should -Be 'TEXT'
    }
    It 'converts a column of bool tokens even when some cells are null tokens' {
        $csv = New-TestCsv -Name 'b006b.csv' -Lines @('id,active', '1,Y', '2,', '3,n')
        $db = New-TestDbPath -Name 'b006b'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT * FROM t ORDER BY id')
        [int]$rows[0].active | Should -Be 1
        [int]$rows[2].active | Should -Be 0
    }
}

Describe 'Import-CsvToSqlite Relaxed schema evolution' -Tag 'BUG-050' {
    It 'adds an id column to an existing table as plain INTEGER and inserts the rows' {
        $csv1 = New-TestCsv -Name 'b050a.csv' -Lines @('name,qty', 'x,1', 'y,2')
        $csv2 = New-TestCsv -Name 'b050b.csv' -Lines @('id,name,qty', '7,z,9')
        $db = New-TestDbPath -Name 'b050'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'n' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'n' -SchemaMode Relaxed } | Should -Not -Throw
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(n)')
        ($info | ForEach-Object { $_.name }) | Should -Contain 'id'
        ($info | Where-Object { $_.name -eq 'id' }).type | Should -Be 'INTEGER'
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM n' | Select-Object -First 1
        [int]$count.c | Should -Be 3
        $z = Invoke-DbQuery -Database $db -Query "SELECT id FROM n WHERE name='z'" | Select-Object -First 1
        [int]$z.id | Should -Be 7
    }
}

Describe 'Import-CsvToSqlite AppendOnly column validation' -Tag 'BUG-051' {
    It 'throws before inserting when the CSV has a column the table lacks' {
        $csv1 = New-TestCsv -Name 'b051a.csv' -Lines @('id,hostname,ip', '1,server01,10.0.0.1', '2,server02,10.0.0.2')
        $csv2 = New-TestCsv -Name 'b051b.csv' -Lines @('id,hostname,ip,rack', '9,server09,10.0.0.9,R1')
        $db = New-TestDbPath -Name 'b051'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'assets' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'assets' -SchemaMode AppendOnly } | Should -Throw '*AppendOnly mode: column rack does not exist*'
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM assets' | Select-Object -First 1
        [int]$count.c | Should -Be 2
        $cat = Invoke-DbQuery -Database $db -Query "SELECT source FROM __tables__ WHERE table_name='assets'" | Select-Object -First 1
        $cat.source | Should -Be $csv1
    }
    It 'still appends when every CSV column exists in the table' {
        $csv1 = New-TestCsv -Name 'b051c.csv' -Lines @('id,hostname,ip', '1,server01,10.0.0.1')
        $csv2 = New-TestCsv -Name 'b051d.csv' -Lines @('id,hostname,ip', '2,server02,10.0.0.2')
        $db = New-TestDbPath -Name 'b051ok'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'assets' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'assets' -SchemaMode AppendOnly } | Should -Not -Throw
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM assets' | Select-Object -First 1
        [int]$count.c | Should -Be 2
    }
}
