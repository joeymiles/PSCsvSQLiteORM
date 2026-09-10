function ConvertTo-ParamMap {
    <#
    .SYNOPSIS
        Builds collision-free SQL parameter names for a list of column names.
    .DESCRIPTION
        Returns an ordered dictionary that maps each column name to a positional
        parameter name (p0, p1, ...). Positional names never collide, unlike
        sanitized header text where "a b", "a_b" and "a-b" all became a_b.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Columns)
    $map = [ordered]@{}
    $i = 0
    foreach ($c in $Columns) {
        $map[$c] = "p$i"
        $i++
    }
    return $map
}
