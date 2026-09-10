# Functional tests for PSCsvSQLiteORM

Import-Module (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'output') 'PSCsvSQLiteORM') -Force

Describe 'Initialize-ORMVars settings script' {
    It 'Applies settings from a SettingsPath file' {
        $tmpDir = Join-Path $PSScriptRoot 'tmp'
        if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
        $logFile = Join-Path $tmpDir ("orm_{0}.log" -f ([guid]::NewGuid().ToString('N')))
        $settingsPath = Join-Path $env:TEMP ("orm_settings_{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
        "@{ LogLevel = 'DEBUG'; LogPath = '$logFile' }" | Set-Content -LiteralPath $settingsPath -Encoding UTF8

        Initialize-ORMVars -SettingsPath $settingsPath
        Write-DbLog INFO 'hello from test'

        Test-Path -LiteralPath $logFile | Should -BeTrue
        (Get-Content -LiteralPath $logFile -Raw) | Should -Match 'hello from test'
    }
}

Describe 'Import-CsvToSqlite AppendOnly mode' {
    $tmpDir = Join-Path $PSScriptRoot 'tmp'
    if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
    $db = Join-Path $tmpDir ("orm_func_{0}.db" -f ([guid]::NewGuid().ToString('N')))
    It 'Throws if table does not exist in AppendOnly' {
        { Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -Database $db -TableName 'new_assets' -SchemaMode AppendOnly } | Should -Throw
    }
}

Describe 'Find-DbRelationships returns suggestions' {
    It 'Suggests relationships based on *_id' {
        $tmpDir = Join-Path $PSScriptRoot 'tmp'
        if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
        $db = Join-Path $tmpDir ("orm_rel_{0}.db" -f ([guid]::NewGuid().ToString('N')))

        # Import sample csvs (Relaxed schema)
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'assets.csv') -Database $db -TableName 'assets' -SchemaMode Relaxed | Out-Null
        Import-CsvToSqlite -CsvPath (Join-Path $PSScriptRoot 'vulns.csv') -Database $db -TableName 'vulns' -SchemaMode Relaxed | Out-Null

        $sugs = Find-DbRelationships -Database $db
        $sugs | Should -Not -BeNullOrEmpty
        ($sugs | Get-Member -Type NoteProperty | Select-Object -ExpandProperty Name) | Should -Contain 'table_name'
        ($sugs | Get-Member -Type NoteProperty | Select-Object -ExpandProperty Name) | Should -Contain 'column_name'
        ($sugs | Get-Member -Type NoteProperty | Select-Object -ExpandProperty Name) | Should -Contain 'ref_table'
        ($sugs | Get-Member -Type NoteProperty | Select-Object -ExpandProperty Name) | Should -Contain 'ref_column'
    }
}

Describe 'DbQuery RIGHT/FULL join emulation' {
    It 'Emulates RIGHT and FULL joins correctly' {
        $tmpDir = Join-Path $PSScriptRoot 'tmp'
        if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
        $db = Join-Path $tmpDir ("orm_join_{0}.db" -f ([guid]::NewGuid().ToString('N')))

        # Create tables and seed data
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE a(id INTEGER PRIMARY KEY, name TEXT)'
        Invoke-DbQuery -Database $db -Query 'CREATE TABLE b(id INTEGER PRIMARY KEY, a_id INTEGER, val TEXT)'
        Invoke-DbQuery -Database $db -Query "INSERT INTO a(id,name) VALUES (1,'a1'),(2,'a2')" -NonQuery | Out-Null
        Invoke-DbQuery -Database $db -Query "INSERT INTO b(id,a_id,val) VALUES (10,1,'b1'),(11,3,'b2')" -NonQuery | Out-Null

        # RIGHT join: expect rows from b plus matching a
        $q = New-DbQuery -Database $db -From 'a'
        $q = $q.Join('b', 'a.id = b.a_id', 'Right').Select(@('a.id as aid','b.id as bid'))
        $right = $q.Run()
        ($right | Measure-Object).Count | Should -Be 2
        # Assert expected pairs
        ($right | Where-Object { $_.aid -eq 1 -and $_.bid -eq 10 } | Measure-Object).Count | Should -Be 1
        ($right | Where-Object { ( $null -eq $_.aid -or $_.aid -is [System.DBNull] ) -and $_.bid -eq 11 } | Measure-Object).Count | Should -Be 1

        # FULL join: union of both sides
        $q2 = New-DbQuery -Database $db -From 'a'
        $q2 = $q2.Join('b', 'a.id = b.a_id', 'Full').Select(@('a.id as aid','b.id as bid'))
        $full = $q2.Run()
        ($full | Measure-Object).Count | Should -BeGreaterThan 2
        # Assert expected pairs present (1,10), (2,$null), ($null,11)
        ($full | Where-Object { $_.aid -eq 1 -and $_.bid -eq 10 } | Measure-Object).Count | Should -Be 1
        ($full | Where-Object { $_.aid -eq 2 -and ( $null -eq $_.bid -or $_.bid -is [System.DBNull] ) } | Measure-Object).Count | Should -Be 1
        ($full | Where-Object { ( $null -eq $_.aid -or $_.aid -is [System.DBNull] ) -and $_.bid -eq 11 } | Measure-Object).Count | Should -Be 1
    }
}
