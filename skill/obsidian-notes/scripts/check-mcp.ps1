param(
    [string]$Endpoint = "http://127.0.0.1:8811",
    [int]$TimeoutSeconds = 5
)

$ErrorActionPreference = "Stop"

function Get-EnvFileKey {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $line = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match '^\s*MCP_API_KEY\s*=' } |
        Select-Object -Last 1

    if (-not $line) {
        return $null
    }

    return ($line -replace '^\s*MCP_API_KEY\s*=', '').Trim()
}

$key = $env:MCP_API_KEY
$envPath = Join-Path $PSScriptRoot "../../../.env"

if ([string]::IsNullOrWhiteSpace($key)) {
    $key = Get-EnvFileKey -Path $envPath
}

if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Host "ERROR: MCP_API_KEY is not set and no key was found in $envPath" -ForegroundColor Red
    exit 2
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: curl.exe is required" -ForegroundColor Red
    exit 2
}

$base = $Endpoint.TrimEnd('/')
$bodyFile = [IO.Path]::GetTempFileName()
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-mcp","version":"1"}}}'

try {
    [IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding($false)))

    $health = & curl.exe -s -o NUL -w "%{http_code}" --max-time $TimeoutSeconds "$base/healthz"
    $noKey = & curl.exe -s -o NUL -w "%{http_code}" --max-time $TimeoutSeconds `
        -X POST `
        -H "Content-Type: application/json" `
        -H "Accept: application/json, text/event-stream" `
        --data-binary "@$bodyFile" `
        "$base/mcp"

    $withKey = & curl.exe -s -o NUL -w "%{http_code}" --max-time $TimeoutSeconds `
        -X POST `
        -H "Content-Type: application/json" `
        -H "Accept: application/json, text/event-stream" `
        -H "X-API-Key: $key" `
        --data-binary "@$bodyFile" `
        "$base/mcp"

    Write-Host "Endpoint:       $base"
    Write-Host "GET /healthz:   $health"
    Write-Host "POST /mcp (none): $noKey"
    Write-Host "POST /mcp (key):  $withKey"

    $ok = ($health -eq "200" -and $noKey -eq "401" -and $withKey -eq "200")

    if ($ok) {
        Write-Host "OK: MCP is healthy and the API key is accepted." -ForegroundColor Green
        exit 0
    }

    Write-Host "FAILED: expected health=200, no-key=401, with-key=200." -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
}
