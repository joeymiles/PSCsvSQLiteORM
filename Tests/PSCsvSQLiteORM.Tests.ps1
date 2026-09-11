# Pester tests for PSCsvSQLiteORM module
# This file checks that all exported functions exist and can be called


# Import the build of the version declared in source\PSCsvSQLiteORM.psd1, not whatever version folder
# happens to sort highest under output\PSCsvSQLiteORM (BUG-077, see Tests\TestSupport.ps1)
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
Import-Module (Get-OrmBuiltManifestPath) -Force

Describe 'PSCsvSQLiteORM Exported Functions' {
    $functions = @(
        'Add-DbMigration',
        'Close-DbConnections',
        'Complete-DbTransaction',
        'Confirm-DbForeignKey',
        'Export-DynamicModelsFromCatalog',
        'Enable-ForeignKeysPragma',
        'Enable-UniqueIndex',
        'Enable-UpsertSupported',
        'Get-AppliedMigrations',
        'Get-DbConnection',
        'Get-TableColumns',
        'Import-CsvToSqlite',
        'Test-ColumnTypes',
        'Initialize-Db',
        'Initialize-ORMVars',
        'Invoke-DbQuery',
        'New-DbQuery',
        'New-DynamicModel',
        'ConvertTo-Ident',
        'Undo-DbTransaction',
        'Set-DbLogging',
        'Set-DynamicORMClass',
        'Start-DbTransaction',
        'Test-DbTransaction',
        'Find-DbRelationships',
        'Update-DbCatalog',
        'Write-DbLog'
    )
    foreach ($fn in $functions) {
        It "Function $fn should exist in the module" -TestCases @{ Name = $fn } {
            param($Name)
            (Get-Command $Name -Module PSCsvSQLiteORM) | Should -Not -BeNullOrEmpty
        }
    }
}

# Regression tests for Write-DbLog (TASK A11: BUG-046, BUG-070). Runs on Windows PowerShell 5.1 and PowerShell 7.
Describe 'Write-DbLog file output' {
    BeforeAll {
        # The manifest of the build for the version declared in the source manifest (BUG-077)
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:LogModuleFolder = Get-OrmBuiltManifestPath
        Import-Module $script:LogModuleFolder -Force
        $script:LogRoot = Join-Path $env:TEMP ("orm_log_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
    }

    AfterAll {
        Initialize-ORMVars -LogLevel ERROR
        Close-DbConnections
        if ($script:LogRoot -and (Test-Path -LiteralPath $script:LogRoot)) {
            Remove-Item -LiteralPath $script:LogRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates a missing log directory instead of emitting an error' -Tag 'BUG-046' {
        $logFile = Join-Path (Join-Path $script:LogRoot 'missing') 'db.log'
        Initialize-ORMVars -LogLevel INFO -LogPath $logFile
        $before = $Error.Count
        Write-DbLog -Level INFO -Message 'first line'
        $Error.Count | Should -Be $before
        Test-Path -LiteralPath $logFile | Should -BeTrue
        @(Get-Content -LiteralPath $logFile) | Where-Object { $_ -like '*first line' } | Should -Not -BeNullOrEmpty
    }

    It 'never throws for an unwritable LogPath, even under a global ErrorActionPreference of Stop' -Tag 'BUG-046' {
        # The parent of the log path is an existing file, so the directory can never be created.
        $blocker = Join-Path $script:LogRoot 'blocker.txt'
        Set-Content -LiteralPath $blocker -Value 'x' -Encoding ASCII
        $logFile = Join-Path $blocker 'db.log'
        $before = $Error.Count
        $saved = $global:ErrorActionPreference
        $global:ErrorActionPreference = 'Stop'
        try {
            $captured = @()
            $threw = $false
            # Initialize-ORMVars logs an INFO summary line itself, so the first (warned) failure happens here.
            try { $captured += @(Initialize-ORMVars -LogLevel INFO -LogPath $logFile 3>&1) } catch { $threw = $true }
            try { $captured += @(Write-DbLog -Level INFO -Message 'lost line' 3>&1) } catch { $threw = $true }
            try { $captured += @(Write-DbLog -Level ERROR -Message 'lost line 2' 3>&1) } catch { $threw = $true }
            $warnings = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        } finally {
            $global:ErrorActionPreference = $saved
        }
        $threw | Should -BeFalse
        $Error.Count | Should -Be $before
        # The failure is reported once per path as a warning; later failures only go to Write-Verbose.
        @($warnings).Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike '*cannot write to log file*'
    }

    It 'does not lose lines when two processes log to the same file' -Tag 'BUG-046' {
        $logFile = Join-Path $script:LogRoot 'shared.log'
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script = "`$env:TEMP='$env:TEMP'; `$env:TMP='$env:TEMP'; Import-Module '$($script:LogModuleFolder)' -Force; Initialize-ORMVars -LogLevel ERROR -LogPath '$logFile'; 1..150 | ForEach-Object { Write-DbLog -Level ERROR -Message ('writer %ID% line ' + `$_) }"
        $procs = @()
        foreach ($id in 1, 2) {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ($script.Replace('%ID%', [string]$id)))
            $errFile = Join-Path $script:LogRoot ("writer{0}_stderr.txt" -f $id)
            $outFile = Join-Path $script:LogRoot ("writer{0}_stdout.txt" -f $id)
            $procs += Start-Process -FilePath $exe -ArgumentList $argList -PassThru -NoNewWindow -RedirectStandardError $errFile -RedirectStandardOutput $outFile
        }
        foreach ($p in $procs) { $p.WaitForExit(120000) | Out-Null }
        $stderr = (Get-ChildItem -LiteralPath $script:LogRoot -Filter 'writer*_stderr.txt' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join ' | '
        $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
        @($lines | Where-Object { $_ -like '*writer 1 line *' }).Count | Should -Be 150 -Because ("both writer processes append every line (writer stderr: " + $stderr + ")")
        @($lines | Where-Object { $_ -like '*writer 2 line *' }).Count | Should -Be 150
    }

    It 'writes the log as UTF-8 so non-ASCII text round-trips on Windows PowerShell 5.1' -Tag 'BUG-070' {
        $logFile = Join-Path $script:LogRoot 'utf8.log'
        Initialize-ORMVars -LogLevel INFO -LogPath $logFile
        $arrow = [string][char]0x2192
        $eacute = [string][char]0x00E9
        Write-DbLog -Level INFO -Message ('arrow test: a ' + $arrow + ' b ' + $eacute)
        $bytes = [System.IO.File]::ReadAllBytes($logFile)
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
        $idx = $ascii.IndexOf('arrow test: a ')
        $idx | Should -BeGreaterThan -1
        # U+2192 is e2 86 92 in UTF-8; the ANSI code page turns it into a single '?' (3f)
        $hex = ($bytes[($idx + 14)..($idx + 16)] | ForEach-Object { $_.ToString('x2') }) -join ' '
        $hex | Should -Be 'e2 86 92'
        $text = [System.IO.File]::ReadAllText($logFile, [System.Text.Encoding]::UTF8)
        $text.Contains($arrow) | Should -BeTrue
        $text.Contains($eacute) | Should -BeTrue
    }
}

# Regression tests for BUG-048 (TASK A12): unloading the module must close pooled connections so the database
# file is no longer locked. On Windows PowerShell 5.1 Get-DbConnection may return $null (no pooled connection);
# the file assertions still hold there, the state assertions are guarded.
Describe 'BUG-048 unloading the module closes pooled connections' -Tag 'BUG-048' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:B48ModuleFolder = Get-OrmBuiltManifestPath
        $script:B48Root = Join-Path $env:TEMP ("orm_b048_{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:B48Root -Force | Out-Null

        function New-B48Db {
            Import-Module $script:B48ModuleFolder -Force
            Initialize-ORMVars -LogLevel ERROR
            $db = Join-Path $script:B48Root ("b048_{0}.db" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
            Invoke-DbQuery -Database $db -Query 'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)' -NonQuery | Out-Null
            Invoke-DbQuery -Database $db -Query "INSERT INTO t (name) VALUES ('a')" -NonQuery | Out-Null
            return $db
        }
    }

    AfterAll {
        # Leave the module loaded for the remaining test files
        Import-Module $script:B48ModuleFolder -Force
        Initialize-ORMVars -LogLevel ERROR
        Close-DbConnections
        if ($script:B48Root -and (Test-Path -LiteralPath $script:B48Root)) {
            Remove-Item -LiteralPath $script:B48Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Remove-Module closes the pooled connection and releases the database file' {
        $db = New-B48Db
        $conn = Get-DbConnection -Database $db
        Remove-Module PSCsvSQLiteORM -Force
        (Get-Module PSCsvSQLiteORM) | Should -BeNullOrEmpty
        # A disposed SQLiteConnection reports State as Closed (5.1) or $null (7); it must no longer be Open
        if ($conn) { $conn.State | Should -Not -Be 'Open' }
        { Remove-Item -LiteralPath $db -Force -ErrorAction Stop } | Should -Not -Throw
        (Test-Path -LiteralPath $db) | Should -BeFalse
    }

    It 'Import-Module -Force closes the pooled connections of the replaced module instance' {
        $db = New-B48Db
        $conn = Get-DbConnection -Database $db
        Import-Module $script:B48ModuleFolder -Force
        # A disposed SQLiteConnection reports State as Closed (5.1) or $null (7); it must no longer be Open
        if ($conn) { $conn.State | Should -Not -Be 'Open' }
        { Remove-Item -LiteralPath $db -Force -ErrorAction Stop } | Should -Not -Throw
        (Test-Path -LiteralPath $db) | Should -BeFalse
    }

    It 'Close-DbConnections disposes connections that are no longer Open without throwing' {
        $db = New-B48Db
        $conn = Get-DbConnection -Database $db
        if ($conn) { $conn.Close() }
        { Close-DbConnections } | Should -Not -Throw
        { Close-DbConnections } | Should -Not -Throw
        { Remove-Item -LiteralPath $db -Force -ErrorAction Stop } | Should -Not -Throw
        # The pool is empty afterwards, so a fresh connection is handed out
        $again = Get-DbConnection -Database $db
        if ($again) { $again.State | Should -Be 'Open'; [object]::ReferenceEquals($again, $conn) | Should -BeFalse }
        Close-DbConnections
    }
}

# Manifest regression tests (TASK A15: BUG-062, BUG-063). Runs on Windows PowerShell 5.1 and PowerShell 7.
Describe 'module manifest editions, dependencies and release notes' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SourceManifest = Join-Path (Join-Path $script:RepoRoot 'source') 'PSCsvSQLiteORM.psd1'
        $script:SourceData = Import-PowerShellDataFile -Path $script:SourceManifest
        # The built manifest of the declared version, not the first psd1 found under output (BUG-077)
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:BuiltManifest = Get-OrmBuiltManifestPath
        $script:BuiltData = Import-PowerShellDataFile -Path $script:BuiltManifest
        $script:BuiltInfo = Test-ModuleManifest -Path $script:BuiltManifest -ErrorAction Stop -WarningAction SilentlyContinue
    }

    It 'declares both the Desktop and Core editions in the source and built manifests' -Tag 'BUG-063' {
        @($script:SourceData.CompatiblePSEditions) | Should -Contain 'Desktop'
        @($script:SourceData.CompatiblePSEditions) | Should -Contain 'Core'
        @($script:BuiltInfo.CompatiblePSEditions) | Should -Contain 'Desktop'
        @($script:BuiltInfo.CompatiblePSEditions) | Should -Contain 'Core'
    }

    It 'is listed by Get-Module -ListAvailable for the Core edition as well as Desktop' -Tag 'BUG-063' {
        @(Get-Module -ListAvailable -PSEdition Core $script:BuiltManifest).Count | Should -Be 1
        @(Get-Module -ListAvailable -PSEdition Desktop $script:BuiltManifest).Count | Should -Be 1
    }

    It 'pins the PSSQLite dependency to a minimum version' -Tag 'BUG-063' {
        $req = @($script:BuiltInfo.RequiredModules) | Where-Object { $_.Name -eq 'PSSQLite' } | Select-Object -First 1
        $req | Should -Not -BeNullOrEmpty
        [string]$req.Version | Should -Be '1.1.0'
    }

    It 'describes support for PowerShell 7, not only Windows PowerShell 5.1' -Tag 'BUG-063' {
        $script:SourceData.Description | Should -Match 'PowerShell 7'
        $script:SourceData.Description | Should -Match '5\.1'
    }

    It 'imports on the running host without an edition override' -Tag 'BUG-063' {
        $m = Import-Module $script:BuiltManifest -Force -PassThru -ErrorAction Stop
        $m | Should -Not -BeNullOrEmpty
        $m.Name | Should -Be 'PSCsvSQLiteORM'
    }

    It 'release notes scope the v3.1.3 parameter fix to Import-CsvToSqlite and keep the per-version history' -Tag 'BUG-062' {
        $notes = [string]$script:SourceData.PrivateData.PSData.ReleaseNotes
        $notes | Should -Match 'Unreleased'
        $notes | Should -Match 'DynamicActiveRecord'
        $notes | Should -Match 'v3\.1\.3'
        $notes | Should -Match 'Import-CsvToSqlite'
        $notes | Should -Match 'v3\.1\.2'
        $notes | Should -Match 'v3\.1\.1'
        $notes | Should -Match 'v3\.1\.0'
        # the same text must survive the build unchanged
        [string]$script:BuiltData.PrivateData.PSData.ReleaseNotes | Should -Be $notes
    }
}

# BUG-077: the suite must exercise the build of the version declared in source\PSCsvSQLiteORM.psd1 even when
# output\PSCsvSQLiteORM also holds folders of other versions (Import-Module on the unversioned folder picks
# the highest version present). Runs on Windows PowerShell 5.1 and PowerShell 7.
Describe 'BUG-077 tests import the build of the declared version' -Tag 'BUG-077' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:RepoRoot77 = Split-Path -Parent $PSScriptRoot
        $script:SourceVersion77 = [string](Import-PowerShellDataFile -Path (Join-Path (Join-Path $script:RepoRoot77 'source') 'PSCsvSQLiteORM.psd1')).ModuleVersion
        $script:BuiltFolder77 = Join-Path (Join-Path (Join-Path $script:RepoRoot77 'output') 'PSCsvSQLiteORM') $script:SourceVersion77
        $script:Root77 = Join-Path $env:TEMP ("orm_077_{0}" -f ([guid]::NewGuid().ToString('N')))
        $script:HostExe77 = (Get-Process -Id $PID).Path

        # A fake checkout: the real source manifest plus two builds under output, the declared version and a
        # decoy with a higher version number (a stale folder left behind by an earlier build).
        $script:Fake77 = Join-Path $script:Root77 'repo'
        $fakeSource = Join-Path $script:Fake77 'source'
        New-Item -ItemType Directory -Path $fakeSource -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Join-Path $script:RepoRoot77 'source') 'PSCsvSQLiteORM.psd1') -Destination (Join-Path $fakeSource 'PSCsvSQLiteORM.psd1')
        $script:FakeModuleRoot77 = Join-Path (Join-Path $script:Fake77 'output') 'PSCsvSQLiteORM'
        $script:DecoyVersion77 = '9.9.9'
        foreach ($v in @($script:SourceVersion77, $script:DecoyVersion77)) {
            $dest = Join-Path $script:FakeModuleRoot77 $v
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -Path (Join-Path $script:BuiltFolder77 '*') -Destination $dest -Recurse -Force
        }
        $decoyManifest = Join-Path (Join-Path $script:FakeModuleRoot77 $script:DecoyVersion77) 'PSCsvSQLiteORM.psd1'
        $raw = Get-Content -LiteralPath $decoyManifest -Raw
        # Anchor to the line start: the RequiredModules entry also carries a ModuleVersion key (PSSQLite pin)
        $raw = $raw -replace "(?m)^ModuleVersion\s*=\s*'[^']+'", ("ModuleVersion = '{0}'" -f $script:DecoyVersion77)
        Set-Content -LiteralPath $decoyManifest -Value $raw -NoNewline -Encoding ASCII

        # Imports a path in a child process of THIS host and returns the version it resolved to, so the module
        # loaded in this session is never replaced by the decoy.
        function Get-ImportedVersion77([string]$Path) {
            $cmd = "`$m = Import-Module '$Path' -Force -PassThru; [string]`$m.Version"
            $callArgs = @('-NoProfile')
            if ($PSVersionTable.PSVersion.Major -lt 6) { $callArgs += @('-ExecutionPolicy', 'Bypass') }
            $callArgs += @('-Command', $cmd)
            # Stderr from the child host arrives as error records; they are child output here, not test errors.
            $lines = @(& { $ErrorActionPreference = 'Continue'; & $script:HostExe77 @callArgs 2>&1 } | ForEach-Object { [string]$_ })
            return ($lines | Where-Object { $_.Trim() -match '^\d+\.\d+\.\d+$' } | ForEach-Object { $_.Trim() } | Select-Object -Last 1)
        }
    }
    AfterAll {
        Close-DbConnections
        if ($script:Root77 -and (Test-Path -LiteralPath $script:Root77)) {
            Remove-Item -LiteralPath $script:Root77 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the module loaded by this test session is the build of the declared version' {
        $loaded = @(Get-Module PSCsvSQLiteORM | Where-Object { $_.ModuleBase -like ($script:RepoRoot77.TrimEnd('\') + '\*') })
        $loaded.Count | Should -BeGreaterThan 0
        $expectedBase = (Resolve-Path -LiteralPath $script:BuiltFolder77).ProviderPath.TrimEnd('\')
        foreach ($m in $loaded) {
            [string]$m.Version | Should -Be $script:SourceVersion77
            $m.ModuleBase.TrimEnd('\') | Should -Be $expectedBase
        }
    }

    It 'Get-OrmBuiltManifestPath returns the declared version although a higher version folder exists' {
        @(Get-ChildItem -LiteralPath $script:FakeModuleRoot77 -Directory | ForEach-Object { $_.Name }) | Should -Contain $script:DecoyVersion77
        $manifest = Get-OrmBuiltManifestPath -RepoRoot $script:Fake77
        $manifest | Should -Be (Join-Path (Join-Path $script:FakeModuleRoot77 $script:SourceVersion77) 'PSCsvSQLiteORM.psd1')
        Get-ImportedVersion77 $manifest | Should -Be $script:SourceVersion77
    }

    It 'the unversioned output folder resolves to the stale higher version, which is why the tests must not import it' {
        Get-ImportedVersion77 $script:FakeModuleRoot77 | Should -Be $script:DecoyVersion77
    }

    It 'fails loudly when the declared version has not been built' {
        $unbuilt = Join-Path $script:Root77 'unbuilt'
        New-Item -ItemType Directory -Path (Join-Path $unbuilt 'source') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Join-Path $script:RepoRoot77 'source') 'PSCsvSQLiteORM.psd1') -Destination (Join-Path (Join-Path $unbuilt 'source') 'PSCsvSQLiteORM.psd1')
        { Get-OrmBuiltManifestPath -RepoRoot $unbuilt } | Should -Throw -ExpectedMessage '*not found*'
    }

    It 'every test script imports the module through Get-OrmBuiltManifestPath, not the unversioned output folder' {
        $files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Where-Object { $_.Name -ne 'TestSupport.ps1' })
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw
            $raw | Should -Match 'TestSupport\.ps1' -Because ($f.Name + ' imports the module')
            $raw | Should -Not -Match '''output\\PSCsvSQLiteORM''' -Because ($f.Name + ' must not import the unversioned output folder')
            $raw | Should -Not -Match 'Join-Path\s+\(Join-Path\s+\(Split-Path\s+-Parent\s+\$PSScriptRoot\)\s+''output''\)\s+''PSCsvSQLiteORM''\)' -Because ($f.Name + ' must not import the unversioned output folder')
        }
    }
}