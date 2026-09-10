# Unit tests for core helpers (TASK B2: BUG-004, BUG-005, BUG-013; TASK B3: BASE-02, BUG-014, BUG-049, BUG-072)

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
