# Tests how the collector copes with its environment: slow Windows queries, a 32-bit PowerShell host,
# Constrained Language Mode, PowerShell module logging, OneDrive-synced folders and elevated runs.
# Windows health data is mocked. The only real reads are two registry values (Windows edition and build)
# read from a 64-bit and a 32-bit PowerShell; one short cmd.exe "rem" is started to test process start.
# Nothing is changed, no browser is opened and the clipboard is not touched.
$ErrorActionPreference = 'Stop'
$collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Collect-Health.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Collector parse errors: $($parseErrors -join '; ')" }
function Get-FunctionText([string]$Name) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $false)
    if (-not $functionAst) { throw "Collector function not found: $Name" }
    return $functionAst.Extent.Text
}
foreach ($functionName in 'Invoke-Bounded','Exit-Collector','Get-FailureNote','Write-TextFile','Start-BrowserProcess','Get-SyncNote','Test-Elevated') {
    . ([scriptblock]::Create((Get-FunctionText $functionName)))
}
$script:StepRunspace = $null
$script:StepAbandoned = $false
$script:passed = 0
# Fully qualified: the hand-off tests below replace Write-Host with a mock.
function Pass([string]$Name) { $script:passed++; Microsoft.PowerShell.Utility\Write-Host "PASS $Name" }

# --- Bounded steps: real second runspace, values and errors come back, a hung step is left behind ---
if ((Invoke-Bounded 'adding' 10 { param($a, $b) $a + $b } @(2, 3)) -ne 5) { throw 'Step arguments or result were lost.' }
$when = Invoke-Bounded 'date' 10 { [datetime]'2026-11-10T08:00:00' }
if (-not ($when -is [datetime]) -or $when.Hour -ne 8) { throw 'A date did not come back as a date.' }
$custom = Invoke-Bounded 'object' 10 { New-Object PSObject -Property @{ Name = 'x'; Count = 3 } }
if ($custom.Name -ne 'x' -or $custom.Count -ne 3) { throw 'A custom object lost its properties.' }
if (@(Invoke-Bounded 'list' 10 { 1, 2, 3 }).Count -ne 3) { throw 'A list was not returned item by item.' }
$flag = Invoke-Bounded 'flag' 10 { $false }
if ($flag -ne $false -or $flag) { throw 'A false value did not come back as false.' }
$failed = $false
try { Invoke-Bounded 'failing' 10 { throw 'boom' } } catch { $failed = $true; if (Get-FailureNote $_) { throw 'An ordinary failure was reported as a timeout.' } }
if (-not $failed) { throw 'A failing step did not raise an error.' }
if ($script:StepAbandoned) { throw 'A step that finished was marked as left behind.' }
Pass 'Bounded steps return values and errors from the second runspace'

$clock = [Diagnostics.Stopwatch]::StartNew()
$info = @()
$timeoutError = $null
try {
    & { Invoke-Bounded 'test sleeping step' 11 { Start-Sleep -Seconds 120; 'late' } } 6>&1 | ForEach-Object { $info += "$_" }
} catch { $timeoutError = $_ }
$elapsed = $clock.Elapsed.TotalSeconds
if (-not $timeoutError -or "$($timeoutError.FullyQualifiedErrorId)" -notmatch '^HealthScanStepTimeout') { throw "A hung step did not time out ($timeoutError)." }
if ($elapsed -lt 10.5 -or $elapsed -gt 25) { throw "A hung step took $elapsed seconds to be skipped with an 11 second limit." }
if (-not ($info -match 'Still waiting for Windows to answer: test sleeping step')) { throw "No progress note named the slow step ($($info -join ' / '))." }
if (-not ($info -match 'Skipped: test sleeping step')) { throw 'No note said the slow step was skipped.' }
if (-not (Get-FailureNote $timeoutError)) { throw 'A timeout is not explained in the check detail.' }
if ((Invoke-Bounded 'after a timeout' 10 { 42 }) -ne 42) { throw 'Steps after a timeout did not run.' }
if (-not $script:StepAbandoned) { throw 'A step left behind was not recorded.' }
Pass 'A hung step is skipped after its limit, named on screen, and later steps still run'

# --- A step left behind must not keep the console window open after the report is handed over ---
# Under -EmitJson (inside HealthScan.exe) the process is never ended, and without a stuck step nothing changes.
$EmitJson = $true
$script:StepAbandoned = $true
Exit-Collector 0
$EmitJson = $false
$script:StepAbandoned = $false
Exit-Collector 0
$script:StepAbandoned = $true
$lastStatement = $ast.EndBlock.Statements[$ast.EndBlock.Statements.Count - 1].Extent.Text
if ($lastStatement -ne 'Exit-Collector 0') { throw "The collector must end with 'Exit-Collector 0' after the hand-off (ends with: $lastStatement)." }
$trapAst = @($ast.EndBlock.Traps)
if ($trapAst.Count -ne 1 -or $trapAst[0].Body.Extent.Text -notmatch 'Exit-Collector 1') { throw 'The collector needs one script-level trap that reports a terminating scan failure.' }
# Real child processes: a .NET call that never returns, left behind after a 1 second limit.
$childText = @'
param($path, $mode)
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($name in 'Invoke-Bounded', 'Exit-Collector') {
    . ([scriptblock]::Create($ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false).Extent.Text))
}
$EmitJson = ($mode -eq 'emitjson')
$script:StepRunspace = $null; $script:StepAbandoned = $false
try { Invoke-Bounded 'test stuck call' 1 { [Threading.Thread]::Sleep(60000) } } catch { }
"abandoned:$script:StepAbandoned"
if ($mode -eq 'fail') { & ([scriptblock]::Create($ast.EndBlock.Traps[0].Extent.Text + "`nthrow 'test failure after a stuck step'")) }
if ($mode -ne 'none') { Exit-Collector 7 }
'end of script'
'@
function Invoke-ExitChild([string]$Mode, [int]$WaitSeconds) {
    $command = "& {`n$childText`n} '$($collectorPath.Replace("'", "''"))' '$Mode'"
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $exited = $process.WaitForExit($WaitSeconds * 1000)
        $seconds = $clock.Elapsed.TotalSeconds
        if (-not $exited) { $process.Kill(); [void]$process.WaitForExit(10000) }
        [void]$output.Wait(10000)
        return [pscustomobject]@{ Exited = $exited; Seconds = $seconds; Code = $(if ($exited) { $process.ExitCode } else { $null }); Output = [string]$output.Result }
    } finally { $process.Dispose() }
}
$control = Invoke-ExitChild 'none' 12
if (-not $control.Output.Contains('abandoned:True')) { throw "The stuck call in the control process was not left behind ($($control.Output))." }
if ($control.Exited) { throw 'Control: a left-behind call no longer keeps PowerShell running, so this test proves nothing.' }
$ended = Invoke-ExitChild 'exit' 30
if (-not $ended.Exited -or $ended.Code -ne 7) { throw "After a stuck step the process did not end with the intended exit code (exited: $($ended.Exited), code: $($ended.Code))." }
if ($ended.Output.Contains('end of script') -or -not $ended.Output.Contains('abandoned:True')) { throw "The process did not end at Exit-Collector ($($ended.Output))." }
$failedRun = Invoke-ExitChild 'fail' 30
if (-not $failedRun.Exited -or $failedRun.Code -ne 1) { throw "A scan that failed after a stuck step did not end with exit code 1 (exited: $($failedRun.Exited), code: $($failedRun.Code))." }
if (-not $failedRun.Output.Contains('Scan stopped before the report was ready.')) { throw 'The error that stopped the scan was not shown before the process ended.' }
$hosted = Invoke-ExitChild 'emitjson' 8
if ($hosted.Exited -or -not $hosted.Output.Contains('end of script')) { throw 'Under -EmitJson the process must never be ended by the collector.' }
# Constrained Language Mode refuses [Environment]::Exit, so a plain exit is used there.
$clmExit = [runspacefactory]::CreateRunspace()
$clmExit.Open()
try {
    $clmExit.SessionStateProxy.LanguageMode = 'ConstrainedLanguage'
    $shell = [powershell]::Create()
    $shell.Runspace = $clmExit
    [void]$shell.AddScript((Get-FunctionText 'Exit-Collector') + "`n" + '$EmitJson = $false; $script:StepAbandoned = $true; "before"; Exit-Collector 3; "after"')
    $result = @($shell.Invoke())
    if (($result -join ',') -ne 'before' -or $shell.Streams.Error.Count) { throw "Under Constrained Language Mode Exit-Collector did not end the script cleanly ($($result -join ',') / $($shell.Streams.Error -join ' | '))." }
} finally { $clmExit.Dispose() }
Pass "A stuck step no longer keeps the console open: the process ends in $([int]$ended.Seconds)s with the intended code (control still running after 12s)"

$cimTimeout = New-Object System.Management.Automation.ErrorRecord((New-Object Exception 'x'), 'HRESULT 0x80338029', 'OperationTimeout', $null)
if (-not (Get-FailureNote $cimTimeout)) { throw 'A CIM operation timeout is not explained.' }
Pass 'CIM operation timeouts are explained'

# --- 64-bit registry view from a 32-bit PowerShell ---
$ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
if ([Environment]::Is64BitOperatingSystem -and [Environment]::Is64BitProcess -and (Test-Path -LiteralPath $ps32)) {
    $reader = {
        param($path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($name in 'Get-MachineRegistryValues', 'Test-MachineRegistryKey') {
            . ([scriptblock]::Create($ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false).Extent.Text))
        }
        $cv = Get-MachineRegistryValues 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $plain = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        "$([Environment]::Is64BitProcess)|$($cv.EditionID)|$($cv.CurrentBuildNumber)|$($cv.InstallationType)|$(Test-MachineRegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update')|$($plain.EditionID)"
    }
    $native = [string](& $reader $collectorPath)
    $wow = [string](& $ps32 -NoProfile -NonInteractive -Command $reader -args $collectorPath)
    $n = $native.Split('|'); $w = $wow.Split('|')
    if ($n[0] -ne 'True' -or $w[0] -ne 'False') { throw "Could not run the 64-bit and 32-bit readers ($native / $wow)." }
    if (($n[1..4] -join '|') -ne ($w[1..4] -join '|')) { throw "A 32-bit host read different machine settings: 64-bit '$native', 32-bit '$wow'." }
    if ($n[4] -ne 'True') { throw 'The Windows Update registry key was not found through the 64-bit view.' }
    $note = if ($w[5] -ne $n[1]) { " (a plain 32-bit read says '$($w[5])' here)" } else { '' }
    Pass "A 32-bit host reads the 64-bit registry view: edition '$($n[1])'$note"
} else {
    Write-Host 'SKIP 32-bit registry view: no 32-bit PowerShell on this PC.'
}

# --- Constrained Language Mode: the whole scan degrades check by check ---
$mocks = @'
function New-Object {
    param([Parameter(Position = 0)][string]$TypeName, [string]$ComObject, [System.Collections.IDictionary]$Property, [object[]]$ArgumentList)
    # Same refusal Constrained Language Mode gives: only core types; never a real COM object.
    if ($ComObject -or $TypeName -notmatch '^(PSObject|System\.Management\.Automation\.PSObject)$') { throw 'Cannot create type. Only core types are supported in this language mode.' }
    Microsoft.PowerShell.Utility\New-Object -TypeName PSObject -Property $Property
}
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter, [string[]]$Property, [int]$OperationTimeoutSec)
    switch ($ClassName) {
        'Win32_OperatingSystem' { [pscustomobject]@{ FreePhysicalMemory = 8000000; TotalVisibleMemorySize = 16000000; LastBootUpTime = (Get-Date).AddDays(-1); Caption = 'Microsoft Windows 11 Pro' } }
        'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; Size = 500GB; FreeSpace = 200GB } }
        'AntiVirusProduct' { }
        'Win32_Battery' { [pscustomobject]@{ Name = 'Battery' } }
        'BatteryStaticData' { [pscustomobject]@{ Active = $true; InstanceName = 'PACK_A'; Tag = 1; Capabilities = [uint32]2147483648; DesignedCapacity = 50000 } }
        'BatteryFullChargedCapacity' { [pscustomobject]@{ Active = $true; InstanceName = 'PACK_A'; Tag = 1; FullChargedCapacity = 45000 } }
        'Win32_StartupCommand' { [pscustomobject]@{ Name = 'Helper'; Location = 'Startup' } }
        'Win32_PnPEntity' { [pscustomobject]@{ HardwareID = @('ACPI\MSFT0101'); CompatibleID = $null; ConfigManagerErrorCode = 0 } }
        'Win32_ComputerSystem' { [pscustomobject]@{ UserName = '' } }
        default { throw "Unexpected CIM class: $ClassName" }
    }
}
function Get-PhysicalDisk { [CmdletBinding()] param() [pscustomobject]@{ DeviceId = '0'; FriendlyName = 'Test SSD'; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); MediaType = 'SSD'; BusType = 'NVMe'; Size = 512GB } }
function Get-StorageReliabilityCounter { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$PhysicalDisk) process { [pscustomobject]@{ Wear = 1; Temperature = 30 } } }
function Get-MpComputerStatus { [CmdletBinding()] param() [pscustomobject]@{ RealTimeProtectionEnabled = $true; AntivirusEnabled = $true; AntivirusSignatureAge = 0; QuickScanEndTime = (Get-Date).AddDays(-1) } }
function Get-MpThreat { [CmdletBinding()] param() }
function Start-MpScan { [CmdletBinding()] param($ScanType) }
function Get-NetFirewallProfile { [CmdletBinding()] param($PolicyStore) [pscustomobject]@{ Name = 'Public'; Enabled = $true } }
function Get-HotFix { [CmdletBinding()] param() [pscustomobject]@{ HotFixID = 'KB1'; InstalledOn = (Get-Date).AddDays(-3) } }
function Get-BitLockerVolume { [CmdletBinding()] param($MountPoint) [pscustomobject]@{ ProtectionStatus = 'On'; VolumeStatus = 'FullyEncrypted' } }
function Get-ItemProperty {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Path)
    switch -Wildcard ($Path) {
        '*\Windows NT\CurrentVersion' { [pscustomobject]@{ CurrentBuildNumber = '26300'; EditionID = 'Professional'; InstallationType = 'Client'; DisplayVersion = '26H2' } }
        '*\SecureBoot\State' { [pscustomobject]@{ UEFISecureBootEnabled = 1 } }
        '*\Policies\System' { [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 5 } }
        '*\WindowsUpdate\UX\Settings' { [pscustomobject]@{ PauseUpdatesExpiryTime = 'PAUSE_END_UTC'; PauseFeatureUpdatesEndTime = '2026-01-01T00:00:00' } }
        default { throw 'Registry key not found.' }
    }
}
function Test-Path { [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath) $false }
function Get-WinEvent {
    [CmdletBinding()]
    param($LogName, $FilterXPath, [switch]$Oldest, $MaxEvents)
    if ($Oldest) { return [pscustomobject]@{ TimeCreated = (Get-Date).AddDays(-90) } }
    throw (Microsoft.PowerShell.Utility\New-Object System.Management.Automation.ErrorRecord((Microsoft.PowerShell.Utility\New-Object Exception 'No events were found.'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null))
}
'@
# Updates paused for 20 more days, as Settings records it (UTC).
$pauseEnd = [datetime]::SpecifyKind((Get-Date).ToUniversalTime().Date.AddDays(20).AddHours(12), [DateTimeKind]::Utc)
$mocks = $mocks.Replace('PAUSE_END_UTC', $pauseEnd.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))
# A PC named after its user: the computer name pairs reports, so it must not be username-redacted.
$realNames = @{ COMPUTERNAME = $env:COMPUTERNAME; USERNAME = $env:USERNAME }
$env:USERNAME = 'HSTESTUSER'
$env:COMPUTERNAME = "HSTESTUSER-PC`t" + ('A' * 70)
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
try {
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($mocks).Invoke()
    $runspace.SessionStateProxy.LanguageMode = 'ConstrainedLanguage'
    $shell.Commands.Clear()
    [void]$shell.AddScript('try { [math]::Round(1.5); "full" } catch { "constrained" }')
    if ([string]($shell.Invoke() | Select-Object -Last 1) -ne 'constrained') { throw 'The test runspace is not in Constrained Language Mode.' }
    $shell.Commands.Clear()
    [void]$shell.AddScript("& '$($collectorPath.Replace("'", "''"))' -EmitJson")
    $output = @($shell.Invoke())
    $errors = @($shell.Streams.Error)
    $jsonText = [string]($output | Where-Object { "$_".StartsWith('{') } | Select-Object -Last 1)
    if (-not $jsonText) { throw "The scan stopped under Constrained Language Mode: $($errors -join ' | ')" }
    $clmReport = $jsonText | ConvertFrom-Json
    $expected = [ordered]@{
        'Memory availability' = 'pass'; 'System uptime' = 'pass'; 'Disk space C:' = 'pass'; 'Drive health: Disk 0 (Test SSD)' = 'pass'
        'Real-time antivirus protection' = 'pass'; 'Defender signatures' = 'pass'; 'Defender quick scan' = 'info'; 'Active Defender detections' = 'pass'
        # The pause is read without TryParse, which Constrained Language Mode refuses.
        'Windows Firewall profiles' = 'pass'; 'Restart pending' = 'unknown'; 'Windows Update recency' = 'warning'
        # The offline update search needs a COM object, which Constrained Language Mode refuses.
        'Pending Windows updates' = 'unknown'
        'System drive encryption' = 'pass'; 'Battery health: Battery 1' = 'pass'; 'Startup apps (inventory only)' = 'info'
        'Windows version support' = 'pass'; 'TPM security chip' = 'pass'; 'User Account Control' = 'pass'
        'System stability (last 30 days)' = 'pass'; 'Drive error events (last 30 days)' = 'pass'; 'Program crashes (last 7 days, inventory only)' = 'info'
    }
    foreach ($name in $expected.Keys) {
        $check = @($clmReport.checks | Where-Object { $_.name -eq $name })
        if ($check.Count -ne 1 -or $check[0].status -ne $expected[$name]) { throw "Under Constrained Language Mode '$name' was '$($check.status)' ($($check.detail)), expected '$($expected[$name])'." }
    }
    if (-not @($clmReport.checks | Where-Object { $_.name -eq 'Secure Boot' -and $_.status -in 'pass', 'info' }).Count) { throw 'Secure Boot check missing under Constrained Language Mode.' }
    if ($jsonText -match 'core types|language mode|Cannot ') { throw 'Raw language-mode error text reached the report.' }
    if ($jsonText.Contains('"id"')) { throw 'The battery identifier should be omitted when hashing is refused.' }
    $recency = @($clmReport.checks | Where-Object { $_.name -eq 'Windows Update recency' })[0]
    $pauseText = 'Windows updates are paused until ' + $pauseEnd.ToLocalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + '.'
    if (-not $recency.detail.Contains($pauseText) -or $recency.action -notmatch 'Resume updates') { throw "Under Constrained Language Mode the update pause was missed ($($recency.detail))." }
    $expectedDevice = ('HSTESTUSER-PC ' + ('A' * 70)).Substring(0, 61) + '...'
    if ($clmReport.device -ne $expectedDevice) { throw "The computer name must be one bounded line and not username-redacted ('$($clmReport.device)')." }
    Pass "The whole scan completes under Constrained Language Mode ($($clmReport.checks.Count) checks), sees an update pause, and keeps the computer name"
} finally {
    $runspace.Dispose()
    $env:COMPUTERNAME = $realNames.COMPUTERNAME; $env:USERNAME = $realNames.USERNAME
}

# --- Report data never passes through cmdlet parameters (PowerShell module logging records them) ---
$tracePath = Join-Path ([IO.Path]::GetTempPath()) ('healthscan-trace-' + [guid]::NewGuid().ToString('N') + '.txt')
$filePath = Join-Path ([IO.Path]::GetTempPath()) ('healthscan-test-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    Trace-Command -Name ParameterBinding -FilePath $tracePath -Expression { Write-TextFile $filePath '{"SECRET_REPORT_DATA":1}' } | Out-Null
    $bytes = [IO.File]::ReadAllBytes($filePath)
    if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw 'Saved reports must keep their UTF-8 byte-order mark.' }
    if ([Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) -ne "{`"SECRET_REPORT_DATA`":1}`r`n") { throw 'Saved report text changed.' }
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $trace = [IO.File]::ReadAllText($tracePath)
    Trace-Command -Name ParameterBinding -FilePath $tracePath -Expression { Start-BrowserProcess $cmd '/d /c rem SECRET_REPORT_DATA' } | Out-Null
    $trace += [IO.File]::ReadAllText($tracePath)
    if (-not $trace.Contains('BIND arg')) { throw 'Parameter-binding trace captured nothing.' }
    # Only the collector's own helper parameters ([text], [arguments]) may carry the data; module
    # logging records cmdlets from modules, not functions defined in the script.
    $findLeaks = { param($text, $marker) @($text -split "`n" | Where-Object { $_.Contains($marker) -and $_ -match 'BIND arg' -and $_ -notmatch 'to param(eter)? \[(text|arguments)\]' }) }
    $leaks = & $findLeaks $trace 'SECRET_REPORT_DATA'
    if ($leaks.Count) { throw "Report data was bound to a cmdlet parameter: $($leaks[0])" }
    # The check itself must notice a cmdlet that takes the data (what v1.4 did with Set-Content).
    Trace-Command -Name ParameterBinding -FilePath $tracePath -Expression { 'CONTROL_DATA' | Set-Content -LiteralPath $filePath } | Out-Null
    if (-not (& $findLeaks ([IO.File]::ReadAllText($tracePath)) 'CONTROL_DATA').Count) { throw 'The binding check did not notice Set-Content taking the data.' }
} finally {
    Remove-Item -LiteralPath $tracePath, $filePath -ErrorAction SilentlyContinue
}
# The hand-off code outside the two Constrained Language fallbacks uses no cmdlet that takes the report.
$fallbacks = @('Write-TextFile', 'Copy-TextToClipboard')
$risky = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Set-Content', 'Add-Content', 'Out-File', 'Set-Clipboard', 'Start-Process', 'Tee-Object', 'Write-Output' }, $true) | Where-Object {
    $node = $_; $inside = $false
    for ($p = $node.Parent; $p; $p = $p.Parent) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $p.Name -in $fallbacks) { $inside = $true } }
    (-not $inside) -and $node.Parent.Extent.Text -match '\$(json|compact|url|b64|text|report)\b'
})
if ($risky.Count) { throw "Report data is passed to a cmdlet: $($risky[0].Parent.Extent.Text)" }
Pass 'Report data reaches files and the browser without cmdlet parameters'

# --- OneDrive-synced folders are disclosed ---
$before = @{ OneDrive = $env:OneDrive; OneDriveConsumer = $env:OneDriveConsumer; OneDriveCommercial = $env:OneDriveCommercial }
try {
    $env:OneDrive = 'X:\Users\someone\OneDrive'; $env:OneDriveConsumer = $null; $env:OneDriveCommercial = 'X:\Users\someone\OneDrive - Contoso\'
    if (-not (Get-SyncNote 'X:\Users\someone\OneDrive\Desktop\ComputerHealth-1.json').Contains('synced by OneDrive')) { throw 'A report saved in OneDrive was not disclosed.' }
    if (-not (Get-SyncNote 'x:\users\someone\onedrive - contoso\Desktop\r.json')) { throw 'A report saved in OneDrive for work was not disclosed.' }
    if (Get-SyncNote 'X:\Users\someone\OneDriveOther\r.json') { throw 'A folder that only starts with the same letters is not OneDrive.' }
    if (Get-SyncNote 'X:\Users\someone\Desktop\r.json') { throw 'A local folder was reported as synced.' }
    $env:OneDrive = $null; $env:OneDriveCommercial = $null
    if (Get-SyncNote 'X:\Users\someone\OneDrive\Desktop\r.json') { throw 'Without OneDrive no folder is synced.' }
} finally { foreach ($k in $before.Keys) { Set-Item -Path "Env:\$k" -Value $before[$k] -ErrorAction SilentlyContinue; if ($null -eq $before[$k]) { Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue } } }
Pass 'Reports saved in OneDrive folders are disclosed'

# --- Hand-off: an elevated scan never starts a browser; another account's Desktop is not used ---
if ((Test-Elevated) -isnot [bool]) { throw 'Test-Elevated must return true or false.' }
$noteAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$elevatedNote' }, $false)
$handoffAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Parent -eq $ast.EndBlock -and $n.Clauses[0].Item1.Extent.Text -eq '-not $OpenDashboard' }, $true)
if (-not $noteAst -or -not $handoffAst) { throw 'Could not find the collector hand-off code.' }
# $PSScriptRoot is empty in a created script block; stand in for the app folder.
$handoff = [scriptblock]::Create(($noteAst.Extent.Text + "`n" + $handoffAst.Extent.Text).Replace('$PSScriptRoot', '$AppRoot'))
function Save-Report($primary, $text) { $script:calls += "save:$primary"; return 'C:\saved\ComputerHealth.json' }
function Write-SavedReportNote($path) { }
function Write-TextFile($path, $text) { $script:calls += "write:$path" }
function Copy-TextToClipboard($text) { $script:calls += 'clipboard' }
function Start-BrowserProcess($exe, $arguments) { $script:calls += "browser:$arguments" }
function Start-Process { param([Parameter(Position = 0)]$FilePath) $script:calls += "open:$FilePath" }
function Get-BrowserExe { 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
function Test-PrivateModeBlocked($browser) { return $script:privateBlocked }
$script:privateBlocked = $false
function Get-DesktopFolder { 'C:\Desktop' }
function Start-Sleep { param($Seconds) }
function Write-Host { param([Parameter(Position = 0)]$Object) $script:calls += "say:$Object" }
function Write-Warning { param([Parameter(Position = 0)]$Message) $script:calls += "warn:$Message" }
function Invoke-Handoff([bool]$Open, [bool]$Save, [bool]$Elevated, [string]$OtherAccount = '') {
    $script:calls = @()
    $script:SessionUserName = $OtherAccount
    $OpenDashboard = $Open; $SaveReport = $Save; $IsElevated = $Elevated
    $report = [ordered]@{ schemaVersion = 1; checks = @() }
    $json = '{"schemaVersion":1}'
    $dashboard = 'C:\HealthScan\index.html'
    $AppRoot = 'C:\HealthScan'
    & $handoff
    return $script:calls
}
$calls = Invoke-Handoff $true $false $false
if (-not ($calls -match '^browser:--inprivate "file:///C:/HealthScan/index.html#report=')) { throw "A standard one-click scan should open a private window ($($calls -join ' / '))." }
if (-not ($calls -match 'Asking your browser for a private window') -or ($calls -match 'in a private browser window') -or ($calls -match 'Warning:')) { throw "The private window must be described as requested, without a warning when no policy blocks it ($($calls -join ' / '))." }
$script:privateBlocked = $true
$calls = Invoke-Handoff $true $false $false
$script:privateBlocked = $false
if (-not ($calls -match '^say:Warning: a policy') -or -not ($calls -match 'normal window')) { throw "A policy that turns private windows off must be reported ($($calls -join ' / '))." }
$calls = Invoke-Handoff $true $false $true
if ($calls -match '^(browser|open):') { throw "An elevated one-click scan started a program ($($calls -join ' / '))." }
if (-not ($calls -contains 'clipboard') -or -not ($calls -match 'administrator rights') -or -not ($calls -match 'C:\\HealthScan\\index.html')) { throw "An elevated scan must copy the report and say how to open the dashboard ($($calls -join ' / '))." }
$calls = Invoke-Handoff $true $true $true
if ($calls -match '^(browser|open):') { throw 'An elevated -SaveReport scan started a program.' }
if (-not ($calls -match '^write:.*latest-report\.js$')) { throw 'An elevated -SaveReport scan must still hand the report to the dashboard file.' }
$calls = Invoke-Handoff $true $true $false
if (-not ($calls -contains 'open:C:\HealthScan\index.html')) { throw 'A standard -SaveReport scan should open the dashboard.' }
$calls = Invoke-Handoff $false $false $true 'someoneelse'
if (-not ($calls -contains 'save:C:\HealthScan\reports') -or ($calls -contains 'save:C:\Desktop')) { throw "A scan elevated with another account must not save to that account's Desktop ($($calls -join ' / '))." }
$calls = Invoke-Handoff $false $false $false
if (-not ($calls -contains 'save:C:\Desktop') -or -not ($calls -match 'uploaded nothing')) { throw 'A manual scan saves to the Desktop and says it uploaded nothing.' }
if ($calls -match 'No data was uploaded') { throw 'The manual-mode message must not claim no data was uploaded.' }
Pass 'Elevated scans start no program, and other accounts do not save to their own Desktop'

# --- Private-window policy detection reads machine policy before user policy ---
$policyAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PrivateModeBlocked' }, $false)
if (-not $policyAst) { throw 'Test-PrivateModeBlocked not found in the collector.' }
Remove-Item Function:\Test-PrivateModeBlocked
. ([scriptblock]::Create($policyAst.Extent.Text))
$script:policy = @{}
function Get-MachineRegistryValues($path) { if ($script:policy.ContainsKey($path)) { return $script:policy[$path] }; throw 'no key' }
function Get-ItemProperty { param([string]$Path) if ($script:policy.ContainsKey($Path)) { return $script:policy[$Path] }; throw 'no key' }
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (Test-PrivateModeBlocked $edge) { throw 'No policy must not count as blocked.' }
$script:policy = @{ 'HKCU:\Software\Policies\Microsoft\Edge' = [pscustomobject]@{ InPrivateModeAvailability = 1 } }
if (-not (Test-PrivateModeBlocked $edge)) { throw 'A user policy of 1 blocks private windows.' }
$script:policy['HKLM:\Software\Policies\Microsoft\Edge'] = [pscustomobject]@{ InPrivateModeAvailability = 0 }
if (Test-PrivateModeBlocked $edge) { throw 'The machine policy must win over the user policy.' }
$script:policy = @{ 'HKLM:\Software\Policies\Google\Chrome' = [pscustomobject]@{ IncognitoModeAvailability = 1 } }
if (-not (Test-PrivateModeBlocked 'C:\Chrome\chrome.exe')) { throw 'Chrome incognito policy 1 blocks private windows.' }
if (Test-PrivateModeBlocked 'C:\Firefox\firefox.exe') { throw 'Browsers without a known policy are not reported as blocked.' }
$script:policy = @{ 'HKLM:\Software\Policies\BraveSoftware\Brave' = [pscustomobject]@{ IncognitoModeAvailability = 2 } }
if (Test-PrivateModeBlocked 'C:\Brave\brave.exe') { throw 'Policy value 2 forces private windows and must not count as blocked.' }
Pass 'Private-window policies are detected for Edge, Chrome and Brave'

Microsoft.PowerShell.Utility\Write-Host "$script:passed robustness regression checks passed. Windows health data was mocked."
