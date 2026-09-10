function Close-DbConnections {
    # Closes and disposes every pooled connection whatever its state (BUG-048): a connection that is Broken or
    # was closed without being disposed still holds native handles, so the database file stays locked.
    # Never throws: this also runs from the module's OnRemove handler (Remove-Module / Import-Module -Force).
    if (-not $script:DbPool) { $script:DbPool = @{}; return }
    foreach ($conn in @($script:DbPool.Values)) {
        if (-not $conn) { continue }
        try { if ($conn.State -ne 'Closed') { $conn.Close() } } catch { Write-Verbose "Close-DbConnections: Close failed: $($_.Exception.Message)" }
        try { $conn.Dispose() } catch { Write-Verbose "Close-DbConnections: Dispose failed: $($_.Exception.Message)" }
    }
    $script:DbPool.Clear()
}