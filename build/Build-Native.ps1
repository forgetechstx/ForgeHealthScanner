param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist\native' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$compiler = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The Windows .NET Framework compiler could not be found.' }
$exe = Join-Path $OutputDirectory 'HealthScan.exe'
$options = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/warn:4', "/out:$exe",
    '/win32icon:HealthScan.ico', '/resource:ForgeSplash.png,ForgeSplash.png', '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll', '/reference:System.Management.dll', '/reference:System.Web.Extensions.dll', '/reference:Microsoft.CSharp.dll',
    'NativeApp.cs', 'NativeCollector.cs', 'NativeReports.cs', 'NativeCleanup.cs', 'NativeTools.cs', 'RegistryAtomic.cs'
)
Push-Location -LiteralPath $PSScriptRoot
try {
    & $compiler @options
    if ($LASTEXITCODE -ne 0) { throw "C# compilation failed ($LASTEXITCODE)." }
} finally { Pop-Location }
Write-Host "Built $exe ($((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion))."
