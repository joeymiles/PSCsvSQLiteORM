# Initialize-ORMVars -SettingsPath .\orm.settings.ps1 dot-sources this file and uses the last
# hashtable it emits, so the script may create its own log directory or write other output first.
# Single-quoted strings are literal in PowerShell: a backslash is never an escape character here.
@{
  # Default database file path
  DbPath   = 'C:\data\app.db'

  # Optional log file; when not set, logs go to Write-Verbose
  LogPath  = 'C:\logs\db.log'

  # Logging verbosity: DEBUG | INFO | WARN | ERROR
  LogLevel = 'INFO'
}

