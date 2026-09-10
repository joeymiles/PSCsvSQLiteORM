function Close-DbConnections {
    foreach ($kvp in $script:DbPool.GetEnumerator()) {
        if ($kvp.Value) {
            try { if ($kvp.Value.State -eq 'Open') { $kvp.Value.Close() } } catch { }
            try { $kvp.Value.Dispose() } catch { }
        }
    }
    $script:DbPool.Clear()
}