# Regression tests for the real collector's memory, disk, drive, antivirus, firewall, Windows Update
# and encryption checks. Uses only in-memory mocks: no Windows health queries, scans, or configuration changes.
$ErrorActionPreference = 'Stop'
$collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Collect-Health.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Collector parse errors: $($parseErrors -join '; ')" }
foreach ($functionName in 'Add-Check','Remove-UserNames','Get-OneLineText','Get-SafeText','Get-Round','Get-Floor','Format-Date','Test-AccessDenied','Get-FailureNote',
    'Add-MemoryChecks','Add-DiskSpaceChecks','Add-DriveHealthChecks','Add-AntivirusChecks','Add-FirewallCheck',
    'ConvertFrom-WuDate','Get-UpdatePauseEnd','Add-RestartPendingCheck','Add-UpdateRecencyCheck','Add-PendingUpdatesCheck','Add-EncryptionCheck') {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $false)
    if (-not $functionAst) { throw "Collector function not found: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$PRIVATE = 'Simulated failure in C:\Users\PRIVATE_USERNAME\PRIVATE_ERROR_PATH (S-1-5-21-PRIVATE_SID)'
$NOW = [datetime]'2026-11-10T12:00:00'
function Get-Date { return $script:NOW }

# The real step runner uses a second runspace, where these mocks would not exist; run steps inline.
function Invoke-Bounded([string]$Step, [int]$Seconds, [scriptblock]$Script, [object[]]$ArgumentList = @()) {
    $script:steps += $Step
    if ($Seconds -le 0) { throw "Step without a time limit: $Step" }
    if ($script:timeouts -contains $Step) { Write-Error -Message "Step timed out: $Step" -Category OperationTimeout -ErrorId 'HealthScanStepTimeout' -ErrorAction Stop }
    & $Script @ArgumentList
}
function Test-Fail($key) { if ($script:fail -contains $key) { throw $script:PRIVATE } }
function Write-Host { param([Parameter(Position = 0)]$Object) $script:log += "host:$Object"; Microsoft.PowerShell.Utility\Write-Host $Object }
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter, [string[]]$Property, [int]$OperationTimeoutSec)
    if ($OperationTimeoutSec -le 0) { throw "CIM query without a time limit: $ClassName" }
    if ($script:cimTimeouts -contains $ClassName) { Write-Error -Message 'CIM timed out' -Category OperationTimeout -ErrorAction Stop }
    Test-Fail "cim:$ClassName"
    return $script:cim[$ClassName]
}
function Get-PhysicalDisk { [CmdletBinding()] param() Test-Fail 'physicaldisk'; return $script:disks }
function Get-StorageReliabilityCounter {
    [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$PhysicalDisk)
    process { Test-Fail 'reliability'; return $script:reliability }
}
function Start-MpScan { [CmdletBinding()] param([string]$ScanType) $script:log += "scan:$ScanType"; if ($script:scanError) { throw $script:scanError }; Test-Fail 'mpscan' }
function Get-MpComputerStatus { [CmdletBinding()] param() Test-Fail 'mpstatus'; return $script:mpStatus }
function Get-MpThreat { [CmdletBinding()] param() Test-Fail 'mpthreat'; return $script:threats }
function Get-NetFirewallProfile { [CmdletBinding()] param([string]$PolicyStore) Test-Fail 'firewall'; return $script:firewall }
function Get-HotFix { [CmdletBinding()] param() Test-Fail 'hotfix'; return $script:hotfixes }
function Get-BitLockerVolume { [CmdletBinding()] param([string]$MountPoint) Test-Fail 'bitlocker'; return $script:bitlocker }
function Test-MachineRegistryKey($path) { Test-Fail 'registry'; return ($script:registryKeys -contains $path) }
function Get-MachineRegistryValues($path) { Test-Fail 'registry'; if (-not $script:registryValues.ContainsKey($path)) { throw 'Registry key not found.' }; return $script:registryValues[$path] }

$script:mockSearcher = [pscustomobject]@{ Online = $true }
$script:mockSearcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
    param($criteria)
    if ($this.Online -ne $false) { throw 'The collector attempted an online update search.' }
    if ($criteria -ne 'IsInstalled=0 and IsHidden=0 and BrowseOnly=0') { throw 'Unexpected update criteria.' }
    Test-Fail 'search'
    return $script:mockResult
}
$script:mockSession = [pscustomobject]@{}
$script:mockSession | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $script:mockSearcher }
function New-Object {
    param([Parameter(Position = 0)][string]$TypeName, [string]$ComObject, [System.Collections.IDictionary]$Property)
    if ($ComObject) {
        Test-Fail "com:$ComObject"
        switch ($ComObject) {
            'Microsoft.Update.Session' { return $script:mockSession }
            'Microsoft.Update.SystemInfo' { return [pscustomobject]@{ RebootRequired = $script:wuRebootRequired } }
            'Microsoft.Update.AutoUpdate' { return [pscustomobject]@{ Results = [pscustomobject]@{ LastSearchSuccessDate = $script:lastSearch } } }
            'Shell.Application' { return $script:shell }
            default { throw "Unexpected COM request: $ComObject" }
        }
    }
    return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -Property $Property
}

function Reset-Fixtures {
    $script:checks = @()
    $script:steps = @()
    $script:log = @()
    $script:fail = @()
    $script:timeouts = @()
    $script:cimTimeouts = @()
    $script:cim = @{
        Win32_OperatingSystem = [pscustomobject]@{ FreePhysicalMemory = 4000000; TotalVisibleMemorySize = 16000000; LastBootUpTime = $script:NOW.AddDays(-2.34); Caption = 'Microsoft Windows 11 Pro' }
        Win32_LogicalDisk = @([pscustomobject]@{ DeviceID = 'C:'; Size = 500GB; FreeSpace = 100GB })
        AntiVirusProduct = @()
    }
    $script:disks = @([pscustomobject]@{ DeviceId = '0'; FriendlyName = 'Fast SSD'; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); MediaType = 'SSD'; BusType = 'NVMe'; Size = 512GB })
    $script:reliability = [pscustomobject]@{ Wear = 3; Temperature = 40 }
    $script:mpStatus = [pscustomobject]@{ RealTimeProtectionEnabled = $true; AntivirusEnabled = $true; AntivirusSignatureAge = 0; QuickScanEndTime = [datetime]'2026-11-09T08:30:00' }
    $script:threats = @()
    $script:firewall = @([pscustomobject]@{ Name = 'Domain'; Enabled = $true }, [pscustomobject]@{ Name = 'Private'; Enabled = $true }, [pscustomobject]@{ Name = 'Public'; Enabled = $true })
    $script:hotfixes = @([pscustomobject]@{ HotFixID = 'KB5000001'; InstalledOn = [datetime]'2026-11-01' })
    $script:lastSearch = [datetime]'2026-11-10T06:00:00'
    $script:wuRebootRequired = $false
    $script:bitlocker = [pscustomobject]@{ ProtectionStatus = 'On'; VolumeStatus = 'FullyEncrypted' }
    $script:shell = $null
    $script:registryKeys = @()
    $script:registryValues = @{}
    $script:mockResult = [pscustomobject]@{ ResultCode = 2; Updates = @(); Warnings = @() }
    $script:scanError = $null
    $script:IsElevated = $false
    $script:UpdateCheckUnreadable = $false
}
function New-MockShell($code) {
    # Shell.Application -> NameSpace(drive).Self.ExtendedProperty('System.Volume.BitLockerProtection')
    $self = [pscustomobject]@{ Code = $code }
    $self | Add-Member -MemberType ScriptMethod -Name ExtendedProperty -Value { param($name) if ($name -ne 'System.Volume.BitLockerProtection') { throw 'Unexpected shell property.' }; return $this.Code }
    $folder = [pscustomobject]@{ Self = $self }
    $shell = [pscustomobject]@{ Folder = $folder }
    $shell | Add-Member -MemberType ScriptMethod -Name NameSpace -Value { param($path) return $this.Folder }
    return $shell
}
function Assert-Checks {
    param([string]$Name, [string]$Statuses, [string[]]$Contains = @(), [string[]]$Excludes = @())
    $actual = ($script:checks | ForEach-Object status) -join ','
    if ($actual -ne $Statuses) { throw "${Name}: expected '$Statuses', got '$actual' ($(($script:checks | ForEach-Object detail) -join ' | '))." }
    $reportText = $script:checks | ConvertTo-Json -Depth 6
    foreach ($text in $Contains) {
        if (-not $reportText.Contains($text)) { throw "${Name}: report did not include '$text'. Report: $reportText" }
    }
    foreach ($text in (@($Excludes) + @('PRIVATE_ERROR_PATH', 'PRIVATE_USERNAME', 'PRIVATE_SID', 'Simulated failure', 'C:\\Users'))) {
        if ($reportText.Contains($text)) { throw "${Name}: report leaked or incorrectly included '$text'." }
    }
    foreach ($check in $script:checks) {
        foreach ($field in 'name', 'detail', 'action') {
            if (-not ([string]$check.$field).Trim()) { throw "${Name}: empty $field." }
        }
    }
    $script:passed++
    Write-Host "PASS $Name"
}
function Use-Culture([string]$Culture, [scriptblock]$Body) {
    $thread = [Threading.Thread]::CurrentThread
    $before = $thread.CurrentCulture
    try {
        $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
        & $Body
    } finally { $thread.CurrentCulture = $before }
}
$script:passed = 0
$realUserName = $env:USERNAME

# --- Healthy results ---
Reset-Fixtures
$os = Add-MemoryChecks
Assert-Checks 'Memory and uptime' 'pass,pass' -Contains '25% RAM available', '2.3 days since restart'
if ($os.Caption -ne 'Microsoft Windows 11 Pro') { throw 'Add-MemoryChecks must return the operating system for the report.' }
Reset-Fixtures
Add-DiskSpaceChecks
Assert-Checks 'Disk space' pass -Contains 'Disk space C:', '20% free; 100 GB available'
Reset-Fixtures
Add-DriveHealthChecks
Assert-Checks 'Drive health with wear and temperature' pass -Contains 'Disk 0 (Fast SSD)', 'health: Healthy; status: OK. SSD, 512 GB.', 'Wear: 3%', 'Temperature: 40 C.'
Reset-Fixtures
$script:disks = @(
    [pscustomobject]@{ DeviceId = '10'; FriendlyName = 'Ten'; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); MediaType = 'HDD'; BusType = 'SATA'; Size = 1TB }
    [pscustomobject]@{ DeviceId = '2'; FriendlyName = 'Two'; HealthStatus = 'Warning'; OperationalStatus = @('Degraded'); MediaType = 'HDD'; BusType = 'SATA'; Size = 1TB }
)
$script:fail = @('reliability')
Add-DriveHealthChecks
Assert-Checks 'Drives sort numerically and counters are optional' 'warning,pass' -Contains 'Disk 2 (Two)', 'Disk 10 (Ten)' -Excludes 'Wear:'
if ($script:checks[0].name -notmatch 'Disk 2') { throw 'Disk 2 must come before Disk 10.' }
Reset-Fixtures
Add-AntivirusChecks $false
Assert-Checks 'Defender healthy' 'pass,pass,info,pass' -Contains 'Last completed quick scan: 2026-11-09 08:30', '0 active detections'
Reset-Fixtures
$script:firewall[2].Enabled = $false
Add-FirewallCheck
Assert-Checks 'Firewall profile off' warning -Contains 'Disabled: Public'
Reset-Fixtures
Add-FirewallCheck
Assert-Checks 'Firewall profiles on' pass -Contains 'All Windows Firewall profiles enabled'
Reset-Fixtures
Add-EncryptionCheck
Assert-Checks 'BitLocker on' pass -Contains 'BitLocker protection: On (volume status: FullyEncrypted)'

# --- Restart pending reads the 64-bit registry view through the shared helper ---
Reset-Fixtures
$script:registryKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
Add-RestartPendingCheck
Assert-Checks 'Restart pending from the Windows Update registry key' warning -Contains '(Windows Update)'
Reset-Fixtures
$script:wuRebootRequired = $true
Add-RestartPendingCheck
Assert-Checks 'Restart pending from Windows Update' warning -Contains '(Windows Update)'
Reset-Fixtures
Add-RestartPendingCheck
Assert-Checks 'No restart pending' pass
Reset-Fixtures
$script:timeouts = @('asking Windows Update whether a restart is needed')
Add-RestartPendingCheck
Assert-Checks 'Timed-out restart query is unknown' unknown -Contains 'did not confirm'
Reset-Fixtures
$script:fail = @('com:Microsoft.Update.SystemInfo')
$script:registryKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
Add-RestartPendingCheck
Assert-Checks 'Registry restart evidence survives a failed update query' warning -Contains 'component servicing'
Reset-Fixtures
$script:fail = @('hotfix')
Add-UpdateRecencyCheck $null | Out-Null
Assert-Checks 'Current update search without install evidence is unknown' unknown -Contains 'last installed update could not be verified'

# --- Update pause and recency ---
Reset-Fixtures
$script:registryValues['HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'] = [pscustomobject]@{ PauseUpdatesExpiryTime = '2026-11-20T08:00:00Z'; PauseQualityUpdatesEndTime = '2026-01-01T00:00:00Z' }
$paused = Get-UpdatePauseEnd
if (-not $paused -or $paused.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) -ne '2026-11-20 08:00') { throw "Pause end was not read from the registry helper ($paused)." }
$script:passed++; Write-Host 'PASS Update pause is read through the 64-bit registry helper'

# The same pause values must be read alike in full and Constrained Language Mode: a time with no zone
# is UTC, an offset is honoured, an expired or unreadable value is ignored.
$pauseCases = @(
    @{ Values = [pscustomobject]@{ PauseUpdatesExpiryTime = '2026-11-20T08:00:00Z'; PauseQualityUpdatesEndTime = '2026-01-01T00:00:00Z' }; Expected = '2026-11-20 08:00' }
    @{ Values = [pscustomobject]@{ PauseUpdatesExpiryTime = '2026-11-20T08:00:00Z'; PauseFeatureUpdatesEndTime = ' 2026-11-25T08:30:00 ' }; Expected = '2026-11-25 08:30' }
    @{ Values = [pscustomobject]@{ PauseQualityUpdatesEndTime = '2026-11-22T10:00:00+02:00'; PauseFeatureUpdatesEndTime = 'not a date' }; Expected = '2026-11-22 08:00' }
    @{ Values = [pscustomobject]@{ PauseUpdatesExpiryTime = '2026-11-01T08:00:00Z'; PauseQualityUpdatesEndTime = '' }; Expected = '' }
)
$pauseFunction = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-UpdatePauseEnd' }, $false).Extent.Text
function Format-PauseEnd($value) { if ($value -is [datetime]) { $value.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { '' } }
foreach ($case in $pauseCases) {
    Reset-Fixtures
    $script:registryValues['HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'] = $case.Values
    $full = Format-PauseEnd (Get-UpdatePauseEnd)
    if ($full -ne $case.Expected) { throw "Pause end '$full', expected '$($case.Expected)' ($($case.Values))." }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    try {
        $runspace.SessionStateProxy.SetVariable('PauseValues', $case.Values)
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript('function Get-Date { [datetime]''2026-11-10T12:00:00'' }; function Get-MachineRegistryValues($path) { if ($path -ne ''HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'') { throw ''Unexpected key.'' }; $PauseValues }').Invoke()
        $runspace.SessionStateProxy.LanguageMode = 'ConstrainedLanguage'
        $shell.Commands.Clear()
        # Defined after the switch, so the collector function itself runs constrained.
        [void]$shell.AddScript($pauseFunction + "`n" + '$ExecutionContext.SessionState.LanguageMode.ToString(); Get-UpdatePauseEnd')
        $out = @($shell.Invoke())
        if ([string]$out[0] -ne 'ConstrainedLanguage') { throw 'The pause test runspace is not in Constrained Language Mode.' }
        if ($shell.Streams.Error.Count) { throw "Get-UpdatePauseEnd failed under Constrained Language Mode: $($shell.Streams.Error -join ' | ')" }
        $clm = Format-PauseEnd ($out | Select-Object -Skip 1 | Select-Object -First 1)
        if ($clm -ne $case.Expected) { throw "Under Constrained Language Mode the pause end was '$clm', expected '$($case.Expected)' ($($case.Values))." }
    } finally { $runspace.Dispose() }
}
$script:passed++; Write-Host 'PASS Update pause is read the same way under Constrained Language Mode'
Reset-Fixtures
$last = Add-UpdateRecencyCheck $null
Assert-Checks 'Update recency' pass -Contains 'KB5000001 on 2026-11-01 (9 days ago)', 'Last successful check for updates:'
if (-not ($last -is [datetime])) { throw 'Add-UpdateRecencyCheck must return the last successful check.' }

# --- Finding: no raw exception text, paths, usernames or SIDs in any older check ---
Reset-Fixtures
$script:fail = @('cim:Win32_OperatingSystem')
Add-MemoryChecks | Out-Null
Assert-Checks 'Memory failure uses fixed wording' unknown -Contains 'did not return memory and uptime'
Reset-Fixtures
$script:fail = @('cim:Win32_LogicalDisk')
Add-DiskSpaceChecks
Assert-Checks 'Disk space failure uses fixed wording' unknown -Contains 'did not return disk space'
Reset-Fixtures
$script:fail = @('physicaldisk')
Add-DriveHealthChecks
Assert-Checks 'Drive health failure uses fixed wording' unknown -Contains 'did not return drive health'
Reset-Fixtures
$script:fail = @('mpscan', 'mpstatus', 'mpthreat', 'cim:AntiVirusProduct')
Add-AntivirusChecks $true
Assert-Checks 'Antivirus failures use fixed wording' 'unknown,unknown,unknown' -Contains 'quick scan could not be started', 'Defender status could not be read', 'detection list could not be read'
Reset-Fixtures
$script:fail = @('firewall')
Add-FirewallCheck
Assert-Checks 'Firewall failure uses fixed wording' unknown -Contains 'could not be read'
Reset-Fixtures
$script:fail = @('registry')
Add-RestartPendingCheck
Assert-Checks 'Restart pending failure uses fixed wording' unknown -Contains 'did not say whether a restart is waiting'
Reset-Fixtures
$script:fail = @('hotfix', 'com:Microsoft.Update.AutoUpdate')
Add-UpdateRecencyCheck $null | Out-Null
Assert-Checks 'Update history failure uses fixed wording' unknown -Contains 'Update history could not be read'
Reset-Fixtures
$script:fail = @('search')
Add-PendingUpdatesCheck $NOW $null
Assert-Checks 'Cached update search failure uses fixed wording' unknown -Contains 'saved results could not be read'
Reset-Fixtures
$script:fail = @('bitlocker', 'com:Shell.Application')
Add-EncryptionCheck
Assert-Checks 'Encryption failure uses fixed wording' unknown -Contains 'could not be read'

# --- Finding: time limits on every Windows query, and a visible note when one is skipped ---
Reset-Fixtures
$script:timeouts = @('reading drive health')
Add-DriveHealthChecks
Assert-Checks 'Timed-out drive query says so' unknown -Contains 'did not answer within the time limit'
Reset-Fixtures
$script:cimTimeouts = @('Win32_OperatingSystem')
Add-MemoryChecks | Out-Null
Assert-Checks 'CIM operation timeout says so' unknown -Contains 'did not answer within the time limit'
Reset-Fixtures
$script:timeouts = @('reading Windows Update''s saved results')
Add-PendingUpdatesCheck $NOW $null
Assert-Checks 'Timed-out update search says so' unknown -Contains 'did not answer within the time limit'
Reset-Fixtures
$script:disks += [pscustomobject]@{ DeviceId = '1'; FriendlyName = 'Second'; HealthStatus = 'Healthy'; OperationalStatus = @('OK'); MediaType = 'SSD'; BusType = 'NVMe'; Size = 512GB }
$script:timeouts = @('reading drive wear and temperature')
Add-DriveHealthChecks
Assert-Checks 'A timed-out wear counter keeps the drive result' 'pass,pass' -Excludes 'Wear:'
if (@($script:steps | Where-Object { $_ -eq 'reading drive wear and temperature' }).Count -ne 1) { throw 'After one wear counter timed out, the others must be skipped instead of waiting again.' }
$script:passed++; Write-Host 'PASS Wear counters stop after one timeout'
Reset-Fixtures
$script:registryKeys = @()
Add-RestartPendingCheck; Add-UpdateRecencyCheck $null | Out-Null; Add-PendingUpdatesCheck $NOW $null; Add-EncryptionCheck; Add-AntivirusChecks $false; Add-FirewallCheck; Add-DriveHealthChecks
foreach ($step in 'asking Windows Update whether a restart is needed', 'reading installed Windows updates', 'reading Windows Update history', 'reading Windows Update''s saved results', 'reading BitLocker status', 'reading Microsoft Defender status', 'reading Microsoft Defender detections', 'reading Windows Firewall settings', 'reading drive health', 'reading drive wear and temperature') {
    if ($script:steps -notcontains $step) { throw "Windows query is not run under a time limit: $step" }
}
$script:passed++; Write-Host 'PASS Slow Windows queries run as bounded steps'

# --- Finding: -QuickScan says it waits for the scan before it starts ---
Reset-Fixtures
Add-AntivirusChecks $true
$scanAt = [array]::IndexOf($script:log, 'scan:QuickScan')
$noteAt = -1
for ($i = 0; $i -lt $script:log.Count; $i++) { if ($script:log[$i] -match '^host:Running a Microsoft Defender quick scan.*several minutes') { $noteAt = $i } }
if ($scanAt -lt 0 -or $noteAt -lt 0 -or $noteAt -gt $scanAt) { throw "The quick-scan wait message must be shown before the scan starts ($($script:log -join ' / '))." }
$script:passed++; Write-Host 'PASS Quick scan warns that it can take several minutes'

# --- Finding: externally supplied names are single-line, bounded and username-free ---
try {
    $env:USERNAME = 'PRIVATE_USERNAME'
    Reset-Fixtures
    $script:disks[0].FriendlyName = "PRIVATE_USERNAME`nDrive"
    $script:cim.AntiVirusProduct = @([pscustomobject]@{ instanceGuid = '{1}'; displayName = 'PRIVATE_USERNAME Antivirus'; productState = 0x1000 })
    $script:mpStatus.RealTimeProtectionEnabled = $false
    Add-DriveHealthChecks
    Add-AntivirusChecks $false
    Assert-Checks 'Drive model and antivirus names are sanitised' 'pass,pass,pass,info,info' -Contains '([user] Drive)', 'enabled: [user] Antivirus.', 'kept by [user] Antivirus.'
    Reset-Fixtures
    $script:mockResult.Updates = @([pscustomobject]@{ Title = "Update for PRIVATE_USERNAME`nsecond line"; RebootRequired = $false; Categories = @() })
    Add-PendingUpdatesCheck $NOW $null
    Assert-Checks 'Update titles are sanitised' warning -Contains '- Update for [user] second line'
} finally { $env:USERNAME = $realUserName }

# --- Finding: dates use the Gregorian calendar and ':' on every regional setting ---
Use-Culture 'th-TH' {
    if ($script:NOW.ToString('yyyy') -eq '2026') { throw 'The test culture did not take effect.' }
    Reset-Fixtures
    Add-AntivirusChecks $false
    Add-UpdateRecencyCheck $null | Out-Null
    Assert-Checks 'Thai regional settings keep Gregorian dates' 'pass,pass,info,pass,pass' -Contains 'quick scan: 2026-11-09 08:30', 'on 2026-11-01', 'updates: 2026-11-10' -Excludes '2569'
}
Use-Culture 'fi-FI' {
    Reset-Fixtures
    Add-AntivirusChecks $false
    Assert-Checks 'Regional time separators do not change times' 'pass,pass,info,pass' -Contains '2026-11-09 08:30' -Excludes '08.30'
}

# --- Cached update search (offline only) ---
function Assert-Case {
    param(
        [string]$Name,
        [int]$ResultCode = 2,
        [object[]]$Updates = @(),
        [object[]]$Warnings = @(),
        [string]$ExpectedStatus,
        [string[]]$Contains = @(),
        [string[]]$Excludes = @(),
        [switch]$Paused,
        [switch]$NoHistory,
        [switch]$ThrowSearch
    )
    Reset-Fixtures
    $script:mockResult = [pscustomobject]@{ ResultCode = $ResultCode; Updates = $Updates; Warnings = $Warnings }
    $script:mockSearcher.Online = $true
    if ($ThrowSearch) { $script:fail = @('search') }
    $lastCheck = if ($NoHistory) { $null } else { [datetime]'2026-11-10T12:00:00' }
    $pausedUntil = if ($Paused) { [datetime]'2026-11-17T12:00:00' } else { $null }
    Add-PendingUpdatesCheck $lastCheck $pausedUntil
    if ($script:checks.Count -ne 1) { throw "${Name}: expected exactly one update check." }
    if ($script:checks[0].name -ne 'Pending Windows updates') { throw "${Name}: wrong check name." }
    Assert-Checks $Name $ExpectedStatus -Contains $Contains -Excludes $Excludes
}

$pending = [pscustomobject]@{ Title = 'Security update'; RebootRequired = $false; Categories = @() }
$restart = [pscustomobject]@{ Title = 'Restart required update'; RebootRequired = $true; Categories = @() }
$definition = [pscustomobject]@{
    Title = 'Antivirus definition'; RebootRequired = $false
    Categories = @([pscustomobject]@{ CategoryID = 'E0789628-CE08-4437-BE74-2495B842F43B' })
}
$warning = [pscustomobject]@{ Message = 'Incomplete update metadata' }
$incomplete = 'did not return a complete set of saved results'

Assert-Case 'Complete empty search' -ExpectedStatus pass -Contains 'No updates were waiting' -Excludes $incomplete
Assert-Case 'Succeeded-with-errors empty search' -ResultCode 3 -ExpectedStatus unknown -Contains $incomplete -Excludes 'No updates were waiting'
Assert-Case 'Successful result with warnings' -Warnings @($warning) -ExpectedStatus unknown -Contains $incomplete
Assert-Case 'Failed empty search' -ResultCode 4 -ExpectedStatus unknown -Contains $incomplete
Assert-Case 'Aborted empty search' -ResultCode 5 -ExpectedStatus unknown -Contains $incomplete
Assert-Case 'Complete pending updates' -Updates @($pending) -ExpectedStatus warning -Contains 'Security update' -Excludes $incomplete
Assert-Case 'Partial pending updates' -ResultCode 3 -Updates @($pending) -Warnings @($warning) -ExpectedStatus warning -Contains 'Security update',$incomplete
Assert-Case 'Failed result retains known pending updates' -ResultCode 4 -Updates @($pending) -ExpectedStatus warning -Contains 'Security update',$incomplete
Assert-Case 'Complete restart-only updates' -Updates @($restart) -ExpectedStatus info -Contains 'No other updates were waiting' -Excludes $incomplete
Assert-Case 'Partial restart-only updates' -ResultCode 3 -Updates @($restart) -ExpectedStatus warning -Contains 'need a restart',$incomplete -Excludes 'No other updates were waiting'
Assert-Case 'Complete paused search' -Paused -ExpectedStatus info -Contains 'paused until 2026-11-17' -Excludes $incomplete
Assert-Case 'Partial paused search' -Paused -ResultCode 3 -ExpectedStatus unknown -Contains $incomplete
Assert-Case 'Complete search without update history' -NoHistory -ExpectedStatus unknown -Contains 'no successful update check'
Assert-Case 'Partial search without update history' -NoHistory -ResultCode 3 -ExpectedStatus unknown -Contains $incomplete
Assert-Case 'Complete definitions-only search' -Updates @($definition) -ExpectedStatus pass -Contains 'No updates were waiting'
Assert-Case 'Partial definitions-only search' -Updates @($definition) -ResultCode 3 -ExpectedStatus unknown -Contains $incomplete
Assert-Case 'COM search exception' -ThrowSearch -ExpectedStatus unknown -Contains 'saved results could not be read'
Assert-Case 'Pending list is bounded' -Updates @(1..7 | ForEach-Object { [pscustomobject]@{ Title = "Update $_"; RebootRequired = $false; Categories = @() } }) -ExpectedStatus warning -Contains '7 update(s)', 'Update 5', 'and 2 more' -Excludes 'Update 6'

# --- Finding: pending updates do not pass on an old saved search ---
Reset-Fixtures
Add-PendingUpdatesCheck ([datetime]'2026-09-01T12:00:00') $null
Assert-Checks 'Saved results older than 14 days are not a pass' unknown -Contains 'last checked for updates 70 days ago', 'No online check' -Excludes 'No updates were waiting'
Reset-Fixtures
Add-PendingUpdatesCheck ([datetime]'2026-10-28T12:00:00') $null
Assert-Checks 'Saved results 13 days old still pass' pass -Contains 'No updates were waiting'

# --- Finding: an unreadable update-check time is not reported as "never checked" or "checking works" ---
Reset-Fixtures
$script:hotfixes = @([pscustomobject]@{ HotFixID = 'KB5000001'; InstalledOn = [datetime]'2026-08-01' })
$script:fail = @('com:Microsoft.Update.AutoUpdate')
$last = Add-UpdateRecencyCheck $null
Assert-Checks 'Unreadable check time with an old install' warning -Contains 'KB5000001', 'time of the last check for updates could not be read', 'select Check for updates' -Excludes 'Windows is checking for updates', 'no successful check'
if ($null -ne $last -or -not $script:UpdateCheckUnreadable) { throw 'An unreadable check time must be flagged for the pending-updates check.' }
Reset-Fixtures
Add-PendingUpdatesCheck $null $null $true
Assert-Checks 'Pending updates with an unreadable check time' unknown -Contains 'could not be read' -Excludes 'no successful update check'
Reset-Fixtures
$script:hotfixes = @([pscustomobject]@{ HotFixID = 'KB5000001'; InstalledOn = [datetime]'2026-08-01' })
Add-UpdateRecencyCheck $null | Out-Null
Assert-Checks 'Fresh check time with an old install still says checking works' warning -Contains 'Windows is checking for updates'
if ($script:UpdateCheckUnreadable) { throw 'A readable check time must not be flagged as unreadable.' }

# --- Finding: uptime explains Fast Startup and never prints a negative number ---
$POWER = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
Reset-Fixtures
$script:cim.Win32_OperatingSystem.LastBootUpTime = $NOW.AddDays(-20)
$script:registryValues[$POWER] = [pscustomobject]@{ HiberbootEnabled = 1 }
Add-MemoryChecks | Out-Null
Assert-Checks 'Long uptime with Fast Startup explains Shut down' 'pass,warning' -Contains '20 days since restart', 'Fast Startup is on, so Shut down does not reset this', 'choose Restart from the Start menu'
Reset-Fixtures
$script:cim.Win32_OperatingSystem.LastBootUpTime = $NOW.AddDays(-20)
$script:registryValues[$POWER] = [pscustomobject]@{ HiberbootEnabled = 0 }
Add-MemoryChecks | Out-Null
Assert-Checks 'Long uptime without Fast Startup' 'pass,warning' -Contains '20 days since restart' -Excludes 'Fast Startup'
Reset-Fixtures
$script:cim.Win32_OperatingSystem.LastBootUpTime = $NOW.AddDays(3)
Add-MemoryChecks | Out-Null
Assert-Checks 'Start time in the future is unknown, not negative' 'pass,unknown' -Contains 'start time in the future' -Excludes '-3 days'

# --- Finding: disk space uses an absolute floor and reports unreadable volumes ---
Reset-Fixtures
$script:cim.Win32_LogicalDisk = @(
    [pscustomobject]@{ DeviceID = 'C:'; Size = 32GB; FreeSpace = 5GB },
    [pscustomobject]@{ DeviceID = 'D:'; Size = 4096GB; FreeSpace = 500GB },
    [pscustomobject]@{ DeviceID = 'E:'; Size = 200GB; FreeSpace = 20GB },
    [pscustomobject]@{ DeviceID = 'F:'; Size = 0; FreeSpace = 0 }
)
$systemDriveBefore = $env:SystemDrive
try {
    $env:SystemDrive = 'C:'
    Add-DiskSpaceChecks
} finally { $env:SystemDrive = $systemDriveBefore }
Assert-Checks 'Disk space floors and unreadable volumes' 'warning,pass,warning,unknown' -Contains 'Disk space F:', 'could not read the size', 'Windows needs free space on this drive', '12% free; 500 GB available'
Reset-Fixtures
$script:cim.Win32_LogicalDisk = @()
Add-DiskSpaceChecks
Assert-Checks 'No fixed drives listed is unknown' unknown -Contains 'did not list any fixed drives'

# --- Finding: the firewall check reads the default inbound action and an empty result ---
Reset-Fixtures
foreach ($p in $script:firewall) { $p | Add-Member -NotePropertyName DefaultInboundAction -NotePropertyValue 'Allow' }
Add-FirewallCheck
Assert-Checks 'Enabled profiles that allow all inbound traffic' warning -Contains 'allowing all inbound connections by default: Domain, Private, Public' -Excludes 'All Windows Firewall profiles enabled'
Reset-Fixtures
foreach ($p in $script:firewall) { $p | Add-Member -NotePropertyName DefaultInboundAction -NotePropertyValue 'Block' }
Add-FirewallCheck
Assert-Checks 'Blocking profiles pass' pass -Contains 'All Windows Firewall profiles enabled'
Reset-Fixtures
$script:firewall = @()
Add-FirewallCheck
Assert-Checks 'No firewall profiles returned is unknown' unknown -Contains 'did not return any Windows Firewall profiles'

# --- Finding: third-party firewalls and Windows Server without Security Center ---
Reset-Fixtures
foreach ($p in $script:firewall) { $p.Enabled = $false }
$script:cim.FirewallProduct = @([pscustomobject]@{ displayName = 'Suite Firewall'; productState = 0x1000 })
Add-FirewallCheck
Assert-Checks 'Windows Firewall off with an enabled third-party firewall' pass -Contains 'Disabled: Domain, Private, Public', 'reports this firewall as enabled: Suite Firewall'
Reset-Fixtures
foreach ($p in $script:firewall) { $p.Enabled = $false }
$script:cim.FirewallProduct = @([pscustomobject]@{ displayName = 'Expired Firewall'; productState = 0x0000 })
Add-FirewallCheck
Assert-Checks 'A disabled third-party firewall does not count' warning -Contains 'Disabled: Domain' -Excludes 'Expired Firewall'
Reset-Fixtures
$script:firewall[0].Enabled = $false
$script:fail = @('cim:FirewallProduct')
Add-FirewallCheck
Assert-Checks 'Firewall off where Security Center does not answer' warning -Contains 'Disabled: Domain', 'other firewall products could not be checked'
Reset-Fixtures
$script:fail = @('cim:AntiVirusProduct')
$script:mpStatus.RealTimeProtectionEnabled = $false
$script:mpStatus.AntivirusEnabled = $false
Add-AntivirusChecks $false
Assert-Checks 'Defender off where Security Center does not answer is not a false warning' 'unknown,unknown,info,info' -Contains 'other antivirus products could not be checked' -Excludes 'no other enabled antivirus was reported'

# --- Finding: out-of-date third-party definitions are not passed silently ---
Reset-Fixtures
$script:cim.AntiVirusProduct = @([pscustomobject]@{ instanceGuid = '{2}'; displayName = 'Other AV'; productState = 0x1010 })
$script:mpStatus.RealTimeProtectionEnabled = $false
$script:mpStatus.AntivirusEnabled = $false
$script:mpStatus.QuickScanEndTime = $null
Add-AntivirusChecks $false
Assert-Checks 'Enabled third-party antivirus with out-of-date definitions' 'pass,warning,info,info' -Contains 'definitions of Other AV are out of date'
Reset-Fixtures
$script:cim.AntiVirusProduct = @([pscustomobject]@{ instanceGuid = '{2}'; displayName = 'Other AV'; productState = 0x1000 })
$script:mpStatus.RealTimeProtectionEnabled = $false
$script:mpStatus.AntivirusEnabled = $false
$script:mpStatus.QuickScanEndTime = $null
Add-AntivirusChecks $false
Assert-Checks 'Enabled third-party antivirus with current definitions' 'pass,info,info,info' -Contains 'definitions are managed by Other AV' -Excludes 'out of date'
Reset-Fixtures
$script:cim.AntiVirusProduct = @([pscustomobject]@{ instanceGuid = '{2}'; displayName = 'Other AV'; productState = 0x1010 })
$script:fail = @('mpstatus')
Add-AntivirusChecks $false
Assert-Checks 'Out-of-date third-party definitions when Defender does not answer' 'pass,warning,pass' -Contains 'definitions of Other AV are out of date'

# --- Finding: detections do not pass when Defender is not protecting ---
Reset-Fixtures
$script:mpStatus.RealTimeProtectionEnabled = $false
Add-AntivirusChecks $false
Assert-Checks 'Zero detections with real-time protection off is not a pass' 'warning,pass,info,info' -Contains 'not providing real-time protection' -Excludes '0 active detections reported by Defender'
Reset-Fixtures
$script:mpStatus.RealTimeProtectionEnabled = $false
$script:threats = @([pscustomobject]@{ IsActive = $true })
Add-AntivirusChecks $false
Assert-Checks 'Active detections still warn with protection off' 'warning,pass,info,warning' -Contains '1 active detections'

# --- Finding: a failed quick-scan request is explained by its cause ---
$accessDenied = [System.Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('denied'), 'HRESULT 0x80070005,Start-MpScan', 'PermissionDenied', $null)
$busy = [System.Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('busy'), 'HRESULT 0x80508023,Start-MpScan', 'NotSpecified', $null)
Reset-Fixtures
$script:IsElevated = $true
$script:scanError = $accessDenied
Add-AntivirusChecks $true
Assert-Checks 'Access denied scan request asks for administrator' 'unknown,pass,pass,info,pass' -Contains 'needs administrator rights'
Reset-Fixtures
$script:IsElevated = $true
$script:scanError = $busy
Add-AntivirusChecks $true
Assert-Checks 'Other scan failures as administrator do not ask to elevate' 'unknown,pass,pass,info,pass' -Contains 'Another scan may already be running' -Excludes 'needs administrator rights'
Reset-Fixtures
$script:IsElevated = $false
$script:scanError = $busy
Add-AntivirusChecks $true
Assert-Checks 'Scan failure without administrator still points to elevation' 'unknown,pass,pass,info,pass' -Contains 'needs administrator rights'
Reset-Fixtures
$script:IsElevated = $true
$script:scanError = $busy
$script:cim.AntiVirusProduct = @([pscustomobject]@{ instanceGuid = '{2}'; displayName = 'Other AV'; productState = 0x1000 })
$script:mpStatus.RealTimeProtectionEnabled = $false
$script:mpStatus.AntivirusEnabled = $false
Add-AntivirusChecks $true
Assert-Checks 'Scan failure while another antivirus is active' 'info,pass,info,info,info' -Contains 'scans are handled by Other AV' -Excludes 'needs administrator rights'
if (-not (Test-AccessDenied $accessDenied) -or (Test-AccessDenied $busy)) { throw 'Access-denied errors are not told apart from other failures.' }
$script:passed++; Write-Host 'PASS Access-denied errors are recognised'

# --- Finding: the non-administrator encryption fallback does not blame missing rights for everything ---
Reset-Fixtures
$script:fail = @('bitlocker')
$script:shell = New-MockShell '8'
Add-EncryptionCheck
Assert-Checks 'Device encryption waiting for activation' warning -Contains 'waiting for activation'
Reset-Fixtures
$script:fail = @('bitlocker')
$script:shell = New-MockShell '0'
Add-EncryptionCheck
Assert-Checks 'BitLocker not available for the drive' info -Contains 'BitLocker is not available'
Reset-Fixtures
$script:fail = @('bitlocker')
$script:shell = New-MockShell ''
Add-EncryptionCheck
Assert-Checks 'No reported status without administrator' unknown -Contains 'did not report an encryption status', 'run this scan again as administrator' -Excludes 'without administrator access'
Reset-Fixtures
$script:IsElevated = $true
$script:fail = @('bitlocker')
$script:shell = New-MockShell ''
Add-EncryptionCheck
Assert-Checks 'No reported status as administrator does not ask to elevate' unknown -Contains 'did not report an encryption status' -Excludes 'as administrator', 'without administrator access'
Reset-Fixtures
$script:fail = @('bitlocker')
$script:shell = New-MockShell '2'
Add-EncryptionCheck
Assert-Checks 'Fallback still reports BitLocker off' warning -Contains 'BitLocker protection: Off'

Write-Host "$script:passed collector regression checks passed. No real health queries were run."
