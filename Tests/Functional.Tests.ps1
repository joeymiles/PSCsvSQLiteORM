# Functional tests for PSCsvSQLiteORM

# Join two pieces at a time: the three-argument Join-Path form does not exist on Windows PowerShell 5.1
Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM') -Force

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

Describe 'BUG-064 README SchemaMode example and documentation' -Tag 'BUG-064' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:Readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md')
        $script:ReadmeRaw = ($script:Readme -join "`n")
        $script:Root064 = Join-Path $env:TEMP ("orm_064_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Root064 -Force | Out-Null
        Initialize-ORMVars -LogLevel ERROR
        function New-Csv064([string]$Name, [string]$Content) {
            $f = Join-Path $script:Root064 $Name
            Set-Content -LiteralPath $f -Value $Content -Encoding ASCII
            return $f
        }
        function Get-Count064([string]$Database, [string]$Table) {
            $r = Invoke-DbQuery -Database $Database -Query "SELECT COUNT(*) AS c FROM $Table"
            return [int]($r | Select-Object -First 1).c
        }
        $script:Assets064 = Join-Path $PSScriptRoot 'assets.csv'
    }
    AfterAll { Close-DbConnections }

    It 'the README never uses AppendOnly for the first import of a table' {
        $appendLines = @($script:Readme | Where-Object { $_ -match 'Import-CsvToSqlite' -and $_ -match '-SchemaMode\s+AppendOnly' })
        $appendLines.Count | Should -BeGreaterThan 0
        foreach ($line in $appendLines) {
            $line | Should -Match '-TableName\s+(\S+)'
            $table = [regex]::Match($line, '-TableName\s+(\S+)').Groups[1].Value
            $index = [array]::IndexOf($script:Readme, $line)
            $earlier = @($script:Readme[0..($index - 1)] | Where-Object {
                $_ -match 'Import-CsvToSqlite' -and $_ -match ('-TableName\s+' + [regex]::Escape($table) + '(\s|$)') -and $_ -notmatch 'AppendOnly'
            })
            $earlier.Count | Should -BeGreaterThan 0 -Because "table '$table' must be created by an earlier import before an AppendOnly import"
        }
    }

    It 'the README documents every SchemaMode value' {
        foreach ($mode in @('Relaxed', 'Strict', 'AppendOnly')) {
            $script:ReadmeRaw | Should -Match ('`' + $mode + '`:')
        }
        $script:ReadmeRaw | Should -Match 'default `Relaxed`'
    }

    It 'AppendOnly on a fresh database throws the documented message' {
        $db = Join-Path $script:Root064 'fresh.db'
        { Import-CsvToSqlite -CsvPath $script:Assets064 -Database $db -TableName users -SchemaMode AppendOnly } |
            Should -Throw -ExpectedMessage "*AppendOnly mode: table 'users' does not exist.*"
    }

    It 'AppendOnly appends rows to an existing table and keeps its schema' {
        $db = Join-Path $script:Root064 'append.db'
        Import-CsvToSqlite -CsvPath $script:Assets064 -Database $db -TableName assets | Out-Null
        $more = New-Csv064 'assets_more.csv' "id,hostname,ip`r`n9,server09,10.0.0.9"
        Import-CsvToSqlite -CsvPath $more -Database $db -TableName assets -SchemaMode AppendOnly | Out-Null
        Get-Count064 $db 'assets' | Should -Be 4
        $cols = @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(assets)' | ForEach-Object { $_.name })
        $cols | Should -Be @('id', 'hostname', 'ip')
    }

    It 'Strict creates a missing table but rejects a CSV header the table lacks' {
        $db = Join-Path $script:Root064 'strict.db'
        Import-CsvToSqlite -CsvPath $script:Assets064 -Database $db -TableName assets -SchemaMode Strict | Out-Null
        Get-Count064 $db 'assets' | Should -Be 3
        $extra = New-Csv064 'assets_extra.csv' "id,hostname,ip,extra`r`n9,server09,10.0.0.9,x"
        { Import-CsvToSqlite -CsvPath $extra -Database $db -TableName assets -SchemaMode Strict } |
            Should -Throw -ExpectedMessage '*Strict mode: missing column extra in assets*'
        Get-Count064 $db 'assets' | Should -Be 3
        @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(assets)' | ForEach-Object { $_.name }) | Should -Not -Contain 'extra'
    }

    It 'Relaxed adds a missing column' {
        $db = Join-Path $script:Root064 'relaxed.db'
        Import-CsvToSqlite -CsvPath $script:Assets064 -Database $db -TableName assets | Out-Null
        $extra = New-Csv064 'assets_extra2.csv' "id,hostname,ip,extra`r`n9,server09,10.0.0.9,x"
        Import-CsvToSqlite -CsvPath $extra -Database $db -TableName assets -SchemaMode Relaxed | Out-Null
        Get-Count064 $db 'assets' | Should -Be 4
        @(Invoke-DbQuery -Database $db -Query 'PRAGMA table_info(assets)' | ForEach-Object { $_.name }) | Should -Contain 'extra'
    }
}

Describe 'BASE-10 README Quick Start runs against the real API' -Tag 'BASE-10' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:ReadmeRaw = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw)
        $script:HelpRaw = (Get-Content -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'docs') 'about_PSCsvSQLiteORM.help.txt') -Raw)
        $script:Root10 = Join-Path $env:TEMP ("orm_base10_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Root10 -Force | Out-Null
        Initialize-ORMVars -LogLevel ERROR
        $script:Db10 = Join-Path $script:Root10 'myapp.db'
        $script:AssetsCsv = Join-Path $PSScriptRoot 'assets.csv'
        $script:VulnsCsv = Join-Path $PSScriptRoot 'vulns.csv'
        $script:MoreCsv = Join-Path $script:Root10 'assets_more.csv'
        Set-Content -LiteralPath $script:MoreCsv -Value "id,hostname,ip`r`n9,server09,10.0.0.9" -Encoding ASCII
        function Get-Rows10([object]$Result) {
            $rows = @($Result | Where-Object { $null -ne $_ })
            return , $rows
        }
        # The README code blocks in order: 1 install, 2 initialize, 3 import, 4 models, 5 query, 6 records,
        # 7 upserts, 8 validation. Blocks 3-8 are executed verbatim (only the sample paths are rewritten).
        $script:Blocks10 = @([regex]::Matches($script:ReadmeRaw, '(?s)```powershell\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value })
        function Convert-ReadmePath10([string]$Line) {
            # Replacement strings are literal apart from '$', so paths are quoted and any '$' is doubled.
            $map = @(
                @('.\data\assets.csv', $script:AssetsCsv),
                @('.\data\vulns.csv', $script:VulnsCsv),
                @('.\data\assets_more.csv', $script:MoreCsv),
                @('.\myapp.db', $script:Db10)
            )
            foreach ($pair in $map) {
                $Line = [regex]::Replace($Line, [regex]::Escape($pair[0]), ("'" + ($pair[1] -replace '\$', '$$$$') + "'"))
            }
            return $Line
        }
        function Get-ReadmeLines10([int]$BlockNumber) {
            # Returns the executable statements of a README block: comments, blank lines and the two
            # $ticket/$user stand-in lines (records of tables the Quick Start does not create) are dropped.
            $lines = @()
            foreach ($raw in ($script:Blocks10[$BlockNumber - 1] -split "\r?\n")) {
                $line = $raw.Trim()
                if (-not $line -or $line.StartsWith('#')) { continue }
                if ($line -match '\$ticket\.|\$user\.') { continue }
                $lines += $line
            }
            return , $lines
        }
    }
    AfterAll { Close-DbConnections }

    It 'the README and help topic do not describe the removed API' {
        foreach ($doc in @($script:ReadmeRaw, $script:HelpRaw)) {
            $doc | Should -Not -Match 'New-DynamicModel\s+-Type'
            $doc | Should -Not -Match '-Properties\s+@\{'
            $doc | Should -Not -Match '\[Asset\]::'
            $doc | Should -Not -Match '\$asset\.status\s*='
        }
        $script:ReadmeRaw | Should -Match 'New-DynamicRecord -Table'
    }

    It 'every command the README Quick Start calls is exported by the module' {
        $exported = @((Get-Module PSCsvSQLiteORM | Where-Object { $_.ModuleBase -like ($script:RepoRoot + '*') } | Select-Object -First 1).ExportedCommands.Keys)
        if ($exported.Count -eq 0) { $exported = @((Get-Module PSCsvSQLiteORM | Select-Object -First 1).ExportedCommands.Keys) }
        $blocks = [regex]::Matches($script:ReadmeRaw, '(?s)```powershell\r?\n(.*?)```')
        $blocks.Count | Should -BeGreaterThan 5
        $called = @()
        foreach ($b in $blocks) {
            foreach ($m in [regex]::Matches($b.Groups[1].Value, '(?m)^\s*(?:\$\w+\s*=\s*)?((?:Import|Initialize|Export|Set|New|Find|Confirm|Invoke|Close|Update|Start|Complete|Undo|Get|Add|Enable|Test|Write)-\w+)')) {
                $called += $m.Groups[1].Value
            }
        }
        $called = @($called | Where-Object { $_ -ne 'Import-Module' -and $_ -ne 'Install-Module' } | Sort-Object -Unique)
        $called.Count | Should -BeGreaterThan 5
        foreach ($c in $called) { $exported | Should -Contain $c }
    }

    It 'the README Quick Start blocks 3-8 run line by line without an error on this host' {
        $script:Blocks10.Count | Should -Be 8
        $failures = @()
        $executed = 0
        foreach ($blockNumber in 3..8) {
            $lines = Get-ReadmeLines10 $blockNumber
            $lines.Count | Should -BeGreaterThan 0 -Because "README block $blockNumber must contain executable statements"
            foreach ($line in $lines) {
                $cmd = Convert-ReadmePath10 $line
                # On Windows PowerShell 5.1 SQLite errors surface as non-terminating errors (Get-DbConnection is
                # null there), so the global error list is inspected as well as catching terminating errors.
                # The Add-Type failure that Get-DbConnection catches internally on 5.1 is not a README error.
                $global:Error.Clear()
                try {
                    Invoke-Expression $cmd | Out-Null
                    $errs = @($global:Error | Where-Object { -not ($_ -is [System.Management.Automation.ErrorRecord] -and $_.InvocationInfo -and $_.InvocationInfo.MyCommand -and $_.InvocationInfo.MyCommand.Name -eq 'Add-Type') })
                    if ($errs.Count -gt 0) { $failures += ("block {0}: {1} :: {2}" -f $blockNumber, $line, $errs[0]) }
                } catch {
                    $failures += ("block {0}: {1} :: {2}" -f $blockNumber, $line, $_.Exception.Message)
                }
                $executed++
            }
        }
        $global:Error.Clear()
        $failures | Should -BeNullOrEmpty
        $executed | Should -BeGreaterThan 25
        # Objects left behind by the README lines carry the documented results
        $query | Should -Not -BeNullOrEmpty
        (Get-Rows10 $results).Count | Should -Be 2
        $asset.GetType().Name | Should -Be 'DynamicAssets'
        $asset.Id | Should -Be 0
        $found.Id | Should -Be 1
        $found.ip() | Should -Be '10.0.0.1'
        (Get-Rows10 $rows).Count | Should -Be 3
        @($vulns).Count | Should -Be 2
        $vulns[0].GetType().Name | Should -Be 'DynamicVulns'
        $owner.GetType().Name | Should -Be 'DynamicAssets'
        $owner.Id | Should -Be 1
    }

    It 'after the Quick Start the database holds what the README describes' {
        $fk = @(Invoke-DbQuery -Database $script:Db10 -Query "SELECT status FROM __fks__ WHERE table_name='vulns' AND column_name='asset_id'")
        $fk[0].status | Should -Be 'confirmed'
        $hosts = @(Invoke-DbQuery -Database $script:Db10 -Query 'SELECT hostname, ip FROM assets ORDER BY id')
        # 3 imported + 1 AppendOnly + server04 (deleted again) + BulkUpsert a and b + InsertMany c; server01 is
        # upserted to 10.0.0.1, then by the three explicit UpdateSet forms (the last one is the raw expression)
        @($hosts | ForEach-Object { $_.hostname }) | Should -Be @('server01', 'server02', 'server03', 'server09', 'a', 'b', 'c')
        [string]$hosts[0].ip | Should -Be '10.0.0.2-x'
        @(Invoke-DbQuery -Database $script:Db10 -Query "SELECT id FROM assets WHERE hostname='server04'").Count | Should -Be 0
        $cols = @(Invoke-DbQuery -Database $script:Db10 -Query 'PRAGMA table_info(assets)' | ForEach-Object { $_.name })
        $cols | Should -Be @('id', 'hostname', 'ip')
    }

    It 'step 5 as documented: Where, explicit Join, Auto join, OrderBy, Limit and Offset return the expected rows' {
        $query = New-DbQuery -Database $script:Db10 -From 'assets'
        $rows = Get-Rows10 ($query.Where('hostname = @host', @{ host = 'server01' }).Run())
        $rows.Count | Should -Be 1
        $rows[0].hostname | Should -Be 'server01'
        $query = New-DbQuery -Database $script:Db10 -From 'assets'
        $rows = Get-Rows10 ($query.Join('vulns', 'vulns.asset_id = assets.id', 'Left').Select(@('assets.*', 'vulns.title AS vuln_title')).Run())
        # 7 assets (server01 twice for its two vulns, server02, server03, server09, a, b, c) = 8 joined rows
        $rows.Count | Should -Be 8
        @($rows | Where-Object { $_.hostname -eq 'server01' }).Count | Should -Be 2
        $query = New-DbQuery -Database $script:Db10 -From 'vulns v'
        $rows = Get-Rows10 ($query.Join('assets a', 'Auto', 'Inner').Select(@('v.*', 'a.hostname')).OrderBy('v.id DESC').Limit(2).Offset(1).Run())
        $rows.Count | Should -Be 2
        $rows[0].id | Should -Be 3
        $rows[0].hostname | Should -Be 'server01'
    }

    It 'step 8 as documented: the BeforeSave callback blocks the write and AfterSave runs after it' {
        $asset = New-DynamicRecord -Table 'assets' -Database $script:Db10
        $asset.AddValidator('hostname', 'Required', $null)
        $asset.On('BeforeSave', { param($record) if ($record.GetAttribute('ip') -eq '0.0.0.0') { throw 'ip not allowed' } })
        $script:Saved10 = @()
        $asset.On('AfterSave', { param($record) $script:Saved10 += $record.Id })
        $asset.hostname('server05')
        $asset.ip('0.0.0.0')
        { $asset.Save() } | Should -Throw -ExpectedMessage '*ip not allowed*'
        $asset.ip('10.0.0.5')
        $asset.Save()
        $asset.Id | Should -BeGreaterThan 0
        @($script:Saved10).Count | Should -Be 1
    }
}

Describe 'BASE-01 test scripts run on Windows PowerShell 5.1' -Tag 'BASE-01' {
    BeforeAll {
        $script:RepoRoot01 = Split-Path -Parent $PSScriptRoot
        $script:TestScripts01 = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)

        # Returns one object per Join-Path call in the file: the line number and the number of positional
        # arguments (or 99 when -AdditionalChildPath is used). The three-argument form only exists on
        # PowerShell 6+, so anything above 2 breaks discovery on Windows PowerShell 5.1.
        function Get-JoinPathUsage01 {
            param([string]$Path)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0 -Because "$Path must parse on this host"
            $calls = $ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.CommandAst]) -and ($node.GetCommandName() -eq 'Join-Path')
            }, $true)
            foreach ($call in $calls) {
                $positional = 0
                $expectValue = $false
                foreach ($element in @($call.CommandElements | Select-Object -Skip 1)) {
                    if ($expectValue) { $expectValue = $false; continue }
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                        if ($element.ParameterName -eq 'AdditionalChildPath') { $positional = 99 }
                        if (($null -eq $element.Argument) -and ($element.ParameterName -ne 'Resolve')) { $expectValue = $true }
                        continue
                    }
                    $positional++
                }
                [pscustomobject]@{ File = (Split-Path -Leaf $Path); Line = $call.Extent.StartLineNumber; Positional = $positional }
            }
        }
    }
    AfterAll { Close-DbConnections }

    It 'the three-argument Join-Path form is rejected on Windows PowerShell 5.1 and accepted on 7' {
        # Invoked through the call operator so the AST scan below does not see a literal three-argument call.
        $joinPath = Get-Command -Name 'Join-Path' -CommandType Cmdlet
        $probe = { & $joinPath $PSScriptRoot '..' 'output' }
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $probe | Should -Throw -ExpectedMessage '*positional parameter*'
        } else {
            $probe | Should -Not -Throw
        }
    }

    It 'every script under Tests parses and joins paths two pieces at a time' {
        $script:TestScripts01.Count | Should -BeGreaterThan 0
        $offenders = @()
        foreach ($file in $script:TestScripts01) {
            $usage = @(Get-JoinPathUsage01 -Path $file.FullName)
            $usage.Count | Should -BeGreaterThan 0 -Because "$($file.Name) is expected to build at least one path with Join-Path"
            $offenders += @($usage | Where-Object { $_.Positional -gt 2 })
        }
        ($offenders | ForEach-Object { "{0}:{1} ({2} positional arguments)" -f $_.File, $_.Line, $_.Positional }) | Should -BeNullOrEmpty
    }

    It 'the test files import the module from this repository output folder, not an installed copy' {
        $expectedRoot = Join-Path (Join-Path $script:RepoRoot01 'output') 'PSCsvSQLiteORM'
        $command = Get-Command -Name 'Import-CsvToSqlite' -CommandType Function
        $command.Module | Should -Not -BeNullOrEmpty
        $command.Module.ModuleBase | Should -BeLike ($expectedRoot + '*')
    }

    It 'SampleModuleTest.ps1 runs to completion on this host' {
        $sample = Join-Path $PSScriptRoot 'SampleModuleTest.ps1'
        Test-Path -LiteralPath $sample | Should -BeTrue
        { $script:SampleOutput01 = @(& $sample *>&1) } | Should -Not -Throw
        $errors = @($script:SampleOutput01 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        ($errors | ForEach-Object { $_.ToString() }) | Should -BeNullOrEmpty
    }
}
