# Functional tests for PSCsvSQLiteORM

# Import the build of the version declared in source\PSCsvSQLiteORM.psd1 (BUG-077, see Tests\TestSupport.ps1)
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Import-Module (Get-OrmBuiltManifestPath) -Force

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

    It 'Strict requires an existing table and rejects a CSV header the table lacks' {
        $db = Join-Path $script:Root064 'strict.db'
        { Import-CsvToSqlite -CsvPath $script:Assets064 -Database $db -TableName assets -SchemaMode Strict } |
            Should -Throw -ExpectedMessage "*Strict mode: table 'assets' does not exist.*"
        Import-CsvToSqlite -CsvPath $script:Assets064 -Database $db -TableName assets | Out-Null
        Import-CsvToSqlite -CsvPath (New-Csv064 'assets_strict_more.csv' "id,hostname,ip`r`n8,server08,10.0.0.8") -Database $db -TableName assets -SchemaMode Strict | Out-Null
        Get-Count064 $db 'assets' | Should -Be 4
        $extra = New-Csv064 'assets_extra.csv' "id,hostname,ip,extra`r`n9,server09,10.0.0.9,x"
        { Import-CsvToSqlite -CsvPath $extra -Database $db -TableName assets -SchemaMode Strict } |
            Should -Throw -ExpectedMessage '*Strict mode: missing column extra in assets*'
        Get-Count064 $db 'assets' | Should -Be 4
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
            foreach ($m in [regex]::Matches($b.Groups[1].Value, '(?m)^\s*(?:\$\w+\s*=\s*)?((?:Import|Initialize|Export|Set|New|Find|Confirm|Invoke|Close|Update|Start|Complete|Undo|Get|Add|Enable|Test|Write|Remove)-\w+)')) {
                $called += $m.Groups[1].Value
            }
        }
        $called = @($called | Where-Object { $_ -ne 'Import-Module' -and $_ -ne 'Install-Module' } | Sort-Object -Unique)
        $called.Count | Should -BeGreaterThan 5
        foreach ($c in $called) { $exported | Should -Contain $c }
    }

    It 'the README Quick Start blocks 3-8 run line by line without an error on this host' {
        # Blocks 1-8 are the Quick Start; later blocks (section 9) are executed by the DOCS-320 container.
        $script:Blocks10.Count | Should -BeGreaterOrEqual 8
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
        # Other test files may already have registered DynamicAssets for another database; the README documents the suffix
        $asset.GetType().Name | Should -Match '^DynamicAssets(_[0-9a-f]{8})?$'
        $asset.Id | Should -Be 0
        $found.Id | Should -Be 1
        $found.ip() | Should -Be '10.0.0.1'
        (Get-Rows10 $rows).Count | Should -Be 3
        @($vulns).Count | Should -Be 2
        $vulns[0].GetType().Name | Should -Match '^DynamicVulns(_[0-9a-f]{8})?$'
        $owner.GetType().Name | Should -Match '^DynamicAssets(_[0-9a-f]{8})?$'
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

Describe 'BUG-059 BUG-060 BUG-076 BUG-077 build-module.ps1 builds the manifest version from any directory' -Tag 'BUG-059', 'BUG-060', 'BUG-076', 'BUG-077' {
    BeforeAll {
        $script:RepoRoot59 = Split-Path -Parent $PSScriptRoot
        $script:Root59 = Join-Path $env:TEMP ("orm_build_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Root59 -Force | Out-Null
        $script:Copy59 = Join-Path $script:Root59 'repo'
        New-Item -ItemType Directory -Path $script:Copy59 -Force | Out-Null
        Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot59 'source') -Destination (Join-Path $script:Copy59 'source')
        Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot59 'docs') -Destination (Join-Path $script:Copy59 'docs')
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot59 'build-module.ps1') -Destination (Join-Path $script:Copy59 'build-module.ps1')
        $script:BuildScript59 = Join-Path $script:Copy59 'build-module.ps1'
        $script:SourceManifest59 = Join-Path (Join-Path $script:Copy59 'source') 'PSCsvSQLiteORM.psd1'
        $script:Public59 = Join-Path (Join-Path $script:Copy59 'source') 'Public'
        $script:BuiltBase59 = Join-Path (Join-Path $script:Copy59 'output') 'PSCsvSQLiteORM'
        $script:PublicCount59 = @(Get-ChildItem -Path (Join-Path (Join-Path $script:RepoRoot59 'source') 'Public') -Filter '*.ps1' -File).Count

        # Bump the copied source manifest without touching the script: the build must follow the manifest.
        $script:BumpedVersion59 = '9.9.9'
        $raw = Get-Content -LiteralPath $script:SourceManifest59 -Raw
        # Anchor to the line start: the RequiredModules entry also carries a ModuleVersion key (PSSQLite pin) that must stay untouched
        $raw = $raw -replace "(?m)^ModuleVersion\s*=\s*'[^']+'", ("ModuleVersion = '{0}'" -f $script:BumpedVersion59)
        Set-Content -LiteralPath $script:SourceManifest59 -Value $raw -NoNewline -Encoding ASCII

        # Runs the copied build script in a child process of THIS host from an unrelated directory.
        # That directory is an empty sibling of the copied repo: when ModuleBuilder is given a folder it
        # searches the current location recursively for a *.psd1, so running from a parent of the copy
        # (or from the copy itself) would still find the manifest and hide BUG-060.
        $script:Cwd59 = Join-Path $script:Root59 'elsewhere'
        New-Item -ItemType Directory -Path $script:Cwd59 -Force | Out-Null
        $script:HostExe59 = (Get-Process -Id $PID).Path
        function Invoke-Build59 {
            param([string[]]$ScriptArgs = @())
            $callArgs = @('-NoProfile')
            if ($PSVersionTable.PSVersion.Major -lt 6) { $callArgs += @('-ExecutionPolicy', 'Bypass') }
            $callArgs += @('-File', $script:BuildScript59) + $ScriptArgs
            Push-Location -LiteralPath $script:Cwd59
            try {
                # Stderr from the child host arrives as error records; they are build output here, not test errors.
                $lines = @(& { $ErrorActionPreference = 'Continue'; & $script:HostExe59 @callArgs 2>&1 } | ForEach-Object { [string]$_ })
                $code = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            return [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = ($lines -join "`n") }
        }

        function Get-BuiltVersion59([string]$Version) {
            $psd1 = Join-Path (Join-Path $script:BuiltBase59 $Version) 'PSCsvSQLiteORM.psd1'
            if (-not (Test-Path -LiteralPath $psd1)) { return $null }
            return [string](Import-PowerShellDataFile -Path $psd1).ModuleVersion
        }

        $script:DefaultRun59 = Invoke-Build59
    }
    AfterAll {
        Close-DbConnections
        if ($script:Root59 -and (Test-Path -LiteralPath $script:Root59)) {
            Remove-Item -LiteralPath $script:Root59 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'BUG-060: succeeds when the current directory is not the repository root' {
        # Guard the test itself: the working directory must hold no manifest and must not contain the copy.
        @(Get-ChildItem -LiteralPath $script:Cwd59 -Recurse -Filter '*.psd1' -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        $script:Copy59 | Should -Not -BeLike ($script:Cwd59.TrimEnd('\') + '\*')
        $script:DefaultRun59.Text | Should -Not -Match 'determine the module manifest'
        $script:DefaultRun59.Text | Should -Not -Match 'Build failed'
        $script:DefaultRun59.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path (Join-Path $script:BuiltBase59 $script:BumpedVersion59) 'PSCsvSQLiteORM.psm1') | Should -BeTrue
    }

    It 'BUG-059: the built version comes from the source manifest, not a value hardcoded in the script' {
        $script:DefaultRun59.Text | Should -Match ("Building PSCsvSQLiteORM version {0}" -f [regex]::Escape($script:BumpedVersion59))
        Get-BuiltVersion59 $script:BumpedVersion59 | Should -Be $script:BumpedVersion59
        $folders = @(Get-ChildItem -LiteralPath $script:BuiltBase59 -Directory | ForEach-Object { $_.Name })
        $folders | Should -Be @($script:BumpedVersion59)
    }

    It 'BUG-059: the script declares no default version of its own' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BuildScript59, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $versionParam = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' }
        $versionParam | Should -Not -BeNullOrEmpty
        $versionParam.DefaultValue | Should -BeNullOrEmpty
        $sourceVersion = [string](Import-PowerShellDataFile -Path (Join-Path (Join-Path $script:RepoRoot59 'source') 'PSCsvSQLiteORM.psd1')).ModuleVersion
        (Get-Content -LiteralPath $script:BuildScript59 -Raw) | Should -Not -Match ("'{0}'" -f [regex]::Escape($sourceVersion))
    }

    It 'BUG-059: an explicit -Version still overrides the manifest' {
        $run = Invoke-Build59 -ScriptArgs @('-Version', '1.2.3')
        $run.ExitCode | Should -Be 0
        $run.Text | Should -Match 'Building PSCsvSQLiteORM version 1\.2\.3'
        Get-BuiltVersion59 '1.2.3' | Should -Be '1.2.3'
        @($run.Lines | Where-Object { $_.Trim() -eq 'Module imported successfully. Version: 1.2.3' }).Count | Should -Be 1
    }

    It 'BUG-076: the self-test reports the version and command count of the module it just built' {
        $versionLines = @($script:DefaultRun59.Lines | Where-Object { $_ -match 'Module imported successfully' })
        $versionLines.Count | Should -Be 1
        $versionLines[0].Trim() | Should -Be ("Module imported successfully. Version: {0}" -f $script:BumpedVersion59)
        $commandLines = @($script:DefaultRun59.Lines | Where-Object { $_ -match 'Exported commands:' })
        $commandLines.Count | Should -Be 1
        $commandLines[0].Trim() | Should -Be ("Exported commands: {0}" -f $script:PublicCount59)
        $script:PublicCount59 | Should -BeGreaterThan 2
    }

    It 'BUG-076: the self-test fails the build when the built module does not export every public function' {
        # A Public file that defines no function makes the source Public count exceed the exported command
        # count; the self-test must fail loudly instead of printing whatever Get-Module happened to return.
        $stub = Join-Path $script:Public59 'Zz-NotAFunction.ps1'
        Set-Content -LiteralPath $stub -Value '# no function here' -Encoding ASCII
        try {
            $run = Invoke-Build59 -ScriptArgs @('-Version', '2.0.0')
            $run.ExitCode | Should -Not -Be 0
            $run.Text | Should -Match 'Module import test failed'
            $run.Text | Should -Not -Match 'Module imported successfully'
        } finally {
            Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue
        }
    }

    It 'BUG-077: a build removes stale version folders so output holds only the version just built' -Tag 'BUG-077' {
        # A leftover folder with a HIGHER version than the build: Import-Module on the unversioned output
        # folder would pick it over the build just made, so the build script must clear it.
        $stale = Join-Path $script:BuiltBase59 '99.0.0'
        New-Item -ItemType Directory -Path $stale -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $stale 'PSCsvSQLiteORM.psd1') -Value "@{ ModuleVersion = '99.0.0' }" -Encoding ASCII
        @(Get-ChildItem -LiteralPath $script:BuiltBase59 -Directory).Count | Should -BeGreaterThan 1
        $run = Invoke-Build59 -ScriptArgs @('-Version', '3.3.3')
        $run.ExitCode | Should -Be 0
        @($run.Lines | Where-Object { $_.Trim() -eq 'Module imported successfully. Version: 3.3.3' }).Count | Should -Be 1
        $folders = @(Get-ChildItem -LiteralPath $script:BuiltBase59 -Directory | ForEach-Object { $_.Name })
        $folders | Should -Be @('3.3.3')
        Test-Path -LiteralPath $stale | Should -BeFalse
    }
}

Describe 'E2E1-031 build-module.ps1 ships docs and Examples and verifies that they arrived' -Tag 'E2E1-031' {
    BeforeAll {
        $script:RepoRoot31 = Split-Path -Parent $PSScriptRoot
        $script:AboutTopic31 = 'about_PSCsvSQLiteORM.help.txt'

        # The build the whole suite imports: docs\, en-US\ and Examples\ must be part of it.
        # Dot-source the helper here as well: functions defined while the container is discovered are not
        # in scope inside BeforeAll on either host.
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:BuiltRoot31 = Split-Path -Parent (Get-OrmBuiltManifestPath -RepoRoot $script:RepoRoot31)

        $script:Root31 = Join-Path $env:TEMP ("orm_ship_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Root31 -Force | Out-Null
        $script:Copy31 = Join-Path $script:Root31 'repo'
        New-Item -ItemType Directory -Path $script:Copy31 -Force | Out-Null
        Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot31 'source') -Destination (Join-Path $script:Copy31 'source')
        Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot31 'docs') -Destination (Join-Path $script:Copy31 'docs')
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot31 'build-module.ps1') -Destination (Join-Path $script:Copy31 'build-module.ps1')
        $script:BuildScript31 = Join-Path $script:Copy31 'build-module.ps1'
        $script:Version31 = [string](Import-PowerShellDataFile -Path (Join-Path (Join-Path $script:Copy31 'source') 'PSCsvSQLiteORM.psd1')).ModuleVersion
        $script:BuiltBase31 = Join-Path (Join-Path $script:Copy31 'output') 'PSCsvSQLiteORM'
        $script:HostExe31 = (Get-Process -Id $PID).Path

        # Runs the copied build script in a child process of THIS host, so the build never disturbs the
        # module loaded into the test session.
        function Invoke-Build31 {
            $callArgs = @('-NoProfile')
            if ($PSVersionTable.PSVersion.Major -lt 6) { $callArgs += @('-ExecutionPolicy', 'Bypass') }
            $callArgs += @('-File', $script:BuildScript31)
            # Stderr from the child host arrives as error records; they are build output here, not test errors.
            $lines = @(& { $ErrorActionPreference = 'Continue'; & $script:HostExe31 @callArgs 2>&1 } | ForEach-Object { [string]$_ })
            $code = $LASTEXITCODE
            return [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = ($lines -join "`n") }
        }
    }
    AfterAll {
        Close-DbConnections
        if ($script:Root31 -and (Test-Path -LiteralPath $script:Root31)) {
            Remove-Item -LiteralPath $script:Root31 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'E2E1-031: the build under test carries the about topic, its en-US copy and the settings example' {
        # README points at Examples\orm.settings.ps1 inside the module folder, and Get-Help looks for the
        # about topic in the module's culture folder; both have to exist in the module the tests import.
        Test-Path -LiteralPath (Join-Path (Join-Path $script:BuiltRoot31 'docs') $script:AboutTopic31) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $script:BuiltRoot31 'en-US') $script:AboutTopic31) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $script:BuiltRoot31 'Examples') 'orm.settings.ps1') | Should -BeTrue
        $shipped = Get-Content -LiteralPath (Join-Path (Join-Path $script:BuiltRoot31 'en-US') $script:AboutTopic31) -Raw
        $source = Get-Content -LiteralPath (Join-Path (Join-Path $script:RepoRoot31 'docs') $script:AboutTopic31) -Raw
        $shipped | Should -Be $source
    }

    It 'E2E1-031: a build copies docs, en-US and Examples into the built module folder' {
        $run = Invoke-Build31
        $run.ExitCode | Should -Be 0
        $run.Text | Should -Match 'Successfully built'
        $built = Join-Path $script:BuiltBase31 $script:Version31
        Test-Path -LiteralPath (Join-Path (Join-Path $built 'docs') $script:AboutTopic31) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $built 'en-US') $script:AboutTopic31) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Join-Path $built 'Examples') 'orm.settings.ps1') | Should -BeTrue
    }

    It 'E2E1-031: the build fails instead of reporting success when docs and Examples do not ship' {
        # Before the post-build check the script skipped both copies without a word and still printed
        # "Successfully built", so an incomplete module shipped with no signal at all.
        $docsCopy = Join-Path $script:Copy31 'docs'
        $examplesCopy = Join-Path (Join-Path $script:Copy31 'source') 'Examples'
        $docsBackup = Join-Path $script:Root31 'docs_backup'
        $examplesBackup = Join-Path $script:Root31 'examples_backup'
        Copy-Item -Recurse -LiteralPath $docsCopy -Destination $docsBackup
        Copy-Item -Recurse -LiteralPath $examplesCopy -Destination $examplesBackup
        Remove-Item -LiteralPath $docsCopy -Recurse -Force
        Remove-Item -LiteralPath $examplesCopy -Recurse -Force
        try {
            $run = Invoke-Build31
            $run.ExitCode | Should -Not -Be 0
            $run.Text | Should -Match 'Build incomplete'
            $run.Text | Should -Match 'about_PSCsvSQLiteORM\.help\.txt'
            $run.Text | Should -Match 'orm\.settings\.ps1'
            $run.Text | Should -Not -Match 'Successfully built'
        }
        finally {
            Copy-Item -Recurse -LiteralPath $docsBackup -Destination $docsCopy
            Copy-Item -Recurse -LiteralPath $examplesBackup -Destination $examplesCopy
            Remove-Item -LiteralPath $docsBackup -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $examplesBackup -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'BUG-061 publish-module.ps1 publishes the committed build of this checkout' -Tag 'BUG-061' {
    BeforeAll {
        $script:RepoRoot61 = Split-Path -Parent $PSScriptRoot
        # Keep the path short: git object paths under this copy must stay below the 260 character limit
        # regardless of how long the caller's TEMP directory is.
        $script:Root61 = Join-Path $env:TEMP ("p61_{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $script:Copy61 = Join-Path $script:Root61 'r'
        New-Item -ItemType Directory -Path $script:Copy61 -Force | Out-Null
        foreach ($item in @('source', 'docs')) {
            Copy-Item -Recurse -LiteralPath (Join-Path $script:RepoRoot61 $item) -Destination (Join-Path $script:Copy61 $item)
        }
        foreach ($item in @('build-module.ps1', 'publish-module.ps1', '.gitignore')) {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot61 $item) -Destination (Join-Path $script:Copy61 $item)
        }
        $script:PublishScript61 = Join-Path $script:Copy61 'publish-module.ps1'
        $script:Version61 = [string](Import-PowerShellDataFile -Path (Join-Path (Join-Path $script:Copy61 'source') 'PSCsvSQLiteORM.psd1')).ModuleVersion
        $script:ExpectedBase61 = Join-Path (Join-Path (Join-Path $script:Copy61 'output') 'PSCsvSQLiteORM') $script:Version61
        $script:FakeKey61 = 'oy2fakekeyfakekeyfakekeyfakekey'

        # The copy is its own git repository with everything committed, so the clean tree check can pass.
        $script:Git61 = Get-Command git -ErrorAction SilentlyContinue
        function Invoke-Git61 { param([string[]]$GitArgs) & $script:Git61.Source -C $script:Copy61 @GitArgs 2>&1 | Out-Null }
        if ($script:Git61) {
            Invoke-Git61 @('-c', 'core.longpaths=true', 'init', '-q')
            Invoke-Git61 @('config', 'core.longpaths', 'true')
            Invoke-Git61 @('config', 'user.email', 'test@example.com')
            Invoke-Git61 @('config', 'user.name', 'Pester')
            Invoke-Git61 @('config', 'commit.gpgsign', 'false')
            Invoke-Git61 @('add', '-A')
            Invoke-Git61 @('commit', '-q', '-m', 'baseline')
        }

        # A driver script for a child process of THIS host: it stubs Publish-Module so nothing reaches a
        # repository, then runs the copied publish script from an unrelated directory with the given arguments.
        $script:Cwd61 = Join-Path $script:Root61 'elsewhere'
        New-Item -ItemType Directory -Path $script:Cwd61 -Force | Out-Null
        $script:Driver61 = Join-Path $script:Root61 'publish_driver.ps1'
        $driver = @'
param([string]$Script, [string]$NuGetApiKey, [switch]$WhatIf, [switch]$SkipBuild, [switch]$AllowDirty)
function Publish-Module {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$NuGetApiKey, [string]$Repository)
    "STUB Publish-Module Path=$Path Repository=$Repository KeyLength=$($NuGetApiKey.Length)"
}
$splat = @{ NuGetApiKey = $NuGetApiKey; WhatIf = $WhatIf; SkipBuild = $SkipBuild; AllowDirty = $AllowDirty }
& $Script @splat
'@
        Set-Content -LiteralPath $script:Driver61 -Value $driver -Encoding ASCII
        $script:HostExe61 = (Get-Process -Id $PID).Path
        function Invoke-Publish61 {
            param([string[]]$ScriptArgs = @())
            $callArgs = @('-NoProfile')
            if ($PSVersionTable.PSVersion.Major -lt 6) { $callArgs += @('-ExecutionPolicy', 'Bypass') }
            $callArgs += @('-File', $script:Driver61, '-Script', $script:PublishScript61) + $ScriptArgs
            Push-Location -LiteralPath $script:Cwd61
            try {
                $lines = @(& { $ErrorActionPreference = 'Continue'; & $script:HostExe61 @callArgs 2>&1 } | ForEach-Object { [string]$_ })
                $code = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            # Windows PowerShell 5.1 word-wraps a child process's warning and error streams at the console
            # width, and where the wrap falls depends on the length of the temp path. Flat joins all lines
            # and collapses whitespace so phrase matches do not depend on that wrapping.
            $flat = (($lines -join ' ') -replace '\s+', ' ')
            return [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = ($lines -join "`n"); Flat = $flat }
        }
    }
    AfterAll {
        Close-DbConnections
        if ($script:Root61 -and (Test-Path -LiteralPath $script:Root61)) {
            Remove-Item -LiteralPath $script:Root61 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'BUG-061: the script references no machine-specific path, no build-and-test.ps1 and never prints part of the key' {
        $text = Get-Content -LiteralPath $script:PublishScript61 -Raw
        $text | Should -Not -Match '(?i)C:\\Users'
        $text | Should -Not -Match 'build-and-test'
        $text | Should -Match 'build-module\.ps1'
        $text | Should -Not -Match 'NuGetApiKey\.Substring'
    }

    It 'BUG-061: builds with build-module.ps1 and publishes the output folder next to the script' {
        if (-not $script:Git61) { Set-ItResult -Skipped -Because 'git is not available' }
        $run = Invoke-Publish61 -ScriptArgs @('-NuGetApiKey', $script:FakeKey61, '-WhatIf')
        $run.Text | Should -Not -Match 'build-and-test'
        $run.Text | Should -Match ("Building PSCsvSQLiteORM version {0}" -f [regex]::Escape($script:Version61))
        $run.Text | Should -Match ("Preparing to publish PSCsvSQLiteORM v{0} from {1}" -f [regex]::Escape($script:Version61), [regex]::Escape($script:ExpectedBase61))
        $stub = @($run.Lines | Where-Object { $_ -like 'STUB Publish-Module *' })
        $stub.Count | Should -Be 1
        $stub[0] | Should -Be ("STUB Publish-Module Path={0} Repository=PSGallery KeyLength={1}" -f $script:ExpectedBase61, $script:FakeKey61.Length)
        $run.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:ExpectedBase61 'PSCsvSQLiteORM.psm1') | Should -BeTrue
    }

    It 'BUG-061: no fragment of the API key appears in the output' {
        if (-not $script:Git61) { Set-ItResult -Skipped -Because 'git is not available' }
        $run = Invoke-Publish61 -ScriptArgs @('-NuGetApiKey', $script:FakeKey61, '-WhatIf', '-SkipBuild')
        $run.ExitCode | Should -Be 0
        $run.Text | Should -Not -Match ([regex]::Escape($script:FakeKey61.Substring(0, 6)))
        $run.Text | Should -Match ("len={0}" -f $script:FakeKey61.Length)
    }

    It 'BUG-061: refuses to publish a working tree with uncommitted changes unless -AllowDirty is given' {
        if (-not $script:Git61) { Set-ItResult -Skipped -Because 'git is not available' }
        $dirty = Join-Path (Join-Path $script:Copy61 'source') 'PSCsvSQLiteORM.psd1'
        Add-Content -LiteralPath $dirty -Value '# uncommitted edit' -Encoding ASCII
        try {
            $run = Invoke-Publish61 -ScriptArgs @('-NuGetApiKey', $script:FakeKey61, '-WhatIf', '-SkipBuild')
            $run.ExitCode | Should -Not -Be 0
            $run.Flat | Should -Match 'Refusing to publish'
            $run.Flat | Should -Match 'source/PSCsvSQLiteORM\.psd1'
            @($run.Lines | Where-Object { $_ -like 'STUB Publish-Module *' }).Count | Should -Be 0

            $forced = Invoke-Publish61 -ScriptArgs @('-NuGetApiKey', $script:FakeKey61, '-WhatIf', '-SkipBuild', '-AllowDirty')
            $forced.ExitCode | Should -Be 0
            $forced.Flat | Should -Match 'uncommitted or untracked changes'
            @($forced.Lines | Where-Object { $_ -like 'STUB Publish-Module *' }).Count | Should -Be 1
        } finally {
            Invoke-Git61 @('checkout', '--', 'source/PSCsvSQLiteORM.psd1')
        }
    }

    It 'BUG-061: refuses when the checkout is not a git repository unless -AllowDirty is given' {
        if (-not $script:Git61) { Set-ItResult -Skipped -Because 'git is not available' }
        $gitDir = Join-Path $script:Copy61 '.git'
        $parked = Join-Path $script:Root61 'git_parked'
        Move-Item -LiteralPath $gitDir -Destination $parked
        try {
            $run = Invoke-Publish61 -ScriptArgs @('-NuGetApiKey', $script:FakeKey61, '-WhatIf', '-SkipBuild')
            $run.ExitCode | Should -Not -Be 0
            $run.Flat | Should -Match 'not a git repository'
            @($run.Lines | Where-Object { $_ -like 'STUB Publish-Module *' }).Count | Should -Be 0

            $forced = Invoke-Publish61 -ScriptArgs @('-NuGetApiKey', $script:FakeKey61, '-WhatIf', '-SkipBuild', '-AllowDirty')
            $forced.ExitCode | Should -Be 0
            @($forced.Lines | Where-Object { $_ -like 'STUB Publish-Module *' }).Count | Should -Be 1
        } finally {
            Move-Item -LiteralPath $parked -Destination $gitDir
        }
    }
}

Describe 'BUG-080 no database artifact is tracked under Tests and .gitignore names only real things' -Tag 'BUG-080' {
    BeforeAll {
        $script:RepoRoot80 = Split-Path -Parent $PSScriptRoot
        $script:IgnoreLines80 = @(Get-Content -LiteralPath (Join-Path $script:RepoRoot80 '.gitignore') | ForEach-Object { $_.Trim() })
        $script:Git80 = Get-Command git -ErrorAction SilentlyContinue
        # Runs git against this checkout; ExitCode 128 means the checkout is not a git repository (for example
        # an extracted archive), in which case the git-backed assertions are skipped rather than failed.
        function Invoke-Git80 {
            param([string[]]$GitArgs)
            $lines = @(& { $ErrorActionPreference = 'Continue'; & $script:Git80.Source -C $script:RepoRoot80 @GitArgs 2>&1 } | ForEach-Object { [string]$_ })
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
        }
    }

    It 'BUG-080: Tests/sample.db is not present in the working tree' {
        Test-Path -LiteralPath (Join-Path $PSScriptRoot 'sample.db') | Should -BeFalse
    }

    It 'BUG-080: git tracks no .db file under Tests' {
        if (-not $script:Git80) { Set-ItResult -Skipped -Because 'git is not available' }
        $run = Invoke-Git80 @('ls-files', '--', 'Tests/*.db')
        if ($run.ExitCode -eq 128) { Set-ItResult -Skipped -Because 'the checkout is not a git repository' }
        $run.ExitCode | Should -Be 0
        @($run.Lines | Where-Object { $_ -ne '' }) | Should -BeNullOrEmpty
    }

    It 'BUG-080: the ignore rules exclude Tests/sample.db and Tests/tmp' {
        $script:IgnoreLines80 | Should -Contain '*.db'
        $script:IgnoreLines80 | Should -Contain 'Tests/tmp/'
        if (-not $script:Git80) { Set-ItResult -Skipped -Because 'git is not available' }
        foreach ($path in @('Tests/sample.db', 'Tests/tmp/orm_func_x.db')) {
            $run = Invoke-Git80 @('check-ignore', '--no-index', '-q', '--', $path)
            if ($run.ExitCode -eq 128) { Set-ItResult -Skipped -Because 'the checkout is not a git repository' }
            $run.ExitCode | Should -Be 0 -Because "$path must match an ignore rule"
        }
    }

    It 'BUG-080: .gitignore does not name scripts that do not exist and does not ignore the committed scripts' {
        $script:IgnoreLines80 | Should -Not -Contain 'build-and-test.ps1'
        $script:IgnoreLines80 | Should -Not -Contain 'publish.ps1'
        foreach ($name in @('build-module.ps1', 'publish-module.ps1')) {
            Test-Path -LiteralPath (Join-Path $script:RepoRoot80 $name) | Should -BeTrue -Because "$name is the committed script"
            $script:IgnoreLines80 | Should -Not -Contain $name
        }
        if (-not $script:Git80) { Set-ItResult -Skipped -Because 'git is not available' }
        foreach ($name in @('build-module.ps1', 'publish-module.ps1')) {
            $run = Invoke-Git80 @('check-ignore', '--no-index', '-q', '--', $name)
            if ($run.ExitCode -eq 128) { Set-ItResult -Skipped -Because 'the checkout is not a git repository' }
            $run.ExitCode | Should -Be 1 -Because "$name must not be ignored"
        }
    }
}

Describe 'Write-DbLog defaults to INFO when -Level is omitted' -Tag 'E2E1-028' {
    BeforeAll {
        # Unique directory inside TEMP so concurrent runs cannot share the log file.
        $script:Dir028 = Join-Path $env:TEMP ("orm_e2e1028_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Dir028 | Out-Null
        $script:Log028 = Join-Path $script:Dir028 'log028.log'
        function Get-Log028Text {
            if (-not (Test-Path -LiteralPath $script:Log028)) { return '' }
            return [string](Get-Content -LiteralPath $script:Log028 -Raw)
        }
    }
    AfterAll {
        # Restore the module's import-time logging defaults so later containers are unaffected.
        Set-DbLogging -Level INFO -Path $null
        Close-DbConnections
        if ($script:Dir028 -and (Test-Path -LiteralPath $script:Dir028)) {
            Remove-Item -LiteralPath $script:Dir028 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'E2E1-028: writes the message and labels it INFO when no -Level is given' {
        Remove-Item -LiteralPath $script:Log028 -Force -ErrorAction SilentlyContinue
        Set-DbLogging -Level DEBUG -Path $script:Log028
        Write-DbLog -Message 'no level given'
        Write-DbLog -Level INFO -Message 'level given'

        $text = Get-Log028Text
        $text | Should -Match 'no level given'
        $text | Should -Match '\[INFO\] no level given'
        $text | Should -Match '\[INFO\] level given'
    }

    It 'E2E1-028: the defaulted level is still filtered by the configured threshold' {
        Remove-Item -LiteralPath $script:Log028 -Force -ErrorAction SilentlyContinue
        Set-DbLogging -Level WARN -Path $script:Log028
        Write-DbLog -Message 'default level below threshold'
        Write-DbLog -Level WARN -Message 'warn above threshold'

        $text = Get-Log028Text
        $text | Should -Not -Match 'default level below threshold'
        $text | Should -Match '\[WARN\] warn above threshold'
    }

    It 'E2E1-028: with no log path the defaulted level still reaches the verbose stream' {
        Set-DbLogging -Level DEBUG -Path $null
        $verbose = @(Write-DbLog -Message 'verbose without level' -Verbose 4>&1 | ForEach-Object { [string]$_ })
        ($verbose -join ' ') | Should -Match '\[INFO\] verbose without level'
    }
}

# The 3.2.0 documentation pass: every statement the README and the about topic make about this build is
# executed here, and the README's own section 9 block is run line by line the way BASE-10 runs blocks 3-8.
Describe 'DOCS-320 the documentation describes the build under test' -Tag 'DOCS-320' {
    BeforeAll {
        # Functions dot-sourced at container level are not in scope inside BeforeAll on either host.
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:RepoRoot320 = Split-Path -Parent $PSScriptRoot
        $script:Readme320 = Get-Content -LiteralPath (Join-Path $script:RepoRoot320 'README.md') -Raw
        $script:HelpPath320 = Join-Path (Join-Path $script:RepoRoot320 'docs') 'about_PSCsvSQLiteORM.help.txt'
        $script:Help320 = Get-Content -LiteralPath $script:HelpPath320 -Raw
        $script:SamplePath320 = Join-Path (Join-Path (Join-Path $script:RepoRoot320 'source') 'Examples') 'orm.settings.ps1'
        $script:Manifest320 = Import-PowerShellDataFile -Path (Join-Path (Join-Path $script:RepoRoot320 'source') 'PSCsvSQLiteORM.psd1')
        $script:Blocks320 = @([regex]::Matches($script:Readme320, '(?s)```powershell\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value })

        $script:Root320 = Join-Path $env:TEMP ("orm_docs320_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:Root320 -Force | Out-Null
        Initialize-ORMVars -LogLevel ERROR
        $script:Assets320 = Join-Path $PSScriptRoot 'assets.csv'
        $script:Vulns320 = Join-Path $PSScriptRoot 'vulns.csv'
        # The database README section 9 is written against: the Quick Start's two tables and its relationship.
        $script:Db320 = Join-Path $script:Root320 'myapp.db'
        Import-CsvToSqlite -CsvPath $script:Assets320 -Database $script:Db320 -TableName assets | Out-Null
        Import-CsvToSqlite -CsvPath $script:Vulns320 -Database $script:Db320 -TableName vulns | Out-Null
        Confirm-DbForeignKey -Database $script:Db320 -From vulns -Column asset_id -To assets | Out-Null

        function New-Csv320([string]$Name, [string]$Content) {
            $f = Join-Path $script:Root320 $Name
            Set-Content -LiteralPath $f -Value $Content -Encoding ASCII
            return $f
        }
    }
    AfterAll {
        Close-DbConnections
        if ($script:Root320 -and (Test-Path -LiteralPath $script:Root320)) {
            Remove-Item -LiteralPath $script:Root320 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'E2E1-010: the manifest and the README name the version that exports the new commands' {
        $script:Manifest320.ModuleVersion | Should -Be '3.2.0'
        $notes = [string]$script:Manifest320.PrivateData.PSData.ReleaseNotes
        $notes | Should -Match '(?m)^v3\.2\.0\s*$'
        $notes | Should -Not -Match 'Unreleased'
        $script:Readme320 | Should -Match 'RequiredVersion 3\.2\.0'
        $script:Readme320 | Should -Not -Match 'RequiredVersion 3\.1\.3'
        $script:Help320 | Should -Match '3\.2\.0'
        foreach ($c in @('New-DynamicRecord', 'Remove-DbForeignKey', 'Test-DbTransaction')) {
            (Get-Command -Name $c -Module PSCsvSQLiteORM -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
            $script:Readme320 | Should -Match ([regex]::Escape($c))
            $script:Help320 | Should -Match ([regex]::Escape($c))
        }
    }

    It 'E2E1-024: the help topic describes Strict the way the code behaves' {
        $script:Help320 | Should -Not -Match 'Strict\s+create the table if missing'
        $script:Help320 | Should -Match 'Strict\s+the table must already exist'
        $db = Join-Path $script:Root320 'strict320.db'
        { Import-CsvToSqlite -CsvPath $script:Assets320 -Database $db -TableName assets -SchemaMode Strict } |
            Should -Throw -ExpectedMessage "*Strict mode: table 'assets' does not exist.*"
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='assets'").Count |
            Should -Be 0
    }

    It 'E2E1-025: Import-CsvToSqlite returns the trimmed headers, as both documents now say' {
        $script:Readme320 | Should -Match 'returns the trimmed CSV header names'
        $script:Help320 | Should -Match 'returns the trimmed CSV header names'
        $db = Join-Path $script:Root320 'ret320.db'
        $csv = New-Csv320 'ret320.csv' "id, hostname ,ip`r`n1,server01,10.0.0.1"
        $ret = Import-CsvToSqlite -CsvPath $csv -Database $db -TableName t
        @($ret) | Should -Be @('id', 'hostname', 'ip')
    }

    It 'E2E1-030: the sample settings script and the help example configure real paths' {
        $raw = Get-Content -LiteralPath $script:SamplePath320 -Raw
        $raw | Should -Not -Match '\\\\'
        $cfg = @(@(. $script:SamplePath320) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1)[0]
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.DbPath | Should -Be 'C:\data\app.db'
        $cfg.LogPath | Should -Be 'C:\logs\db.log'
        $cfg.LogLevel | Should -Be 'INFO'
        (Split-Path -Parent $cfg.DbPath) | Should -Be 'C:\data'
        $script:Help320 | Should -Match ([regex]::Escape("DbPath='C:\data\app.db'"))
        $script:Help320 | Should -Not -Match '\\\\data'
    }

    It 'the README section 9 block runs line by line without an error on this host' {
        $script:Blocks320.Count | Should -BeGreaterOrEqual 9
        $lines = @()
        foreach ($raw in ($script:Blocks320[8] -split "\r?\n")) {
            $line = $raw.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            $lines += $line
        }
        $lines.Count | Should -BeGreaterThan 5
        $failures = @()
        foreach ($line in $lines) {
            # Replacement strings are literal apart from '$', so the path is quoted and any '$' is doubled.
            $cmd = [regex]::Replace($line, [regex]::Escape('.\myapp.db'), ("'" + ($script:Db320 -replace '\$', '$$$$') + "'"))
            $global:Error.Clear()
            try {
                Invoke-Expression $cmd | Out-Null
                $errs = @($global:Error | Where-Object { -not ($_ -is [System.Management.Automation.ErrorRecord] -and $_.InvocationInfo -and $_.InvocationInfo.MyCommand -and $_.InvocationInfo.MyCommand.Name -eq 'Add-Type') })
                if ($errs.Count -gt 0) { $failures += ("{0} :: {1}" -f $line, $errs[0]) }
            }
            catch {
                $failures += ("{0} :: {1}" -f $line, $_.Exception.Message)
            }
        }
        $global:Error.Clear()
        $failures | Should -BeNullOrEmpty
        # The block leaves no transaction open, and the relationship it removes is really gone.
        Test-DbTransaction -Database $script:Db320 | Should -BeFalse
        @(Invoke-DbQuery -Database $script:Db320 -Query "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_fk_vulns_asset_id%'").Count | Should -Be 0
        @(Invoke-DbQuery -Database $script:Db320 -Query "SELECT table_name FROM __fks__ WHERE table_name='vulns' AND column_name='asset_id'").Count | Should -Be 0
    }

    It 'the documented Join overloads, Auto ambiguity, Full join source and Run() shape behave as described' {
        $db = Join-Path $script:Root320 'join320.db'
        Import-CsvToSqlite -CsvPath (New-Csv320 'users320.csv' "id,name`r`n1,ann`r`n2,bob") -Database $db -TableName users | Out-Null
        Import-CsvToSqlite -CsvPath (New-Csv320 'tickets320.csv' "id,created_by,assigned_to,title`r`n1,1,2,first") -Database $db -TableName tickets | Out-Null
        Confirm-DbForeignKey -Database $db -From tickets -Column created_by -To users | Out-Null
        Confirm-DbForeignKey -Database $db -From tickets -Column assigned_to -To users | Out-Null

        $q1 = New-DbQuery -Database $db -From 'tickets'
        { $q1.Join('users') } | Should -Throw -ExpectedMessage '*is ambiguous*'
        $q2 = New-DbQuery -Database $db -From 'tickets'
        $rows = @($q2.Join('users', 'Auto', 'Inner', 'created_by').Select(@('tickets.id', 'users.name')).Run())
        $rows.Count | Should -Be 1
        $rows[0].name | Should -Be 'ann'
        $q3 = New-DbQuery -Database $db -From 'tickets'
        { $q3.Join('users', 'users.id = tickets.created_by', 'Inner', 'created_by') } |
            Should -Throw -ExpectedMessage "*applies to an 'Auto' join only*"
        $q4 = New-DbQuery -Database $db -From 'tickets'
        @($q4.Where('id = @i', @{ i = 999 }).Run()).Count | Should -Be 0
        $q5 = New-DbQuery -Database $db -From 'tickets'
        $right = @($q5.Join('users', 'users.id = tickets.created_by', 'Right').Run())
        @($right[0].PSObject.Properties.Name) | Should -Be @('id', 'created_by', 'assigned_to', 'title', 'id1', 'name')
        Invoke-DbQuery -Database $db -Query 'CREATE VIEW IF NOT EXISTS v_tickets AS SELECT * FROM tickets' -NonQuery | Out-Null
        $q6 = New-DbQuery -Database $db -From 'v_tickets'
        { $q6.Join('users', 'users.id = v_tickets.created_by', 'Full').Run() } |
            Should -Throw -ExpectedMessage '*requires a rowid table as its From source*'
    }

    It 'All() returns records, AllRows() returns plain rows, and a relationship through another column navigates' {
        $db = Join-Path $script:Root320 'rec320.db'
        Import-CsvToSqlite -CsvPath (New-Csv320 'corp320.csv' "id,code,name`r`n1,ACME,Acme Inc") -Database $db -TableName corp | Out-Null
        Import-CsvToSqlite -CsvPath (New-Csv320 'branch320.csv' "id,corp_code,city`r`n1,ACME,Paris`r`n2,ACME,Rome") -Database $db -TableName branch | Out-Null
        Confirm-DbForeignKey -Database $db -From branch -Column corp_code -To corp -RefColumn code | Out-Null
        Export-DynamicModelsFromCatalog -Database $db | Out-Null
        Set-DynamicORMClass
        $rec = New-DynamicRecord -Table 'corp' -Database $db

        $all = @($rec.All())
        $all.Count | Should -Be 1
        $all[0].GetType().Name | Should -Match '^DynamicCorp(_[0-9a-f]{8})?$'
        $all[0].Id | Should -Be 1
        $all[0].GetAttribute('name') | Should -Be 'Acme Inc'
        $plain = @($rec.AllRows())
        $plain[0].GetType().Name | Should -Be 'PSCustomObject'
        $plain[0].name | Should -Be 'Acme Inc'

        $parent = $rec.FindById(1)
        $kids = @($parent.GetHasMany('branch'))
        $kids.Count | Should -Be 2
        @($kids | ForEach-Object { $_.GetAttribute('city') }) | Should -Be @('Paris', 'Rome')
        $kids[0].GetBelongsTo('corp').GetAttribute('code') | Should -Be 'ACME'
    }

    It 'the documented import rules hold: -WhatIf, the id unique index, punctuation in names and -Scalar' {
        $wdb = Join-Path $script:Root320 'whatif320.db'
        $ret = Import-CsvToSqlite -CsvPath $script:Assets320 -Database $wdb -TableName assets -WhatIf
        @($ret) | Should -Be @('id', 'hostname', 'ip')
        @(Invoke-DbQuery -Database $wdb -Query "SELECT name FROM sqlite_master WHERE type='table' AND name='assets'").Count | Should -Be 0

        $idb = Join-Path $script:Root320 'idcol320.db'
        Import-CsvToSqlite -CsvPath (New-Csv320 'noid320.csv' "hostname,ip`r`nserver01,10.0.0.1") -Database $idb -TableName t | Out-Null
        $withId = New-Csv320 'withid320.csv' "id,hostname,ip`r`n5,server05,10.0.0.5"
        Import-CsvToSqlite -CsvPath $withId -Database $idb -TableName t | Out-Null
        $idInfo = @(Invoke-DbQuery -Database $idb -Query 'PRAGMA table_info(t)') | Where-Object { $_.name -eq 'id' }
        [int]$idInfo.pk | Should -Be 0
        @(Invoke-DbQuery -Database $idb -Query "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='t'" | ForEach-Object { [string]$_.name }) |
            Should -Contain 'ux_t_id'
        { Import-CsvToSqlite -CsvPath $withId -Database $idb -TableName t } | Should -Throw -ExpectedMessage '*UNIQUE constraint failed*'

        $pdb = Join-Path $script:Root320 'punct320.db'
        Import-CsvToSqlite -CsvPath (New-Csv320 'punct320.csv' "Cost (USD),50%,A/B`r`n10,20,30") -Database $pdb -TableName punct | Out-Null
        @(Invoke-DbQuery -Database $pdb -Query 'PRAGMA table_info(punct)' | ForEach-Object { [string]$_.name }) |
            Should -Be @('Cost (USD)', '50%', 'A/B')
        { ConvertTo-Ident ('bad' + [char]0 + 'name') } | Should -Throw -ExpectedMessage '*contains control characters*'

        ($null -eq (Invoke-DbQuery -Database $pdb -Query 'SELECT NULL AS x' -Scalar)) | Should -BeTrue
        ($null -eq (Invoke-DbQuery -Database $pdb -Query "SELECT [50%] FROM punct WHERE [50%] = -1" -Scalar)) | Should -BeTrue
    }

    It 'Confirm-DbForeignKey refuses dirty data, -Force records it and Remove-DbForeignKey cleans up' {
        $db = Join-Path $script:Root320 'fk320.db'
        Import-CsvToSqlite -CsvPath (New-Csv320 'p320.csv' "id,name`r`n1,one") -Database $db -TableName p | Out-Null
        Import-CsvToSqlite -CsvPath (New-Csv320 'c320.csv' "id,p_id`r`n1,1`r`n2,99") -Database $db -TableName ch | Out-Null
        { Confirm-DbForeignKey -Database $db -From ch -Column p_id -To p } |
            Should -Throw -ExpectedMessage '*value that is not in p.id*'
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='trigger'").Count | Should -Be 0
        Confirm-DbForeignKey -Database $db -From ch -Column p_id -To p -Force -WarningAction SilentlyContinue | Out-Null
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='trigger'").Count | Should -Be 3
        $dropped = @(Remove-DbForeignKey -Database $db -From ch -Column p_id)
        $dropped.Count | Should -Be 3
        @(Invoke-DbQuery -Database $db -Query "SELECT name FROM sqlite_master WHERE type='trigger'").Count | Should -Be 0
        @(Remove-DbForeignKey -Database $db -From ch -Column p_id).Count | Should -Be 0
    }

    It 'Test-DbTransaction reports the state of the pooled connection' {
        $db = Join-Path $script:Root320 'tx320.db'
        Import-CsvToSqlite -CsvPath $script:Assets320 -Database $db -TableName assets | Out-Null
        Test-DbTransaction -Database $db | Should -BeFalse
        $tx = Start-DbTransaction -Database $db
        if ($tx) {
            Test-DbTransaction -Database $db | Should -BeTrue
            Complete-DbTransaction -Database $db
        }
        Test-DbTransaction -Database $db | Should -BeFalse
    }

    It 'both documents describe the behaviour this build has' {
        foreach ($doc in @($script:Readme320, $script:Help320)) {
            $doc | Should -Match 'AllRows'
            $doc | Should -Match 'Remove-DbForeignKey'
            $doc | Should -Match 'Test-DbTransaction'
            $doc | Should -Match 'NullTokens'
            $doc | Should -Match 'BoolTokens'
            $doc | Should -Match '999'
            $doc | Should -Match ([regex]::Escape('ux_<table>_id'))
            $doc | Should -Match 'control characters'
            $doc | Should -Match 'defaults to INFO'
            $doc | Should -Match '-Force'
            $doc | Should -Match ([regex]::Escape('-WhatIf'))
        }
        $script:Readme320 | Should -Match ([regex]::Escape('Join(<table>, <on>, <type>, <foreign key column>)'))
        $script:Help320 | Should -Match ([regex]::Escape('Join(<table>, <on>, <type>, <foreign key>)'))
    }
}
