$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'dist/native/HealthScan.exe'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
$static = [Reflection.BindingFlags]'Static,NonPublic'
$instance = [Reflection.BindingFlags]'Instance,NonPublic'
$collector = $assembly.GetType('NativeCollector')
$reports = $assembly.GetType('ScanReports')
$cleaner = $assembly.GetType('NativeCleanup')
function Expect($ok, $message) { if (-not $ok) { throw $message } }
function Invoke-Check($type, $name, [object[]]$values) {
    for ($i = 0; $i -lt $values.Length; $i++) {
        if ($null -ne $values[$i]) { $values[$i] = $values[$i].PSObject.BaseObject }
    }
    $type.GetMethod($name,$static).Invoke($null,$values)
}
function Get-Control($window, $name) { $window.GetType().GetField($name,$instance).GetValue($window) }

Expect ((& $exe -Version | Out-String).Trim() -eq ('ForgeHealthScanner '+$assembly.GetName().Version.ToString(3))) 'Version output failed.'
Expect ((Invoke-Check $collector 'FirewallStatus' @($true,1)) -eq 'warning') 'Permissive firewall must warn.'
Expect ((Invoke-Check $collector 'FirewallStatus' @($true,0)) -eq 'pass') 'Blocking firewall should pass.'
Expect ((Invoke-Check $collector 'FirewallStatus' @($true,$null)) -eq 'unknown') 'Unknown inbound action must remain unknown.'
Expect (-not (Invoke-Check $collector 'DefenderActive' @('Passive',$true))) 'Passive Defender should not pass.'
Expect (-not (Invoke-Check $collector 'DefenderActive' @('Normal',$false))) 'Disabled real-time protection should not pass.'
Expect (Invoke-Check $collector 'DefenderActive' @('Normal',$true)) 'Active Defender should be recognized.'
Expect (Invoke-Check $collector 'LowDiskSpace' @([long]8GB,[long]32GB,$true)) 'System volume reserve was missed.'
Expect (-not (Invoke-Check $collector 'LowDiskSpace' @([long]100GB,[long]1TB,$false))) 'Large volume with adequate free space should pass.'
foreach ($exitCode in 0,2) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $start.Arguments = '/d /c exit '+$exitCode
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    Expect ((Invoke-Check $collector 'WaitForScan' @($start)) -eq $exitCode) 'Lost scan subprocess exit status.'
}

$dir = Join-Path ([IO.Path]::GetTempPath()) ('ForgeScannerRegression-'+[guid]::NewGuid().ToString('N'))
$target = Join-Path $dir 'target'
$link = Join-Path $dir 'history-link'
$fixture = Join-Path $dir 'Existing fixture with a long name.exe'
[void][IO.Directory]::CreateDirectory($target)
try {
    [IO.File]::WriteAllText($fixture,'inert fixture')
    $short = (New-Object -ComObject Scripting.FileSystemObject).GetFile($fixture).ShortPath
    Expect ([IO.File]::Exists($short)) 'Fixture path does not resolve.'
    Expect (-not (Invoke-Check $cleaner 'MissingLocalExecutable' @([string]$fixture))) 'Existing file marked missing.'
    Expect (-not (Invoke-Check $cleaner 'MissingLocalExecutable' @([string]$short))) 'Existing short alias marked missing.'
    $journal = [Activator]::CreateInstance($assembly.GetType('StartupEntry'))
    $journal.Name = 'Fixture'
    $journal.Command = '"'+$fixture+'"'
    $journal.Path = $fixture+'.other'
    Expect (-not (Invoke-Check $cleaner 'Apply' @($null,$journal,$true))) 'Inconsistent journal got past validation.'
    $serializer = Invoke-Check $reports 'Serializer' @()
    $old = '{"schemaVersion":1,"source":"windows-collector","collectorVersion":"1.6.0","device":"Fixture","os":"Windows","collectedAt":"2026-11-01T00:00:00Z","checks":[{"name":"Battery health: Battery 1","id":"battery:abc","status":"warning","detail":"75%","action":"Review"}]}'
    $type = $assembly.GetType('ScanReport')
    $first = $serializer.Deserialize($old,$type)
    $next = $serializer.Deserialize($old.Replace('1.6.0','2.0.0').Replace('11-01','11-02').Replace('"warning"','"pass"').Replace('"id":"battery:abc",',''),$type)
    $delta = Invoke-Check $reports 'Compare' @($first,$next)
    Expect ($delta.State -eq 'Needs review') 'Changed rules or uncertain battery identity produced a false resolution.'
    $next.collectorVersion = $first.collectorVersion
    $next.checks[0].name = 'Battery health: Battery 2'
    $next.checks[0].id = 'battery:abc'
    $delta = Invoke-Check $reports 'Compare' @($first,$next)
    Expect ($delta.State -eq 'Resolved warning') 'Stable ID did not follow a reordered pack.'
    [void](New-Item -ItemType Junction -Path $link -Target $target)
    foreach ($method in 'WriteHistory','SavedFiles') {
        $blocked = $false
        $child = [IO.Path]::Combine($link,'scans')
        try {
            if ($method -eq 'WriteHistory') { Invoke-Check $reports $method @($first,$child) }
            else { Invoke-Check $reports $method @($child) }
        } catch { $blocked = $_.Exception.GetBaseException() -is [IO.InvalidDataException] }
        Expect $blocked 'Redirected history folder should be rejected.'
    }
    Expect (@([IO.Directory]::GetFileSystemEntries($target)).Count -eq 0) 'History was written through the junction.'
} finally {
    if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link) }
    [IO.File]::Delete($fixture)
    [IO.Directory]::Delete($target)
    [IO.Directory]::Delete($dir)
}

Add-Type -AssemblyName System.Windows.Forms
$window = [Activator]::CreateInstance($assembly.GetType('NativeWindow'),$true)
try {
    $window.Show()
    [Windows.Forms.Application]::DoEvents()
    $save = Get-Control $window 'saveHistory'
    Expect (-not $save.Checked) 'History was enabled initially.'
    $save.Checked = $true
    (Get-Control $window 'cancel').PerformClick()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Control $window 'pending') -and $watch.Elapsed.TotalSeconds -lt 10) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    Expect ((Get-Control $window 'progress').Text -eq 'Scan canceled') 'Cancel did not finish.'
    (Get-Control $window 'scan').PerformClick()
    Expect (-not $save.Checked) 'Consent carried into retry.'
    Expect ((Get-Control $window 'programs').Text -eq 'Remove a program') 'Remove a program is missing.'
    $window.Close()
    [Windows.Forms.Application]::DoEvents()
    Expect $window.IsDisposed 'Window did not close during collection.'
} finally { $window.Dispose() }
Write-Host 'PASS native policy verdicts, provider process outcomes, version output, file aliases, journal checks, redirected history, comparison, cancellation, retry and close.'
