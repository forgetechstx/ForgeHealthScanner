# ForgeHealthScanner

Portable Windows health-status utility by **Forge Technologies**, maintained by
[`forgetechstx`](https://github.com/forgetechstx). Windows 10/11; no installer,
service, scheduled task, account, or application telemetry.

**Current release: 1.5.2 — unsigned.** Windows may show an unknown-publisher warning.
SignPath has not accepted or sponsored this project. No trusted signature is claimed.

- [Homepage / downloads](https://forgetechstx.github.io/ForgeHealthScanner/)
- [Releases](https://github.com/forgetechstx/ForgeHealthScanner/releases)
- [Privacy](PRIVACY.md) · [Code signing policy](CODE-SIGNING.md)
- [Detailed usage](README.txt) · [Build and release](docs/RELEASING.md)
- [Publication review](docs/PUBLICATION-REVIEW.md) · [License](LICENSE)

## Use

Download the portable ZIP, verify SHA-256 against the release checksum file,
extract, and run `HealthScan.exe`. The executable embeds the collector and dashboard.
Windows' included .NET Framework 4.x and Windows PowerShell 5.1 are required.
Optional checks may need administrator rights. The progress window offers Cancel.
Local history is off by default for every scan; enable it to save that completed
report under `%LOCALAPPDATA%\HealthScan\scan-history`.

The report covers storage, battery, Windows Update cache, protection status,
startup inventory and selected stability events. It is not a medical application
or a guarantee of system security. It performs no remote port or exploit scanning.
The optional Defender quick scan uses Microsoft Defender. Startup cleanup only
changes explicitly selected missing per-user Run entries after confirmation,
backup and a fresh check. Undo skips values that already exist.

Remove the executable and shortcut to stop using it. Optional reports/history and
registry backups remain yours; review or retain them before deleting any files.
Removing the app does not undo previously confirmed startup changes.

## Build / test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build/Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build/Test-All.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build/Package.ps1
```

No NuGet/npm packages are restored. Dashboard tests use Node's built-in modules.
CI pins Node and action commits; Windows system libraries and runner images are
provided by Microsoft and are recorded, not falsely represented as vendored OSS.
See [dependency inventory](THIRD-PARTY-NOTICES.md).

This is a new public project. Tests, audits and release evidence are engineering
evidence, not proof of widespread adoption or independent endorsement.
