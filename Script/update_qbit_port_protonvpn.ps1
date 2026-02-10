# Requires -Version 5.1

<#
.SYNOPSIS
    Synchronizes qBittorrent listening port with ProtonVPN.
.DESCRIPTION
    Securely loads credentials via DPAPI, detects the VPN port (handling file locks),
    and updates qBittorrent settings.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$QBitUrl = "http://localhost:8080",

    [Parameter(Mandatory = $false)]
    [string]$CredFilePath = "$PSScriptRoot\qbit_creds.xml"
)

# ==============================================================================
# 1. CREDENTIAL MANAGEMENT (DPAPI)
# ==============================================================================
function Get-QBitCredentials {
    param ([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Warning "Credential file not found at: $Path"
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
# 2. PORT DETECTION (LOCK-SAFE)
# ==============================================================================
function Get-ProtonVPNPort {
    # Method A: Check standard text file
    $protonDataPath = Join-Path $env:LOCALAPPDATA "ProtonVPN"
    $portFile = Join-Path $protonDataPath "port.txt"
    
    if (Test-Path -Path $portFile) {
        $content = Get-Content -Path $portFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($content -match '^\d{4,5}$') { return [int]$content }
    }

    # Method B: Check Windows Notification DB (Lock-Safe)
    $dbPath = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Notifications\AppDb.db"
    if (Test-Path -Path $dbPath) {
        $tempPath = [System.IO.Path]::GetTempFileName()
        $fileStream = $null
        try {
            # Open file with FileShare.ReadWrite to allow reading even if locked by OS
            $fileStream = [System.IO.File]::Open($dbPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $destStream = [System.IO.File]::Create($tempPath)
            $fileStream.CopyTo($destStream)
            
            # Flush and close streams before reading
            $destStream.Close()
            $fileStream.Close()

            # Parse the temp copy
            $matches = Select-String -Path $tempPath -Pattern "(?<=port: )\d{4,5}" -AllMatches
            if ($matches) {
                return [int]($matches.Matches | Select-Object -Last 1 -ExpandProperty Value)
            }
        }
        catch {
            Write-Warning "Could not extract port from AppDb: $_"
        }
        finally {
            if ($fileStream) { $fileStream.Dispose() }
            if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        }
    }
    return $null
}

# ==============================================================================
# 3. QBITTORRENT API INTERACTION
# ==============================================================================
function Update-QBittorrentConfiguration {
    param(
        [Parameter(Mandatory)]$WebSession,
        [int]$NewPort
    )

    $currentPort = try {
        (Invoke-RestMethod -Uri "$QBitUrl/api/v2/app/preferences" -Method Get -WebSession $WebSession -ErrorAction Stop).listen_port
    } catch { $null }

    if ($null -ne $currentPort -and $currentPort -ne $NewPort) {
        Write-Host "Updating Port: $currentPort -> $NewPort" -ForegroundColor Cyan
        
        # Use PSCustomObject for clean JSON generation
        $payload = [PSCustomObject]@{ 
            listen_port = $NewPort 
        } | ConvertTo-Json

        Invoke-RestMethod -Uri "$QBitUrl/api/v2/app/setPreferences" `
            -Method Post `
            -WebSession $WebSession `
            -Body $payload `
            -ContentType "application/json"
    }
    else {
        Write-Host "Port is already set to $currentPort. No action needed." -ForegroundColor Green
    }
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================
try {
    # 1. Get Credentials
    $Creds = Get-QBitCredentials -Path $CredFilePath

    # 2. Authenticate
    $loginUri = "$QBitUrl/api/v2/auth/login"
    $Body = @{ 
        username = $Creds.UserName
        password = $Creds.GetNetworkCredential().Password 
    }
    
    $Session = $null
    Invoke-RestMethod -Uri $loginUri -Method Post -Body $Body -SessionVariable 'Session' -ErrorAction Stop | Out-Null

    # 3. Get VPN Port
    $vpnPort = Get-ProtonVPNPort
    
    if ($vpnPort) {
        # 4. Update qBittorrent
        Update-QBittorrentConfiguration -WebSession $Session -NewPort $vpnPort
    }
    else {
        Write-Warning "Could not detect an active ProtonVPN port."
    }
}
catch {
    Write-Error "Script failed: $_"
}