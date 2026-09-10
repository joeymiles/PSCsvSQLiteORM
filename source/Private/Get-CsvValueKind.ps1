function Get-CsvValueKind {
    <#
    .SYNOPSIS
        Classifies one CSV cell as INTEGER, REAL or TEXT for schema inference.
    .DESCRIPTION
        A value is INTEGER or REAL only when storing it as that SQLite type and
        reading it back reproduces the original text exactly. Anything else is
        TEXT, so that leading zeros ('02134', '00501'), values beyond Int64
        ('12345678901234567890'), trailing decimal zeros ('1.10') and
        non-canonical spellings ('-0', '+5', '.5', '1e3') are never silently
        altered by SQLite type affinity.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -match '^-?\d+$') {
        $l = [long]0
        if ([long]::TryParse($Value, [System.Globalization.NumberStyles]::AllowLeadingSign, $inv, [ref]$l) -and $l.ToString($inv) -eq $Value) {
            return 'INTEGER'
        }
        return 'TEXT'
    }
    if ($Value -match '^-?\d+\.\d+$') {
        $d = [double]0
        if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d) -and -not [double]::IsInfinity($d) -and $d.ToString('R', $inv) -eq $Value) {
            return 'REAL'
        }
        return 'TEXT'
    }
    return 'TEXT'
}
