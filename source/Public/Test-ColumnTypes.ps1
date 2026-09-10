function Test-ColumnTypes {
    param (
        [Parameter(Mandatory)][array]$Csv,
        [Parameter(Mandatory)][string[]]$Headers,
        # Treat empty strings as text values instead of missing values. Import-CsvToSqlite
        # sets this when '' is not a null token, so '' is never stored in a numeric column.
        [switch]$EmptyIsText
    )
    $columnTypes = @{}
    foreach ($header in $Headers) {
        $isInteger = $true; $isReal = $true; $seen = $false
        foreach ($row in $Csv) {
            $value = $row.$header
            if ($null -eq $value) { continue }
            $text = "$value"
            if ($text -eq "") {
                if (-not $EmptyIsText) { continue }
                $seen = $true; $isInteger = $false; $isReal = $false; break
            }
            $seen = $true
            $kind = Get-CsvValueKind -Value $text
            if ($kind -ne 'INTEGER') { $isInteger = $false }
            if ($kind -eq 'TEXT') { $isReal = $false; break }
        }
        if ($header -eq "id") {
            # A natural key ('srv-01', 'A1', a GUID) cannot live in an INTEGER PRIMARY KEY column.
            if ($isInteger) { $columnTypes[$header] = "INTEGER PRIMARY KEY AUTOINCREMENT" }
            else { $columnTypes[$header] = "TEXT PRIMARY KEY" }
            continue
        }
        # A column without any value carries no evidence of a numeric type; TEXT accepts everything later.
        if (-not $seen) { $columnTypes[$header] = "TEXT" }
        elseif ($isInteger) { $columnTypes[$header] = "INTEGER" }
        elseif ($isReal) { $columnTypes[$header] = "REAL" }
        else { $columnTypes[$header] = "TEXT" }
    }
    return $columnTypes
}
