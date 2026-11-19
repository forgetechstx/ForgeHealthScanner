# Builds HealthScan.exe from build\HealthScan.cs, embedding Collect-Health.ps1 and index.html.
# Uses only what ships with Windows: the .NET Framework 4.x C# compiler. Nothing is installed.
# Run from the app folder (the default execution policy blocks running it directly):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build.ps1
# Rebuild after changing Collect-Health.ps1 or index.html, or the exe will carry the old copies.
param(
  # Only check that the version agrees in the three files, and build nothing (build\Test-Exe.ps1 uses this).
  [switch]$VersionCheckOnly,
  # The app folder (with build\HealthScan.cs inside); the default is the folder above this script.
  [string]$AppFolder
)
$ErrorActionPreference = 'Stop'
$root = if ($AppFolder) { $AppFolder } else { Split-Path -Parent $PSScriptRoot }
$collector = Join-Path $root 'Collect-Health.ps1'
$dashboard = Join-Path $root 'index.html'
$cleaner = Join-Path $root 'RegistryCleaner.ps1'
$source = Join-Path $root 'build\HealthScan.cs'
$atomicSource = Join-Path $root 'build\RegistryAtomic.cs'
$icon = Join-Path $root 'build\HealthScan.ico'
$splash = Join-Path $root 'build\ForgeSplash.png'
$out = Join-Path $root 'HealthScan.exe'
foreach ($f in $collector, $dashboard, $source) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f" } }

# The version is written in three places; refuse to build an exe whose parts disagree. A version is
# X.Y or X.Y.Z; a missing patch number counts as .0, so 1.4 and 1.4.0 are the same version.
function ConvertTo-FullVersion([string]$version) { if ($version -match '^\d+\.\d+$') { "$version.0" } else { $version } }
$text = { param($path) Get-Content -LiteralPath $path -Raw -Encoding UTF8 }
$vCollector = if ((& $text $collector) -match "(?m)^\`$CollectorVersion='(\d+\.\d+(?:\.\d+)?)'") { $Matches[1] }
$dashText = & $text $dashboard
# Case-sensitive on purpose: the badge (vX.Y</span>) and the About text (Version X.Y).
$vDashboardAll = @(@([regex]::Matches($dashText, '\bv(\d+\.\d+(?:\.\d+)?)</span>')) + @([regex]::Matches($dashText, '\bVersion (\d+\.\d+(?:\.\d+)?)\b')) |
  ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$vDashboard = @($vDashboardAll | ForEach-Object { ConvertTo-FullVersion $_ } | Select-Object -Unique)
# Both assembly attributes must read "X.Y.Z.0".
$vExeAll = @([regex]::Matches((& $text $source), 'Assembly(?:File)?Version\("([^"]*)"\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$vExe = if ($vExeAll.Count -eq 1 -and $vExeAll[0] -match '^(\d+\.\d+\.\d+)\.0$') { $Matches[1] }
$vFull = if ($vCollector) { ConvertTo-FullVersion $vCollector }
if (-not $vFull -or -not $vExe -or $vDashboard.Count -ne 1 -or $vDashboard[0] -ne $vFull -or $vExe -ne $vFull) {
  throw "Version mismatch: Collect-Health.ps1 '$vCollector', index.html '$($vDashboardAll -join ',')', HealthScan.cs '$($vExeAll -join ',')'. Set all of them to the same version (X.Y or X.Y.Z; the assembly versions as X.Y.Z.0)."
}
if ($VersionCheckOnly) { Write-Host "Versions agree: $vCollector"; return }
if (-not (Test-Path -LiteralPath $cleaner)) { throw "Missing $cleaner" }
if (-not (Test-Path -LiteralPath $atomicSource)) { throw "Missing $atomicSource" }
if (-not (Test-Path -LiteralPath $icon)) { throw "Missing $icon" }
if (-not (Test-Path -LiteralPath $splash)) { throw "Missing $splash" }

$csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'The .NET Framework 4.x C# compiler (csc.exe) was not found.' }
# The PowerShell engine library the launcher hosts; this is the copy Windows PowerShell itself uses.
$sma = [psobject].Assembly.Location
# The launcher swaps this exact tag for the report; fail the build rather than ship an exe that cannot.
$marker = '<script src="latest-report.js" onload="window.HEALTHSCAN_REPORT_FILE=true"></script>'
if (-not $dashText.Contains($marker)) { throw 'index.html no longer contains the saved-scan script tag that HealthScan.cs replaces.' }

# csc splits /resource on commas, so run from the app folder and name the files without a path.
Push-Location -LiteralPath $root
try {
  & $csc /nologo /target:exe /platform:anycpu /optimize+ /warn:4 `
    "/out:$out" `
    "/win32icon:$icon" `
    "/reference:$sma" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    "/resource:Collect-Health.ps1,Collect-Health.ps1" `
    "/resource:index.html,index.html" `
    "/resource:RegistryCleaner.ps1,RegistryCleaner.ps1" `
    "/resource:build\ForgeSplash.png,ForgeSplash.png" `
    $source $atomicSource
} finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "Compilation failed (exit code $LASTEXITCODE)." }
$item = Get-Item -LiteralPath $out

# Smoke check: the new exe starts, reports this version, and carries byte-identical copies of the
# two files. build\Test-Exe.ps1 repeats this for a committed exe and also runs a full scan.
$said = (& $out -Version | Out-String).Trim()
$saidVersion = if ($said -match '^Total Computer Health Scan (\d+\.\d+(?:\.\d+)?)$') { ConvertTo-FullVersion $Matches[1] }
if ($LASTEXITCODE -ne 0 -or $saidVersion -ne $vFull) { throw "The built exe did not start as expected (-Version said '$said', exit code $LASTEXITCODE)." }
# Loaded from bytes so the file is not locked.
$asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($out))
$sha = [Security.Cryptography.SHA256]::Create()
foreach ($name in 'Collect-Health.ps1', 'index.html', 'RegistryCleaner.ps1', 'build/ForgeSplash.png') {
  $s = $asm.GetManifestResourceStream([IO.Path]::GetFileName($name))
  if (-not $s) { throw "The built exe does not embed $name." }
  try { $embedded = [BitConverter]::ToString($sha.ComputeHash($s)) } finally { $s.Dispose() }
  $onDisk = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $root $name))))
  if ($embedded -ne $onDisk) { throw "The built exe's copy of $name differs from the file on disk." }
}
Write-Host "Built $($item.FullName) v$vCollector ($([math]::Round($item.Length/1KB)) KB); embedded files match the sources."
