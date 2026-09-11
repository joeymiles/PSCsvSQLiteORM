# Regression tests for Import-CsvToSqlite (TASK B1: BUG-003, BUG-006, BUG-050, BUG-051; TASK B4: BUG-007; TASK B10: BUG-052, BUG-054, BUG-071, BUG-073; TASK B13: BUG-074; round 2 TASK B1: E2E1-001)

# Import the build of the version declared in source\PSCsvSQLiteORM.psd1 (BUG-077, see Tests\TestSupport.ps1)
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$moduleFolder = Get-OrmBuiltManifestPath
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

Describe 'Import-CsvToSqlite numeric inference keeps values intact' -Tag 'BUG-004' {
    It 'stores leading-zero, oversized and formatted numeric strings as TEXT unchanged' {
        $csv = New-TestCsv -Name 'b004.csv' -Lines @(
            'id,zip,acct,phone,version,amount,ratio',
            '1,02134,12345678901234567890,0015551234567,1.10,1.5,0.5',
            '2,00501,5,15551234567,1.1,2.25,1.0')
        $db = New-TestDbPath -Name 'b004'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)')
        ($info | Where-Object { $_.name -eq 'zip' }).type | Should -Be 'TEXT'
        ($info | Where-Object { $_.name -eq 'acct' }).type | Should -Be 'TEXT'
        ($info | Where-Object { $_.name -eq 'phone' }).type | Should -Be 'TEXT'
        ($info | Where-Object { $_.name -eq 'version' }).type | Should -Be 'TEXT'
        ($info | Where-Object { $_.name -eq 'amount' }).type | Should -Be 'REAL'
        ($info | Where-Object { $_.name -eq 'ratio' }).type | Should -Be 'TEXT'
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT * FROM t ORDER BY id')
        $rows[0].zip | Should -Be '02134'
        $rows[1].zip | Should -Be '00501'
        $rows[0].acct | Should -Be '12345678901234567890'
        $rows[0].phone | Should -Be '0015551234567'
        $rows[0].version | Should -Be '1.10'
        $rows[1].version | Should -Be '1.1'
        [double]$rows[1].amount | Should -Be 2.25
    }
    It 'still infers INTEGER and REAL for canonical numbers' {
        $csv = New-TestCsv -Name 'b004b.csv' -Lines @('id,qty,price', '1,5,1.5', '2,-3,2.25', '3,0,10.75')
        $db = New-TestDbPath -Name 'b004b'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)')
        ($info | Where-Object { $_.name -eq 'qty' }).type | Should -Be 'INTEGER'
        ($info | Where-Object { $_.name -eq 'price' }).type | Should -Be 'REAL'
        $row = Invoke-DbQuery -Database $db -Query 'SELECT qty, typeof(qty) AS tq, price, typeof(price) AS tp FROM t WHERE id=2' | Select-Object -First 1
        $row.tq | Should -Be 'integer'
        [long]$row.qty | Should -Be -3
        $row.tp | Should -Be 'real'
    }
}

Describe 'Import-CsvToSqlite reconciles column types across imports' -Tag 'BUG-005' {
    It 'infers TEXT for a column without any value so later text is read back intact' {
        $csv1 = New-TestCsv -Name 'b005a.csv' -Lines @('id,notes', '1,', '2,')
        $csv2 = New-TestCsv -Name 'b005b.csv' -Lines @('id,notes', '5,hello')
        $db = New-TestDbPath -Name 'b005'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'n' | Out-Null
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(n)')
        ($info | Where-Object { $_.name -eq 'notes' }).type | Should -Be 'TEXT'
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'n' | Out-Null
        $row = Invoke-DbQuery -Database $db -Query 'SELECT notes FROM n WHERE id=5' | Select-Object -First 1
        $row.notes | Should -Be 'hello'
    }
    It 'widens an INTEGER column to TEXT in Relaxed mode and keeps old and new values readable' {
        $csv1 = New-TestCsv -Name 'b005c.csv' -Lines @('id,zip', '1,12345', '2,90210')
        $csv2 = New-TestCsv -Name 'b005d.csv' -Lines @('id,zip', '3,SW1A 1AA', '4,K1A0B1')
        $db = New-TestDbPath -Name 'b005w'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'z' | Out-Null
        Enable-UniqueIndex -Database $db -Table 'z' -Columns @('zip') | Out-Null
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(z)') | Where-Object { $_.name -eq 'zip' }).type | Should -Be 'INTEGER'
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'z' -SchemaMode Relaxed | Out-Null
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(z)')
        ($info | Where-Object { $_.name -eq 'zip' }).type | Should -Be 'TEXT'
        ($info | Where-Object { $_.name -eq 'id' }).pk | Should -Be 1
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT id, zip FROM z ORDER BY id')
        $rows.Count | Should -Be 4
        "$($rows[0].zip)" | Should -Be '12345'
        $rows[2].zip | Should -Be 'SW1A 1AA'
        $rows[3].zip | Should -Be 'K1A0B1'
        # the unique index survived the rebuild
        $idx = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='z' AND name='ux_z_zip'")
        $idx.Count | Should -Be 1
        # catalog reflects the new type
        $cat = Invoke-DbQuery -Database $db -Query "SELECT data_type FROM __columns__ WHERE table_name='z' AND column_name='zip'" | Select-Object -First 1
        $cat.data_type | Should -Be 'TEXT'
    }
    It 'refuses text for an INTEGER column in Strict and AppendOnly mode before inserting' {
        $csv1 = New-TestCsv -Name 'b005e.csv' -Lines @('id,zip', '1,12345')
        $csv2 = New-TestCsv -Name 'b005f.csv' -Lines @('id,zip', '3,SW1A 1AA')
        $db = New-TestDbPath -Name 'b005s'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'z' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'z' -SchemaMode Strict } | Should -Throw '*declared INTEGER but the CSV contains TEXT*'
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'z' -SchemaMode AppendOnly } | Should -Throw '*declared INTEGER but the CSV contains TEXT*'
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM z' | Select-Object -First 1
        [int]$count.c | Should -Be 1
    }
    It 'infers TEXT when empty strings are values (NullTokens @()) so they are not read back as 0' {
        $csv = New-TestCsv -Name 'b005g.csv' -Lines @('id,n', '1,5', '2,')
        $db = New-TestDbPath -Name 'b005n'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'e' -NullTokens @() | Out-Null
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(e)') | Where-Object { $_.name -eq 'n' }).type | Should -Be 'TEXT'
        $row = Invoke-DbQuery -Database $db -Query 'SELECT n, typeof(n) AS t FROM e WHERE id=2' | Select-Object -First 1
        $row.t | Should -Be 'text'
        "$($row.n)" | Should -Be ''
    }
}

Describe 'Import-CsvToSqlite id column inference' -Tag 'BUG-013' {
    It 'declares a text id column as TEXT PRIMARY KEY and imports every row' {
        $csv = New-TestCsv -Name 'b013a.csv' -Lines @('id,name', 'srv-01,alpha', 'srv-02,beta')
        $db = New-TestDbPath -Name 'b013a'
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' } | Should -Not -Throw
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)')
        $idInfo = $info | Where-Object { $_.name -eq 'id' }
        $idInfo.type | Should -Be 'TEXT'
        [int]$idInfo.pk | Should -Be 1
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT id, name FROM t ORDER BY id')
        $rows.Count | Should -Be 2
        $rows[0].id | Should -Be 'srv-01'
        $rows[1].name | Should -Be 'beta'
        $cat = Invoke-DbQuery -Database $db -Query "SELECT rowcount FROM __tables__ WHERE table_name='t'" | Select-Object -First 1
        [int]$cat.rowcount | Should -Be 2
    }
    It 'handles an upper-case ID header with text values' {
        $csv = New-TestCsv -Name 'b013b.csv' -Lines @('ID,name', 'A1,alpha')
        $db = New-TestDbPath -Name 'b013b'
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' } | Should -Not -Throw
        $idInfo = (Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'ID' }
        $idInfo.type | Should -Be 'TEXT'
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM t' | Select-Object -First 1
        [int]$count.c | Should -Be 1
    }
    It 'keeps INTEGER PRIMARY KEY AUTOINCREMENT for integer ids' {
        $csv = New-TestCsv -Name 'b013c.csv' -Lines @('id,name', '1,a', '2,b')
        $db = New-TestDbPath -Name 'b013c'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $sql = (Invoke-DbQuery -Database $db -Query "SELECT sql FROM sqlite_master WHERE type='table' AND name='t'" | Select-Object -First 1).sql
        $sql | Should -Match 'INTEGER PRIMARY KEY AUTOINCREMENT'
    }
    It 'numbers blank integer ids past the explicit ids so they do not collide' {
        $csv = New-TestCsv -Name 'b013d.csv' -Lines @('id,name', '1,a', ',b', '2,c')
        $db = New-TestDbPath -Name 'b013d'
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' } | Should -Not -Throw
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT id, name FROM t ORDER BY name')
        $rows.Count | Should -Be 3
        [long]$rows[0].id | Should -Be 1
        [long]$rows[1].id | Should -Be 3
        [long]$rows[2].id | Should -Be 2
    }
    It 'widens an INTEGER id to TEXT PRIMARY KEY in Relaxed mode when text ids arrive' {
        $csv1 = New-TestCsv -Name 'b013e.csv' -Lines @('id,name', '1,a')
        $csv2 = New-TestCsv -Name 'b013f.csv' -Lines @('id,name', 'x9,b')
        $db = New-TestDbPath -Name 'b013e'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' -SchemaMode Relaxed } | Should -Not -Throw
        $idInfo = (Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'id' }
        $idInfo.type | Should -Be 'TEXT'
        [int]$idInfo.pk | Should -Be 1
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT id FROM t ORDER BY id')
        $rows.Count | Should -Be 2
        "$($rows[0].id)" | Should -Be '1'
        $rows[1].id | Should -Be 'x9'
    }
}

Describe 'Import-CsvToSqlite one-row CSV with -BatchSize' -Tag 'BUG-007' {
    It 'imports a single-row CSV with -BatchSize 1 and records it in the catalog' {
        $csv = New-TestCsv -Name 'b007.csv' -Lines @('id,hostname', '1,only-host')
        $db = New-TestDbPath -Name 'b007'
        $headers = @(Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'hosts' -BatchSize 1)
        $headers -join ',' | Should -Be 'id,hostname'
        [int](Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM hosts' -Scalar) | Should -Be 1
        [int](Invoke-DbQuery -Database $db -Query "SELECT count(*) FROM __tables__ WHERE table_name='hosts'" -Scalar) | Should -Be 1
    }
}

Describe 'Import-CsvToSqlite null tokens match case-sensitively' -Tag 'BUG-052' {
    BeforeAll {
        $script:csv052 = New-TestCsv -Name 'b052.csv' -Lines @('id,surname,code', '1,Null,nan', '2,Smith,n/a', '3,Jones,x', '4,NULL,N/A')
    }
    It 'keeps values that only differ from a null token by case' {
        $db = New-TestDbPath -Name 'b052a'
        Import-CsvToSqlite -CsvPath $script:csv052 -Database $db -TableName 't' | Out-Null
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT id, quote(surname) AS s, quote(code) AS c FROM t ORDER BY id')
        $rows[0].s | Should -Be "'Null'"
        $rows[0].c | Should -Be "'nan'"
        $rows[1].c | Should -Be "'n/a'"
        $rows[2].c | Should -Be "'x'"
    }
    It 'still stores the exact default tokens as NULL' {
        $db = New-TestDbPath -Name 'b052b'
        Import-CsvToSqlite -CsvPath $script:csv052 -Database $db -TableName 't' | Out-Null
        $row = Invoke-DbQuery -Database $db -Query 'SELECT quote(surname) AS s, quote(code) AS c FROM t WHERE id = 4' | Select-Object -First 1
        $row.s | Should -Be 'NULL'
        $row.c | Should -Be 'NULL'
    }
    It 'restores case-insensitive matching with -IgnoreNullTokenCase' {
        $db = New-TestDbPath -Name 'b052c'
        Import-CsvToSqlite -CsvPath $script:csv052 -Database $db -TableName 't' -IgnoreNullTokenCase | Out-Null
        $row = Invoke-DbQuery -Database $db -Query 'SELECT quote(surname) AS s, quote(code) AS c FROM t WHERE id = 1' | Select-Object -First 1
        $row.s | Should -Be 'NULL'
        $row.c | Should -Be 'NULL'
    }
}

Describe 'Import-CsvToSqlite header-only CSV' -Tag 'BUG-054' {
    It 'creates the table from a header-only template file and returns the headers' {
        $csv = New-TestCsv -Name 'b054.csv' -Lines @('id,name,qty')
        $db = New-TestDbPath -Name 'b054a'
        $headers = @(Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't')
        $headers -join ',' | Should -Be 'id,name,qty'
        $cols = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)')
        ($cols | ForEach-Object { $_.name }) -join ',' | Should -Be 'id,name,qty'
        ($cols | Where-Object { $_.name -eq 'name' }).type | Should -Be 'TEXT'
        [int](Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM t' -Scalar) | Should -Be 0
        [int](Invoke-DbQuery -Database $db -Query "SELECT count(*) FROM __tables__ WHERE table_name='t'" -Scalar) | Should -Be 1
    }
    It 'lets data be appended later in AppendOnly mode' {
        $tpl = New-TestCsv -Name 'b054tpl.csv' -Lines @('id,name')
        $data = New-TestCsv -Name 'b054data.csv' -Lines @('id,name', '1,alpha', '2,beta')
        $db = New-TestDbPath -Name 'b054b'
        Import-CsvToSqlite -CsvPath $tpl -Database $db -TableName 't' | Out-Null
        Import-CsvToSqlite -CsvPath $data -Database $db -TableName 't' -SchemaMode AppendOnly | Out-Null
        [int](Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM t' -Scalar) | Should -Be 2
    }
    It 'reports a zero-byte file with its own message' {
        $csv = Join-Path $script:workDir 'b054zero.csv'
        [System.IO.File]::WriteAllBytes($csv, [byte[]]@())
        $db = New-TestDbPath -Name 'b054c'
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' } | Should -Throw '*CSV file is empty*'
    }
}

Describe 'Import-CsvToSqlite paths containing square brackets' -Tag 'BUG-071' {
    BeforeAll {
        $script:brDir = Join-Path $script:workDir '[br]'
        New-Item -ItemType Directory -Force -Path $script:brDir | Out-Null
    }
    It 'imports a CSV whose path contains [ and ] and records its hash' {
        $csv = Join-Path $script:brDir 'report[2024].csv'
        "id,name`r`n1,a`r`n2,b" | Set-Content -LiteralPath $csv -Encoding ASCII
        $db = New-TestDbPath -Name 'b071a'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        [int](Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM t' -Scalar) | Should -Be 2
        $cat = Invoke-DbQuery -Database $db -Query "SELECT source, csv_hash FROM __tables__ WHERE table_name='t'" | Select-Object -First 1
        $cat.source | Should -Be $csv
        $cat.csv_hash | Should -Be (Get-FileHash -Algorithm SHA256 -LiteralPath $csv).Hash
    }
    It 'writes the log file when LogPath contains [ and ]' {
        $log = Join-Path $script:brDir 'orm[1].log'
        try {
            Set-DbLogging -Level DEBUG -Path $log
            { Write-DbLog INFO 'bracket log probe' -ErrorAction Stop } | Should -Not -Throw
            Test-Path -LiteralPath $log | Should -BeTrue
            (Get-Content -LiteralPath $log -Raw) | Should -Match 'bracket log probe'
        }
        finally {
            Set-DbLogging -Level INFO -Path ''
        }
    }
}

Describe 'Import-CsvToSqlite trims whitespace around header names' -Tag 'BUG-073' {
    It 'creates columns without surrounding whitespace and keeps cell values intact' {
        $csv = New-TestCsv -Name 'b073.csv' -Lines @('id, name ,city ', '1, Bob ,X', '2,C,D')
        $db = New-TestDbPath -Name 'b073a'
        $headers = @(Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't')
        $headers -join ',' | Should -Be 'id,name,city'
        $cols = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)')
        ($cols | ForEach-Object { $_.name }) -join ',' | Should -Be 'id,name,city'
        $rows = @(Invoke-DbQuery -Database $db -Query 'SELECT id, name, city FROM t ORDER BY id')
        $rows.Count | Should -Be 2
        # Import-Csv itself drops leading whitespace of an unquoted cell; the trailing space is kept.
        $rows[0].name | Should -Be 'Bob '
        $rows[1].city | Should -Be 'D'
    }
    It 'rejects headers that collide once trimmed' {
        $csv = New-TestCsv -Name 'b073dup.csv' -Lines @('id,name,name ', '1,a,b')
        $db = New-TestDbPath -Name 'b073b'
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' } | Should -Throw '*duplicate column names*'
    }
}

Describe 'Import-CsvToSqlite Strict mode requires an existing table' -Tag 'BUG-074' {
    It 'throws on a misspelled table name in Strict mode instead of creating a new table' {
        $csv = New-TestCsv -Name 'b074.csv' -Lines @('id,name', '1,alpha')
        $db = New-TestDbPath -Name 'b074'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'assets' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'asets' -SchemaMode Strict } | Should -Throw "*Strict mode: table 'asets' does not exist*"
        $names = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'as%'" | ForEach-Object { $_.name })
        $names | Should -Be @('assets')
    }
    It 'still imports into an existing table in Strict mode' {
        $csv = New-TestCsv -Name 'b074b.csv' -Lines @('id,name', '1,alpha')
        $csv2 = New-TestCsv -Name 'b074c.csv' -Lines @('id,name', '2,beta')
        $db = New-TestDbPath -Name 'b074b'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'assets' | Out-Null
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'assets' -SchemaMode Strict | Out-Null
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM assets' | Select-Object -First 1
        [int]$count.c | Should -Be 2
    }
    It 'still creates the table in Relaxed mode' {
        $csv = New-TestCsv -Name 'b074d.csv' -Lines @('id,name', '1,alpha')
        $db = New-TestDbPath -Name 'b074d'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'fresh' -SchemaMode Relaxed | Out-Null
        $count = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM fresh' | Select-Object -First 1
        [int]$count.c | Should -Be 1
    }
}

Describe 'Relaxed import that rebuilds a table to widen a column' -Tag 'E2E1-001' {
    It 'widens a table that a Confirm-DbForeignKey ON DELETE trigger on the parent refers to' {
        $db = New-TestDbPath -Name 'e2e1001a'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE parent (id INTEGER PRIMARY KEY, t TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE prices (id INTEGER PRIMARY KEY, parent_id INTEGER, amount REAL)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO parent(id,t) VALUES(1,'p')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO prices(id,parent_id,amount) VALUES(1,1,1.5)' -NonQuery | Out-Null
        Confirm-DbForeignKey -Database $db -From 'prices' -Column 'parent_id' -To 'parent' -OnDelete 'CASCADE'

        # '10.0' is inferred TEXT, so Relaxed widens the declared REAL column and rebuilds the table.
        # The ON DELETE trigger lives on 'parent' and names 'prices', so before the fix the rename
        # inside the rebuild failed on SQLite 3.25+ after 'prices' had already been dropped.
        $csv = New-TestCsv -Name 'e2e1001a.csv' -Lines @('id,parent_id,amount', '3,1,10.0')
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'prices' -SchemaMode Relaxed } | Should -Not -Throw

        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(prices)')
        ($info | Where-Object { $_.name -eq 'amount' }).type | Should -Be 'TEXT'
        $rows = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM prices' | Select-Object -First 1
        [int]$rows.c | Should -Be 2
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%__widen_tmp'").Count | Should -Be 0

        # every foreign key trigger survived the rebuild, including the one on the parent table
        $triggers = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name" | ForEach-Object { [string]$_.name })
        $triggers | Should -Contain 'trg_fk_prices_parent_id_check'
        $triggers | Should -Contain 'trg_fk_prices_parent_id_check_upd'
        $triggers | Should -Contain 'trg_fk_prices_parent_id_ondelete'

        # and they still enforce the relationship
        { Invoke-DbQuery -Database $db -Query 'INSERT INTO prices(id,parent_id,amount) VALUES(9,777,1)' -NonQuery } | Should -Throw
        Invoke-DbQuery -Database $db -Query 'DELETE FROM parent WHERE id=1' -NonQuery | Out-Null
        $afterCascade = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM prices' | Select-Object -First 1
        [int]$afterCascade.c | Should -Be 0
    }

    It 'rolls a failed rebuild back instead of leaving the connection inside an aborted transaction' {
        $db = New-TestDbPath -Name 'e2e1001b'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO t(id,v) VALUES(1,1.5)' -NonQuery | Out-Null
        # an index already holding the name the rebuild needs for its temporary table makes the
        # CREATE TABLE inside the rebuild fail, after the batch has opened its savepoint
        Invoke-DbQuery -Database $db -Query 'CREATE INDEX "t__widen_tmp" ON t(v)' -NonQuery | Out-Null

        $csv = New-TestCsv -Name 'e2e1001b.csv' -Lines @('id,v', '2,abc')
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' -SchemaMode Relaxed } | Should -Throw

        # the original table is untouched
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'v' }).type | Should -Be 'REAL'
        $kept = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM t' | Select-Object -First 1
        [int]$kept.c | Should -Be 1

        # the pooled connection is no longer inside the transaction the failed batch opened
        $txError = $null
        $tx = $null
        try { $tx = Start-DbTransaction -Database $db } catch { $txError = $_ }
        $txError | Should -BeNullOrEmpty
        if ($tx) { Undo-DbTransaction -Database $db -Transaction $tx }

        # a write made after the failure is committed instead of being discarded on close
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE later (x INTEGER)' -NonQuery | Out-Null
        Close-DbConnections
        $later = Invoke-DbQuery -Database $db -Query "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='later'" | Select-Object -First 1
        [int]$later.c | Should -Be 1
    }

    It 'widens a table inside a transaction the caller already opened' {
        $db = New-TestDbPath -Name 'e2e1001c'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO t(id,v) VALUES(1,1.5)' -NonQuery | Out-Null

        $tx = Start-DbTransaction -Database $db
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE userwork (x INTEGER)' -NonQuery -Transaction $tx | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO userwork(x) VALUES(42)' -NonQuery -Transaction $tx | Out-Null

        # the rebuild must nest inside the caller's transaction (SAVEPOINT), not try to BEGIN a
        # second one, and it must never roll the caller's transaction back
        $csv = New-TestCsv -Name 'e2e1001c.csv' -Lines @('id,v', '2,abc')
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' -SchemaMode Relaxed } | Should -Not -Throw

        Complete-DbTransaction -Database $db -Transaction $tx
        Close-DbConnections

        $survived = Invoke-DbQuery -Database $db -Query "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='userwork'" | Select-Object -First 1
        [int]$survived.c | Should -Be 1
        $rows = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM userwork' | Select-Object -First 1
        [int]$rows.c | Should -Be 1
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'v' }).type | Should -Be 'TEXT'
        $tRows = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM t' | Select-Object -First 1
        [int]$tRows.c | Should -Be 2
    }

    It 'keeps the caller transaction usable when the rebuild itself fails' {
        $db = New-TestDbPath -Name 'e2e1001d'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO t(id,v) VALUES(1,1.5)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE INDEX "t__widen_tmp" ON t(v)' -NonQuery | Out-Null

        $tx = Start-DbTransaction -Database $db
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE userwork (x INTEGER)' -NonQuery -Transaction $tx | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO userwork(x) VALUES(42)' -NonQuery -Transaction $tx | Out-Null

        $csv = New-TestCsv -Name 'e2e1001d.csv' -Lines @('id,v', '2,abc')
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' -SchemaMode Relaxed } | Should -Throw

        # the cleanup rolls back to the rebuild's own savepoint only, so the caller can still commit
        { Complete-DbTransaction -Database $db -Transaction $tx } | Should -Not -Throw
        Close-DbConnections

        $survived = Invoke-DbQuery -Database $db -Query "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='userwork'" | Select-Object -First 1
        [int]$survived.c | Should -Be 1
        $rows = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM userwork' | Select-Object -First 1
        [int]$rows.c | Should -Be 1
        # and the failed rebuild left the table exactly as it was
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'v' }).type | Should -Be 'REAL'
        $tRows = Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) AS c FROM t' | Select-Object -First 1
        [int]$tRows.c | Should -Be 1
        # foreign key enforcement was restored on the pooled connection
        $fk = Invoke-DbQuery -Database $db -Query 'PRAGMA foreign_keys' | Select-Object -First 1
        "$($fk.foreign_keys)" | Should -Be '1'
    }
}

Describe 'Import-CsvToSqlite bool token normalisation needs evidence' -Tag 'E2E1-002' {
    It 'keeps a single bool token as ordinary text instead of rewriting the column to 1/0' {
        $csv = New-TestCsv -Name 'e2e1002a.csv' -Lines @('id,initial,code', '1,Y,NO')
        $db = New-TestDbPath -Name 'e2e1002a'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $row = Invoke-DbQuery -Database $db -Query 'SELECT initial, code FROM t' | Select-Object -First 1
        $row.initial | Should -Be 'Y'
        $row.code | Should -Be 'NO'
        $info = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)')
        ($info | Where-Object { $_.name -eq 'initial' }).type | Should -Be 'TEXT'
        ($info | Where-Object { $_.name -eq 'code' }).type | Should -Be 'TEXT'
    }
    It 'does not re-encode an append into a column the table already declares TEXT' {
        $csv1 = New-TestCsv -Name 'e2e1002b1.csv' -Lines @('answer,name', 'yes,a', 'maybe,b')
        $csv2 = New-TestCsv -Name 'e2e1002b2.csv' -Lines @('answer,name', 'no,c')
        $db = New-TestDbPath -Name 'e2e1002b'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' -SchemaMode Strict | Out-Null
        $answers = @(Invoke-DbQuery -Database $db -Query 'SELECT answer FROM t ORDER BY name' | ForEach-Object { "$($_.answer)" })
        $answers -join ',' | Should -Be 'yes,maybe,no'
    }
    It 'still converts a column that shows both a true and a false token' {
        $csv = New-TestCsv -Name 'e2e1002c.csv' -Lines @('id,flag', '1,yes', '2,no')
        $db = New-TestDbPath -Name 'e2e1002c'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        $flags = @(Invoke-DbQuery -Database $db -Query 'SELECT flag FROM t ORDER BY id' | ForEach-Object { "$($_.flag)" })
        $flags -join ',' | Should -Be '1,0'
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'flag' }).type | Should -Be 'INTEGER'
    }
    It 'still converts a one-sided append into a column the table already declares INTEGER' {
        $csv1 = New-TestCsv -Name 'e2e1002d1.csv' -Lines @('id,flag', '1,yes', '2,no')
        $csv2 = New-TestCsv -Name 'e2e1002d2.csv' -Lines @('id,flag', '3,yes')
        $db = New-TestDbPath -Name 'e2e1002d'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' -SchemaMode Strict | Out-Null
        # the column keeps its INTEGER type - the append is not widened back to TEXT
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'flag' }).type | Should -Be 'INTEGER'
        $row = Invoke-DbQuery -Database $db -Query 'SELECT flag, typeof(flag) AS tf FROM t WHERE id=3' | Select-Object -First 1
        [int]$row.flag | Should -Be 1
        $row.tf | Should -Be 'integer'
    }
}

Describe 'Import-CsvToSqlite honours -WhatIf' -Tag 'E2E1-004' {
    It 'declares -WhatIf of its own' {
        (Get-Command Import-CsvToSqlite).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }
    It 'writes no rows, no table and no catalog with -WhatIf' {
        $csv = New-TestCsv -Name 'e2e1004a.csv' -Lines @('id,name', '1,alpha', '2,beta')
        $db = New-TestDbPath -Name 'e2e1004a'
        $headers = @(Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' -WhatIf)
        $headers -join ',' | Should -Be 'id,name'
        $tables = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table'" | ForEach-Object { [string]$_.name })
        $tables | Should -Not -Contain 't'
        $tables | Should -Not -Contain '__tables__'
    }
    It 'writes no rows when $WhatIfPreference is set globally' {
        $csv = New-TestCsv -Name 'e2e1004b.csv' -Lines @('id,name', '1,alpha', '2,beta')
        $db = New-TestDbPath -Name 'e2e1004b'
        $previous = $global:WhatIfPreference
        $global:WhatIfPreference = $true
        try { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null }
        finally { $global:WhatIfPreference = $previous }
        $tables = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table'" | ForEach-Object { [string]$_.name })
        $tables | Should -Not -Contain 't'
        $tables | Should -Not -Contain '__tables__'
    }
    It 'still imports and catalogs normally without -WhatIf' {
        $csv = New-TestCsv -Name 'e2e1004c.csv' -Lines @('id,name', '1,alpha', '2,beta')
        $db = New-TestDbPath -Name 'e2e1004c'
        Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 't' | Out-Null
        [int](Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM t' -Scalar) | Should -Be 2
        [int](Invoke-DbQuery -Database $db -Query "SELECT COUNT(*) FROM __tables__ WHERE table_name='t'" -Scalar) | Should -Be 1
    }
}

Describe 'Import-CsvToSqlite keeps ids unique when the id column arrives later' -Tag 'E2E1-009' {
    It 'refuses a re-import of the same ids after the id column was added by ALTER TABLE' {
        $csv1 = New-TestCsv -Name 'e2e1009a1.csv' -Lines @('hostname,ip', 'first,1.1.1.1')
        $csv2 = New-TestCsv -Name 'e2e1009a2.csv' -Lines @('id,hostname,ip', '1,a,2.2.2.2', '2,b,3.3.3.3')
        $db = New-TestDbPath -Name 'e2e1009a'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' } | Should -Throw
        $ids = @(Invoke-DbQuery -Database $db -Query 'SELECT id FROM t' | ForEach-Object { "$($_.id)" })
        $ids -join ',' | Should -Be ',1,2'
        # the column is still a plain INTEGER (ALTER TABLE cannot add a primary key); the
        # uniqueness lives in an index instead
        ((Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'id' }).type | Should -Be 'INTEGER'
        $unique = @(Invoke-DbQuery -Database $db -Query 'PRAGMA index_list(t)' | Where-Object { [int]$_.unique -eq 1 })
        $unique.Count | Should -BeGreaterThan 0
    }
    It 'rejects duplicate ids inside the very file that adds the id column' {
        $csv1 = New-TestCsv -Name 'e2e1009b1.csv' -Lines @('hostname', 'first')
        $csv2 = New-TestCsv -Name 'e2e1009b2.csv' -Lines @('id,hostname', '1,a', '1,b')
        $db = New-TestDbPath -Name 'e2e1009b'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' } | Should -Throw
        [int](Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM t' -Scalar) | Should -Be 1
    }
    It 'still lets rows that predate the id column keep a null id' {
        $csv1 = New-TestCsv -Name 'e2e1009c1.csv' -Lines @('name,qty', 'x,1', 'y,2')
        $csv2 = New-TestCsv -Name 'e2e1009c2.csv' -Lines @('id,name,qty', '7,z,9')
        $db = New-TestDbPath -Name 'e2e1009c'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 'n' | Out-Null
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 'n' } | Should -Not -Throw
        [int](Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM n' -Scalar) | Should -Be 3
    }
}

Describe 'Import-CsvToSqlite undoes its schema changes when the import fails' -Tag 'E2E1-012' {
    It 'leaves no added column behind when the inserts fail' {
        $csv1 = New-TestCsv -Name 'e2e1012a1.csv' -Lines @('id,name', '1,a')
        $csv2 = New-TestCsv -Name 'e2e1012a2.csv' -Lines @('id,name,extra', '1,dup,zzz')
        $db = New-TestDbPath -Name 'e2e1012a'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        $before = (@(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | ForEach-Object { [string]$_.name }) -join '|'
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' } | Should -Throw
        $after = (@(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | ForEach-Object { [string]$_.name }) -join '|'
        $after | Should -Be $before
        [int](Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM t' -Scalar) | Should -Be 1
        # the failed import must not have made the column exist for a later AppendOnly run
        { Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' -SchemaMode AppendOnly } | Should -Throw '*AppendOnly mode: column extra does not exist*'
    }
    It 'leaves no table behind when the first import into a new table fails' {
        $csv = New-TestCsv -Name 'e2e1012b.csv' -Lines @('id,name', '1,a', '1,b')
        $db = New-TestDbPath -Name 'e2e1012b'
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'newt' } | Should -Throw
        $tables = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='newt'")
        $tables.Count | Should -Be 0
        { Import-CsvToSqlite -CsvPath $csv -Database $db -TableName 'newt' -SchemaMode Strict } | Should -Throw "*Strict mode: table 'newt' does not exist*"
    }
    It 'still commits the schema change when the import succeeds' {
        $csv1 = New-TestCsv -Name 'e2e1012c1.csv' -Lines @('id,name', '1,a')
        $csv2 = New-TestCsv -Name 'e2e1012c2.csv' -Lines @('id,name,extra', '2,b,zzz')
        $db = New-TestDbPath -Name 'e2e1012c'
        Import-CsvToSqlite -CsvPath $csv1 -Database $db -TableName 't' | Out-Null
        Import-CsvToSqlite -CsvPath $csv2 -Database $db -TableName 't' | Out-Null
        $cols = (@(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(t)') | ForEach-Object { [string]$_.name }) -join '|'
        $cols | Should -Be 'id|name|extra'
        [int](Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM t' -Scalar) | Should -Be 2
    }
}
