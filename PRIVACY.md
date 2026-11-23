# Privacy policy

ForgeHealthScanner by Forge Technologies / forgetechstx. Updated 2026-11-23.

## Native desktop app (2.0.1)

ForgeHealthScanner reads local Windows and hardware status. Reports include the PC name, OS build, time, storage and battery details, hashed battery identifiers when available, registered antivirus names, configuration results and event counts. Startup inventory includes a count. A report can identify the PC.

The app keeps results in memory. Opting in during a scan saves its report under `%LOCALAPPDATA%\HealthScan\scan-history`. Users may export to another location or print through a configured printer. Shared printers and synchronized folders may send copies elsewhere. Imported reports are read locally.

Confirmed startup cleanup saves the entire current-user Run key and a journal under `%LOCALAPPDATA%\HealthScan\registry-backups`. These can include private commands, paths and the account SID. Undo restores selected entries. Users may preview and delete individual backups. History and backup management reject redirected folders.

Windows Update checks use the local cache. A user-requested Defender scan follows Microsoft's existing configuration. Remove a program opens Windows Installed apps, where Windows and the selected uninstaller handle removal. ForgeHealthScanner does not upload a software inventory or health reports. It has no project telemetry, account, installed service or startup task.

The earlier PowerShell edition used a loopback browser dashboard and a separate script mode. [Read the 1.6.0 privacy policy](https://github.com/forgetechstx/ForgeHealthScanner/blob/v1.6.0/PRIVACY.md).

## Website and support

The static download site has no project trackers, forms, third-party fonts or
analytics. GitHub hosts the site and release downloads and processes access data,
including IP addresses, under its privacy statement:
https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement

GitHub issues are public. Do not upload reports, logs, startup backups or personal
data without reviewing and redacting them. The maintainer receives only material
you choose to submit. Contact the maintainer through the repository; no private
contact address is required to run the app.

## Retention and removal

History/backups remain local until you remove them; no automatic retention limit
is imposed. Deleting the EXE does not remove history, backups, browser data or
exported files. Preserve recovery files you need before deletion. OS/browser/cloud
copies are managed through those products. No existing user data is migrated or
deleted by the publication changes.
