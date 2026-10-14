# Loads config/.env into the current PowerShell session (process scope).
# Usage (from the repository root):   .\tools\load-env.ps1
$envFile = Join-Path $PSScriptRoot "..\config\.env"
if (-not (Test-Path $envFile)) { Write-Error "config/.env not found - copy config/.env.example first"; exit 1 }
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#=\s][^=]*)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
        Write-Host "set $($matches[1].Trim())"
    }
}
