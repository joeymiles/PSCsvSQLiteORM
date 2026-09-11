# Regression tests for the DbQuery fluent query builder.
# Runs on Windows PowerShell 5.1 and PowerShell 7. Databases are created under a unique directory inside $env:TEMP.

# Import the build of the version declared in source\PSCsvSQLiteORM.psd1 (BUG-077, see Tests\TestSupport.ps1)
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Import-Module (Get-OrmBuiltManifestPath) -Force

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    Import-Module (Get-OrmBuiltManifestPath) -Force
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

Describe 'DbQuery rejects SQL in From and Join table references (BUG-029)' -Tag 'BUG-029' {
    BeforeAll {
        $script:db029 = New-TestDbPath 'bug029'
        Invoke-DbQuery -Database $script:db029 -Query 'CREATE TABLE a(id INTEGER PRIMARY KEY, b_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'CREATE TABLE b(id INTEGER PRIMARY KEY)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'CREATE TABLE "my table"(id INTEGER PRIMARY KEY)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'INSERT INTO a(id,b_id) VALUES (1,1),(2,1)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'INSERT INTO b(id) VALUES (1)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'INSERT INTO "my table"(id) VALUES (7)' -NonQuery | Out-Null

        function Test-TableExists([string]$Name) {
            return (@(Invoke-DbQuery -Database $script:db029 -Query "SELECT name FROM sqlite_master WHERE type='table' AND name=@n" -SqlParameters @{ n = $Name }).Count -eq 1)
        }
    }

    It 'a multi-statement From is rejected before any SQL runs' {
        { New-DbQuery -Database $script:db029 -From 'a; DROP TABLE b' } | Should -Throw -ExpectedMessage '*Invalid From table reference*'
        Test-TableExists 'b' | Should -BeTrue
    }

    It 'a multi-statement Join table is rejected before any SQL runs' {
        $q = New-DbQuery -Database $script:db029 -From 'a'
        { $q.Join('b x; DROP TABLE b', 'a.b_id = x.id', 'Inner') } | Should -Throw -ExpectedMessage '*Invalid Join table reference*'
        { $q.Join('b; DROP TABLE b', 'a.b_id = b.id') } | Should -Throw -ExpectedMessage '*Invalid Join table reference*'
        $q.Joins.Count | Should -Be 0
        Test-TableExists 'b' | Should -BeTrue
    }

    It 'an unquoted name with illegal characters is rejected even as a single token' {
        foreach ($bad in @('a;', 'a/*', "a`nDROP TABLE b", "a'", 'a)', '(SELECT 1) x')) {
            { New-DbQuery -Database $script:db029 -From $bad } | Should -Throw -ExpectedMessage '*Invalid From table reference*' -Because "'$bad' must not reach the driver"
        }
        { New-DbQuery -Database $script:db029 -From '' } | Should -Throw
        Test-TableExists 'b' | Should -BeTrue
    }

    It 'a comment marker in an unquoted name or alias cannot disable the ON and WHERE clauses' {
        # '--' used to pass the identifier check and comment out everything after the table reference, so a Where()
        # filter (or a join ON) was silently discarded and every row came back.
        { New-DbQuery -Database $script:db029 -From 'a--' } | Should -Throw -ExpectedMessage '*Invalid From table reference*'
        { New-DbQuery -Database $script:db029 -From 'a x--' } | Should -Throw -ExpectedMessage '*Invalid From table reference*'
        { New-DbQuery -Database $script:db029 -From 'a-b' } | Should -Throw -ExpectedMessage '*Invalid From table reference*'
        $q = New-DbQuery -Database $script:db029 -From 'a'
        { $q.Join('b--', 'a.b_id = b.id') } | Should -Throw -ExpectedMessage '*Invalid Join table reference*'
        { $q.Join('b y--', 'a.b_id = y.id', 'Left') } | Should -Throw -ExpectedMessage '*Invalid Join table reference*'
        $q.Joins.Count | Should -Be 0
        # The filter still applies after the rejected calls: only one of the two rows of a has id 1.
        (Get-Rows ($q.Where('a.id = @i', @{ i = 1 }).Run())).Count | Should -Be 1
        (Get-Rows ((New-DbQuery -Database $script:db029 -From 'a').Join('b', 'a.b_id = b.id').Where('a.id = @i', @{ i = 1 }).Run())).Count | Should -Be 1
    }

    It 'a double-quoted name or alias may contain a dash' {
        Invoke-DbQuery -Database $script:db029 -Query 'CREATE TABLE "dash-name"(id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'INSERT INTO "dash-name"(id) VALUES (5),(6)' -NonQuery | Out-Null
        $rows = Get-Rows ((New-DbQuery -Database $script:db029 -From '"dash-name" "d-1"').Where('"d-1".id = @i', @{ i = 6 }).Run())
        $rows.Count | Should -Be 1
        [int]$rows[0].id | Should -Be 6
    }

    It 'plain, aliased, AS-aliased, schema-qualified and double-quoted references are still accepted' {
        (Get-Rows ((New-DbQuery -Database $script:db029 -From 'a').Run())).Count | Should -Be 2
        (Get-Rows ((New-DbQuery -Database $script:db029 -From 'a x').Where('x.id = 1', $null).Run())).Count | Should -Be 1
        (Get-Rows ((New-DbQuery -Database $script:db029 -From 'a AS x').Join('b AS y', 'x.b_id = y.id', 'Left').Run())).Count | Should -Be 2
        (Get-Rows ((New-DbQuery -Database $script:db029 -From 'main.a').Run())).Count | Should -Be 2
        $rows = Get-Rows ((New-DbQuery -Database $script:db029 -From '"my table" t').Select(@('t.id AS tid')).Run())
        $rows.Count | Should -Be 1
        [int]$rows[0].tid | Should -Be 7
    }

    It 'a double-quoted name may contain characters that are illegal unquoted' {
        Invoke-DbQuery -Database $script:db029 -Query 'CREATE TABLE "odd;name"(id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db029 -Query 'INSERT INTO "odd;name"(id) VALUES (3)' -NonQuery | Out-Null
        $rows = Get-Rows ((New-DbQuery -Database $script:db029 -From '"odd;name"').Run())
        $rows.Count | Should -Be 1
        [int]$rows[0].id | Should -Be 3
    }
}

Describe 'DbQuery two-argument and one-argument Join overloads (BUG-065)' -Tag 'BUG-065' {
    BeforeAll {
        $script:db065 = New-RelationalDb
    }

    It 'Join(<table>, <on>) as documented in the README is an INNER join' {
        $query = New-DbQuery -Database $script:db065 -From 'assets'
        $result = $query.Join('vulns', 'vulns.asset_id = assets.id')
        $result | Should -Be $query
        $query.Joins.Count | Should -Be 1
        $query.Joins[0].Type | Should -Be 'Inner'
        $query.Joins[0].On | Should -Be 'vulns.asset_id = assets.id'
        $rows = Get-Rows ($query.Select(@('assets.hostname', 'vulns.title')).Run())
        $rows.Count | Should -Be 4
    }

    It 'Join(<table>) uses the catalog relationship as an INNER join' {
        $q = (New-DbQuery -Database $script:db065 -From 'vulns v').Join('assets a')
        $q.Joins[0].Type | Should -Be 'Inner'
        $q.Joins[0].On | Should -Be 'v."asset_id" = a."id"'
        (Get-Rows ($q.Run())).Count | Should -Be 4
    }

    It 'the three-argument form still selects the join type' {
        $q = (New-DbQuery -Database $script:db065 -From 'assets').Join('vulns', 'vulns.asset_id = assets.id', 'Left')
        $q.Joins[0].Type | Should -Be 'Left'
        { (New-DbQuery -Database $script:db065 -From 'assets').Join('vulns', 'vulns.asset_id = assets.id', 'Cross') } | Should -Throw -ExpectedMessage "*Invalid join type*"
    }
}

Describe 'DbQuery Right/Full join projection with the default SELECT * (E2E1-005)' -Tag 'E2E1-005' {
    BeforeAll {
        $script:db005 = New-TestDbPath 'e2e1005'
        Invoke-DbQuery -Database $script:db005 -Query 'CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, city TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db005 -Query 'CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total REAL)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db005 -Query "INSERT INTO customers VALUES (1,'Ann','Oslo')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db005 -Query 'INSERT INTO orders VALUES (10,1,5.0),(99,777,9.0)' -NonQuery | Out-Null

        function Get-ColumnNames([object]$Row) {
            return , @($Row.PSObject.Properties | ForEach-Object { $_.Name })
        }
        function Get-ColumnValue([object]$Row, [int]$Index) {
            return (@($Row.PSObject.Properties)[$Index]).Value
        }
    }

    It 'a Full join without Select() keeps both halves of the UNION in the same column order' {
        # The unmatched order used to come back with its own values sitting in the customer columns, because
        # '*' expands in FROM order and the emulation swaps the tables round for the second half.
        $rows = Get-Rows ((New-DbQuery -Database $script:db005 -From 'customers').Join('orders', 'orders.customer_id = customers.id', 'Full').Run())
        $rows.Count | Should -Be 2
        $names = Get-ColumnNames $rows[0]
        $names.Count | Should -Be 6
        $names[0] | Should -Be 'id'
        $names[1] | Should -Be 'name'
        $names[2] | Should -Be 'city'
        $names[4] | Should -Be 'customer_id'
        $names[5] | Should -Be 'total'

        $matched = @($rows | Where-Object { -not (Test-IsNull $_.name) })
        $matched.Count | Should -Be 1
        $matched[0].name | Should -Be 'Ann'
        $matched[0].city | Should -Be 'Oslo'
        [int](Get-ColumnValue $matched[0] 3) | Should -Be 10
        [int]$matched[0].customer_id | Should -Be 1

        $unmatched = @($rows | Where-Object { Test-IsNull $_.name })
        $unmatched.Count | Should -Be 1
        Test-IsNull $unmatched[0].id | Should -BeTrue -Because 'the order without a customer must leave every customer column NULL'
        Test-IsNull $unmatched[0].city | Should -BeTrue
        [int](Get-ColumnValue $unmatched[0] 3) | Should -Be 99
        [int]$unmatched[0].customer_id | Should -Be 777
        [double]$unmatched[0].total | Should -Be 9
    }

    It 'a Right join without Select() returns the From table columns first, like Inner and Left do' {
        $inner = Get-Rows ((New-DbQuery -Database $script:db005 -From 'customers').Join('orders', 'orders.customer_id = customers.id', 'Inner').Run())
        $right = Get-Rows ((New-DbQuery -Database $script:db005 -From 'customers').Join('orders', 'orders.customer_id = customers.id', 'Right').Run())
        $right.Count | Should -Be 2
        (Get-ColumnNames $right[0]) | Should -Be (Get-ColumnNames $inner[0])
        $matched = @($right | Where-Object { -not (Test-IsNull $_.name) })
        $matched.Count | Should -Be 1
        $matched[0].name | Should -Be 'Ann'
        [int]$matched[0].customer_id | Should -Be 1
    }

    It 'an explicit Select() is still used verbatim for both join types' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db005 -From 'customers').Join('orders', 'orders.customer_id = customers.id', 'Full').Select(@('customers.name AS cname', 'orders.id AS oid')).OrderBy('oid').Run())
        $rows.Count | Should -Be 2
        (Get-ColumnNames $rows[0]) | Should -Be @('cname', 'oid')
    }

    It 'aliased table references project the alias columns in From order' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db005 -From 'customers c').Join('orders o', 'o.customer_id = c.id', 'Full').Run())
        $rows.Count | Should -Be 2
        $names = Get-ColumnNames $rows[0]
        $names[0] | Should -Be 'id'
        $names[1] | Should -Be 'name'
        $names[4] | Should -Be 'customer_id'
    }
}

Describe 'DbQuery Auto join rejects an ambiguous catalog relationship (E2E1-015)' -Tag 'E2E1-015' {
    BeforeAll {
        $script:db015 = New-TestDbPath 'e2e1015'
        Invoke-DbQuery -Database $script:db015 -Query 'CREATE TABLE users (id INTEGER PRIMARY KEY, uname TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db015 -Query 'CREATE TABLE tickets (id INTEGER PRIMARY KEY, created_by INTEGER, assigned_to INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db015 -Query "INSERT INTO users VALUES (1,'ann'),(2,'bob')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db015 -Query 'INSERT INTO tickets VALUES (1,1,2),(2,2,1),(3,1,NULL),(4,2,NULL),(5,1,NULL)' -NonQuery | Out-Null
        Confirm-DbForeignKey -Database $script:db015 -From 'tickets' -Column 'created_by' -To 'users'
        Confirm-DbForeignKey -Database $script:db015 -From 'tickets' -Column 'assigned_to' -To 'users'
    }

    It 'two confirmed foreign keys to the same table make Join(<table>) throw instead of picking one' {
        $q = New-DbQuery -Database $script:db015 -From 'tickets'
        { $q.Join('users') } | Should -Throw -ExpectedMessage '*ambiguous*'
        { $q.Join('users', 'Auto', 'Left') } | Should -Throw -ExpectedMessage '*created_by*'
        $q.Joins.Count | Should -Be 0 -Because 'a rejected Auto join must not be recorded'
    }

    It 'the four-argument overload selects the foreign key to join on' {
        $byCreated = (New-DbQuery -Database $script:db015 -From 'tickets').Join('users', 'Auto', 'Inner', 'created_by')
        $byCreated.Joins[0].On | Should -Be 'tickets."created_by" = users."id"'
        (Get-Rows ($byCreated.Run())).Count | Should -Be 5

        $byAssigned = (New-DbQuery -Database $script:db015 -From 'tickets').Join('users', 'Auto', 'Inner', 'assigned_to')
        $byAssigned.Joins[0].On | Should -Be 'tickets."assigned_to" = users."id"'
        (Get-Rows ($byAssigned.Run())).Count | Should -Be 2
    }

    It 'the four-argument overload works with aliases and other join types' {
        $q = (New-DbQuery -Database $script:db015 -From 'tickets t').Join('users u', 'Auto', 'Left', 'assigned_to')
        $q.Joins[0].Type | Should -Be 'Left'
        $q.Joins[0].On | Should -Be 't."assigned_to" = u."id"'
        (Get-Rows ($q.Select(@('t.id AS tid', 'u.uname AS un')).Run())).Count | Should -Be 5
    }

    It 'an unknown foreign-key column and a ForeignKey next to an explicit ON are rejected' {
        $q = New-DbQuery -Database $script:db015 -From 'tickets'
        { $q.Join('users', 'Auto', 'Inner', 'nosuch') } | Should -Throw -ExpectedMessage "*'nosuch'*"
        { $q.Join('users', 'tickets.created_by = users.id', 'Inner', 'created_by') } | Should -Throw -ExpectedMessage '*ForeignKey argument*'
        $q.Joins.Count | Should -Be 0
    }

    It 'a single relationship is still resolved automatically' {
        $db = New-RelationalDb
        $q = (New-DbQuery -Database $db -From 'vulns').Join('assets')
        $q.Joins[0].On | Should -Be 'vulns."asset_id" = assets."id"'
        (Get-Rows ($q.Run())).Count | Should -Be 4
    }
}

Describe 'DbQuery Full join rejects a From source without a rowid (E2E1-016)' -Tag 'E2E1-016' {
    BeforeAll {
        $script:db016 = New-TestDbPath 'e2e1016'
        Invoke-DbQuery -Database $script:db016 -Query 'CREATE TABLE hosts (id INTEGER PRIMARY KEY, hostname TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db016 -Query "INSERT INTO hosts VALUES (1,'server01'),(2,'server02'),(3,'server03')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db016 -Query 'CREATE VIEW v_hosts AS SELECT * FROM hosts' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db016 -Query 'CREATE TABLE norowid (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db016 -Query "INSERT INTO norowid VALUES ('a','1'),('b','2')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db016 -Query 'CREATE TABLE tags (k TEXT, n INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db016 -Query "INSERT INTO tags VALUES ('a',1),('z',9)" -NonQuery | Out-Null
    }

    It 'a Full join whose From table is a view throws instead of answering differently per host' {
        # It used to return 3 rows on Windows PowerShell 5.1 and 6 duplicated rows on PowerShell 7.
        $q = (New-DbQuery -Database $script:db016 -From 'v_hosts').Join('hosts', 'hosts.id = v_hosts.id', 'Full').Select(@('v_hosts.hostname AS h'))
        { $q.Run() } | Should -Throw -ExpectedMessage '*Full join requires a rowid table*'
        { $q.Run() } | Should -Throw -ExpectedMessage '*view*'
    }

    It 'a Full join whose From table is WITHOUT ROWID throws a clear message' {
        $q = (New-DbQuery -Database $script:db016 -From 'norowid').Join('tags', 'norowid.k = tags.k', 'Full').Select(@('norowid.k AS k1', 'tags.k AS k2'))
        { $q.Run() } | Should -Throw -ExpectedMessage '*WITHOUT ROWID*'
    }

    It 'the same query against the base table still returns the full outer join' {
        $rows = Get-Rows ((New-DbQuery -Database $script:db016 -From 'tags').Join('norowid', 'norowid.k = tags.k', 'Full').Select(@('tags.k AS k1', 'norowid.k AS k2')).Run())
        $rows.Count | Should -Be 3
    }

    It 'Inner, Left and Right joins from a view are untouched' {
        (Get-Rows ((New-DbQuery -Database $script:db016 -From 'v_hosts').Join('hosts', 'hosts.id = v_hosts.id', 'Inner').Select(@('v_hosts.hostname AS h')).Run())).Count | Should -Be 3
        (Get-Rows ((New-DbQuery -Database $script:db016 -From 'v_hosts').Join('hosts', 'hosts.id = v_hosts.id', 'Left').Select(@('v_hosts.hostname AS h')).Run())).Count | Should -Be 3
        (Get-Rows ((New-DbQuery -Database $script:db016 -From 'v_hosts').Join('hosts', 'hosts.id = v_hosts.id', 'Right').Select(@('v_hosts.hostname AS h')).Run())).Count | Should -Be 3
    }
}

Describe 'DbQuery.Run() returns an array for an empty result (E2E1-017)' -Tag 'E2E1-017' {
    BeforeAll {
        $script:db017 = New-TestDbPath 'e2e1017'
        Invoke-DbQuery -Database $script:db017 -Query 'CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db017 -Query 'CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db017 -Query "INSERT INTO customers VALUES (1,'Ann')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:db017 -Query 'INSERT INTO orders VALUES (10,1)' -NonQuery | Out-Null
    }

    It 'an empty plain query yields an empty array, not $null' {
        $result = (New-DbQuery -Database $script:db017 -From 'customers').Where('1=0', $null).Run()
        $null -eq $result | Should -BeFalse
        @($result).Count | Should -Be 0
        $result.Count | Should -Be 0
    }

    It 'an empty Right/Full emulation yields an empty array too' {
        foreach ($type in @('Right', 'Full')) {
            $result = (New-DbQuery -Database $script:db017 -From 'customers').Join('orders', 'orders.customer_id = customers.id', $type).Select(@('customers.id AS cid')).Where('1=0', $null).Run()
            $null -eq $result | Should -BeFalse -Because "$type must return an array"
            @($result).Count | Should -Be 0 -Because "$type must return an empty array"
        }
    }

    It 'a non-empty result is unchanged' {
        $result = (New-DbQuery -Database $script:db017 -From 'customers').Run()
        @($result).Count | Should -Be 1
        [int]$result[0].id | Should -Be 1
    }
}
