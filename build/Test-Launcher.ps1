# Tests for Open-HealthScan.cmd and .gitignore. Runs no scan and starts no browser: only the
# launcher's PowerShell-path lines are run, copied into a temporary batch file.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Launcher.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:passed = 0
function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAILED: $message" }
    $script:passed++
}

# --- Open-HealthScan.cmd runs Windows PowerShell by its full path, 64-bit even from a 32-bit cmd ---
$launcher = @(Get-Content -LiteralPath (Join-Path $root 'Open-HealthScan.cmd'))
$code = @($launcher | Where-Object { $_ -notmatch '^\s*(rem\b|echo\b|::)' })
$bare = @($code | Where-Object { $_ -match '(^|[\s&|(])powershell(\.exe)?(\s|$)' })
Assert ($bare.Count -eq 0) "The launcher runs PowerShell without a full path: $($bare -join ' | ')"
$run = @($code | Where-Object { $_ -match 'Collect-Health\.ps1"\s+-OpenDashboard' })
Assert ($run.Count -eq 1 -and $run[0] -match '^\s*"%HS_PS%"\s') 'The launcher does not start the collector through the resolved PowerShell path.'
$resolve = @($code | Where-Object { $_ -match '^\s*(set "HS_PS=|if exist "%SystemRoot%\\Sysnative\\)' })
Assert ($resolve.Count -eq 2) 'The launcher no longer resolves PowerShell in the expected two lines.'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('HealthScanTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # A planted powershell.exe in the current folder must never be the one chosen.
    [IO.File]::WriteAllBytes((Join-Path $tmp 'powershell.exe'), [byte[]]@())
    $probe = Join-Path $tmp 'probe.cmd'
    [IO.File]::WriteAllLines($probe, [string[]](@('@echo off') + $resolve + @('echo %HS_PS%')), (New-Object Text.ASCIIEncoding))
    $expected64 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd64 = Join-Path $env:SystemRoot $(if ([Environment]::Is64BitProcess) { 'System32\cmd.exe' } else { 'Sysnative\cmd.exe' })
    Push-Location -LiteralPath $tmp
    try {
        $chosen = (& $cmd64 /d /c $probe | Out-String).Trim()
        Assert ($chosen -eq $expected64) "64-bit cmd chose '$chosen'."
        $cmd32 = Join-Path $env:SystemRoot 'SysWOW64\cmd.exe'
        if ([Environment]::Is64BitOperatingSystem -and (Test-Path -LiteralPath $cmd32)) {
            $chosen32 = (& $cmd32 /d /c $probe | Out-String).Trim()
            Assert ($chosen32 -eq (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')) "32-bit cmd chose '$chosen32' instead of the 64-bit PowerShell."
            # And that path really is the 64-bit PowerShell when seen from a 32-bit process.
            $bits = (& $cmd32 /d /c "`"$chosen32`" -NoProfile -NonInteractive -Command [IntPtr]::Size" | Out-String).Trim()
            Assert ($bits -eq '8') "The PowerShell chosen from a 32-bit cmd is not 64-bit (pointer size '$bits')."
        } else { $script:passed += 2 }
    } finally { Pop-Location }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }

# --- .gitignore keeps every report name the tools produce out of version control ---
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    Push-Location -LiteralPath $root
    try {
        foreach ($name in 'health-report.json', 'health-report-2026-11-10.json', 'health-report-2026-11-10 (1).json',
                          'DEMO-health-report.json', 'ComputerHealth-20261110-120000.json', 'latest-report.js', 'reports/x.json') {
            & git check-ignore -q --no-index -- $name
            Assert ($LASTEXITCODE -eq 0) ".gitignore does not ignore the report name '$name'."
        }
        foreach ($name in 'index.html', 'Collect-Health.ps1', 'HealthScan.exe', 'build/Test-Exe.ps1') {
            & git check-ignore -q --no-index -- $name
            Assert ($LASTEXITCODE -eq 1) ".gitignore wrongly ignores '$name'."
        }
    } finally { Pop-Location }
} else { Write-Host 'git not available; .gitignore checks skipped.' }

Write-Host "$script:passed launcher checks passed. No scan was run and no browser was started."
