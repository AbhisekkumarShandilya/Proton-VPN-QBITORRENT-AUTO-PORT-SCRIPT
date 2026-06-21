# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-06-22

### Changed
- Replaced fixed-interval polling with an event-driven `FileSystemWatcher` on
  ProtonVPN's `port.txt`, so the port syncs to qBittorrent immediately instead
  of on the next scheduled tick. A 60s periodic check remains as a safety net
  in case a file-system event is missed.
- qBittorrent session is now reused across syncs instead of re-authenticating
  on every run.
- The last-applied port is cached (`last_port.txt`) so qBittorrent's API is
  only called when the port has actually changed.
- Status, warnings, and errors are now written to a log file (`sync.log`)
  instead of only the console, since the script runs unattended.

### Removed
- Notification-DB scraping fallback for port detection. It parsed
  Windows' notification database for ProtonVPN toast text, which was fragile
  (locale-dependent, broke if notifications expired or were missed) and is no
  longer needed now that `port.txt` is read reliably and immediately.

### Added
- `.gitignore` for generated local files (`qbit_creds.xml`, `last_port.txt`,
  `sync.log`).

## [0.1.0] - 2025 (initial release)
- Initial script: polls ProtonVPN's `port.txt` (or scrapes the Windows
  notification DB as a fallback) and pushes the port to qBittorrent via its
  Web API, with credentials loaded from a DPAPI-encrypted XML file.
