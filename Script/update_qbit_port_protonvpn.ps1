# Requires -Version 5.1

<#
.SYNOPSIS
    Keeps qBittorrent's listening port in sync with ProtonVPN's forwarded port.
.DESCRIPTION
    Watches ProtonVPN's port.txt for changes and pushes the new port to qBittorrent
    via its Web API as soon as it changes, instead of polling on a fixed interval.
    Falls back to a periodic check every 60s in case a file-system event is missed.

    Run this as a long-lived process (e.g. a Scheduled Task triggered "At log on").
.NOTES
    Create the credential file once with:
        Get-Credential | Export-Clixml -Path '.\qbit_creds.xml'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$QBitUrl = "http://localhost:8080",

    [Parameter(Mandatory = $false)]
    [string]$CredFilePath = "$PSScriptRoot\qbit_creds.xml",

    [Parameter(Mandatory = $false)]
    [string]$StateFilePath = "$PSScriptRoot\last_port.txt",

    [Parameter(Mandatory = $false)]
    [string]$LogFilePath = "$PSScriptRoot\sync.log"
)

$script:Session = $null

# ==============================================================================
# LOGGING
# ==============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $LogFilePath -Value $line
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

# ==============================================================================
# CREDENTIAL MANAGEMENT (DPAPI)
# ==============================================================================
function Get-QBitCredentials {
    param ([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Log "Credential file not found at: $Path" "ERROR"
        Write-Host "To create this file securely, run the following command ONCE in PowerShell:"
        Write-Host "----------------------------------------------------------------------"
        Write-Host "Get-Credential | Export-Clixml -Path '$Path'"
        Write-Host "----------------------------------------------------------------------"
        throw "Please generate the credential file securely and try again."
    }

    try {
        # Import-Clixml uses Windows DPAPI. Only the user who created the file on this machine can decrypt it.
        return Import-Clixml -Path $Path
    }
    catch {
        throw "Failed to decrypt credentials. Ensure this script runs as the same user who created the XML file."
    }
}

# ==============================================================================
# QBITTORRENT API INTERACTION
# ==============================================================================
function Get-QBitSession {
    param([Parameter(Mandatory)]$Creds)

    $loginUri = "$QBitUrl/api/v2/auth/login"
    $body = @{
        username = $Creds.UserName
        password = $Creds.GetNetworkCredential().Password
    }

    $session = $null
    Invoke-RestMethod -Uri $loginUri -Method Post -Body $body -SessionVariable 'session' -ErrorAction Stop | Out-Null
    return $session
}

function Update-QBittorrentPort {
    param(
        [Parameter(Mandatory)][int]$NewPort,
        [Parameter(Mandatory)]$Creds
    )

    if (-not $script:Session) {
        $script:Session = Get-QBitSession -Creds $Creds
    }

    try {
        $currentPort = (Invoke-RestMethod -Uri "$QBitUrl/api/v2/app/preferences" -Method Get -WebSession $script:Session -ErrorAction Stop).listen_port
    }
    catch {
        # Session likely expired - re-authenticate once and retry.
        $script:Session = Get-QBitSession -Creds $Creds
        $currentPort = (Invoke-RestMethod -Uri "$QBitUrl/api/v2/app/preferences" -Method Get -WebSession $script:Session -ErrorAction Stop).listen_port
    }

    if ($currentPort -eq $NewPort) {
        Write-Log "qBittorrent is already on port $NewPort. No action needed."
        return
    }

    $payload = [PSCustomObject]@{ listen_port = $NewPort } | ConvertTo-Json

    Invoke-RestMethod -Uri "$QBitUrl/api/v2/app/setPreferences" `
        -Method Post `
        -WebSession $script:Session `
        -Body $payload `
        -ContentType "application/json"

    Write-Log "Updated qBittorrent port: $currentPort -> $NewPort"
}

# ==============================================================================
# PORT SYNC
# ==============================================================================
function Sync-Port {
    param([Parameter(Mandatory)]$Creds)

    $portFile = Join-Path $env:LOCALAPPDATA "ProtonVPN\port.txt"

    if (-not (Test-Path $portFile)) {
        Write-Log "port.txt not found. Is ProtonVPN connected with port forwarding enabled?" "WARN"
        return
    }

    # The file can be mid-write when the event fires; retry briefly.
    $content = $null
    for ($i = 0; $i -lt 5; $i++) {
        $content = Get-Content -Path $portFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($content -match '^\d{4,5}$') { break }
        Start-Sleep -Milliseconds 200
    }

    if ($content -notmatch '^\d{4,5}$') {
        Write-Log "Could not parse a valid port from port.txt (content: '$content')." "WARN"
        return
    }

    $newPort = [int]$content
    $lastPort = if (Test-Path $StateFilePath) { Get-Content $StateFilePath -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }

    if ($lastPort -eq "$newPort") {
        return
    }

    try {
        Update-QBittorrentPort -NewPort $newPort -Creds $Creds
        Set-Content -Path $StateFilePath -Value $newPort
    }
    catch {
        Write-Log "Failed to sync port to qBittorrent: $_" "ERROR"
    }
}

# ==============================================================================
# MAIN
# ==============================================================================
$Creds = Get-QBitCredentials -Path $CredFilePath
$watchDir = Join-Path $env:LOCALAPPDATA "ProtonVPN"

if (-not (Test-Path $watchDir)) {
    Write-Log "ProtonVPN data directory not found at $watchDir. Is ProtonVPN installed?" "ERROR"
    exit 1
}

Write-Log "Started. Watching '$watchDir\port.txt' for changes."
Sync-Port -Creds $Creds

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $watchDir
$watcher.Filter = "port.txt"
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
$watcher.EnableRaisingEvents = $true

Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier "PortFileChanged" | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier "PortFileCreated" | Out-Null

try {
    while ($true) {
        # Wake on a file event, or every 60s as a safety net in case an event is missed.
        $event = Wait-Event -Timeout 60
        if ($event) {
            Get-Event | Remove-Event -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500 # debounce rapid-fire writes
        }
        Sync-Port -Creds $Creds
    }
}
finally {
    Unregister-Event -SourceIdentifier "PortFileChanged" -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "PortFileCreated" -ErrorAction SilentlyContinue
    $watcher.Dispose()
    Write-Log "Stopped."
}
