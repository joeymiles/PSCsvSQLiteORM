# Unit tests for core helpers (TASK B2: BUG-004, BUG-005, BUG-013; TASK B3: BASE-02, BUG-014, BUG-049, BUG-072; TASK B4: BUG-007, BUG-009, BUG-026, BUG-047; TASK B5: BUG-008; TASK B6: BUG-011, BUG-025, BUG-058)

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
