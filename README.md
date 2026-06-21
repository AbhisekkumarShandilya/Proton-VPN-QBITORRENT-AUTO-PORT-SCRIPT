# Proton-VPN-QBITORRENT-AUTO-PORT-SCRIPT
Keeps qBittorrent's listening port in sync with ProtonVPN's forwarded port, automatically, on Windows.

Current version: **1.0.0** — see [CHANGELOG.md](CHANGELOG.md) for release history.

## How it works
ProtonVPN's Windows client writes the active forwarded port to
`%LOCALAPPDATA%\ProtonVPN\port.txt` while port forwarding is enabled. The script
watches that file with a `FileSystemWatcher` and pushes any change to qBittorrent's
Web API immediately, with a 60s periodic check as a safety net in case a file event
is missed. It only calls the qBittorrent API when the port has actually changed.

## Setup

1. Enable Port Forwarding (NAT-PMP) in the ProtonVPN client's connection settings.
2. Enable the Web UI in qBittorrent (Tools > Options > Web UI) and note the URL/credentials.
3. Create the credential file once, as the same Windows user that will run the script:
   ```powershell
   Get-Credential | Export-Clixml -Path '.\Script\qbit_creds.xml'
   ```
   This uses Windows DPAPI, so the file can only be decrypted by that user on that machine.
4. Run the script:
   ```powershell
   .\Script\update_qbit_port_protonvpn.ps1
   ```
   It runs continuously (it's a watcher, not a one-shot), so register it as a Scheduled
   Task with an "At log on" trigger to start it automatically:
   ```powershell
   $action = New-ScheduledTaskAction -Execute "powershell.exe" `
     -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PWD\Script\update_qbit_port_protonvpn.ps1`""
   $trigger = New-ScheduledTaskTrigger -AtLogOn
   Register-ScheduledTask -TaskName "ProtonVPN-QBit-PortSync" -Action $action -Trigger $trigger
   ```

## Logs
Status and errors are written to `Script\sync.log`. The last successfully applied
port is cached in `Script\last_port.txt` to avoid redundant API calls.

## Parameters
- `-QBitUrl` — qBittorrent Web UI URL (default `http://localhost:8080`)
- `-CredFilePath` — path to the DPAPI-encrypted credential file
- `-StateFilePath` — path to the last-applied-port cache file
- `-LogFilePath` — path to the log file
