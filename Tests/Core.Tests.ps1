# Unit tests for core helpers (TASK B2: BUG-004, BUG-005, BUG-013; TASK B3: BASE-02, BUG-014, BUG-049, BUG-072; TASK B4: BUG-007, BUG-009, BUG-026, BUG-047; TASK B5: BUG-008; TASK B6: BUG-011, BUG-025, BUG-058; TASK B7: BUG-012, BUG-031, BUG-032, BUG-043; TASK B8: BUG-022, BUG-023, BUG-027, BUG-030; TASK B9: BUG-024, BUG-033, BUG-066; TASK B11: BUG-044; TASK B12: BUG-034)

$moduleFolder = Join-Path (Join-Path $PSScriptRoot '..') 'output\PSCsvSQLiteORM'
Import-Module $moduleFolder -Force

BeforeAll {
    function New-Rows {
        param([string]$Header, [object[]]$Values)
        $rows = @()
        foreach ($v in $Values) { $rows += [pscustomobject]@{ $Header = $v } }
        return $rows
    }
    $script:coreWorkDir = Join-Path $env:TEMP ("orm_core_{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $script:coreWorkDir | Out-Null
    function New-CoreDbPath {
        param([string]$Name)
        return (Join-Path $script:coreWorkDir ("{0}_{1}.db" -f $Name, ([guid]::NewGuid().ToString('N'))))
    }
    function Get-DbPoolCount {
        $m = (Get-Command Get-DbConnection).Module
        return (& $m { $script:DbPool.Count })
    }
    # Force the PSSQLite fallback path by replacing Get-DbConnection inside the module
    # scope (Pester's Mock -ModuleName fails when another copy of the module is loaded).
    function Disable-DirectConnection {
        $m = (Get-Command Invoke-DbQuery).Module
        $script:origGetDbConnection = & $m { (Get-Item function:Get-DbConnection).ScriptBlock }
        & $m { Set-Item function:script:Get-DbConnection -Value { param([string]$Database) return $null } }
    }
    function Restore-DirectConnection {
        $m = (Get-Command Invoke-DbQuery).Module
        if ($script:origGetDbConnection) {
            & $m { param($sb) Set-Item function:script:Get-DbConnection -Value $sb } $script:origGetDbConnection
        }
    }
    # TASK B8 helpers: a small parent/child schema for the Confirm-DbForeignKey tests
    function New-FkProbeDb {
        $db = New-CoreDbPath -Name 'fk'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE assets(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE vulns(id INTEGER PRIMARY KEY, asset_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE hosts(id INTEGER PRIMARY KEY)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO assets(id,name) VALUES(1,'a'),(2,'b'),(3,'c')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO vulns(id,asset_id) VALUES(1,1),(2,2)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO hosts(id) VALUES(500)' -NonQuery | Out-Null
        return $db
    }
    function Get-FkTriggerNames {
        param([string]$Database)
        return @(Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name" | ForEach-Object { $_.name })
    }
    function Get-ScalarInt {
        param([string]$Database, [string]$Query)
        return [int](Invoke-DbQuery -Database $Database -Query $Query)[0].c
    }
}

AfterAll {
    Close-DbConnections
}

Describe 'Get-DbConnection uses the System.Data.SQLite type loaded by PSSQLite' -Tag 'BASE-02' {
    It 'returns an open SQLiteConnection and a real transaction on the current host' {
        $db = New-CoreDbPath -Name 'base02'
        $conn = Get-DbConnection -Database $db
        $conn | Should -Not -BeNullOrEmpty
        $conn.GetType().FullName | Should -Be 'System.Data.SQLite.SQLiteConnection'
        $conn.State | Should -Be 'Open'
        $tx = Start-DbTransaction -Database $db
        $tx | Should -Not -BeNullOrEmpty
        $tx.GetType().FullName | Should -Be 'System.Data.SQLite.SQLiteTransaction'
        Undo-DbTransaction -Database $db -Transaction $tx
    }
    It 'rolls back a failed Add-DbMigration so no table or version row is left behind' {
        $db = New-CoreDbPath -Name 'base02mig'
        {
            Add-DbMigration -Database $db -Version 'v_fail' -Up {
                param($d)
                Invoke-DbQuery -Database $d -Query 'CREATE TABLE left_behind(x INTEGER)' -NonQuery | Out-Null
                throw 'boom'
            }
        } | Should -Throw
        $rows = @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='left_behind'")
        $rows.Count | Should -Be 0
        @(Get-AppliedMigrations -Database $db) | Should -Not -Contain 'v_fail'
    }
    It 'returns a scalar value through the pooled connection' {
        $db = New-CoreDbPath -Name 'base02scalar'
        $v = Invoke-DbQuery -Database $db -Query 'SELECT 41 + 1' -Scalar
        [int]$v | Should -Be 42
    }
}

Describe 'Get-DbConnection path normalisation' -Tag 'BUG-014' {
    It 'resolves a relative -Database path against the PowerShell current location' {
        # keep names short: the full path must stay under MAX_PATH for the native SQLite library
        $sub = Join-Path $script:coreWorkDir ('r' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $procDir = [Environment]::CurrentDirectory
        $name = 'rel_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.db'
        Push-Location -LiteralPath $sub
        try {
            Invoke-DbQuery -Database ('.\' + $name) -Query 'CREATE TABLE t(x INTEGER)' -NonQuery | Out-Null
        }
        finally { Pop-Location }
        (Join-Path $sub $name) | Should -Exist
        if ($procDir -ne $sub) { (Join-Path $procDir $name) | Should -Not -Exist }
    }
    It 'pools one connection for different spellings of the same file' {
        Close-DbConnections
        $db = New-CoreDbPath -Name 'key'
        $c1 = Get-DbConnection -Database $db
        $c2 = Get-DbConnection -Database ($db.Replace('\', '/'))
        $c3 = Get-DbConnection -Database ($db.ToUpperInvariant())
        Push-Location -LiteralPath $script:coreWorkDir
        try { $c4 = Get-DbConnection -Database ('.\' + [System.IO.Path]::GetFileName($db)) }
        finally { Pop-Location }
        [object]::ReferenceEquals($c1, $c2) | Should -BeTrue
        [object]::ReferenceEquals($c1, $c3) | Should -BeTrue
        [object]::ReferenceEquals($c1, $c4) | Should -BeTrue
        (Get-DbPoolCount) | Should -Be 1
    }
    It 'lets a write through one spelling proceed while a transaction is open through another' {
        $db = New-CoreDbPath -Name 'lock'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t(x INTEGER)' -NonQuery | Out-Null
        $tx = Start-DbTransaction -Database $db
        Invoke-DbQuery -Database $db -Query 'INSERT INTO t(x) VALUES(1)' -NonQuery -Transaction $tx | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-DbQuery -Database ($db.Replace('\', '/')) -Query 'INSERT INTO t(x) VALUES(2)' -NonQuery -Transaction $tx | Out-Null
        $sw.Stop()
        Complete-DbTransaction -Database $db -Transaction $tx
        $sw.ElapsedMilliseconds | Should -BeLessThan 10000
        [int](Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM t' -Scalar) | Should -Be 2
    }
}

Describe 'Get-DbConnection evicts closed pooled connections' -Tag 'BUG-049' {
    It 'reopens a connection after the caller closed the pooled object' {
        $db = New-CoreDbPath -Name 'closed'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t(x INTEGER)' -NonQuery | Out-Null
        $old = Get-DbConnection -Database $db
        $old.Close()
        $fresh = Get-DbConnection -Database $db
        $fresh | Should -Not -BeNullOrEmpty
        $fresh.State | Should -Be 'Open'
        [object]::ReferenceEquals($old, $fresh) | Should -BeFalse
        $tx = Start-DbTransaction -Database $db
        $tx | Should -Not -BeNullOrEmpty
        Invoke-DbQuery -Database $db -Query 'INSERT INTO t(x) VALUES(1)' -NonQuery -Transaction $tx | Out-Null
        Undo-DbTransaction -Database $db -Transaction $tx
        [int](Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM t' -Scalar) | Should -Be 0
    }
}

Describe 'Get-DbConnection quotes the data source' -Tag 'BUG-072' {
    It 'opens a database whose path contains a semicolon' {
        $dir = Join-Path $script:coreWorkDir 'semi;colon'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $db = Join-Path $dir 'x.db'
        { Invoke-DbQuery -Database $db -Query 'CREATE TABLE q(x INTEGER)' -NonQuery -ErrorAction Stop | Out-Null } | Should -Not -Throw
        $db | Should -Exist
        (Get-DbConnection -Database $db).State | Should -Be 'Open'
        [int](Invoke-DbQuery -Database $db -Query "SELECT count(*) FROM sqlite_master WHERE name='q'" -Scalar) | Should -Be 1
    }
}

Describe 'Test-ColumnTypes numeric inference' -Tag 'BUG-004' {
    It 'infers INTEGER only for canonical integers within Int64' {
        (Test-ColumnTypes -Csv (New-Rows 'c' @('1', '-3', '0', $null)) -Headers @('c'))['c'] | Should -Be 'INTEGER'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('02134', '90210')) -Headers @('c'))['c'] | Should -Be 'TEXT'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('12345678901234567890')) -Headers @('c'))['c'] | Should -Be 'TEXT'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('-0', '1')) -Headers @('c'))['c'] | Should -Be 'TEXT'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('9223372036854775807')) -Headers @('c'))['c'] | Should -Be 'INTEGER'
    }
    It 'infers REAL only when the text is the canonical rendering of the number' {
        (Test-ColumnTypes -Csv (New-Rows 'c' @('1.5', '2.25', '3')) -Headers @('c'))['c'] | Should -Be 'REAL'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('1.10', '1.1')) -Headers @('c'))['c'] | Should -Be 'TEXT'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('01.5')) -Headers @('c'))['c'] | Should -Be 'TEXT'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('1e3')) -Headers @('c'))['c'] | Should -Be 'TEXT'
    }
}

Describe 'Test-ColumnTypes empty columns and empty strings' -Tag 'BUG-005' {
    It 'infers TEXT for a column with no values' {
        (Test-ColumnTypes -Csv (New-Rows 'c' @($null, $null)) -Headers @('c'))['c'] | Should -Be 'TEXT'
    }
    It 'ignores empty strings by default but treats them as text with -EmptyIsText' {
        (Test-ColumnTypes -Csv (New-Rows 'c' @('5', '')) -Headers @('c'))['c'] | Should -Be 'INTEGER'
        (Test-ColumnTypes -Csv (New-Rows 'c' @('5', '')) -Headers @('c') -EmptyIsText)['c'] | Should -Be 'TEXT'
    }
}

Describe 'Test-ColumnTypes id column' -Tag 'BUG-013' {
    It 'declares integer or blank ids as INTEGER PRIMARY KEY AUTOINCREMENT' {
        (Test-ColumnTypes -Csv (New-Rows 'id' @('1', '2')) -Headers @('id'))['id'] | Should -Be 'INTEGER PRIMARY KEY AUTOINCREMENT'
        (Test-ColumnTypes -Csv (New-Rows 'id' @($null, $null)) -Headers @('id'))['id'] | Should -Be 'INTEGER PRIMARY KEY AUTOINCREMENT'
    }
    It 'declares text ids as TEXT PRIMARY KEY, also for an upper-case header' {
        (Test-ColumnTypes -Csv (New-Rows 'id' @('srv-01', 'srv-02')) -Headers @('id'))['id'] | Should -Be 'TEXT PRIMARY KEY'
        (Test-ColumnTypes -Csv (New-Rows 'ID' @('A1')) -Headers @('ID'))['ID'] | Should -Be 'TEXT PRIMARY KEY'
        (Test-ColumnTypes -Csv (New-Rows 'id' @('007')) -Headers @('id'))['id'] | Should -Be 'TEXT PRIMARY KEY'
    }
}

Describe 'Invoke-DbQuery PSSQLite fallback counts a one-row result' -Tag 'BUG-007' {
    BeforeAll { Disable-DirectConnection }
    AfterAll { Restore-DirectConnection }
    It '-Scalar returns the value of a one-row result' {
        $db = New-CoreDbPath -Name 'b007scalar'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t(x INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'INSERT INTO t(x) VALUES(7),(8)' -NonQuery | Out-Null
        $v = Invoke-DbQuery -Database $db -Query 'SELECT count(*) FROM t' -Scalar
        $v | Should -Not -BeNullOrEmpty
        [int]$v | Should -Be 2
        [int](Invoke-DbQuery -Database $db -Query 'SELECT max(x) FROM t' -Scalar) | Should -Be 8
    }
    It '-Scalar returns $null for an empty result' {
        $db = New-CoreDbPath -Name 'b007empty'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t(x INTEGER)' -NonQuery | Out-Null
        $v = Invoke-DbQuery -Database $db -Query 'SELECT x FROM t' -Scalar
        $null -eq $v | Should -BeTrue
    }
}

Describe 'DbQuery Auto join finds a single relationship row' -Tag 'BUG-007' {
    It 'joins through the only confirmed __fks__ row instead of throwing' {
        $db = New-CoreDbPath -Name 'b007join'
        Initialize-Db -Database $db
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE assets(id INTEGER PRIMARY KEY, hostname TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE vulns(id INTEGER PRIMARY KEY, asset_id INTEGER, cve TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO assets VALUES(1,'h1')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO vulns VALUES(1,1,'CVE-1'),(2,1,'CVE-2')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO __fks__(table_name,column_name,ref_table,ref_column,confidence,status) VALUES('vulns','asset_id','assets','id',0.9,'confirmed')" -NonQuery | Out-Null
        $q = New-DbQuery -Database $db -From 'vulns'
        $q = $q.Join('assets', 'Auto', 'Inner')
        $rows = @($q.Run())
        $rows.Count | Should -Be 2
    }
}

Describe 'Invoke-DbQuery PSSQLite fallback raises terminating errors' -Tag 'BUG-009' {
    # A -File runner script executes in the global scope, so its ErrorActionPreference = 'Stop'
    # is the global preference that PSSQLite's Invoke-SqliteQuery already honours. Pin the
    # global preference to Continue here so these tests only pass when Invoke-DbQuery itself
    # requests terminating errors (-ErrorAction Stop) from the fallback.
    BeforeAll {
        Disable-DirectConnection
        $script:oldGlobalEap = $global:ErrorActionPreference
        $global:ErrorActionPreference = 'Continue'
    }
    AfterAll {
        $global:ErrorActionPreference = $script:oldGlobalEap
        Restore-DirectConnection
    }
    It 'throws for a failing -NonQuery statement' {
        $db = New-CoreDbPath -Name 'b009nq'
        { Invoke-DbQuery -Database $db -Query 'INSERT INTO no_such_table VALUES(1)' -NonQuery | Out-Null } | Should -Throw
    }
    It 'throws for a failing SELECT and a failing -Scalar' {
        $db = New-CoreDbPath -Name 'b009sel'
        { $null = Invoke-DbQuery -Database $db -Query 'SELECT * FROM no_such_table' } | Should -Throw
        { $null = Invoke-DbQuery -Database $db -Query 'SELECT * FROM no_such_table' -Scalar } | Should -Throw
    }
    It 'does not record a migration whose Up SQL failed' {
        $db = New-CoreDbPath -Name 'b009mig'
        {
            Add-DbMigration -Database $db -Version 'bad002' -Up {
                param($d)
                Invoke-DbQuery -Database $d -Query 'INSERT INTO no_such_table VALUES(1)' -NonQuery | Out-Null
            } -WarningAction SilentlyContinue
        } | Should -Throw
        @(Get-AppliedMigrations -Database $db) | Should -Not -Contain 'bad002'
    }
}

Describe 'Foreign keys are enforced on both connection paths' -Tag 'BUG-008' {
    BeforeAll {
        function New-FkSchema {
            param([string]$Database)
            Invoke-DbQuery -Database $Database -Query 'CREATE TABLE parent(id INTEGER PRIMARY KEY)' -NonQuery | Out-Null
            Invoke-DbQuery -Database $Database -Query 'CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))' -NonQuery | Out-Null
            Invoke-DbQuery -Database $Database -Query 'INSERT INTO parent(id) VALUES(1)' -NonQuery | Out-Null
        }
    }
    Context 'direct System.Data.SQLite path' {
        It 'rejects an orphan insert and reports the pragma as on' {
            $db = New-CoreDbPath -Name 'b008direct'
            New-FkSchema -Database $db
            Invoke-DbQuery -Database $db -Query 'PRAGMA foreign_keys' -Scalar | Should -Be 1
            { Invoke-DbQuery -Database $db -Query 'INSERT INTO child(parent_id) VALUES(999)' -NonQuery | Out-Null } | Should -Throw
            Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM child' -Scalar | Should -Be 0
        }
    }
    Context 'PSSQLite fallback path' {
        BeforeAll {
            Disable-DirectConnection
            $script:oldGlobalEap008 = $global:ErrorActionPreference
            $global:ErrorActionPreference = 'Continue'
        }
        AfterAll {
            $global:ErrorActionPreference = $script:oldGlobalEap008
            Restore-DirectConnection
        }
        It 'reports the pragma as on for a fresh fallback call' {
            $db = New-CoreDbPath -Name 'b008fbpragma'
            New-FkSchema -Database $db
            # -Scalar and a plain SELECT each run on their own PSSQLite connection
            Invoke-DbQuery -Database $db -Query 'PRAGMA foreign_keys' -Scalar | Should -Be 1
            $rows = @(Invoke-DbQuery -Database $db -Query 'PRAGMA foreign_keys')
            $rows.Count | Should -Be 1
            $rows[0].foreign_keys | Should -Be 1
        }
        It 'rejects an orphan insert with a terminating error and leaves no orphan row' {
            $db = New-CoreDbPath -Name 'b008fbinsert'
            New-FkSchema -Database $db
            { Invoke-DbQuery -Database $db -Query 'INSERT INTO child(parent_id) VALUES(999)' -NonQuery | Out-Null } | Should -Throw
            Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM child' -Scalar | Should -Be 0
        }
        It 'still accepts a valid child row and returns the affected count' {
            $db = New-CoreDbPath -Name 'b008fbvalid'
            New-FkSchema -Database $db
            Invoke-DbQuery -Database $db -Query 'INSERT INTO child(parent_id) VALUES(@p)' -SqlParameters @{ p = 1 } -NonQuery | Should -Be 1
            Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM child' -Scalar | Should -Be 1
        }
        It 'rejects deleting a referenced parent row' {
            $db = New-CoreDbPath -Name 'b008fbdelete'
            New-FkSchema -Database $db
            Invoke-DbQuery -Database $db -Query 'INSERT INTO child(parent_id) VALUES(1)' -NonQuery | Out-Null
            { Invoke-DbQuery -Database $db -Query 'DELETE FROM parent WHERE id = 1' -NonQuery | Out-Null } | Should -Throw
            Invoke-DbQuery -Database $db -Query 'SELECT COUNT(*) FROM parent' -Scalar | Should -Be 1
        }
    }
}

Describe 'Invoke-DbQuery result shape is the same on both paths' -Tag 'BUG-026' {
    BeforeAll {
        $script:db026 = New-CoreDbPath -Name 'b026'
        Invoke-DbQuery -Database $script:db026 -Query 'CREATE TABLE t(id INTEGER, name TEXT, note TEXT, "Table" TEXT, RowState TEXT)' -NonQuery | Out-Null
        $script:nq026 = Invoke-DbQuery -Database $script:db026 -Query "INSERT INTO t VALUES(1,'a',NULL,'oak','new'),(2,'b','x','pine','old')" -NonQuery
    }
    It 'direct path returns only the result columns, in order' {
        $rows = @(Invoke-DbQuery -Database $script:db026 -Query 'SELECT * FROM t ORDER BY id')
        $rows.Count | Should -Be 2
        @($rows[0].PSObject.Properties.Name) -join ',' | Should -Be 'id,name,note,Table,RowState'
        $rows[0].Table | Should -Be 'oak'
        $rows[0].RowState | Should -Be 'new'
    }
    It 'direct path maps NULL to $null instead of DBNull' {
        $row = Invoke-DbQuery -Database $script:db026 -Query 'SELECT note FROM t WHERE id=1'
        $null -eq $row.note | Should -BeTrue
        ($row.note -is [System.DBNull]) | Should -BeFalse
    }
    It 'direct path -NonQuery returns the affected-row count and -AsDataTable still returns a DataTable' {
        [int]$script:nq026 | Should -Be 2
        $dt = Invoke-DbQuery -Database $script:db026 -Query 'SELECT * FROM t' -AsDataTable
        $dt.GetType().FullName | Should -Be 'System.Data.DataTable'
        $dt.Rows.Count | Should -Be 2
    }
    Context 'PSSQLite fallback' {
        BeforeAll { Disable-DirectConnection }
        AfterAll { Restore-DirectConnection }
        It 'returns the same property names, $null for NULL and an affected-row count' {
            $n = Invoke-DbQuery -Database $script:db026 -Query "INSERT INTO t VALUES(3,'c',NULL,'fir','x')" -NonQuery
            [int]$n | Should -Be 1
            [int](Invoke-DbQuery -Database $script:db026 -Query "UPDATE t SET name='z' WHERE id IN (1,2,3);" -NonQuery) | Should -Be 3
            $rows = @(Invoke-DbQuery -Database $script:db026 -Query 'SELECT * FROM t ORDER BY id')
            $rows.Count | Should -Be 3
            @($rows[0].PSObject.Properties.Name) -join ',' | Should -Be 'id,name,note,Table,RowState'
            $null -eq $rows[0].note | Should -BeTrue
        }
        It '-NonQuery tolerates a trailing same-line comment and an existing terminator' {
            [int](Invoke-DbQuery -Database $script:db026 -Query "UPDATE t SET name='q' WHERE id = 1 -- trailing comment" -NonQuery) | Should -Be 1
            [int](Invoke-DbQuery -Database $script:db026 -Query "UPDATE t SET name='r' WHERE id = 2;" -NonQuery) | Should -Be 1
            [int](Invoke-DbQuery -Database $script:db026 -Query "UPDATE t SET name='s' WHERE id = 3; -- done" -NonQuery) | Should -Be 1
        }
    }
}

Describe 'DEBUG logging does not write bound parameter values' -Tag 'BUG-047' {
    It 'logs parameter names but not values' {
        $db = New-CoreDbPath -Name 'b047'
        $log = Join-Path $script:coreWorkDir 'b047.log'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE users(id INTEGER, username TEXT, password TEXT)' -NonQuery | Out-Null
        Set-DbLogging -Level DEBUG -Path $log -Confirm:$false
        try {
            Invoke-DbQuery -Database $db -Query 'INSERT INTO users VALUES(@id, @username, @password)' -SqlParameters @{ id = 1; username = 'alice'; password = 'S3cr3tP@ss' } -NonQuery | Out-Null
        }
        finally { Set-DbLogging -Level INFO -Path '' -Confirm:$false }
        $log | Should -Exist
        $text = Get-Content -LiteralPath $log -Raw
        $text | Should -Not -Match 'S3cr3tP@ss'
        $text | Should -Not -Match 'alice'
        $text | Should -Match 'INSERT INTO users'
        $text | Should -Match 'password'
    }
}

Describe 'Module import sets defaults without calling module functions' -Tag 'BUG-011' {
    It 'loads exactly one module instance from the output folder and records no error' {
        # A child process of the current host gives a clean session with the default PSModulePath
        # (installed copies of the module present), which is where the auto-load used to happen.
        $exe = (Get-Process -Id $PID).Path
        $folder = Join-Path (Join-Path $PSScriptRoot '..') 'output\PSCsvSQLiteORM'
        $expectedRoot = (Resolve-Path -LiteralPath $folder).Path
        $probe = @'
param($Folder)
$Error.Clear()
Import-Module $Folder -Force
$mods = @(Get-Module PSCsvSQLiteORM)
"COUNT=$($mods.Count)"
foreach ($m in $mods) { "PATH=$($m.Path)" }
"ERRORS=$($Error.Count)"
foreach ($e in $Error) { "ERR=$($e.Exception.Message)" }
'@
        $probePath = Join-Path $script:coreWorkDir 'b011_import_probe.ps1'
        Set-Content -LiteralPath $probePath -Value $probe -Encoding ASCII
        $out = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $probePath $folder 2>&1 | ForEach-Object { "$_" })
        ($out -join "`n") | Should -Match 'COUNT=1'
        ($out -join "`n") | Should -Match 'ERRORS=0'
        $paths = @($out | Where-Object { $_ -like 'PATH=*' })
        $paths.Count | Should -Be 1
        $paths[0].Substring(5).StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
    }
    It 'has working defaults in the current session after import' {
        $m = (Get-Command Initialize-ORMVars).Module
        (& $m { $script:DbLogLevel }) | Should -Be 'INFO'
        (& $m { $script:DbPool -is [hashtable] }) | Should -BeTrue
    }
}

Describe 'Initialize-ORMVars closes pooled connections and validates before resetting' -Tag 'BUG-025' {
    AfterAll { Initialize-ORMVars }
    It 'closes the pooled connection so the database file can be removed' {
        $db = New-CoreDbPath -Name 'b025'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t(id INTEGER)' -NonQuery | Out-Null
        $m = (Get-Command Get-DbConnection).Module
        $conn = & $m { @($script:DbPool.Values)[0] }
        $conn | Should -Not -BeNullOrEmpty
        $conn.State | Should -Be 'Open'
        Initialize-ORMVars
        # a disposed SQLiteConnection reports State as $null; it must not be Open
        "$($conn.State)" | Should -Not -Be 'Open'
        (Get-DbPoolCount) | Should -Be 0
        Close-DbConnections
        { Remove-Item -LiteralPath $db -ErrorAction Stop } | Should -Not -Throw
        $db | Should -Not -Exist
    }
    It 'leaves the previous configuration in place when SettingsPath does not exist' {
        $log = Join-Path $script:coreWorkDir 'b025.log'
        Initialize-ORMVars -LogLevel DEBUG -LogPath $log
        { Initialize-ORMVars -SettingsPath (Join-Path $script:coreWorkDir 'b025_missing.ps1') } | Should -Throw '*SettingsPath not found*'
        $m = (Get-Command Initialize-ORMVars).Module
        (& $m { $script:DbLogLevel }) | Should -Be 'DEBUG'
        (& $m { $script:DbLogPath }) | Should -Be $log
    }
    It 'reports an invalid LogLevel in the settings file with a friendly error and keeps the previous state' {
        $log = Join-Path $script:coreWorkDir 'b025b.log'
        Initialize-ORMVars -LogLevel WARN -LogPath $log
        $settings = Join-Path $script:coreWorkDir 'b025_bad_level.ps1'
        "@{ LogLevel = 'TRACE' }" | Set-Content -LiteralPath $settings -Encoding ASCII
        { Initialize-ORMVars -SettingsPath $settings } | Should -Throw '*Failed to load settings*TRACE*'
        $m = (Get-Command Initialize-ORMVars).Module
        (& $m { $script:DbLogLevel }) | Should -Be 'WARN'
        (& $m { $script:DbLogPath }) | Should -Be $log
    }
}

Describe 'Explicit Initialize-ORMVars parameters override the settings file' -Tag 'BUG-058' {
    BeforeAll {
        $script:b058Settings = Join-Path $script:coreWorkDir 'b058_settings.ps1'
        $script:b058FileLog = Join-Path $script:coreWorkDir 'b058_file.log'
        "@{ LogLevel = 'DEBUG'; LogPath = '$script:b058FileLog'; DbPath = 'from_file.db' }" | Set-Content -LiteralPath $script:b058Settings -Encoding ASCII
    }
    AfterAll { Initialize-ORMVars }
    It 'keeps -LogLevel, -LogPath and -DbPath when the settings file also sets them' {
        $explicitLog = Join-Path $script:coreWorkDir 'b058_explicit.log'
        Initialize-ORMVars -LogLevel ERROR -LogPath $explicitLog -DbPath 'explicit.db' -SettingsPath $script:b058Settings
        $m = (Get-Command Initialize-ORMVars).Module
        (& $m { $script:DbLogLevel }) | Should -Be 'ERROR'
        (& $m { $script:DbLogPath }) | Should -Be $explicitLog
        (& $m { $script:DbDefaultPath }) | Should -Be 'explicit.db'
    }
    It 'still takes values from the settings file for parameters that were not given' {
        Initialize-ORMVars -LogLevel WARN -SettingsPath $script:b058Settings
        $m = (Get-Command Initialize-ORMVars).Module
        (& $m { $script:DbLogLevel }) | Should -Be 'WARN'
        (& $m { $script:DbLogPath }) | Should -Be $script:b058FileLog
        (& $m { $script:DbDefaultPath }) | Should -Be 'from_file.db'
    }
}

Describe 'Update-DbCatalog keeps per-table source and csv_hash' -Tag 'BUG-012' {
    BeforeAll {
        $script:b012Db = New-CoreDbPath -Name 'b012'
        $script:b012Assets = Join-Path $PSScriptRoot 'assets.csv'
        $script:b012Vulns = Join-Path $PSScriptRoot 'vulns.csv'
        Import-CsvToSqlite -CsvPath $script:b012Assets -TableName assets -Database $script:b012Db | Out-Null
        Import-CsvToSqlite -CsvPath $script:b012Vulns -TableName vulns -Database $script:b012Db | Out-Null
        $script:b012AssetsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:b012Assets).Hash
        $script:b012VulnsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:b012Vulns).Hash
        function Get-B012Row {
            param([string]$Name)
            return (Invoke-DbQuery -Database $script:b012Db -Query "SELECT source, csv_hash FROM __tables__ WHERE table_name=@t" -SqlParameters @{ t = $Name })[0]
        }
    }
    It 'binds the CSV path and hash only to the imported table' {
        $a = Get-B012Row -Name 'assets'
        $v = Get-B012Row -Name 'vulns'
        $a.source | Should -Be $script:b012Assets
        $a.csv_hash | Should -Be $script:b012AssetsHash
        $v.source | Should -Be $script:b012Vulns
        $v.csv_hash | Should -Be $script:b012VulnsHash
    }
    It 'leaves source and csv_hash untouched on a bare Update-DbCatalog' {
        Update-DbCatalog -Database $script:b012Db
        $a = Get-B012Row -Name 'assets'
        $a.source | Should -Be $script:b012Assets
        $a.csv_hash | Should -Be $script:b012AssetsHash
    }
    It 'leaves other tables untouched after Export-DynamicModelsFromCatalog' {
        Export-DynamicModelsFromCatalog -Database $script:b012Db | Out-Null
        $v = Get-B012Row -Name 'vulns'
        $v.source | Should -Be $script:b012Vulns
        $v.csv_hash | Should -Be $script:b012VulnsHash
    }
}

Describe 'Update-DbCatalog removes rows for dropped tables and columns' -Tag 'BUG-031' {
    BeforeAll {
        $script:b031Db = New-CoreDbPath -Name 'b031'
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -TableName assets -Database $script:b031Db | Out-Null
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -TableName vulns -Database $script:b031Db | Out-Null
        Find-DbRelationships -Database $script:b031Db | Out-Null
        function Get-B031Count {
            param([string]$Query)
            return [int](Invoke-DbQuery -Database $script:b031Db -Query $Query)[0].c
        }
    }
    It 'has a suggested FK for vulns before the drop' {
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='vulns'" | Should -BeGreaterThan 0
    }
    It 'purges __tables__, __columns__ and __fks__ rows of a dropped table' {
        Invoke-DbQuery -Database $script:b031Db -Query 'DROP TABLE vulns' -NonQuery | Out-Null
        Update-DbCatalog -Database $script:b031Db
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='vulns'" | Should -Be 0
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __columns__ WHERE table_name='vulns'" | Should -Be 0
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='vulns'" | Should -Be 0
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='assets'" | Should -Be 1
    }
    It 'does not re-suggest relationships for a dropped table' {
        Find-DbRelationships -Database $script:b031Db | Out-Null
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='vulns'" | Should -Be 0
    }
    It 'purges __columns__ rows of a column that no longer exists' {
        Invoke-DbQuery -Database $script:b031Db -Query 'CREATE TABLE t2(a INTEGER, b TEXT)' -NonQuery | Out-Null
        Update-DbCatalog -Database $script:b031Db
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __columns__ WHERE table_name='t2' AND column_name='b'" | Should -Be 1
        Invoke-DbQuery -Database $script:b031Db -Query 'DROP TABLE t2' -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:b031Db -Query 'CREATE TABLE t2(a INTEGER)' -NonQuery | Out-Null
        Update-DbCatalog -Database $script:b031Db
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __columns__ WHERE table_name='t2' AND column_name='b'" | Should -Be 0
        Get-B031Count -Query "SELECT COUNT(*) AS c FROM __columns__ WHERE table_name='t2' AND column_name='a'" | Should -Be 1
    }
}

Describe 'Update-DbCatalog does not catalog the bookkeeping tables' -Tag 'BUG-032' {
    BeforeAll {
        $script:b032Db = New-CoreDbPath -Name 'b032'
        $script:b032Internal = @('__tables__', '__columns__', '__fks__', 'schema_migrations')
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -TableName assets -Database $script:b032Db | Out-Null
    }
    It 'writes no __tables__ or __columns__ rows for internal tables' {
        Update-DbCatalog -Database $script:b032Db
        $names = @(Invoke-DbQuery -Database $script:b032Db -Query 'SELECT table_name FROM __tables__' | ForEach-Object { $_.table_name })
        $names | Should -Be @('assets')
        $colNames = @(Invoke-DbQuery -Database $script:b032Db -Query 'SELECT DISTINCT table_name FROM __columns__' | ForEach-Object { $_.table_name })
        foreach ($i in $script:b032Internal) { $colNames | Should -Not -Contain $i }
    }
    It 'cleans internal-table rows left by an older catalog' {
        Invoke-DbQuery -Database $script:b032Db -Query "INSERT INTO __tables__(table_name,rowcount) VALUES('__fks__',0)" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:b032Db -Query "INSERT INTO __columns__(table_name,column_name) VALUES('schema_migrations','version')" -NonQuery | Out-Null
        Update-DbCatalog -Database $script:b032Db
        [int](Invoke-DbQuery -Database $script:b032Db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='__fks__'")[0].c | Should -Be 0
        [int](Invoke-DbQuery -Database $script:b032Db -Query "SELECT COUNT(*) AS c FROM __columns__ WHERE table_name='schema_migrations'")[0].c | Should -Be 0
    }
    It 'Find-DbRelationships ignores internal tables even when the catalog lists them' {
        Invoke-DbQuery -Database $script:b032Db -Query "INSERT INTO __tables__(table_name,rowcount) VALUES('__fks__',0)" -NonQuery | Out-Null
        Invoke-DbQuery -Database $script:b032Db -Query "INSERT INTO __columns__(table_name,column_name) VALUES('__fks__','assets_id')" -NonQuery | Out-Null
        Find-DbRelationships -Database $script:b032Db | Out-Null
        [int](Invoke-DbQuery -Database $script:b032Db -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='__fks__'")[0].c | Should -Be 0
        Update-DbCatalog -Database $script:b032Db
    }
}

Describe 'Update-DbCatalog skips tables whose names ConvertTo-Ident rejects' -Tag 'BUG-043' {
    BeforeAll {
        $script:b043Db = New-CoreDbPath -Name 'b043'
        Invoke-DbQuery -Database $script:b043Db -Query 'CREATE TABLE "t$1"(id INTEGER PRIMARY KEY, x TEXT)' -NonQuery | Out-Null
    }
    It 'Import-CsvToSqlite succeeds and catalogs the new table' {
        { Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -TableName vulns -Database $script:b043Db | Out-Null } | Should -Not -Throw
        [int](Invoke-DbQuery -Database $script:b043Db -Query 'SELECT COUNT(*) AS c FROM vulns')[0].c | Should -Be 4
        [int](Invoke-DbQuery -Database $script:b043Db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='vulns'")[0].c | Should -Be 1
        [int](Invoke-DbQuery -Database $script:b043Db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='t`$1'")[0].c | Should -Be 0
    }
    It 'Export-DynamicModelsFromCatalog does not throw for the whole database' {
        { Export-DynamicModelsFromCatalog -Database $script:b043Db | Out-Null } | Should -Not -Throw
    }
}

Describe 'Confirm-DbForeignKey enforces every OnDelete mode at delete time' -Tag 'BUG-022' {
    It 'RESTRICT blocks deleting a parent that still has children' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete RESTRICT
        (Get-FkTriggerNames -Database $db) | Should -Contain 'trg_fk_vulns_asset_id_ondelete'
        { Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 1' -NonQuery | Out-Null } | Should -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM assets' | Should -Be 3
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns WHERE asset_id NOT IN (SELECT id FROM assets)' | Should -Be 0
    }
    It 'RESTRICT still allows deleting a parent without children' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete RESTRICT
        { Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 3' -NonQuery | Out-Null } | Should -Not -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM assets' | Should -Be 2
    }
    It 'NO ACTION (the default) blocks deleting a parent that still has children' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets
        { Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 2' -NonQuery | Out-Null } | Should -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM assets' | Should -Be 3
    }
    It 'SET NULL nulls the child column when the parent is deleted' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete 'SET NULL'
        { Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 2' -NonQuery | Out-Null } | Should -Not -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns' | Should -Be 2
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns WHERE id = 2 AND asset_id IS NULL' | Should -Be 1
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns WHERE id = 1 AND asset_id = 1' | Should -Be 1
    }
    It 'CASCADE still deletes the children' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete CASCADE
        Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 1' -NonQuery | Out-Null
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns' | Should -Be 1
    }
}

Describe 'Confirm-DbForeignKey replaces stale triggers when a column is re-confirmed' -Tag 'BUG-023' {
    It 're-confirming against another table enforces only the new target' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete CASCADE
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To hosts -OnDelete 'NO ACTION'
        $names = Get-FkTriggerNames -Database $db
        $names | Should -Be @('trg_fk_vulns_asset_id_check', 'trg_fk_vulns_asset_id_check_upd', 'trg_fk_vulns_asset_id_ondelete')
        $checkSql = (Invoke-DbQuery -Database $db -Query "SELECT sql FROM sqlite_master WHERE name='trg_fk_vulns_asset_id_check'")[0].sql
        $checkSql | Should -Not -Match 'assets'
        $checkSql | Should -Match 'hosts'
        # 500 exists only in hosts, 3 exists only in assets
        { Invoke-DbQuery -Database $db -Query 'INSERT INTO vulns(id,asset_id) VALUES(9,500)' -NonQuery | Out-Null } | Should -Not -Throw
        { Invoke-DbQuery -Database $db -Query 'INSERT INTO vulns(id,asset_id) VALUES(10,3)' -NonQuery | Out-Null } | Should -Throw
        (Invoke-DbQuery -Database $db -Query "SELECT ref_table FROM __fks__ WHERE table_name='vulns' AND column_name='asset_id'")[0].ref_table | Should -Be 'hosts'
    }
    It 'switching from CASCADE to NO ACTION stops the cascade' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete CASCADE
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete 'NO ACTION'
        { Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 1' -NonQuery | Out-Null } | Should -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns' | Should -Be 2
        (Invoke-DbQuery -Database $db -Query "SELECT on_delete FROM __fks__ WHERE table_name='vulns' AND column_name='asset_id'")[0].on_delete | Should -Be 'NO ACTION'
    }
    It 'switching from NO ACTION to CASCADE starts cascading' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -OnDelete CASCADE
        { Invoke-DbQuery -Database $db -Query 'DELETE FROM assets WHERE id = 1' -NonQuery | Out-Null } | Should -Not -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns' | Should -Be 1
    }
}

Describe 'Confirm-DbForeignKey trigger text is ASCII on every build host' -Tag 'BUG-027' {
    It 'the source file contains no non-ASCII bytes' {
        $src = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'source') 'Public\Confirm-DbForeignKey.ps1'
        $bytes = [IO.File]::ReadAllBytes($src)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'the stored trigger and the violation message use an ASCII arrow' {
        $db = New-FkProbeDb
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets
        $checkSql = (Invoke-DbQuery -Database $db -Query "SELECT sql FROM sqlite_master WHERE name='trg_fk_vulns_asset_id_check'")[0].sql
        $checkSql | Should -Match 'FK violation: vulns\.asset_id -> assets\.id'
        @($checkSql.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        $msg = $null
        try { Invoke-DbQuery -Database $db -Query 'INSERT INTO vulns(id,asset_id) VALUES(9,999)' -NonQuery | Out-Null } catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'vulns\.asset_id -> assets\.id'
    }
}

Describe 'Confirm-DbForeignKey validates the referenced table and column' -Tag 'BUG-030' {
    It 'throws for a missing referenced table and leaves no trigger or catalog row behind' {
        $db = New-FkProbeDb
        { Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To nosuchtable } | Should -Throw -ExpectedMessage '*nosuchtable*'
        (Get-FkTriggerNames -Database $db).Count | Should -Be 0
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='vulns'" | Should -Be 0
        { Invoke-DbQuery -Database $db -Query 'INSERT INTO vulns(id,asset_id) VALUES(9,NULL)' -NonQuery | Out-Null } | Should -Not -Throw
        Get-ScalarInt -Database $db -Query 'SELECT COUNT(*) AS c FROM vulns' | Should -Be 3
    }
    It 'throws for a missing referenced column' {
        $db = New-FkProbeDb
        { Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -RefColumn nosuchcol } | Should -Throw -ExpectedMessage '*nosuchcol*'
        (Get-FkTriggerNames -Database $db).Count | Should -Be 0
    }
    It 'accepts an existing table and column regardless of case' {
        $db = New-FkProbeDb
        { Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To ASSETS -RefColumn ID } | Should -Not -Throw
        (Get-FkTriggerNames -Database $db).Count | Should -Be 3
    }
}

Describe 'Find-DbRelationships leaves confirmed relationships alone' -Tag 'BUG-024' {
    BeforeAll {
        function Get-FkRow {
            param([string]$Database, [string]$Table, [string]$Column)
            return (Invoke-DbQuery -Database $Database -Query "SELECT ref_table, ref_column, confidence, status FROM __fks__ WHERE table_name=@t AND column_name=@c" -SqlParameters @{ t = $Table; c = $Column })[0]
        }
    }
    It 'keeps the confirmed ref_column and reports status confirmed' {
        $db = New-CoreDbPath -Name 'b024a'
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -TableName assets -Database $db | Out-Null
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -TableName vulns -Database $db | Out-Null
        Confirm-DbForeignKey -Database $db -From vulns -Column asset_id -To assets -RefColumn hostname
        $sugs = @(Find-DbRelationships -Database $db)
        $row = Get-FkRow -Database $db -Table vulns -Column asset_id
        $row.ref_table | Should -Be 'assets'
        $row.ref_column | Should -Be 'hostname'
        $row.status | Should -Be 'confirmed'
        $mine = @($sugs | Where-Object { $_.table_name -eq 'vulns' -and $_.column_name -eq 'asset_id' })
        $mine.Count | Should -Be 1
        $mine[0].ref_column | Should -Be 'hostname'
        $mine[0].status | Should -Be 'confirmed'
    }
    It 'keeps a confirmed target table the heuristic could not guess' {
        $db = New-CoreDbPath -Name 'b024b'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE owners(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE docs(id INTEGER PRIMARY KEY, owner_id INTEGER)' -NonQuery | Out-Null
        Confirm-DbForeignKey -Database $db -From docs -Column owner_id -To users
        $sugs = @(Find-DbRelationships -Database $db)
        $row = Get-FkRow -Database $db -Table docs -Column owner_id
        $row.ref_table | Should -Be 'users'
        $row.status | Should -Be 'confirmed'
        $mine = @($sugs | Where-Object { $_.table_name -eq 'docs' })
        $mine.Count | Should -Be 1
        $mine[0].ref_table | Should -Be 'users'
        $mine[0].status | Should -Be 'confirmed'
    }
    It 'returns one suggestion per column that matches the single persisted row' {
        $db = New-CoreDbPath -Name 'b024c'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE asset(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE assets(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE vulns(id INTEGER PRIMARY KEY, asset_id INTEGER)' -NonQuery | Out-Null
        $sugs = @(Find-DbRelationships -Database $db)
        $sugs.Count | Should -Be 1
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='vulns'" | Should -Be 1
        $row = Get-FkRow -Database $db -Table vulns -Column asset_id
        $sugs[0].ref_table | Should -Be $row.ref_table
        $sugs[0].ref_column | Should -Be $row.ref_column
        $sugs[0].status | Should -Be 'suggested'
        $row.status | Should -Be 'suggested'
    }
    It 'still refreshes a suggestion that was never confirmed' {
        $db = New-CoreDbPath -Name 'b024d'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE teams(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE players(id INTEGER PRIMARY KEY, team_id INTEGER)' -NonQuery | Out-Null
        Find-DbRelationships -Database $db | Out-Null
        Invoke-DbQuery -Database $db -Query "UPDATE __fks__ SET ref_column='bogus', confidence=0.1 WHERE table_name='players'" -NonQuery | Out-Null
        Find-DbRelationships -Database $db | Out-Null
        $row = Get-FkRow -Database $db -Table players -Column team_id
        $row.ref_column | Should -Be 'id'
        [double]$row.confidence | Should -Be 1
        $row.status | Should -Be 'suggested'
    }
}

Describe 'Find-DbRelationships only suggests real key columns' -Tag 'BUG-033' {
    BeforeAll {
        $script:b033Db = New-CoreDbPath -Name 'b033'
        $db = $script:b033Db
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE users(name TEXT, email TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INTEGER, total REAL)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE owners(name TEXT, region_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE pets(id INTEGER PRIMARY KEY, owner_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE teams(team_id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE players(id INTEGER PRIMARY KEY, team_id INTEGER)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE hosts(host_key TEXT PRIMARY KEY, label TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE scans(id INTEGER PRIMARY KEY, host_id TEXT)' -NonQuery | Out-Null
        # Refresh the catalog explicitly so these tests do not depend on the BUG-066 fix.
        Update-DbCatalog -Database $db
        $script:b033Sugs = @(Find-DbRelationships -Database $db)
        function Get-B033 {
            param([string]$Table, [string]$Column)
            return @($script:b033Sugs | Where-Object { $_.table_name -eq $Table -and $_.column_name -eq $Column })
        }
    }
    It 'does not suggest a non-existent id column' {
        (Get-B033 -Table orders -Column user_id).Count | Should -Be 0
        Get-ScalarInt -Database $script:b033Db -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='orders'" | Should -Be 0
    }
    It 'does not treat a foreign key column of the referenced table as its key' {
        (Get-B033 -Table pets -Column owner_id).Count | Should -Be 0
        Get-ScalarInt -Database $script:b033Db -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='pets'" | Should -Be 0
    }
    It 'prefers the primary key of the referenced table' {
        $s = @(Get-B033 -Table players -Column team_id)
        $s.Count | Should -Be 1
        $s[0].ref_table | Should -Be 'teams'
        $s[0].ref_column | Should -Be 'team_id'
        [double]$s[0].confidence | Should -Be 1
        $s = @(Get-B033 -Table scans -Column host_id)
        $s.Count | Should -Be 1
        $s[0].ref_table | Should -Be 'hosts'
        $s[0].ref_column | Should -Be 'host_key'
        [double]$s[0].confidence | Should -Be 1
    }
    It 'never suggests a column as referencing itself' {
        (Get-B033 -Table teams -Column team_id).Count | Should -Be 0
        Get-ScalarInt -Database $script:b033Db -Query "SELECT COUNT(*) AS c FROM __fks__ WHERE table_name='teams'" | Should -Be 0
    }
}

Describe 'Find-DbRelationships refreshes the catalog first' -Tag 'BUG-066' {
    It 'suggests relationships for tables created with plain SQL' {
        $db = New-CoreDbPath -Name 'b066'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE teams(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE players(id INTEGER PRIMARY KEY, team_id INTEGER)' -NonQuery | Out-Null
        $sugs = @(Find-DbRelationships -Database $db)
        $sugs.Count | Should -Be 1
        $sugs[0].table_name | Should -Be 'players'
        $sugs[0].ref_table | Should -Be 'teams'
        $sugs[0].ref_column | Should -Be 'id'
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __columns__ WHERE table_name='players'" | Should -Be 2
    }
    It 'sees a table added by a migration after an earlier run' {
        $db = New-CoreDbPath -Name 'b066m'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE teams(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        @(Find-DbRelationships -Database $db).Count | Should -Be 0
        Add-DbMigration -Database $db -Version 'b066_players' -Up { param($d) Invoke-DbQuery -Database $d -Query 'CREATE TABLE players(id INTEGER PRIMARY KEY, team_id INTEGER)' -NonQuery | Out-Null }
        $sugs = @(Find-DbRelationships -Database $db)
        $sugs.Count | Should -Be 1
        $sugs[0].ref_table | Should -Be 'teams'
    }
}

Describe 'Update-DbCatalog and New-DbQuery honor ShouldProcess' -Tag 'BUG-044' {
    BeforeAll {
        function Get-B044TableCount {
            param([string]$Database, [string]$Name)
            return @(Invoke-DbQuery -Database $Database -Query "SELECT name FROM sqlite_master WHERE type='table' AND name=@n" -SqlParameters @{ n = $Name }).Count
        }
        function New-B044Db {
            $db = New-CoreDbPath -Name 'b044'
            Invoke-DbQuery -Database $db -Query 'CREATE TABLE things(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
            return $db
        }
    }
    It 'Update-DbCatalog -WhatIf does not create the catalog tables' {
        $db = New-B044Db
        Update-DbCatalog -Database $db -WhatIf
        Get-B044TableCount -Database $db -Name '__tables__' | Should -Be 0
        Get-B044TableCount -Database $db -Name '__columns__' | Should -Be 0
    }
    It 'Update-DbCatalog -WhatIf does not overwrite an existing catalog entry' {
        $db = New-CoreDbPath -Name 'b044w'
        $csv = Join-Path $PSScriptRoot 'assets.csv'
        Import-CsvToSqlite -CsvPath $csv -TableName assets -Database $db | Out-Null
        $before = (Invoke-DbQuery -Database $db -Query "SELECT source, csv_hash FROM __tables__ WHERE table_name='assets'")[0]
        # A table created after the import is not cataloged yet; -WhatIf must leave it that way.
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE things(id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
        Update-DbCatalog -Database $db -WhatIf
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='things'" | Should -Be 0
        $after = (Invoke-DbQuery -Database $db -Query "SELECT source, csv_hash FROM __tables__ WHERE table_name='assets'")[0]
        $after.source | Should -Be $before.source
        $after.csv_hash | Should -Be $before.csv_hash
    }
    It 'Update-DbCatalog writes without prompting when -Confirm:$false is given or by default' {
        $db = New-B044Db
        Update-DbCatalog -Database $db -Confirm:$false
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='things'" | Should -Be 1
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE more(id INTEGER PRIMARY KEY)' -NonQuery | Out-Null
        Update-DbCatalog -Database $db
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='more'" | Should -Be 1
    }
    It 'Import-CsvToSqlite still catalogs the imported table (ConfirmImpact does not prompt)' {
        $db = New-CoreDbPath -Name 'b044i'
        $csv = Join-Path $PSScriptRoot 'vulns.csv'
        Import-CsvToSqlite -CsvPath $csv -TableName vulns -Database $db | Out-Null
        Get-ScalarInt -Database $db -Query "SELECT COUNT(*) AS c FROM __tables__ WHERE table_name='vulns'" | Should -Be 1
    }
    It 'New-DbQuery -WhatIf returns nothing and the plain call returns a DbQuery' {
        $db = New-B044Db
        $q = New-DbQuery -Database $db -From things -WhatIf
        $q | Should -BeNullOrEmpty
        $q2 = New-DbQuery -Database $db -From things
        $q2 | Should -Not -BeNullOrEmpty
        $q2.GetType().Name | Should -Be 'DbQuery'
    }
}

Describe 'Enable-UniqueIndex creates a distinct index for every distinct column set' -Tag 'BUG-034' {
    BeforeAll {
        function Get-B034IndexSql {
            param([string]$Database, [string]$Name)
            return @(Invoke-DbQuery -Database $Database -Query "SELECT sql FROM sqlite_master WHERE type='index' AND name=@n" -SqlParameters @{ n = $Name } | ForEach-Object { [string]$_.sql })
        }
    }
    It 'keeps the historical name for a non-colliding column list' {
        $db = New-CoreDbPath -Name 'b034plain'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE z(id INTEGER PRIMARY KEY, zip TEXT)' -NonQuery | Out-Null
        Enable-UniqueIndex -Database $db -Table 'z' -Columns @('zip') | Should -Be 'ux_z_zip'
        (Get-B034IndexSql -Database $db -Name 'ux_z_zip').Count | Should -Be 1
        # calling again is idempotent and returns the same index
        Enable-UniqueIndex -Database $db -Table 'z' -Columns @('zip') | Should -Be 'ux_z_zip'
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='z'").Count | Should -Be 1
    }
    It 'creates a second index when columns a_b and (a, b) derive the same name' {
        $db = New-CoreDbPath -Name 'b034cols'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE ux(id INTEGER PRIMARY KEY, a TEXT, b TEXT, a_b TEXT)' -NonQuery | Out-Null
        $n1 = Enable-UniqueIndex -Database $db -Table 'ux' -Columns @('a_b')
        $n2 = Enable-UniqueIndex -Database $db -Table 'ux' -Columns @('a', 'b')
        $n1 | Should -Be 'ux_ux_a_b'
        $n2 | Should -Not -Be $n1
        @(Get-B034IndexSql -Database $db -Name $n1)[0] | Should -Match '\("a_b"\)'
        @(Get-B034IndexSql -Database $db -Name $n2)[0] | Should -Match '\("a", "b"\)'
        # both constraints are enforced
        Invoke-DbQuery -Database $db -Query "INSERT INTO ux(a,b,a_b) VALUES('1','2','x')" -NonQuery | Out-Null
        { Invoke-DbQuery -Database $db -Query "INSERT INTO ux(a,b,a_b) VALUES('1','2','y')" -NonQuery -ErrorAction Stop } | Should -Throw
        { Invoke-DbQuery -Database $db -Query "INSERT INTO ux(a,b,a_b) VALUES('3','4','x')" -NonQuery -ErrorAction Stop } | Should -Throw
        Invoke-DbQuery -Database $db -Query "INSERT INTO ux(a,b,a_b) VALUES('3','4','y')" -NonQuery | Out-Null
        # repeated calls return the existing names and create nothing new
        Enable-UniqueIndex -Database $db -Table 'ux' -Columns @('a_b') | Should -Be $n1
        Enable-UniqueIndex -Database $db -Table 'ux' -Columns @('a', 'b') | Should -Be $n2
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ux'").Count | Should -Be 2
    }
    It 'creates a second index when table a (b_c) and table a_b (c) derive the same name' {
        $db = New-CoreDbPath -Name 'b034tbl'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE a(id INTEGER PRIMARY KEY, b_c TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE a_b(id INTEGER PRIMARY KEY, c TEXT)' -NonQuery | Out-Null
        $n1 = Enable-UniqueIndex -Database $db -Table 'a' -Columns @('b_c')
        $n2 = Enable-UniqueIndex -Database $db -Table 'a_b' -Columns @('c')
        $n1 | Should -Be 'ux_a_b_c'
        $n2 | Should -Not -Be $n1
        $rows = @(Invoke-DbQuery -Database $db -Query "SELECT name, tbl_name FROM sqlite_master WHERE type='index' AND name LIKE 'ux_a%' ORDER BY tbl_name")
        $rows.Count | Should -Be 2
        ($rows | Where-Object { $_.name -eq $n1 }).tbl_name | Should -Be 'a'
        ($rows | Where-Object { $_.name -eq $n2 }).tbl_name | Should -Be 'a_b'
    }
    It 'reuses an existing unique index or constraint that already covers the columns' {
        $db = New-CoreDbPath -Name 'b034reuse'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE t(id INTEGER PRIMARY KEY, code TEXT, other TEXT)' -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query 'CREATE UNIQUE INDEX my_code_idx ON t(code)' -NonQuery | Out-Null
        Enable-UniqueIndex -Database $db -Table 't' -Columns @('code') | Should -Be 'my_code_idx'
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='t'").Count | Should -Be 1
        # a different column set on the same table still gets its own index
        Enable-UniqueIndex -Database $db -Table 't' -Columns @('other') | Should -Be 'ux_t_other'
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='t'").Count | Should -Be 2
    }
}
