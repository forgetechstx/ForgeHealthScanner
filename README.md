# ForgeHealthScanner

Forge Technologies' portable Windows 10/11 health scanner. **Version 2.0.1 is unsigned.** Extract the ZIP and open `HealthScan.exe`. The C# desktop app runs locally using the Windows .NET Framework. It needs no installer or PowerShell session.

[Download the unsigned portable ZIP](https://github.com/forgetechstx/ForgeHealthScanner/releases/download/v2.0.1/ForgeHealthScanner-2.0.1-portable-unsigned.zip) · [Release and SHA-256 checksums](https://github.com/forgetechstx/ForgeHealthScanner/releases/tag/v2.0.1) · [Homepage](https://forgetechstx.github.io/ForgeHealthScanner/)

## Use

- Follow the scan in the main window, cancel it, or filter completed checks. Missing Windows provider data appears as needing review.
- Select **Save this scan locally** during each scan you want to keep. Open **Scan history** to compare two saved scans. A changed collector version or uncertain battery identity can prevent a warning from being marked resolved.
- Import, export or print a report. Reports contain details about the PC.
- Choose **Startup cleanup** to review missing current-user startup entries. Removal requires confirmation and creates a backup. Use **History and undo** for selective recovery or **Backups** to preview and delete backup files.
- **Defender quick scan** asks for approval, monitors Defender and reports its outcome. **Remove a program** opens Windows Installed apps. Select an app there and follow Windows' uninstall prompts.

[Usage and command-line options](README.txt) · [Privacy](PRIVACY.md) · [Build and release](docs/RELEASING.md) · [Signing policy](CODE-SIGNING.md) · [License](LICENSE)

## Build and test

On Windows with Windows PowerShell 5.1, run `./build/Build-Native.ps1`, then `./build/Test-All.ps1`. The binary is written to `dist/native/HealthScan.exe`. The release workflow packages the tested native binary with a checksum list, build manifest and CycloneDX SBOM. No external packages are restored.

Maintained by [forgetechstx](https://github.com/forgetechstx).
