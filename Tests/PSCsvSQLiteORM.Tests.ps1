# Pester tests for PSCsvSQLiteORM module
# This file checks that all exported functions exist and can be called


# Import the module from the repo's output directory (version-agnostic)
$moduleFolder = Join-Path (Split-Path -Parent $PSScriptRoot) 'output\PSCsvSQLiteORM'
Import-Module $moduleFolder -Force

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
        # Join two pieces at a time: the three-argument Join-Path form does not exist on Windows PowerShell 5.1
        $script:LogModuleFolder = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM'
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
