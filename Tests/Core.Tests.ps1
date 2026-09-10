# Unit tests for core helpers (TASK B2: BUG-004, BUG-005, BUG-013)

$moduleFolder = Join-Path (Join-Path $PSScriptRoot '..') 'output\PSCsvSQLiteORM'
Import-Module $moduleFolder -Force

BeforeAll {
    function New-Rows {
        param([string]$Header, [object[]]$Values)
        $rows = @()
        foreach ($v in $Values) { $rows += [pscustomobject]@{ $Header = $v } }
        return $rows
    }
}

AfterAll {
    Close-DbConnections
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
