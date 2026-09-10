# Regression tests for the DbQuery fluent query builder.
# Runs on Windows PowerShell 5.1 and PowerShell 7. Databases are created under a unique directory inside $env:TEMP.

# Join two pieces at a time: the three-argument Join-Path form does not exist on Windows PowerShell 5.1
Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM') -Force

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM') -Force
    $script:TestRoot = Join-Path $env:TEMP ("orm_query_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    Initialize-ORMVars -LogLevel ERROR

    function New-TestDbPath([string]$Name) {
        return (Join-Path $script:TestRoot ("{0}_{1}.db" -f $Name, ([guid]::NewGuid().ToString('N').Substring(0, 8))))
    }

    # Run() may return $null for an empty result; normalise to an array of rows so .Count is reliable on both hosts.
    # The unary comma keeps a one-element array from being unrolled on return (5.1 has no .Count on a lone object).
    function Get-Rows([object]$Result) {
        $rows = @($Result | Where-Object { $null -ne $_ })
        return , $rows
    }

    function Test-IsNull([object]$Value) {
        return ($null -eq $Value -or $Value -is [System.DBNull])
    }

    # Imports the sample assets/vulns CSVs and confirms the vulns.asset_id -> assets.id relationship.
    function New-RelationalDb {
        $db = New-TestDbPath 'rel'
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -Database $db -TableName 'assets' | Out-Null
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -Database $db -TableName 'vulns' | Out-Null
        Find-DbRelationships -Database $db | Out-Null
        Confirm-DbForeignKey -Database $db -From 'vulns' -Column 'asset_id' -To 'assets'
        return $db
    }
}

AfterAll {
    Close-DbConnections
    if ($script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'DbQuery fluent OrderBy/Limit/Offset (BASE-06)' -Tag 'BASE-06' {
    BeforeAll {
        $script:dbB06 = New-TestDbPath 'base06'
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -Database $script:dbB06 -TableName 'vulns' | Out-Null
    }

    It 'OrderBy(), Limit() and Offset() are callable methods that return the query' {
        $q = New-DbQuery -Database $script:dbB06 -From 'vulns'
        $q.OrderBy('id DESC') | Should -Be $q
        $q.Limit(1) | Should -Be $q
        $q.Offset(1) | Should -Be $q
    }

    It 'Where().OrderBy().Limit().Offset().Run() returns the expected row' {
        $rows = Get-Rows ((New-DbQuery -Database $script:dbB06 -From 'vulns').Where('id > @min', @{ min = 1 }).OrderBy('id DESC').Limit(1).Offset(1).Run())
        $rows.Count | Should -Be 1
        [int]$rows[0].id | Should -Be 3
    }

    It 'Limit() and Offset() apply to a plain query' {
        $rows = Get-Rows ((New-DbQuery -Database $script:dbB06 -From 'vulns').OrderBy('id').Limit(2).Offset(2).Run())
        @($rows | ForEach-Object { [int]$_.id }) | Should -Be @(3, 4)
    }
}

Describe 'DbQuery Where() clause grouping (BUG-020)' -Tag 'BUG-020' {
    BeforeAll {
        $script:db020 = New-TestDbPath 'bug020'
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -Database $script:db020 -TableName 'vulns' | Out-Null
    }

    It 'an OR inside one Where() clause does not escape a later AND filter' {
        # No Low/High vuln belongs to asset 1: vulns 2 (High) is asset 2 and 4 (Low) is asset 3
        $rows = Get-Rows ((New-DbQuery -Database $script:db020 -From 'vulns').Where("severity = 'Low' OR severity = 'High'", $null).Where('asset_id = @a', @{ a = 1 }).Run())
        $rows.Count | Should -Be 0
    }

    It 'an OR inside the second Where() clause is grouped as well' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db020 -From 'vulns').Where('asset_id = @a', @{ a = 1 }).Where("severity = 'Low' OR severity = 'High'", $null).Run())
        $rows.Count | Should -Be 0
    }

    It 'grouped clauses still return the matching rows' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db020 -From 'vulns').Where("severity = 'Critical' OR severity = 'Medium'", $null).Where('asset_id = @a', @{ a = 1 }).OrderBy('id').Run())
        @($rows | ForEach-Object { [int]$_.id }) | Should -Be @(1, 3)
    }

    It 'grouping also applies to the RIGHT and FULL join emulation' {
        $db = New-TestDbPath 'bug020join'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE a(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE b(id INTEGER PRIMARY KEY, a_id INTEGER, val TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO a(id,name) VALUES (1,'a1'),(2,'a2')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO b(id,a_id,val) VALUES (10,1,'b1'),(11,3,'b2'),(12,2,'b3')" -NonQuery | Out-Null
        foreach ($type in @('Right', 'Full')) {
            $q = (New-DbQuery -Database $db -From 'a').Join('b', 'a.id = b.a_id', $type).Select(@('b.id AS bid'))
            $rows = Get-Rows ($q.Where('b.id = 10 OR b.id = 11', $null).Where('b.a_id = @a', @{ a = 2 }).Run())
            $rows.Count | Should -Be 0 -Because "$type join: no row has id 10/11 and a_id 2"
        }
    }
}

Describe 'DbQuery Auto join with table aliases (BUG-021)' -Tag 'BUG-021' {
    BeforeAll {
        $script:db021 = New-RelationalDb
    }

    It 'Auto join without aliases still works' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db021 -From 'vulns').Join('assets', 'Auto', 'Inner').Run())
        $rows.Count | Should -Be 4
    }

    It 'Auto join uses the aliases in the ON clause' {
        $q = (New-DbQuery -Database $script:db021 -From 'vulns v').Join('assets a', 'Auto', 'Inner')
        $q.Joins[0].On | Should -Be 'v."asset_id" = a."id"'
        $rows = Get-Rows ($q.Select(@('v.id AS vid', 'a.hostname AS host')).OrderBy('vid').Run())
        $rows.Count | Should -Be 4
        $rows[0].host | Should -Be 'server01'
    }

    It 'Auto join accepts the AS alias form' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db021 -From 'vulns AS v').Join('assets AS a', 'Auto', 'Inner').Select(@('a.hostname AS host')).Run())
        $rows.Count | Should -Be 4
    }

    It 'Auto join resolves the relationship in either direction with aliases' {
        $q = (New-DbQuery -Database $script:db021 -From 'assets a').Join('vulns v', 'Auto', 'Left')
        $q.Joins[0].On | Should -Be 'v."asset_id" = a."id"'
        $rows = Get-Rows ($q.Select(@('a.id AS aid', 'v.id AS vid')).Run())
        $rows.Count | Should -Be 4
    }

    It 'Auto join accepts a quoted table name' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db021 -From '"vulns"').Join('"assets"', 'Auto', 'Inner').Run())
        $rows.Count | Should -Be 4
    }
}

Describe 'DbQuery FULL join emulation keeps duplicates (BUG-028)' -Tag 'BUG-028' {
    BeforeAll {
        $script:db028 = New-TestDbPath 'bug028'
        Invoke-DbQuery -Database $script:db028 -Query 'CREATE TABLE fa(id INTEGER, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db028 -Query 'CREATE TABLE fb(id INTEGER PRIMARY KEY, a_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db028 -Query "INSERT INTO fa(id,name) VALUES (1,'dup'),(1,'dup'),(2,'x')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db028 -Query "INSERT INTO fb(id,a_id) VALUES (10,1),(11,3)" -NonQuery | Out-Null
    }

    It 'returns every row of a FULL OUTER JOIN including identical duplicates' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db028 -From 'fa').Join('fb', 'fa.id = fb.a_id', 'Full').Select(@('fa.id AS aid', 'fb.id AS bid')).Run())
        $rows.Count | Should -Be 4
        @($rows | Where-Object { -not (Test-IsNull $_.aid) -and -not (Test-IsNull $_.bid) -and [int]$_.aid -eq 1 -and [int]$_.bid -eq 10 }).Count | Should -Be 2
        @($rows | Where-Object { -not (Test-IsNull $_.aid) -and [int]$_.aid -eq 2 -and (Test-IsNull $_.bid) }).Count | Should -Be 1
        @($rows | Where-Object { (Test-IsNull $_.aid) -and [int]$_.bid -eq 11 }).Count | Should -Be 1
    }

    It 'does not count matched rows twice' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db028 -From 'fa').Join('fb', 'fa.id = fb.a_id', 'Full').Select(@('fb.id AS bid')).Where('fb.id = 10', $null).Run())
        $rows.Count | Should -Be 2
    }

    It 'applies Where() to both halves of the emulation' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db028 -From 'fa').Join('fb', 'fa.id = fb.a_id', 'Full').Select(@('fa.id AS aid', 'fb.id AS bid')).Where('fb.id IS NULL', $null).Run())
        $rows.Count | Should -Be 1
        [int]$rows[0].aid | Should -Be 2
    }

    It 'works with table aliases and honours OrderBy/Limit' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db028 -From 'fa x').Join('fb y', 'x.id = y.a_id', 'Full').Select(@('x.id AS aid', 'y.id AS bid')).OrderBy('bid DESC').Limit(1).Run())
        $rows.Count | Should -Be 1
        [int]$rows[0].bid | Should -Be 11
    }
}
