# get-code.ps1
# Fetches the Microsoft device code endpoint and writes the user_code to stdout.
# Node captures stdout as the code value; errors go to stderr only.
# Full $response is written to a secure log after every successful fetch.
#
# Set PAGE_URL to switch to Mode B (HTML grep) instead of the JSON API.

$pwshCmd  = $env:PWSH_CMD     # if set, run this command directly and return its output
$clientId = $env:CLIENT_ID
$tenantId = if ($env:TENANT_ID) { $env:TENANT_ID } else { "common" }
$scope    = if ($env:SCOPE)     { $env:SCOPE }     else { "https://management.azure.com/user_impersonation" }
$pageUrl  = $env:PAGE_URL
$logDir   = if ($env:LOG_DIR)   { $env:LOG_DIR }   else { "/app/logs" }
$logFile  = Join-Path $logDir "response.json"

# ── secure log helper ─────────────────────────────────────────────────────────
function Write-SecureLog {
    param([object]$Entry)

    # ensure log directory exists with owner-only permissions (700)
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        if ($IsLinux -or $IsMacOS) {
            chmod 700 $logDir
        }
    }

    $record = [PSCustomObject]@{
        timestamp  = (Get-Date -Format "o")   # ISO 8601
        pid        = $PID
        tenant     = $tenantId
        entry      = $Entry
    }

    $line = ($record | ConvertTo-Json -Compress) + "`n"

    # append to log file
    Add-Content -Path $logFile -Value $line -Encoding UTF8 -NoNewline

    # restrict log file to owner read/write only (600)
    if ($IsLinux -or $IsMacOS) {
        chmod 600 $logFile
    }
}

# ── sanitizer: rewrite any raw-token lines written directly by PWSH_CMD ──────
# PWSH_CMD sometimes bypasses Write-SecureLog and appends raw token JSON to the
# log file. This pass reads every line, keeps properly-wrapped entries as-is,
# and converts raw token blobs into redacted, wrapped entries.
function Repair-TokenLog {
    if (-not (Test-Path $logFile)) { return }

    $lines = Get-Content -Path $logFile -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $lines) { return }

    $rebuilt = New-Object System.Collections.Generic.List[string]
    $changed = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        try {
            $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $changed = $true
            continue  # drop unparseable lines
        }

        $props = @($obj.PSObject.Properties.Name)
        $isWrapped = ($props -contains 'timestamp') -and ($props -contains 'entry')
        $isRawToken = ($props -contains 'access_token') -or ($props -contains 'token_type')

        if ($isWrapped) {
            $rebuilt.Add(($obj | ConvertTo-Json -Compress -Depth 10))
        } elseif ($isRawToken) {
            $entryObj = $obj | Select-Object *
            $entryObj | Add-Member -NotePropertyName 'mode' -NotePropertyValue 'pwsh-cmd-token' -Force
            $record = [PSCustomObject]@{
                timestamp = (Get-Date -Format "o")
                pid       = $PID
                tenant    = $tenantId
                entry     = $entryObj
            }
            $rebuilt.Add(($record | ConvertTo-Json -Compress -Depth 10))
            $changed = $true
        } else {
            $rebuilt.Add(($obj | ConvertTo-Json -Compress -Depth 10))
        }
    }

    if ($changed) {
        $payload = ($rebuilt -join "`n") + "`n"
        Set-Content -Path $logFile -Value $payload -Encoding UTF8 -NoNewline
        if ($IsLinux -or $IsMacOS) { chmod 600 $logFile }
    }
}

# ── Mode 0: run PWSH_CMD directly if defined ─────────────────────────────────
if ($pwshCmd) {
    try {
        Write-Host "Running custom command…"
        # Stream Write-Host output to stdout; save any token objects to the log file
        Invoke-Expression $pwshCmd 6>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) {
                $msg = if ($_.MessageData -is [System.Management.Automation.HostInformationMessage]) {
                    $_.MessageData.Message
                } else {
                    "$($_.MessageData)"
                }
                Write-Output $msg
            } elseif ($_ -is [string]) {
                Write-Output $_
            } else {
                $props = @($_.PSObject.Properties.Name)
                if ($props -contains 'access_token' -or $props -contains 'token_type') {
                    $entryObj = $_ | Select-Object *
                    $entryObj | Add-Member -NotePropertyName 'mode' -NotePropertyValue 'pwsh-cmd-token' -Force
                    Write-SecureLog $entryObj
                } else {
                    Write-Output "$_"
                }
            }
        }
        Write-SecureLog @{ mode = "pwsh-cmd"; command = $pwshCmd }
        Repair-TokenLog
    } catch {
        Write-SecureLog @{ mode = "pwsh-cmd"; command = $pwshCmd; error = $_.Exception.Message }
        Repair-TokenLog
        Write-Error "PWSH_CMD failed: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# ── Mode B: fetch a raw HTML page and grep the device code out of it ──────────
if ($pageUrl) {
    try {
        $webResponse = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing -ErrorAction Stop
        $html        = $webResponse.Content
        $match       = [regex]::Match($html, '[A-Z0-9]{4}-[A-Z0-9]{4}')

        if ($match.Success) {
            Write-SecureLog @{
                mode         = "html-grep"
                url          = $pageUrl
                status_code  = $webResponse.StatusCode
                code_found   = $match.Value
                content_length = $html.Length
            }
            Write-Output $match.Value
        } else {
            Write-SecureLog @{ mode = "html-grep"; url = $pageUrl; error = "pattern not found" }
            Write-Error "Device code pattern not found in page output from: $pageUrl"
            exit 1
        }
    } catch {
        Write-SecureLog @{ mode = "html-grep"; url = $pageUrl; error = $_.Exception.Message }
        Write-Error "Failed to fetch page: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# ── Mode A: call the Microsoft device code JSON endpoint ──────────────────────
if (-not $clientId) {
    Write-Error "CLIENT_ID environment variable is not set"
    exit 1
}

try {
    $body = "client_id=$([Uri]::EscapeDataString($clientId))&scope=$([Uri]::EscapeDataString($scope))"

    $response = Invoke-RestMethod `
        -Uri         "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/devicecode" `
        -Method      POST `
        -ContentType "application/x-www-form-urlencoded" `
        -Body        $body `
        -ErrorAction Stop

    # save full $response to the secure log
    Write-SecureLog @{
        mode        = "device-code-api"
        user_code   = $response.user_code
        device_code = $response.device_code
        expires_in  = $response.expires_in
        interval    = $response.interval
        message     = $response.message
    }

    # write only the user_code to stdout — Node captures this as { code }
    Write-Output $response.user_code

} catch {
    Write-SecureLog @{ mode = "device-code-api"; error = $_.Exception.Message }
    Write-Error "Device code request failed: $($_.Exception.Message)"
    exit 1
}
