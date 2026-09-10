# Sample test script for PSCsvSQLiteORM module
# Imports sample CSVs, creates tables, and runs basic queries

# Join two pieces at a time: the three-argument Join-Path form does not exist on Windows PowerShell 5.1
Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'output') 'PSCsvSQLiteORM') -Force
Initialize-ORMVars -LogLevel INFO

$tmpDir = Join-Path $PSScriptRoot 'tmp'
if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
$database = Join-Path $tmpDir ("sample_{0}.db" -f ([guid]::NewGuid().ToString('N')))

# Import assets
Import-CsvToSqlite -Database $database -TableName 'assets' -CsvPath (Join-Path $PSScriptRoot 'assets.csv')
# Import vulnerabilities
Import-CsvToSqlite -Database $database -TableName 'vulns' -CsvPath (Join-Path $PSScriptRoot 'vulns.csv')

# Query assets
$assets = Invoke-DbQuery -Database $database -Query 'SELECT * FROM assets'
Write-Host "Assets:"
$assets | Format-Table

# Query vulnerabilities
$vulns = Invoke-DbQuery -Database $database -Query 'SELECT * FROM vulns'
Write-Host "Vulnerabilities:"
$vulns | Format-Table

# Find relationships
$relationships = Find-DbRelationships -Database $database
Write-Host "Suggested Relationships:"
$relationships | Format-Table
