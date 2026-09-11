function ConvertTo-Ident {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw "Invalid identifier: value is null or empty" }
    # E2E1-021: the old whitelist was word chars, whitespace, dash, underscore and dot, which threw
    # out ordinary CSV headers - 'Cost (USD)', '50%', 'A/B', "O'Brien", 'Weight [kg]' - so those
    # files could not be imported at all. The return below wraps the name in double quotes and
    # doubles any embedded quote, and inside a double-quoted SQLite identifier every other
    # character is literal, so the whitelist bought nothing over that quoting.
    # Only what quoting cannot survive is refused: control characters. U+0000 above all - SQLite
    # takes it as the end of the identifier - plus the rest of the C0/C1 control range and DEL.
    # Tab, line feed and carriage return stay allowed, as they were before.
    if ($Name -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]') {
        $shown = $Name -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', '?'
        throw "Invalid identifier: '$shown' contains control characters"
    }
    return '"' + ($Name -replace '"', '""') + '"'
}
