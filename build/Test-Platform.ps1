# Tests the collector's Windows-support, Secure Boot, TPM, UAC and event-log functions using
# in-memory mocks. No health queries, event-log reads, report files or setting changes are performed.
$ErrorActionPreference = 'Stop'
$collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Collect-Health.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Collector parse errors: $($parseErrors -join '; ')" }
foreach ($functionName in 'Add-Check','Remove-UserNames','Get-OneLineText','Get-SafeText','Get-Floor','Format-Date','Get-FailureNote','ConvertTo-FirmwareMode','Get-WindowsSupportResult','Add-WindowsSupportChecks','Add-SecureBootCheck','Add-TpmCheck','Add-UacCheck','Get-HealthEvents','Get-LogCoverageNote','Get-CrashProgramName','Add-StabilityChecks','Add-DriveErrorChecks','Add-AppCrashChecks') {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $false)
    if (-not $functionAst) { throw "Collector function not found: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$listDateAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$SupportListDate'
}, $false)
if (-not $listDateAst) { throw 'Collector support-list date not found.' }
. ([scriptblock]::Create($listDateAst.Extent.Text))

$NOW = [datetime]'2026-11-10T12:00:00'
function Get-Date { return $script:NOW }
# Windows does not let a process override %firmware_type%, so the firmware-mode helper is mocked.
function Get-FirmwareMode { return $script:firmwareMode }

# Machine settings are read through the collector's 64-bit registry helper (build\Test-Robustness.ps1
# tests the helper itself); a direct Get-ItemProperty read would see a 32-bit host's redirected copy.
function Get-MachineRegistryValues {
    param([string]$Path)
    if ($script:registryFailures -contains $Path) { throw 'Simulated registry failure containing PRIVATE_ERROR_PATH.' }
    if (-not $script:registry.ContainsKey($Path)) { throw "Unexpected registry path: $Path" }
    return $script:registry[$Path]
}
function Get-ItemProperty { throw 'Machine settings must be read through Get-MachineRegistryValues.' }
# The real step runner uses a second runspace, where these mocks would not exist; run steps inline.
function Invoke-Bounded([string]$Step, [int]$Seconds, [scriptblock]$Script, [object[]]$ArgumentList = @()) {
    if ($Seconds -le 0) { throw "Step without a time limit: $Step" }
    $script:steps += $Step
    if ($script:stepTimeouts | Where-Object { $Step -like $_ }) { Write-Error -Message "Step timed out: $Step" -Category OperationTimeout -ErrorId 'HealthScanStepTimeout' -ErrorAction Stop }
    & $Script @ArgumentList
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter, [string[]]$Property, [int]$OperationTimeoutSec)
    if ($OperationTimeoutSec -le 0) { throw "CIM query without a time limit: $ClassName" }
    if ($ClassName -eq 'Win32_DiskDrive') {
        if ($script:diskDriveFailure) { throw 'Simulated disk query failure containing PRIVATE_ERROR_PATH.' }
        return $script:diskDrives
    }
    if ($ClassName -ne 'Win32_PnPEntity') { throw "Unexpected CIM class: $ClassName" }
    if ($Filter -ne "ClassGuid='{d94ee5d8-d189-4994-83d2-f68d7d41b0e6}'") { throw 'TPM query must be limited to the security-devices class.' }
    if ($script:cimFailure) { throw 'Simulated provider failure containing PRIVATE_ERROR_PATH.' }
    return $script:devices
}
function Get-WinEvent {
    [CmdletBinding()]
    param([string]$LogName, [string]$FilterXPath, [switch]$Oldest, [int]$MaxEvents)
    if ($script:eventFailures -contains $LogName) { throw 'Simulated event-log failure containing PRIVATE_ERROR_PATH.' }
    if ($Oldest) { return [pscustomobject]@{ TimeCreated = $script:oldest[$LogName] } }
    $script:xpaths += $FilterXPath
    $found = @($script:events[$LogName])
    if (-not $found.Count) {
        # Same shape as the real cmdlet's "nothing matched" error.
        $record = New-Object System.Management.Automation.ErrorRecord((New-Object Exception 'No events were found that match the specified selection criteria.'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null)
        throw $record
    }
    return $found
}
function New-Event($provider, $id, $daysAgo, $firstProperty) {
    $properties = @()
    if ($null -ne $firstProperty) { $properties = @([pscustomobject]@{ Value = $firstProperty }) }
    return [pscustomobject]@{ ProviderName = $provider; Id = $id; TimeCreated = $script:NOW.AddDays(-$daysAgo); Properties = $properties; Message = 'PRIVATE_EVENT_MESSAGE' }
}

$CV = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$SB = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
$UAC = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
function Reset-Fixtures {
    $script:checks = @()
    $script:registryFailures = @()
    $script:registry = @{
        $CV = [pscustomobject]@{ CurrentBuildNumber = '26100'; EditionID = 'Professional'; InstallationType = 'Client'; DisplayVersion = '24H2' }
        $SB = [pscustomobject]@{ UEFISecureBootEnabled = 1 }
        $UAC = [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 5 }
    }
    $script:cimFailure = $false
    $script:devices = @([pscustomobject]@{ HardwareID = @('ACPI\VEN_MSFT&DEV_0101', 'ACPI\MSFT0101', '*MSFT0101'); CompatibleID = $null; ConfigManagerErrorCode = 0 })
    $script:eventFailures = @()
    $script:events = @{ System = @(); Application = @() }
    $script:oldest = @{ System = $script:NOW.AddDays(-90); Application = $script:NOW.AddDays(-90) }
    $script:xpaths = @()
    $script:firmwareMode = 'UEFI'
    $script:steps = @()
    $script:stepTimeouts = @()
    # Disk 0 is internal; disk 2 is a USB stick.
    $script:diskDriveFailure = $false
    $script:diskDrives = @(
        [pscustomobject]@{ Index = 0; MediaType = 'Fixed hard disk media'; InterfaceType = 'SCSI' },
        [pscustomobject]@{ Index = 2; MediaType = 'Removable Media'; InterfaceType = 'USB' }
    )
}
function New-DiskEvent($id, $daysAgo, $diskNumber) {
    $e = New-Event 'disk' $id $daysAgo ('\Device\Harddisk{0}\DR{0}' -f $diskNumber)
    return $e
}
function Use-Culture([string]$Culture, [scriptblock]$Body) {
    $thread = [Threading.Thread]::CurrentThread
    $before = $thread.CurrentCulture
    try {
        $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
        & $Body
    } finally { $thread.CurrentCulture = $before }
}
function Assert-Checks {
    param([string]$Name, [string]$Statuses, [string[]]$Contains = @(), [string[]]$Excludes = @())
    $actual = ($script:checks | ForEach-Object status) -join ','
    if ($actual -ne $Statuses) { throw "${Name}: expected '$Statuses', got '$actual' ($(($script:checks | ForEach-Object detail) -join ' | '))." }
    $reportText = $script:checks | ConvertTo-Json -Depth 6
    foreach ($text in $Contains) {
        if (-not $reportText.Contains($text)) { throw "${Name}: report did not include '$text'. Report: $reportText" }
    }
    foreach ($text in (@($Excludes) + @('PRIVATE_ERROR_PATH', 'PRIVATE_EVENT_MESSAGE', 'PRIVATE_PATH'))) {
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
function Assert-Support {
    param([string]$Name, $Build, [string]$Edition = 'Professional', [string]$Type = 'Client', [string]$Display = '', [string]$Status, [string[]]$Contains = @())
    $result = Get-WindowsSupportResult $Build $Edition $Type $Display $script:NOW
    if ($result.status -ne $Status) { throw "${Name}: expected '$Status', got '$($result.status)' ($($result.detail))." }
    foreach ($text in $Contains) { if (-not $result.detail.Contains($text)) { throw "${Name}: detail did not include '$text' ($($result.detail))." } }
    if (-not $result.action) { throw "${Name}: empty action." }
    $script:passed++
    Write-Host "PASS $Name"
}
$script:passed = 0
$realUserName = $env:USERNAME

# --- Windows version support (evaluated as of 2026-11-10) ---
Assert-Support 'Windows 10 is past end of support' -Build 19045 -Display '22H2' -Status warning -Contains '2025-10-14', 'Extended Security Updates'
Assert-Support 'Windows 11 23H2 Pro is past end of servicing' -Build 22631 -Status warning -Contains '2025-11-11', 'Home and Pro'
Assert-Support 'Windows 11 23H2 Enterprise ends today, not yet past' -Build 22631 -Edition Enterprise -Status warning -Contains '2026-11-10', '0 days from now'
Assert-Support 'Windows 11 24H2 Pro is past end of servicing' -Build 26100 -Status warning -Contains '2026-10-13'
Assert-Support 'Windows 11 24H2 Education is supported' -Build 26100 -Edition Education -Status pass -Contains '2027-10-12', 'Enterprise and Education'
Assert-Support 'Windows 11 25H2 Home is supported' -Build 26200 -Edition Core -Status pass -Contains '2027-10-12', 'Home and Pro'
Assert-Support 'Pro Education follows the Home and Pro schedule' -Build 26200 -Edition ProfessionalEducation -Status pass -Contains '2027-10-12', 'Home and Pro'
Assert-Support 'Windows 11 26H2 Pro is supported' -Build 26300 -Display '26H2' -Status pass -Contains '2028-10-10', 'Home and Pro'
Assert-Support 'Windows 11 26H2 Enterprise is supported' -Build 26300 -Edition Enterprise -Display '26H2' -Status pass -Contains '2029-10-09', 'Enterprise and Education'
Assert-Support 'Windows 11 26H1 Home is supported' -Build 28000 -Edition Core -Display '26H1' -Status pass -Contains '2028-03-14', 'Home and Pro'
Assert-Support 'Windows 11 26H1 Enterprise is supported' -Build 28000 -Edition Enterprise -Display '26H1' -Status pass -Contains '2029-03-13'
Assert-Support 'Unlisted newer build is informational, not guessed' -Build 29000 -Display '27H2' -Status info -Contains 'not in this scan', '27H2'
Assert-Support 'LTSC edition is not judged by the consumer schedule' -Build 19044 -Edition EnterpriseS -Status info -Contains 'LTSC'
Assert-Support 'IoT LTSC on a Windows 11 build is informational' -Build 26100 -Edition IoTEnterpriseS -Status info -Contains 'LTSC'
Assert-Support 'Server installation is informational' -Build 26100 -Edition ServerStandard -Type Server -Status info -Contains 'not covered'
Assert-Support 'Unreadable build number is unknown' -Build '' -Status unknown
Assert-Support 'Non-numeric build number is unknown' -Build 'abc' -Status unknown
$near = Get-WindowsSupportResult 26200 'Professional' 'Client' '25H2' ([datetime]'2027-08-01')
if ($near.status -ne 'warning' -or -not $near.detail.Contains('72 days from now')) { throw "Support ending within 90 days should warn with the days left ($($near.detail))." }
$script:passed++; Write-Host 'PASS Support ending within 90 days warns with the days left'
$far = Get-WindowsSupportResult 26200 'Professional' 'Client' '25H2' ([datetime]'2027-07-01')
if ($far.status -ne 'pass') { throw 'Support ending in more than 90 days should pass.' }
$script:passed++; Write-Host 'PASS Support ending in more than 90 days passes'

Reset-Fixtures
Add-WindowsSupportChecks
Assert-Checks 'Support check reads the registry' warning -Contains 'Windows version support', '24H2'
Reset-Fixtures
$script:registryFailures = @($CV)
Add-WindowsSupportChecks
Assert-Checks 'Support check registry failure is unknown' unknown -Contains 'could not be read'

# --- Secure Boot ---
Reset-Fixtures
Add-SecureBootCheck
Assert-Checks 'Secure Boot on' pass
Reset-Fixtures
$script:registry[$SB] = [pscustomobject]@{ UEFISecureBootEnabled = 0 }
Add-SecureBootCheck
Assert-Checks 'Secure Boot off' warning -Contains 'off or not supported', 'To turn on Secure Boot' -Excludes 'Secure Boot is turned on in'
Reset-Fixtures
$script:registryFailures = @($SB)
Add-SecureBootCheck
Assert-Checks 'Secure Boot key missing (legacy BIOS)' unknown -Contains 'legacy BIOS'
Reset-Fixtures
$script:registry[$SB] = [pscustomobject]@{ Other = 1 }
Add-SecureBootCheck
Assert-Checks 'Secure Boot value missing is unknown, not off' unknown
Reset-Fixtures
$script:firmwareMode = 'Legacy'
$script:registry[$SB] = [pscustomobject]@{ UEFISecureBootEnabled = 0 }
Add-SecureBootCheck
Assert-Checks 'Legacy BIOS install is informational and never told to change firmware mode' info -Contains 'legacy BIOS mode', 'Do not change the firmware startup mode'
Reset-Fixtures
$script:firmwareMode = ''
$script:registry[$SB] = [pscustomobject]@{ UEFISecureBootEnabled = 0 }
Add-SecureBootCheck
Assert-Checks 'Undetermined firmware mode falls back to the registry value' warning

# --- TPM ---
Reset-Fixtures
Add-TpmCheck
Assert-Checks 'TPM 2.0 working' pass -Contains 'TPM 2.0'
Reset-Fixtures
$script:devices = @([pscustomobject]@{ HardwareID = @('ACPI\IFX0102'); CompatibleID = @('ACPI\PNP0C31', '*PNP0C31'); ConfigManagerErrorCode = 0 })
Add-TpmCheck
Assert-Checks 'TPM 1.2 is informational' info -Contains 'TPM 1.2', 'move to TPM 2.0 with a firmware update' -Excludes 'turned on in'
Reset-Fixtures
$script:devices = @([pscustomobject]@{ HardwareID = @('ACPI\NTC0702'); CompatibleID = @('ACPI\MSFT0101', '*MSFT0101'); ConfigManagerErrorCode = 0 })
Add-TpmCheck
Assert-Checks 'Vendor TPM identified by compatible ID' pass -Contains 'TPM 2.0'
Reset-Fixtures
$script:devices[0].ConfigManagerErrorCode = 10
Add-TpmCheck
Assert-Checks 'TPM with a device problem' warning -Contains 'code 10'
Reset-Fixtures
$script:devices = @([pscustomobject]@{ HardwareID = @('PCI\VEN_1022&DEV_1649'); CompatibleID = @('PCI\CC_1080'); ConfigManagerErrorCode = 0 })
Add-TpmCheck
Assert-Checks 'Other security devices are not mistaken for a TPM' info -Contains 'did not list a TPM'
Reset-Fixtures
$script:devices = @()
Add-TpmCheck
Assert-Checks 'No TPM device' info -Contains 'did not list a TPM', 'If the PC has a TPM, it can be turned on' -Excludes 'A TPM is turned on in'
Reset-Fixtures
$script:cimFailure = $true
Add-TpmCheck
Assert-Checks 'TPM query failure is unknown without error leakage' unknown

# --- User Account Control ---
Reset-Fixtures
Add-UacCheck
Assert-Checks 'UAC on' pass -Contains 'not set to' -Excludes 'asks before'
Reset-Fixtures
$script:registry[$UAC] = [pscustomobject]@{ EnableLUA = 0; ConsentPromptBehaviorAdmin = 5 }
Add-UacCheck
Assert-Checks 'UAC off' warning -Contains 'turned off'
Reset-Fixtures
$script:registry[$UAC] = [pscustomobject]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 0 }
Add-UacCheck
Assert-Checks 'UAC never notifies' warning -Contains 'never notify'
Reset-Fixtures
$script:registry[$UAC] = [pscustomobject]@{ EnableLUA = 1 }
Add-UacCheck
Assert-Checks 'UAC on without a prompt-level value' pass
Reset-Fixtures
$script:registry[$UAC] = [pscustomobject]@{ Other = 1 }
Add-UacCheck
Assert-Checks 'UAC value missing is unknown' unknown
Reset-Fixtures
$script:registryFailures = @($UAC)
Add-UacCheck
Assert-Checks 'UAC registry failure is unknown' unknown

# --- System stability ---
Reset-Fixtures
$script:events.System = @((New-Event 'Microsoft-Windows-WER-SystemErrorReporting' 1001 2), (New-Event 'Microsoft-Windows-Kernel-Power' 41 8 159))
Add-StabilityChecks
Assert-Checks 'Separate stop errors from different providers are both counted' warning -Contains '2 blue-screen stop error(s)'

$WER = 'Microsoft-Windows-WER-SystemErrorReporting'
$KP = 'Microsoft-Windows-Kernel-Power'
Reset-Fixtures
Add-StabilityChecks
Assert-Checks 'No stability events' pass -Contains '0 blue-screen stop error(s) and 0 unexpected shutdown(s)' -Excludes 'only goes back'
if (-not ($script:xpaths[0].Contains("@Name='$WER'") -and $script:xpaths[0].Contains('EventID=41') -and $script:xpaths[0].Contains('2592000000'))) { throw "Stability query is not limited by provider, id and 30 days: $($script:xpaths[0])" }
Reset-Fixtures
$script:events.System = @((New-Event $KP 41 3), (New-Event $KP 41 9))
Add-StabilityChecks
Assert-Checks 'Two unexpected shutdowns stay below the review threshold' pass -Contains '2 unexpected shutdown(s)', 'Most recent: 2026-11-07'
Reset-Fixtures
$script:events.System = @((New-Event $KP 41 3), (New-Event $KP 41 9), (New-Event $KP 41 20))
Add-StabilityChecks
Assert-Checks 'Three unexpected shutdowns need review' warning -Contains '3 unexpected shutdown(s)'
Reset-Fixtures
$script:events.System = @((New-Event $WER 1001 5))
Add-StabilityChecks
Assert-Checks 'One blue screen needs review' warning -Contains '1 blue-screen stop error(s)', 'Most recent: 2026-11-05'
Reset-Fixtures
$script:events.System = @((New-Event $KP 41 4 159))
Add-StabilityChecks
Assert-Checks 'Kernel-Power 41 with a bug-check code is a stop error even without a dump event' warning -Contains '1 blue-screen stop error(s) and 0 unexpected shutdown(s)'
Reset-Fixtures
$script:events.System = @((New-Event $KP 41 4 159), (New-Event $WER 1001 4))
Add-StabilityChecks
Assert-Checks 'One crash logged both ways is counted once' warning -Contains '1 blue-screen stop error(s) and 0 unexpected shutdown(s)'
Reset-Fixtures
$script:events.System = @((New-Event $KP 41 3 0), (New-Event $KP 41 9 0))
Add-StabilityChecks
Assert-Checks 'Kernel-Power 41 with code 0 is a power loss' pass -Contains '0 blue-screen stop error(s) and 2 unexpected shutdown(s)'
Reset-Fixtures
$script:events.System = @((New-Event 'Microsoft-Windows-Kernel-Boot' 41 1), (New-Event 'Some-Other-Provider' 1001 1))
Add-StabilityChecks
Assert-Checks 'Same event ids from other providers are not counted' pass -Contains '0 blue-screen stop error(s) and 0 unexpected shutdown(s)'
# Finding: one blue screen logged as 1001 plus a code-0 Kernel-Power 41 is one crash.
Reset-Fixtures
$pairedDump = New-Event $WER 1001 4
$pairedPower = New-Event $KP 41 4 0
$pairedPower.TimeCreated = $pairedDump.TimeCreated.AddMinutes(-2)
$script:events.System = @($pairedDump, $pairedPower)
Add-StabilityChecks
Assert-Checks 'A dump event cancels the code-0 shutdown logged with it' warning -Contains '1 blue-screen stop error(s) and 0 unexpected shutdown(s)'
Reset-Fixtures
$script:events.System = @((New-Event $WER 1001 4), (New-Event $KP 41 4 0), (New-Event $KP 41 9 0))
$script:events.System[1].TimeCreated = $script:events.System[0].TimeCreated.AddMinutes(-1)
$script:events.System[2].TimeCreated = $script:events.System[0].TimeCreated.AddMinutes(-3)
Add-StabilityChecks
Assert-Checks 'Each dump event cancels at most one shutdown' warning -Contains '1 blue-screen stop error(s) and 1 unexpected shutdown(s)'
Reset-Fixtures
$script:events.System = @((New-Event $WER 1001 4), (New-Event $KP 41 6 0))
Add-StabilityChecks
Assert-Checks 'A shutdown days away from a dump event is still counted' warning -Contains '1 blue-screen stop error(s) and 1 unexpected shutdown(s)'
Reset-Fixtures
$stopPower = New-Event $KP 41 4 159
$stopDump = New-Event $WER 1001 4
$laterPower = New-Event $KP 41 4 0
$laterPower.TimeCreated = $stopDump.TimeCreated.AddMinutes(5)
$script:events.System = @($stopPower, $stopDump, $laterPower)
Add-StabilityChecks
Assert-Checks 'A dump already matched to a bug-check 41 does not cancel another shutdown' warning -Contains '1 blue-screen stop error(s) and 1 unexpected shutdown(s)'
Reset-Fixtures
$script:oldest.System = $script:NOW.AddDays(-6)
Add-StabilityChecks
Assert-Checks 'Short event-log history is disclosed' pass -Contains 'only goes back 6 day(s)'
Reset-Fixtures
$script:eventFailures = @('System')
Add-StabilityChecks
Assert-Checks 'Unreadable System log is unknown' unknown -Contains 'could not be read'

# --- Drive error events ---
Reset-Fixtures
Add-DriveErrorChecks
Assert-Checks 'No drive error events' pass -Contains 'none of the common disk', 'Other storage events are not checked'
Reset-Fixtures
$script:events.System = @((New-Event 'disk' 51 2), (New-Event 'disk' 153 2))
Add-DriveErrorChecks
Assert-Checks 'Two removable-drive style events on one day stay below the threshold' pass -Contains '2 disk or file-system error event(s)', 'below the review threshold'
Reset-Fixtures
$script:events.System = @((New-Event 'disk' 51 2), (New-Event 'disk' 153 2), (New-Event 'disk' 11 2))
Add-DriveErrorChecks
Assert-Checks 'Three controller, paging or retry events need review' warning
Reset-Fixtures
$script:events.System = @((New-Event 'disk' 153 2), (New-Event 'disk' 153 9))
Add-DriveErrorChecks
Assert-Checks 'Retry events on two different days need review' warning
Reset-Fixtures
$script:events.System = @((New-Event 'disk' 7 2))
Add-DriveErrorChecks
Assert-Checks 'A single bad block needs review at once' warning -Contains '1 x bad block'
Reset-Fixtures
$script:events.System = @((New-Event 'disk' 7 2))
$script:oldest.System = $script:NOW.AddDays(-5)
Add-DriveErrorChecks
Assert-Checks 'Drive warning also discloses a short log' warning -Contains 'only goes back 5 day(s)'
Reset-Fixtures
$script:events.System = @((New-Event 'disk' 7 2), (New-Event 'disk' 7 4), (New-Event 'Ntfs' 55 1), (New-Event 'Microsoft-Windows-Ntfs' 55 8))
Add-DriveErrorChecks
Assert-Checks 'Bad blocks and file-system corruption' warning -Contains '4 disk or file-system error event(s)', '2 x bad block', '2 x file system corruption', 'Most recent: 2026-11-09'
Reset-Fixtures
$script:events.System = @((New-Event 'Microsoft-Windows-Kernel-Processor-Power' 55 1), (New-Event 'Microsoft-Windows-Kernel-Boot' 153 1), (New-Event 'Microsoft-Windows-Kernel-General' 11 1), (New-Event 'Microsoft-Windows-Hyper-V-VmSwitch' 7 1), (New-Event 'disk' 55 1), (New-Event 'Ntfs' 7 1))
Add-DriveErrorChecks
Assert-Checks 'Unrelated providers that reuse the ids are not drive errors' pass
Reset-Fixtures
$script:eventFailures = @('System')
Add-DriveErrorChecks
Assert-Checks 'Unreadable System log leaves drive events unknown' unknown
# Finding: events are tied to the drive they name.
Reset-Fixtures
$script:events.System = @((New-DiskEvent 51 2 0))
Add-DriveErrorChecks
Assert-Checks 'One paging error on the internal drive needs review' warning -Contains 'internal drive that is in this PC now' -Excludes 'below the review threshold', 'Harddisk0'
Reset-Fixtures
$script:events.System = @((New-DiskEvent 153 2 2), (New-DiskEvent 153 2 2), (New-DiskEvent 11 2 2), (New-DiskEvent 51 2 2))
Add-DriveErrorChecks
Assert-Checks 'A burst on one day from a USB stick stays below the threshold' pass -Contains '4 disk or file-system error event(s)', 'below the review threshold' -Excludes 'Harddisk2'
Reset-Fixtures
$script:events.System = @((New-DiskEvent 153 2 5), (New-DiskEvent 153 2 5), (New-DiskEvent 153 2 5))
Add-DriveErrorChecks
Assert-Checks 'A burst on one day from a drive no longer attached stays below the threshold' pass
Reset-Fixtures
$script:events.System = @((New-DiskEvent 153 2 2), (New-DiskEvent 153 9 2))
Add-DriveErrorChecks
Assert-Checks 'USB stick events on two days still need review' warning
Reset-Fixtures
$script:diskDriveFailure = $true
$script:events.System = @((New-DiskEvent 51 2 0))
Add-DriveErrorChecks
Assert-Checks 'Unknown drive list falls back to the count threshold' pass -Contains 'below the review threshold'
Reset-Fixtures
$script:diskDriveFailure = $true
$script:events.System = @((New-DiskEvent 51 2 0), (New-DiskEvent 51 2 0), (New-DiskEvent 51 2 0))
Add-DriveErrorChecks
Assert-Checks 'Unmatched events still warn at three' warning
Reset-Fixtures
$script:diskDrives = @([pscustomobject]@{ Index = 1; MediaType = 'Fixed hard disk media'; InterfaceType = 'USB' })
$script:events.System = @((New-DiskEvent 51 2 1))
Add-DriveErrorChecks
Assert-Checks 'A USB-attached disk is not treated as internal' pass

# --- Program crashes ---
Reset-Fixtures
Add-AppCrashChecks
Assert-Checks 'No program crashes' info -Contains '0 program crash(es) and 0 program hang(s)'
if (-not $script:xpaths[0].Contains('604800000')) { throw 'Program-crash query is not limited to 7 days.' }
Reset-Fixtures
$script:events.Application = @(
    (New-Event 'Application Error' 1000 1 'editor.exe'), (New-Event 'Application Error' 1000 2 'editor.exe'),
    (New-Event 'Application Error' 1000 3 'C:\Users\PRIVATE_PATH\tool.exe'), (New-Event 'Application Hang' 1002 1 'viewer.exe'),
    (New-Event 'Some.Service' 1000 1 'other.exe'), (New-Event 'Microsoft-Windows-Winlogon' 1002 1 'winlogon.exe')
)
Add-AppCrashChecks
Assert-Checks 'Crashes and hangs are counted by provider and names are sanitised' info -Contains '3 program crash(es) and 1 program hang(s)', '- editor.exe: 2', '- viewer.exe: 1', 'program (name omitted)' -Excludes 'other.exe', 'winlogon.exe'
Reset-Fixtures
$script:events.Application = @(1..8 | ForEach-Object { New-Event 'Application Error' 1000 1 ('app{0}.exe' -f $_) })
Add-AppCrashChecks
Assert-Checks 'Program list is bounded to five entries' info -Contains 'app5.exe' -Excludes 'app6.exe'
Reset-Fixtures
$script:events.Application = @((New-Event 'Application Error' 1000 1 $null))
Add-AppCrashChecks
Assert-Checks 'Event without properties is still counted' info -Contains '1 program crash(es)'
Reset-Fixtures
$script:oldest.Application = $script:NOW.AddDays(-2)
Add-AppCrashChecks
Assert-Checks 'Short Application log is disclosed' info -Contains 'only goes back 2 day(s)'
Reset-Fixtures
$script:eventFailures = @('Application')
Add-AppCrashChecks
Assert-Checks 'Unreadable Application log is unknown' unknown

# Username redaction must only hit whole words in the base name.
try {
    $env:USERNAME = 'al'
    if ((Get-CrashProgramName 'calc.exe') -ne 'calc.exe') { throw 'A short username mangled an unrelated program name.' }
    if ((Get-CrashProgramName 'install.exe') -ne 'install.exe') { throw 'A short username mangled an unrelated program name.' }
    if ((Get-CrashProgramName 'AL-backup.exe') -ne '[user]-backup.exe') { throw 'A whole-word username was not redacted.' }
    $env:USERNAME = 'exe'
    if ((Get-CrashProgramName 'tool.exe') -ne 'tool.exe') { throw 'The file extension must never be redacted.' }
} finally { $env:USERNAME = $realUserName }
$script:passed += 4

if ((Get-CrashProgramName "evil`nname.exe") -ne 'program (name omitted)') { throw 'Multiline program names must be omitted.' }
if ((Get-CrashProgramName 'no-extension') -ne 'program (name omitted)') { throw 'Names without a file extension must be omitted.' }
$script:passed += 2

# --- Regional settings ---
# Thai regional settings use the Buddhist calendar; report dates must stay Gregorian.
Use-Culture 'th-TH' {
    if ($script:NOW.ToString('yyyy') -eq '2026') { throw 'The test culture did not take effect.' }
    Reset-Fixtures
    $script:events.System = @((New-Event $KP 41 3), (New-Event $KP 41 9))
    Add-StabilityChecks
    Assert-Checks 'Thai regional settings: stability date is Gregorian' pass -Contains 'Most recent: 2026-11-07' -Excludes '2569'
    Reset-Fixtures
    $script:events.System = @((New-Event 'disk' 153 2), (New-Event 'disk' 153 9))
    Add-DriveErrorChecks
    Assert-Checks 'Thai regional settings: drive-error dates are Gregorian' warning -Contains 'Most recent: 2026-11-08' -Excludes '2569'
}
Use-Culture 'ar-SA' {
    Reset-Fixtures
    $script:events.System = @((New-Event $WER 1001 5))
    Add-StabilityChecks
    Assert-Checks 'Saudi regional settings: stability date is Gregorian' warning -Contains 'Most recent: 2026-11-05'
}
# Turkish and Azeri settings lowercase 'I' to a dotless i, which breaks case-insensitive [A-Za-z] matches.
foreach ($culture in 'tr-TR', 'az-Latn-AZ') {
    Use-Culture $culture {
        foreach ($name in 'WINWORD.EXE', 'FIREFOX.EXE', 'SearchIndexer.exe') {
            if ((Get-CrashProgramName $name) -ne $name) { throw "${culture}: crash program name '$name' was omitted." }
        }
        if ((ConvertTo-FirmwareMode 'UEFI') -ne 'UEFI') { throw "${culture}: UEFI firmware mode not recognised." }
        if ((ConvertTo-FirmwareMode 'LEGACY') -ne 'Legacy' -or (ConvertTo-FirmwareMode 'BIOS') -ne 'Legacy') { throw "${culture}: legacy firmware mode not recognised." }
        try {
            $env:USERNAME = 'IRMAK'
            if ((Get-CrashProgramName 'irmak-tool.exe') -ne '[user]-tool.exe') { throw "${culture}: username with an I was not redacted." }
        } finally { $env:USERNAME = $realUserName }
    }
    $script:passed++; Write-Host "PASS Program names, firmware mode and redaction work under $culture"
}
if ((ConvertTo-FirmwareMode 'uefi') -ne 'UEFI' -or (ConvertTo-FirmwareMode '') -ne '' -or (ConvertTo-FirmwareMode 'other') -ne '') { throw 'Firmware mode conversion is wrong.' }
$script:passed++; Write-Host 'PASS Firmware mode conversion'

# --- Time limits on event-log reads ---
Reset-Fixtures
Add-StabilityChecks
Add-AppCrashChecks
if (@($script:steps | Where-Object { $_ -like 'reading the Windows * event log' }).Count -lt 4) { throw "Event-log reads must run as bounded steps ($($script:steps -join ', '))." }
$script:passed++; Write-Host 'PASS Event-log reads run as bounded steps'
Reset-Fixtures
$script:stepTimeouts = @('reading the Windows System event log')
Add-StabilityChecks
Assert-Checks 'A timed-out event log is unknown and says why' unknown -Contains 'could not be read', 'did not answer within the time limit'
Reset-Fixtures
$script:stepTimeouts = @('reading the Windows Application event log')
Add-AppCrashChecks
Assert-Checks 'A timed-out Application log is unknown and says why' unknown -Contains 'did not answer within the time limit'

Write-Host "$script:passed platform regression checks passed. No real health queries were run."
