# Tests the collector's actual battery and startup functions using in-memory CIM mocks.
# No health queries, scans, report files, or system setting changes are performed.
$ErrorActionPreference = 'Stop'
$collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Collect-Health.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Collector parse errors: $($parseErrors -join '; ')" }
foreach ($functionName in 'Add-Check','Remove-UserNames','Get-OneLineText','Get-SafeText','Get-Floor','Get-BatteryCheckId','Add-BatteryChecks','Get-StartupDisplayName','Get-StartupLocationLabel','Add-StartupChecks') {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $false)
    if (-not $functionAst) { throw "Collector function not found: $functionName" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Namespace, [string[]]$Property, [int]$OperationTimeoutSec)
    # Every CIM query must carry a time limit, so a hung WMI provider cannot stall the scan.
    if ($OperationTimeoutSec -le 0) { throw "CIM query without a time limit: $ClassName" }
    $script:cimCalls += $ClassName
    if ($ClassName -in 'BatteryStaticData','BatteryFullChargedCapacity') {
        if ($Namespace -ne 'root/wmi') { throw 'Unexpected battery namespace.' }
    }
    if ($ClassName -eq 'Win32_StartupCommand' -and ($Property -join ',') -ne 'Name,Location') {
        throw 'Startup query must request only Name and Location.'
    }
    if (-not $script:cimData.ContainsKey($ClassName)) { throw "Unexpected CIM class: $ClassName" }
    if ($script:cimFailures -contains $ClassName) { throw 'Simulated provider failure containing PRIVATE_ERROR_PATH.' }
    return $script:cimData[$ClassName]
}
function Reset-Fixtures {
    $script:checks = @()
    $script:cimCalls = @()
    $script:cimFailures = @()
    $script:cimData = @{
        Win32_Battery = @([pscustomobject]@{ Name = 'Battery' })
        BatteryStaticData = @([pscustomobject]@{
            Active = $true; InstanceName = 'PACK_A'; Tag = 1
            Capabilities = [uint32]2147483648; DesignedCapacity = 50000
        })
        BatteryFullChargedCapacity = @([pscustomobject]@{
            Active = $true; InstanceName = 'PACK_A'; Tag = 1; FullChargedCapacity = 45000
        })
        Win32_StartupCommand = @()
    }
}
function Assert-Checks {
    param([string]$Name, [string]$Statuses, [string[]]$Contains = @(), [string[]]$Excludes = @())
    $actual = ($script:checks | ForEach-Object status) -join ','
    if ($actual -ne $Statuses) { throw "${Name}: expected '$Statuses', got '$actual'." }
    $reportText = $script:checks | ConvertTo-Json -Depth 6
    foreach ($text in $Contains) {
        if (-not $reportText.Contains($text)) { throw "${Name}: report did not include '$text'." }
    }
    foreach ($text in (@($Excludes) + @('PRIVATE_ERROR_PATH','PRIVATE_COMMAND','PRIVATE_USERNAME','PRIVATE_SID','PRIVATE_LOCATION','PACK_A','PACK_B','OTHER_PACK'))) {
        if ($reportText.Contains($text)) { throw "${Name}: report leaked or incorrectly included '$text'." }
    }
    $ids=@($script:checks | ForEach-Object { $_.id } | Where-Object { $_ })
    foreach ($id in $ids) {
        if ($id -notmatch '^battery:[0-9a-f]{64}$') { throw "${Name}: invalid hashed battery identifier." }
    }
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw "${Name}: duplicate battery identifiers." }
    $script:passed++
    Write-Host "PASS $Name"
}
$script:passed = 0

Reset-Fixtures
Add-BatteryChecks
Assert-Checks 'Healthy capacity retention' pass -Contains '90% of design','not the current charge level','review threshold'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity[0].FullChargedCapacity = 35000
Add-BatteryChecks
Assert-Checks 'Reduced capacity' warning -Contains '70% of design'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity[0].FullChargedCapacity = 40000
Add-BatteryChecks
Assert-Checks 'Review threshold boundary' pass -Contains '80% of design'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity[0].FullChargedCapacity = 39999
Add-BatteryChecks
Assert-Checks 'Below threshold is not rounded to healthy' warning -Contains '79.9% of design'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity[0].FullChargedCapacity = 52500
Add-BatteryChecks
Assert-Checks 'Calibration headroom is preserved' pass -Contains '105% of design'

Reset-Fixtures
$script:cimData.Win32_Battery = @()
Add-BatteryChecks
Assert-Checks 'No installed battery' info -Contains 'did not report an installed battery'
if (($script:cimCalls -join ',') -ne 'Win32_Battery') { throw 'No-battery case queried battery capacity classes.' }

Reset-Fixtures
$script:cimFailures = @('Win32_Battery')
Add-BatteryChecks
Assert-Checks 'Battery presence query denied' unknown -Contains 'presence could not be read'

foreach ($className in 'BatteryStaticData','BatteryFullChargedCapacity') {
    Reset-Fixtures
    $script:cimFailures = @($className)
    Add-BatteryChecks
    Assert-Checks "Unsupported or inaccessible $className" unknown -Contains 'did not provide readable capacity data'
}

Reset-Fixtures
$script:cimData.BatteryStaticData[0].Active = $false
Add-BatteryChecks
Assert-Checks 'Inactive battery data is ignored' unknown -Contains 'no active design-capacity data'

foreach ($value in @($null, 0, -1, [uint32]::MaxValue, [double]::NaN)) {
    Reset-Fixtures
    $script:cimData.BatteryStaticData[0].DesignedCapacity = $value
    Add-BatteryChecks
    Assert-Checks "Invalid design capacity ($value)" unknown -Contains 'did not provide valid design capacity'
}
foreach ($value in @($null, 0, -1, [uint32]::MaxValue, [double]::PositiveInfinity)) {
    Reset-Fixtures
    $script:cimData.BatteryFullChargedCapacity[0].FullChargedCapacity = $value
    Add-BatteryChecks
    Assert-Checks "Invalid full-charge capacity ($value)" unknown -Contains 'did not provide valid design capacity'
}

Reset-Fixtures
$script:cimData.BatteryStaticData[0].Capabilities = $null
Add-BatteryChecks
Assert-Checks 'Missing capacity units' unknown -Contains 'capacity units'

Reset-Fixtures
$script:cimData.BatteryStaticData[0].Capabilities = [uint32]3221225472
Add-BatteryChecks
Assert-Checks 'Relative units are not treated as mWh' unknown -Contains 'relative capacity units' -Excludes '90% of design'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity[0].InstanceName = 'OTHER_PACK'
Add-BatteryChecks
Assert-Checks 'Unmatched instance data' unknown -Contains 'could not be matched'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity += $script:cimData.BatteryFullChargedCapacity[0]
Add-BatteryChecks
Assert-Checks 'Ambiguous full-charge records' unknown -Contains 'could not be matched'

Reset-Fixtures
$script:cimData.BatteryStaticData += $script:cimData.BatteryStaticData[0]
Add-BatteryChecks
Assert-Checks 'Duplicate design records cannot pass' 'unknown,unknown,unknown' -Contains 'could not be fully matched','could not be matched'

Reset-Fixtures
$script:cimData.BatteryFullChargedCapacity[0].Tag = 2
Add-BatteryChecks
Assert-Checks 'Battery replacement during collection' unknown -Contains 'battery changed'

Reset-Fixtures
$script:cimData.BatteryStaticData[0].Tag = $null
$script:cimData.BatteryFullChargedCapacity[0].Tag = $null
Add-BatteryChecks
Assert-Checks 'Matching instance without optional tags' pass -Contains '90% of design'

Reset-Fixtures
$script:cimData.Win32_Battery += [pscustomobject]@{ Name = 'Second battery' }
Add-BatteryChecks
Assert-Checks 'Missing capacity data for another battery' 'unknown,pass' -Contains 'could not be fully matched'

Reset-Fixtures
$script:cimData.Win32_Battery += [pscustomobject]@{ Name = 'Second battery' }
$script:cimData.BatteryStaticData = @(
    [pscustomobject]@{ Active=$true; InstanceName='PACK_B'; Tag=2; Capabilities=[uint32]2147483648; DesignedCapacity=60000 }
    $script:cimData.BatteryStaticData[0]
)
$script:cimData.BatteryFullChargedCapacity = @(
    $script:cimData.BatteryFullChargedCapacity[0]
    [pscustomobject]@{ Active=$true; InstanceName='PACK_B'; Tag=2; FullChargedCapacity=36000 }
)
Add-BatteryChecks
Assert-Checks 'Multiple batteries join by instance and preserve weak pack' 'pass,warning' -Contains 'Battery 1','Battery 2','90% of design','60% of design'
$firstPackId=$script:checks[0].id
$secondPackId=$script:checks[1].id
if (-not $firstPackId -or -not $secondPackId -or $firstPackId -eq $secondPackId) { throw 'Battery identifiers must be present and distinct.' }

$script:checks=@()
$script:cimData.BatteryStaticData=@($script:cimData.BatteryStaticData[1],$script:cimData.BatteryStaticData[0])
$script:cimData.BatteryFullChargedCapacity=@($script:cimData.BatteryFullChargedCapacity[1],$script:cimData.BatteryFullChargedCapacity[0])
Add-BatteryChecks
Assert-Checks 'Battery identifiers survive provider ordering changes' 'pass,warning'
if ($script:checks[0].id -ne $firstPackId -or $script:checks[1].id -ne $secondPackId) { throw 'Battery identifiers changed when provider ordering changed.' }

$script:checks=@()
$script:cimData.Win32_Battery=@([pscustomobject]@{Name='Remaining battery'})
$script:cimData.BatteryStaticData=@($script:cimData.BatteryStaticData | Where-Object InstanceName -eq 'PACK_B')
$script:cimData.BatteryFullChargedCapacity=@($script:cimData.BatteryFullChargedCapacity | Where-Object InstanceName -eq 'PACK_B')
Add-BatteryChecks
Assert-Checks 'Battery identifier survives another pack disappearing' warning -Contains 'Battery 1','60% of design'
if ($script:checks[0].id -ne $secondPackId) { throw 'Remaining battery identifier changed when another pack disappeared.' }

if ((Get-BatteryCheckId '  pack_b ') -ne $secondPackId) { throw 'Battery identifier normalization is not stable.' }
# Identifiers must stay the same as earlier versions (plain SHA-256 of the normalized name).
$sha = [Security.Cryptography.SHA256]::Create()
try { $expectedId = 'battery:' + ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('PACK_B')))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
if ($secondPackId -ne $expectedId) { throw 'Battery identifiers changed from the earlier SHA-256 form.' }
$script:passed++; Write-Host 'PASS Battery identifiers keep their earlier form'

# A refused hash (FIPS policy on older .NET, Constrained Language Mode) only drops the id.
function New-Object {
    param([Parameter(Position = 0)][string]$TypeName, [object[]]$ArgumentList)
    if ($TypeName -match 'Cryptography') { throw 'This implementation is not part of the Windows Platform FIPS validated cryptographic algorithms.' }
    Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}
try {
    if ($null -ne (Get-BatteryCheckId 'PACK_A')) { throw 'A failed hash must return no identifier.' }
    Reset-Fixtures
    Add-BatteryChecks
    Assert-Checks 'Battery check survives a refused hash' pass -Contains '90% of design' -Excludes 'FIPS'
    if ($script:checks[0].PSObject.Properties['id']) { throw 'A battery whose identifier could not be computed must omit check.id.' }
} finally { Remove-Item -Path Function:\New-Object }
Reset-Fixtures
$script:cimData.BatteryStaticData[0].InstanceName=''
Add-BatteryChecks
Assert-Checks 'Missing instance identifier is not hashed' unknown
if ($script:checks[0].PSObject.Properties['id']) { throw 'Missing instance identifier must omit check.id.' }

Reset-Fixtures
Add-StartupChecks
if ($script:checks[0].PSObject.Properties['id']) { throw 'Unspecified check IDs must remain absent for schema compatibility.' }
Assert-Checks 'Existing checks omit optional identifiers' info

Reset-Fixtures
Add-StartupChecks
Assert-Checks 'Empty startup inventory is informational' info -Contains '0 registered startup entry','does not establish whether entries are enabled'

Reset-Fixtures
$script:cimData.Win32_StartupCommand = @(
    [pscustomobject]@{ Name='Cloud Sync'; Location='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Command='PRIVATE_COMMAND'; User='PRIVATE_USERNAME'; UserSID='PRIVATE_SID' }
    [pscustomobject]@{ Name='Notes'; Location='HKU\PRIVATE_SID\Software\Microsoft\Windows\CurrentVersion\RunOnce' }
    [pscustomobject]@{ Name='Helper'; Location='Common Startup' }
)
Add-StartupChecks
Assert-Checks 'Startup names with coarse location labels' info -Contains 'Cloud Sync','Machine Run registry','User RunOnce registry','Shared startup folder' -Excludes 'HKLM','HKU'

Reset-Fixtures
$script:cimData.Win32_StartupCommand = @(
    [pscustomobject]@{ Name='C:\Users\PRIVATE_USERNAME\PRIVATE_COMMAND.exe'; Location='C:\Users\PRIVATE_LOCATION\Startup' }
    [pscustomobject]@{ Name='PRIVATE_USERNAME@example.com'; Location='PRIVATE_LOCATION' }
    [pscustomobject]@{ Name='powershell -File PRIVATE_COMMAND'; Location='Startup' }
    [pscustomobject]@{ Name="safe`nPRIVATE_COMMAND"; Location='Startup' }
)
Add-StartupChecks
Assert-Checks 'Sensitive and command-like names are omitted' info -Contains 'name omitted','Other startup location'

# Username redaction uses fixed account names, so the result does not depend on who runs the tests.
$realUserName = $env:USERNAME
try {
    $env:USERNAME = 'PRIVATE_USERNAME'
    Reset-Fixtures
    $script:cimData.Win32_StartupCommand = @([pscustomobject]@{ Name='private_username helper'; Location='Startup' })
    Add-StartupChecks
    Assert-Checks 'Current username is redacted from names' info -Contains '[user] helper'

    # A short account name must only match whole words.
    $env:USERNAME = 'ed'
    Reset-Fixtures
    $script:cimData.Win32_StartupCommand = @(
        [pscustomobject]@{ Name='Microsoft Edge Update'; Location='Startup' }
        [pscustomobject]@{ Name='SecurityHealth Shared'; Location='Startup' }
        [pscustomobject]@{ Name='ED-Sync'; Location='Startup' }
    )
    Add-StartupChecks
    Assert-Checks 'A short username does not mangle other names' info -Contains 'Microsoft Edge Update','SecurityHealth Shared','[user]-Sync' -Excludes '[user]ge','Shar[user]'

    # An administrator account used to elevate is redacted along with the signed-in user's name.
    $env:USERNAME = 'adminacct'
    $script:SessionUserName = 'PRIVATE_USERNAME'
    if ((Get-StartupDisplayName 'PRIVATE_USERNAME tools for adminacct') -ne '[user] tools for [user]') { throw 'Both the scanning and the signed-in account names must be redacted.' }
    $script:passed++; Write-Host 'PASS Signed-in and elevating account names are both redacted'
} finally { $env:USERNAME = $realUserName; $script:SessionUserName = '' }

# Startup-name option switches are detected under Turkish regional settings too (capital I).
$thread = [Threading.Thread]::CurrentThread
$cultureBefore = $thread.CurrentCulture
try {
    $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    if ((Get-StartupDisplayName 'tool -Install') -ne 'Startup entry (name omitted)') { throw 'Command-like startup names must be omitted under tr-TR.' }
} finally { $thread.CurrentCulture = $cultureBefore }
$script:passed++; Write-Host 'PASS Command-like names are omitted under Turkish regional settings'

# Raw startup objects carry the command line and user; they must never be bound as cmdlet input,
# which PowerShell module logging would record. Trace parameter binding to check.
Reset-Fixtures
$rawEntry = [pscustomobject]@{ Name='Cloud Sync'; Location='Startup'; Command='PRIVATE_COMMAND'; User='PRIVATE_USERNAME' }
$rawEntry | Add-Member -MemberType ScriptMethod -Name ToString -Value { 'Win32_StartupCommand (Command = "PRIVATE_COMMAND", User = "PRIVATE_USERNAME")' } -Force
$script:cimData.Win32_StartupCommand = @($rawEntry)
$tracePath = Join-Path ([IO.Path]::GetTempPath()) ('healthscan-trace-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    Trace-Command -Name ParameterBinding -FilePath $tracePath -Expression { Add-StartupChecks } | Out-Null
    $trace = [IO.File]::ReadAllText($tracePath)
    if (-not $trace.Contains('BIND')) { throw 'Parameter-binding trace captured nothing.' }
    if ($trace.Contains('PRIVATE_COMMAND')) { throw 'A raw startup entry was bound as cmdlet input, which module logging would record.' }
} finally { Remove-Item -LiteralPath $tracePath -ErrorAction SilentlyContinue }
Assert-Checks 'Raw startup entries are never bound as cmdlet input' info -Contains 'Cloud Sync'

Reset-Fixtures
$script:cimData.Win32_StartupCommand = @(1..20 | ForEach-Object { [pscustomobject]@{ Name=('App {0:d2}' -f $_); Location='Startup' } })
Add-StartupChecks
Assert-Checks 'Startup inventory has a bounded entry list' info -Contains '20 registered startup entry','8 more entries not shown','App 12' -Excludes 'App 13'

Reset-Fixtures
$script:cimData.Win32_StartupCommand = @([pscustomobject]@{ Name=('A'*100); Location='Startup' })
Add-StartupChecks
Assert-Checks 'Startup names have a bounded length' info -Contains (('A'*61)+'...') -Excludes ('A'*65)

Reset-Fixtures
$script:cimFailures = @('Win32_StartupCommand')
Add-StartupChecks
Assert-Checks 'Startup access failure is unknown without error-path leakage' unknown -Contains 'could not be read'

Write-Host "$script:passed battery and startup regression checks passed. No real health queries were run."
