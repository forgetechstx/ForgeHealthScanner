param([string]$Executable = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\native\HealthScan.exe'))
$ErrorActionPreference = 'Stop'
$file = (Resolve-Path -LiteralPath $Executable).Path
$bytes = [IO.File]::ReadAllBytes($file)
$assembly = [Reflection.Assembly]::Load($bytes)
$references = @($assembly.GetReferencedAssemblies() | ForEach-Object Name)
if ($references -contains 'System.Management.Automation' -or @($assembly.GetManifestResourceNames() | Where-Object { $_ -match '\.(ps1|html)$' }).Count) {
    throw 'The native build contains a PowerShell or browser-dashboard dependency.'
}
$peOffset = [BitConverter]::ToInt32($bytes, 60)
if ([BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68) -ne 2) { throw 'The executable is not a Windows GUI application.' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('HealthScan-Native-Verify-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$probe = Join-Path $temp 'HealthScan.exe'
$report = Join-Path $temp 'result.txt'
try {
    [IO.File]::Copy($file, $probe, $false)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $probe
    $info.Arguments = '--self-test "' + $report + '"'
    $info.WorkingDirectory = $temp
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(180000)) {
            $process.Kill()
            throw 'The isolated native self-test did not finish.'
        }
        if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report }
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $report)) { throw "Native test failed ($($process.ExitCode))." }
    } finally { $process.Dispose() }
    Write-Host 'PASS portable single executable, Windows GUI subsystem and no embedded PowerShell.'
} finally {
    [IO.File]::Delete($report)
    [IO.File]::Delete($probe)
    [IO.Directory]::Delete($temp)
}
