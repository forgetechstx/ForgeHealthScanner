$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($test in 'Test-Collector.ps1','Test-Extras.ps1','Test-Platform.ps1','Test-Robustness.ps1','Test-Launcher.ps1','Test-RegistryCleaner.ps1','Test-PortableRegistry.ps1','Test-Exe.ps1','Test-Publication.ps1') {
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
 if($LASTEXITCODE -ne 0){throw "$test failed ($LASTEXITCODE)"}
}
& node (Join-Path $PSScriptRoot 'Test-Dashboard.js')
if($LASTEXITCODE -ne 0){throw 'Dashboard tests failed'}
