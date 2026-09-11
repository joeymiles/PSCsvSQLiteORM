# Regression tests for Import-CsvToSqlite (TASK B1: BUG-003, BUG-006, BUG-050, BUG-051; TASK B4: BUG-007; TASK B10: BUG-052, BUG-054, BUG-071, BUG-073; TASK B13: BUG-074)

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
