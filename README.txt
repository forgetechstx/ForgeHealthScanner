ForgeHealthScanner 2.0.1 | Forge Technologies | Unsigned portable edition

Verify the ZIP against SHA256SUMS.txt on the release page, extract it and open
HealthScan.exe. The main window starts a local Windows health scan. Cancel stops
collection. Review warnings and unknown checks in Scan results.

Check Save this scan locally during each scan you want to keep. Open Scan history
to reopen or compare saved scans from the same computer. Changes across different
collector versions or uncertain battery identities need review. Use Import,
Export JSON or Print for a report. Local history is kept in
%LOCALAPPDATA%\HealthScan\scan-history.

Startup cleanup reviews simple missing local executable paths in the current
user's Run key. Check entries and confirm to remove them. The whole key and a
recovery journal are backed up under %LOCALAPPDATA%\HealthScan\registry-backups.
History and undo restores selected commands and preserves existing entries.
Use Backups to preview or delete .reg files. Review interrupted cleanup records
before restoring any values.

Remove a program opens Windows Installed apps (Apps & features on Windows 10).
Choose the program and select Uninstall. Windows and the selected uninstaller
handle the operation and any required administrator approval.

Command-line options
  -Version          Print the product and version to standard output and exit.
  -RegistryCleaner  Open startup cleanup for the current account.
  -QuickScan        Ask for approval and monitor a Microsoft Defender quick scan.
                    On success, run the regular health scan in the same window.
                    Declining returns 1223. A completed Defender process returns
                    its exit status after the window closes.

You can copy the executable to another Windows PC. Deleting it leaves your
saved reports and recovery files in their existing locations. See PRIVACY.md
for storage details and CODE-SIGNING.md for signing status. See the v1.6.0
Git tag for the earlier PowerShell/browser edition and its guide.
