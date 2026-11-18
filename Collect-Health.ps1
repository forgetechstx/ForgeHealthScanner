# Total Computer Health Scan | Windows PowerShell 5.1+
# Collects local status; no uploads or configuration changes.
#   (no switch)     save the report as a JSON file on the Desktop, to import by hand
#   -OpenDashboard  open the dashboard with the report loaded and write nothing to disk
#                   (used by Open-HealthScan.cmd)
#   -SaveReport     with -OpenDashboard: also keep the report in the reports\ folder
#   -QuickScan      also run a Microsoft Defender quick scan first and wait for it to finish
#                   (needs administrator; can take several minutes)
#   -EmitJson       return the report as one line of JSON and do nothing else
#                   (used by HealthScan.exe, which runs this script from inside itself)
param([switch]$QuickScan,[switch]$OpenDashboard,[switch]$SaveReport,[switch]$EmitJson)
# Version of this scan. Keep in step with index.html and build\HealthScan.cs; build\Build.ps1 checks.
$CollectorVersion='1.5.2'
$ErrorActionPreference = 'Stop'
$checks = @()
# Under Constrained Language Mode (application control on managed PCs) most .NET calls are refused.
# Every helper below has a path that works there, so the scan degrades check by check instead of stopping.
function Add-Check($name,$status,$detail,$action,$id) {
  $check=[ordered]@{name=[string]$name;status=[string]$status;detail=[string]$detail;action=[string]$action}
  if($id){ $check['id']=[string]$id }
  if($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'){ $script:checks += [pscustomobject]$check }
  else { $script:checks += New-Object PSObject -Property $check }
}

# --- Shared helpers ---
function Remove-UserNames($value) {
 # Whole-word, culture-independent match, so a short username cannot mangle unrelated words.
 $text=[string]$value
 foreach($user in @($env:USERNAME,$script:SessionUserName)){
  if($user){ $text=[regex]::Replace($text,'(?<![A-Za-z0-9])'+[regex]::Escape([string]$user)+'(?![A-Za-z0-9])','[user]','IgnoreCase, CultureInvariant') }
 }
 return $text
}
function Get-OneLineText($value,[int]$max=100) {
 # One line, bounded.
 $text=(([string]$value) -replace '[\x00-\x1f\x7f]+',' ').Trim()
 if($text.Length -gt $max){ $text=$text.Substring(0,$max-3)+'...' }
 return $text
}
function Get-SafeText($value,[int]$max=100) {
 # Names reported by drivers, other software or Windows Update: one line, bounded, username removed.
 return (Get-OneLineText (Remove-UserNames $value) $max)
}
function Get-Round([double]$value,[int]$digits=0) {
 # [math] is not available under Constrained Language Mode; integer conversion rounds the same way.
 $scale=1; for($i=0;$i -lt $digits;$i++){ $scale*=10 }
 return [int64]($value*$scale)/$scale
}
function Get-Floor([double]$value) {
 $whole=[int64]$value
 if($whole -gt $value){ $whole-- }
 return $whole
}
function Format-Date($date,[string]$format) {
 # Gregorian digits and ':' on every regional setting (a Thai calendar would otherwise print 2569).
 return $date.ToString($format,[Globalization.CultureInfo]::InvariantCulture)
}
function Test-AccessDenied($err) {
 # True when Windows refused the request for lack of rights (E_ACCESSDENIED, 0x80070005).
 if(-not $err){ return $false }
 if("$($err.CategoryInfo.Category)" -eq 'PermissionDenied' -or "$($err.FullyQualifiedErrorId)" -match '0x80070005'){ return $true }
 try {
  $ex=$err.Exception
  while($ex){
   if($ex -is [UnauthorizedAccessException] -or $ex.HResult -eq -2147024891 -or "$($ex.StatusCode)" -eq 'AccessDenied' -or "$($ex.Message)" -match '0x80070005'){ return $true }
   $ex=$ex.InnerException
  }
 } catch { }
 return $false
}
function Get-FailureNote($err) {
 if("$($err.FullyQualifiedErrorId)" -match '^HealthScanStepTimeout' -or "$($err.CategoryInfo.Category)" -eq 'OperationTimeout'){
  return ' Windows did not answer within the time limit, so this part of the scan was skipped.'
 }
 return ''
}
# A Windows query that hangs (a busy update service, a sleeping drive, a stuck WMI provider) would
# otherwise stall the whole scan. Each such query runs in a second runspace inside this same process
# and is left behind after $Seconds; the user is told which step is slow. Constrained Language Mode
# allows no second runspace, so there the query runs inline without a limit.
$script:StepRunspace=$null
# Set once a step is left behind: its thread keeps running until Windows answers.
$script:StepAbandoned=$false
function Exit-Collector([int]$Code) {
 # A left-behind step's thread keeps powershell.exe, and so the console window and Open-HealthScan.cmd
 # waiting on it, open until the stuck Windows call returns, which may be never. Once the report has
 # been handed over there is nothing left to wait for, so the process is ended outright.
 # Never under -EmitJson: there this script runs inside HealthScan.exe, which must keep running.
 if($EmitJson -or -not $script:StepAbandoned){ return }
 if($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'){ [Environment]::Exit($Code) }
 exit $Code
}
# A scan that stops on an error after a step was left behind must not hang either.
trap { if(-not $EmitJson -and $script:StepAbandoned){ Write-Host ($_ | Out-String); Exit-Collector 1 }; break }
function Invoke-Bounded([string]$Step,[int]$Seconds,[scriptblock]$Script,[object[]]$ArgumentList=@()) {
 if($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'){ return (& $Script @ArgumentList) }
 if(-not $script:StepRunspace){
  $rs=[runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
  # Same threading model as powershell.exe, which the COM objects used here expect.
  $rs.ApartmentState=[Threading.ApartmentState]::STA
  $rs.ThreadOptions=[Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
  $rs.Open()
  $rs.SessionStateProxy.SetVariable('ErrorActionPreference','Stop')
  $script:StepRunspace=$rs
 }
 $ps=[powershell]::Create()
 $ps.Runspace=$script:StepRunspace
 [void]$ps.AddScript($Script.ToString())
 foreach($argument in $ArgumentList){ [void]$ps.AddArgument($argument) }
 $async=$null
 try {
  $async=$ps.BeginInvoke()
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $noted=$false
  while(-not $async.AsyncWaitHandle.WaitOne(250)){
   if(-not $noted -and $clock.Elapsed.TotalSeconds -ge 10){
    Write-Host "  Still waiting for Windows to answer: $Step. This step is skipped after $Seconds seconds."
    $noted=$true
   }
   if($clock.Elapsed.TotalSeconds -ge $Seconds){
    Write-Host "  Skipped: $Step (Windows did not answer within $Seconds seconds)."
    Write-Error -Message "Step timed out: $Step" -Category OperationTimeout -ErrorId 'HealthScanStepTimeout' -ErrorAction Stop
   }
  }
  foreach($item in $ps.EndInvoke($async)){
   if($null -eq $item){ continue }
   $base=$item.psobject.BaseObject
   if($base -is [Management.Automation.PSCustomObject]){ $item } else { $base }
  }
 } finally {
  if($async -and -not $async.IsCompleted){
   # A call stuck inside Windows may never return: ask it to stop, do not wait, and use a fresh runspace next time.
   $script:StepRunspace=$null
   $script:StepAbandoned=$true
   try { [void]$ps.BeginStop($null,$null) } catch { }
  } else { $ps.Dispose() }
 }
}
# A 32-bit PowerShell sees a redirected copy of HKLM\SOFTWARE (WOW6432Node) with different
# values, so machine settings are read through the 64-bit view whenever .NET calls are allowed.
function Get-MachineRegistryValues($path) {
 if($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'){ return Get-ItemProperty -Path $path -ErrorAction Stop }
 $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
 try {
  $key=$base.OpenSubKey(([string]$path -replace '^HKLM:\\',''))
  if(-not $key){ throw 'Registry key not found.' }
  try {
   $values=[ordered]@{}
   foreach($valueName in $key.GetValueNames()){ if($valueName){ $values[$valueName]=$key.GetValue($valueName) } }
   return [pscustomobject]$values
  } finally { $key.Close() }
 } finally { $base.Close() }
}
function Test-MachineRegistryKey($path) {
 if($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'){ return [bool](Test-Path -Path $path) }
 $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
 try {
  $key=$base.OpenSubKey(([string]$path -replace '^HKLM:\\',''))
  if($key){ $key.Close(); return $true }
  return $false
 } finally { $base.Close() }
}

# --- Who is running the scan ---
function Test-Elevated {
 try {
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 } catch {
  # Constrained Language Mode refuses the .NET check; the integrity level whoami lists says the same.
  # When neither answers, assume elevated, which only means no browser is started from here.
  try { return [bool](@(& "$env:SystemRoot\System32\whoami.exe" /groups) -match 'S-1-16-(12288|16384)') } catch { return $true }
 }
}
function Get-SignedInUserName {
 # The account signed in at the console; empty when Windows does not say (for example over Remote Desktop).
 try {
  $name=[string](Get-CimInstance -ClassName Win32_ComputerSystem -Property UserName -OperationTimeoutSec 10 -ErrorAction Stop).UserName
  if($name -match '\\([^\\]+)$'){ return $Matches[1] }
  return $name
 } catch { return '' }
}
$IsElevated=Test-Elevated
$script:SessionUserName=''
if($IsElevated){
 $signedIn=Get-SignedInUserName
 if($signedIn -and $env:USERNAME -and -not [string]::Equals($signedIn,[string]$env:USERNAME,[StringComparison]::OrdinalIgnoreCase)){
  # Elevating with another administrator's credentials runs the whole scan as that account.
  $script:SessionUserName=$signedIn
  Write-Host 'Note: this scan is running as a different account from the one signed in to Windows (the administrator account used to elevate).'
  Write-Host '      Per-user results, such as startup apps, describe that account, and no report is saved to that account''s Desktop.'
 }
}

# --- Memory and uptime ---
function Add-MemoryChecks {
 try {
  $os=Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 30 -ErrorAction Stop
  $free=Get-Round (100*$os.FreePhysicalMemory/$os.TotalVisibleMemorySize)
  Add-Check 'Memory availability' $(if($free -lt 10){'warning'}else{'pass'}) "$free% RAM available at collection time" 'Review memory-heavy applications in Task Manager.'
  $days=Get-Round ((Get-Date)-$os.LastBootUpTime).TotalDays 1
  # With Fast Startup (the Windows default) Shut down does not restart Windows; only Restart does.
  $fastStartup=$false
  try { $fastStartup=([string](Get-MachineRegistryValues 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled -eq '1') } catch { }
  if($days -lt 0){
   Add-Check 'System uptime' 'unknown' 'Windows reported a start time in the future, so the time since the last restart could not be worked out. The clock may have been changed.' 'Check the date and time in Settings, then restart the computer.'
  } elseif($days -gt 14){
   $detail="$days days since restart."
   $action='Save your work and choose Restart from the Start menu.'
   if($fastStartup){
    $detail+=' Fast Startup is on, so Shut down does not reset this; only Restart does.'
    $action+=' Shut down does not count as a restart while Fast Startup is on.'
   }
   Add-Check 'System uptime' 'warning' $detail $action
  } else {
   Add-Check 'System uptime' 'pass' "$days days since restart" $(if($fastStartup){'No action needed. Shut down does not count as a restart while Fast Startup is on; choose Restart from the Start menu when Windows asks.'}else{'No action needed. Restart when Windows asks.'})
  }
  return $os
 } catch { Add-Check 'System information' 'unknown' ('Windows did not return memory and uptime information.'+(Get-FailureNote $_)) 'Run on Windows with CIM available.' }
}
Write-Host 'Checking memory and uptime...'
$os=Add-MemoryChecks

# --- Disk space ---
function Add-DiskSpaceChecks {
 try {
  $volumes=@(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 30 -ErrorAction Stop)
  foreach($ld in $volumes){
   $name="Disk space $(Get-SafeText $ld.DeviceID 16)"
   if($ld.Size -gt 0){
    $pct=Get-Round (100*$ld.FreeSpace/$ld.Size)
    $freeGB=Get-Round ($ld.FreeSpace/1GB) 1
    $isSystem=[string]::Equals([string]$ld.DeviceID,[string]$env:SystemDrive,[StringComparison]::OrdinalIgnoreCase)
    # A low percentage alone is not a problem on a large drive, but the Windows drive needs room for updates.
    $low=($pct -lt 15 -and $ld.FreeSpace -lt 50GB) -or ($isSystem -and $ld.FreeSpace -lt 10GB)
    $detail="$pct% free; $freeGB GB available"
    if($low -and $isSystem){ $detail+='. Windows needs free space on this drive to install updates.' }
    Add-Check $name $(if($low){'warning'}else{'pass'}) $detail 'Review Storage settings and remove unneeded files.'
   } else {
    Add-Check $name 'unknown' 'Windows could not read the size of this drive. It may be locked by BitLocker or not ready.' 'Open File Explorer to check this drive.'
   }
  }
  if(-not $volumes.Count){ Add-Check 'Disk space' 'unknown' 'Windows did not list any fixed drives.' 'Check disk space in File Explorer.' }
 } catch { Add-Check 'Disk space' 'unknown' ('Windows did not return disk space information.'+(Get-FailureNote $_)) 'Check disk space in File Explorer.' }
}
Write-Host 'Checking disk space...'
Add-DiskSpaceChecks

# --- Physical drive health ---
# Health and operational status are what Windows itself reports for each drive (it folds in
# the drive's SMART failure prediction). Wear and temperature need administrator and are
# added to the detail only when they can be read.
function Add-DriveHealthChecks {
 $driveAction='Back up important files now, then check the drive with its manufacturer''s diagnostic tool.'
 try {
  # DeviceId is a string; sort numerically so Disk 10 does not come before Disk 2.
  # The Storage module's names for status codes exist only in the step's runspace, so text is made there.
  $pds=@(Invoke-Bounded 'reading drive health' 60 {
    foreach($d in @(Get-PhysicalDisk -ErrorAction Stop)){
     New-Object PSObject -Property @{Disk=$d;DeviceId="$($d.DeviceId)";FriendlyName="$($d.FriendlyName)";HealthStatus="$($d.HealthStatus)";OperationalStatus=@(foreach($s in @($d.OperationalStatus)){ "$s" });MediaType="$($d.MediaType)";BusType="$($d.BusType)";Size=$d.Size}
    }
   } |
    Sort-Object @{Expression={ $n="$($_.DeviceId)" -as [int]; if($null -ne $n){$n}else{[int]::MaxValue} }}, FriendlyName)
  if(-not $pds.Count){ throw 'No physical drives.' }
  $readCounters=$true
  foreach($pd in $pds){
   $health="$($pd.HealthStatus)"
   $op=(@($pd.OperationalStatus) | ForEach-Object { "$_" }) -join ', '
   $detail="Windows reports health: $health; status: $op. $($pd.MediaType), $(Get-Round ($pd.Size/1GB)) GB."
   $status=if($health -eq 'Healthy' -and $op -eq 'OK'){'pass'}elseif((-not $health) -or $health -eq 'Unknown'){'unknown'}else{'warning'}
   if($readCounters){
    try {
     $rc=Invoke-Bounded 'reading drive wear and temperature' 20 { param($disk) $c=$disk | Get-StorageReliabilityCounter -ErrorAction Stop; New-Object PSObject -Property @{Wear=$c.Wear;Temperature=$c.Temperature} } @($pd.Disk) | Select-Object -First 1
     # Drives that do not expose wear (hard disks, many SATA/USB devices) report 0, so a zero is only trusted on NVMe.
     if($null -ne $rc.Wear -and ($rc.Wear -gt 0 -or "$($pd.BusType)" -eq 'NVMe')){
      $detail+=" Wear: $($rc.Wear)% of rated life used."
      if($rc.Wear -ge 90 -and $status -eq 'pass'){ $status='warning' }
     }
     if($rc.Temperature -gt 0){ $detail+=" Temperature: $($rc.Temperature) C." }
    } catch { if(Get-FailureNote $_){ $readCounters=$false } }
   }
   $act=if($status -eq 'pass'){'No action needed. Keep regular backups; drives can fail without warning.'}elseif($status -eq 'unknown'){'Windows could not determine this drive''s health. Check it in Disk Management (right-click Start) or with the manufacturer''s diagnostic tool, and keep regular backups.'}else{$driveAction}
   Add-Check "Drive health: Disk $(Get-SafeText $pd.DeviceId 8) ($(Get-SafeText $pd.FriendlyName 64))" $status $detail $act
  }
 } catch { Add-Check 'Drive health' 'unknown' ('Windows did not return drive health information.'+(Get-FailureNote $_)) 'Right-click Start and open Disk Management to check drive status.' }
}
Write-Host 'Checking drive health...'
Add-DriveHealthChecks

# --- Antivirus ---
function Add-AntivirusChecks([bool]$RunQuickScan) {
 # The optional scan has its own try block so a failed scan request does not hide the
 # protection and signature checks below. Its result is reported once Defender's state is known.
 $scanFailure=$null
 if($RunQuickScan){
  # Start-MpScan returns only when the scan is over.
  Write-Host 'Running a Microsoft Defender quick scan first. This can take several minutes; leave this window open until it finishes...'
  try { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
  catch { $scanFailure=$_ }
 }
 # Third-party antivirus registered with Windows Security Center (client editions only; Windows
 # Server has no Security Center, so there other products cannot be seen).
 # productState state nibble (mask 0xF000): 0x1000 = on; 0x0000 off, 0x2000 snoozed, 0x3000 expired.
 # Low byte: 0x00 definitions up to date, 0x10 out of date.
 # Microsoft Defender's own entry is excluded by its fixed instanceGuid, with an anchored
 # name check as a backstop (a plain 'Defender' match would also exclude Bitdefender).
 $otherAv=@(); $staleAv=@(); $securityCenter=$false
 try {
  $names=@(); $staleNames=@()
  foreach($av in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -OperationTimeoutSec 30 -ErrorAction Stop)){
   if($av.instanceGuid -ne '{D68DDC3A-831F-4fae-9E44-DA132C1ACF46}' -and $av.displayName -notmatch '^(Windows|Microsoft) Defender' -and (($av.productState -band 0xF000) -eq 0x1000)){
    $name=Get-SafeText $av.displayName 64
    if($name){
     $names+=$name
     if(($av.productState -band 0xFF) -eq 0x10){ $staleNames+=$name }
    }
   }
  }
  $otherAv=@($names | Sort-Object -Unique)
  $staleAv=@($staleNames | Sort-Object -Unique)
  $securityCenter=$true
 } catch { $otherAv=@(); $staleAv=@() }
 $otherAvNames=$otherAv -join ', '
 # Every enabled third-party product says its definitions are out of date.
 $otherAvStale=($otherAv.Count -gt 0 -and $staleAv.Count -eq $otherAv.Count)
 $noSecurityCenterNote='Windows Security Center did not answer (it is not part of Windows Server), so other antivirus products could not be checked.'
 $d=$null; $statusFailure=$null
 try {
  $d=Invoke-Bounded 'reading Microsoft Defender status' 45 {
   $s=Get-MpComputerStatus -ErrorAction Stop
   New-Object PSObject -Property @{RealTimeProtectionEnabled=$s.RealTimeProtectionEnabled;AntivirusEnabled=$s.AntivirusEnabled;AntivirusSignatureAge=$s.AntivirusSignatureAge;QuickScanEndTime=$s.QuickScanEndTime}
  } | Select-Object -First 1
  if(-not $d){ throw 'No Defender status.' }
 } catch { $d=$null; $statusFailure=$_ }
 if($scanFailure){
  if($d -and -not $d.AntivirusEnabled -and $otherAv.Count){
   Add-Check 'Defender quick scan request' 'info' "The quick scan could not be started. Microsoft Defender is not the active antivirus; scans are handled by $otherAvNames." "Run a scan from $otherAvNames."
  } elseif((Test-AccessDenied $scanFailure) -or -not $script:IsElevated){
   Add-Check 'Defender quick scan request' 'unknown' 'The quick scan could not be started.' 'Running a quick scan needs administrator rights. Run this scan again with -QuickScan from an administrator Command Prompt or PowerShell.'
  } else {
   Add-Check 'Defender quick scan request' 'unknown' 'The quick scan could not be started. Another scan may already be running, or Microsoft Defender may be turned off.' 'Open Windows Security, check Virus & threat protection, and start a quick scan from there.'
  }
 }
 if($d){
  if($d.RealTimeProtectionEnabled){
   Add-Check 'Real-time antivirus protection' 'pass' 'Microsoft Defender real-time protection is enabled.' 'Continue monitoring Windows Security.'
  } elseif($otherAv.Count){
   Add-Check 'Real-time antivirus protection' 'pass' "Microsoft Defender real-time protection is off, and Windows Security Center reports this antivirus as enabled: $otherAvNames." "Confirm $otherAvNames is running and up to date."
  } elseif(-not $securityCenter){
   Add-Check 'Real-time antivirus protection' 'unknown' "Microsoft Defender real-time protection is off. $noSecurityCenterNote" 'Confirm that another antivirus is installed and running, or turn on real-time protection in Windows Security.'
  } else {
   Add-Check 'Real-time antivirus protection' 'warning' 'Microsoft Defender real-time protection is off and no other enabled antivirus was reported by Windows Security Center.' 'Review Windows Security and your installed antivirus.'
  }
  if($d.AntivirusEnabled){
   $age=$d.AntivirusSignatureAge
   if($age -ge 65535){
    # Sentinel value: Defender has never completed a definition update.
    Add-Check 'Defender signatures' 'warning' 'Microsoft Defender reports that its definitions have never been updated.' 'Update protection definitions in Windows Security.'
   } else {
    Add-Check 'Defender signatures' $(if($age -le 2){'pass'}else{'warning'}) "Signature age: $age days" 'Update protection definitions in Windows Security.'
   }
  } elseif($otherAvStale){
   Add-Check 'Defender signatures' 'warning' "Microsoft Defender is not the active antivirus, and Windows Security Center reports that the definitions of $otherAvNames are out of date." "Update $otherAvNames, and check that its subscription is still active."
  } elseif($otherAv.Count){
   Add-Check 'Defender signatures' 'info' "Microsoft Defender is not the active antivirus; definitions are managed by $otherAvNames." "Check for updates in $otherAvNames."
  } elseif(-not $securityCenter){
   Add-Check 'Defender signatures' 'unknown' "Microsoft Defender antivirus is not enabled, so its definitions are not being used. $noSecurityCenterNote" 'Check that your installed antivirus is up to date.'
  } else {
   Add-Check 'Defender signatures' 'warning' 'Microsoft Defender antivirus is not enabled, so its definitions are not being used.' 'Review Windows Security and your installed antivirus.'
  }
  $qs=$d.QuickScanEndTime
  if($qs -is [datetime] -and $qs.Year -gt 2000){
   Add-Check 'Defender quick scan' 'info' "Last completed quick scan: $(Format-Date $qs 'yyyy-MM-dd HH:mm')" 'Review Protection history. A completed scan does not guarantee a clean computer.'
  } elseif((-not $d.AntivirusEnabled) -and $otherAv.Count){
   Add-Check 'Defender quick scan' 'info' "Microsoft Defender is not the active antivirus; scans are handled by $otherAvNames." "Review scan history in $otherAvNames."
  } else {
   Add-Check 'Defender quick scan' 'unknown' 'No completed Microsoft Defender quick scan is recorded.' 'Run a quick scan from Windows Security.'
  }
 } else {
  if($otherAv.Count){
   Add-Check 'Real-time antivirus protection' 'pass' "Microsoft Defender status is unavailable, and Windows Security Center reports this antivirus as enabled: $otherAvNames." "Confirm $otherAvNames is running and up to date."
   if($otherAvStale){
    Add-Check 'Defender signatures' 'warning' "Windows Security Center reports that the definitions of $otherAvNames are out of date." "Update $otherAvNames, and check that its subscription is still active."
   }
  } else {
   Add-Check 'Microsoft Defender' 'unknown' ('Microsoft Defender status could not be read.'+(Get-FailureNote $statusFailure)) 'Open Windows Security and review Virus & threat protection.'
  }
 }
 try {
  $active=[int](Invoke-Bounded 'reading Microsoft Defender detections' 45 { @(Get-MpThreat -ErrorAction Stop | Where-Object IsActive).Count } | Select-Object -First 1)
  if($active -gt 0){
   Add-Check 'Active Defender detections' 'warning' "$active active detections reported by Defender" 'Review Protection history and follow antivirus remediation guidance.'
  } elseif($d -and -not ($d.AntivirusEnabled -and $d.RealTimeProtectionEnabled)){
   # Defender still answers in passive mode or with real-time protection off, but its empty list then says little.
   if($otherAv.Count){
    Add-Check 'Active Defender detections' 'info' "Microsoft Defender reports 0 active detections, but it is not the active antivirus. Threat history is kept by $otherAvNames." "Review threat history in $otherAvNames."
   } else {
    Add-Check 'Active Defender detections' 'info' 'Microsoft Defender reports 0 active detections, but it is not providing real-time protection, so this list may not reflect current threats.' 'Review your antivirus threat history.'
   }
  } else {
   Add-Check 'Active Defender detections' 'pass' "$active active detections reported by Defender" 'Review Protection history and follow antivirus remediation guidance.'
  }
 } catch {
  if($otherAv.Count){
   Add-Check 'Active Defender detections' 'info' "Microsoft Defender is not the active antivirus, so its detection list is unavailable. Threat history is kept by $otherAvNames." "Review threat history in $otherAvNames."
  } else {
   Add-Check 'Active Defender detections' 'unknown' ('Microsoft Defender''s detection list could not be read.'+(Get-FailureNote $_)) 'Review your antivirus threat history.'
  }
 }
}
Write-Host 'Checking antivirus...'
Add-AntivirusChecks $QuickScan

# --- Firewall ---
function Add-FirewallCheck {
 try {
  $fw=Invoke-Bounded 'reading Windows Firewall settings' 30 {
   # ActiveStore is the effective state after Group Policy / MDM; the default store is only the local setting.
   $profiles=$null
   try { $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop) } catch { $profiles=@(Get-NetFirewallProfile -ErrorAction Stop) }
   New-Object PSObject -Property @{
    ProfileCount=@($profiles | Where-Object { $_ }).Count
    Off=@(foreach($p in $profiles){ if($p -and -not $p.Enabled){ [string]$p.Name } })
    # An enabled profile that allows unsolicited inbound connections by default filters nothing coming in.
    AllowInbound=@(foreach($p in $profiles){ if($p -and $p.Enabled -and "$($p.DefaultInboundAction)" -eq 'Allow'){ [string]$p.Name } })
   }
  } | Select-Object -First 1
  if(-not $fw){ throw 'No firewall result.' }
  if(-not $fw.ProfileCount){
   Add-Check 'Windows Firewall profiles' 'unknown' 'Windows did not return any Windows Firewall profiles, so the firewall state could not be read.' 'Review Windows Security firewall settings.'
   return
  }
  $action='Review firewall settings and any managed security policy.'
  $off=@($fw.Off | Where-Object { $_ } | ForEach-Object { Get-SafeText $_ 32 })
  $open=@($fw.AllowInbound | Where-Object { $_ } | ForEach-Object { Get-SafeText $_ 32 })
  $parts=@()
  if($off.Count){ $parts+='Disabled: '+($off -join ', ')+'.' }
  if($open.Count){ $parts+='Enabled but allowing all inbound connections by default: '+($open -join ', ')+'.' }
  if(-not $parts.Count){
   Add-Check 'Windows Firewall profiles' 'pass' 'All Windows Firewall profiles enabled and blocking unrequested inbound connections by default.' $action
   return
  }
  $status='warning'
  if($off.Count -and -not $open.Count){
   # A security suite that brings its own firewall usually turns the Windows Firewall profiles off.
   $otherFw=@(); $securityCenter=$false
   try {
    $names=@()
    foreach($product in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -OperationTimeoutSec 30 -ErrorAction Stop)){
     if((($product.productState -band 0xF000) -eq 0x1000)){
      $name=Get-SafeText $product.displayName 64
      if($name){ $names+=$name }
     }
    }
    $otherFw=@($names | Sort-Object -Unique)
    $securityCenter=$true
   } catch { }
   if($otherFw.Count){
    $status='pass'
    $parts+="Windows Security Center reports this firewall as enabled: $($otherFw -join ', ')."
    $action="Confirm $($otherFw -join ', ') is running."
   } elseif(-not $securityCenter){
    $parts+='Windows Security Center did not answer, so other firewall products could not be checked.'
   }
  }
  Add-Check 'Windows Firewall profiles' $status ($parts -join ' ') $action
 } catch { Add-Check 'Windows Firewall profiles' 'unknown' ('Windows Firewall settings could not be read.'+(Get-FailureNote $_)) 'Review Windows Security firewall settings.' }
}
Write-Host 'Checking firewall...'
Add-FirewallCheck

# --- Windows Update ---
# Everything here is read from this computer: the registry, installed-update records and
# Windows Update's cached results. No online update search is started (Online = $false).
function ConvertFrom-WuDate($d){
 # Windows Update COM dates are UTC; a never-happened date comes back as 1899.
 if($d -is [datetime] -and $d.Year -gt 2000){ [datetime]::SpecifyKind($d,[DateTimeKind]::Utc).ToLocalTime() }
}
function Get-UpdatePauseEnd {
 # A pause set in Settings. Windows leaves old values behind after a pause ends, so only a future expiry counts.
 $pausedUntil=$null
 try {
  $ux=Get-MachineRegistryValues 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
  foreach($n in 'PauseUpdatesExpiryTime','PauseQualityUpdatesEndTime','PauseFeatureUpdatesEndTime'){
   $s=([string]$ux.$n).Trim()
   if(-not $s){ continue }
   $t=$null
   if($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'){
    $parsed=[datetime]::MinValue
    if([datetime]::TryParse($s,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal',[ref]$parsed)){ $t=$parsed.ToLocalTime() }
   } else {
    # Constrained Language Mode refuses TryParse. A [datetime] conversion is allowed and also uses the
    # invariant culture, but reads a time without a zone as local time, so such a time is marked UTC first.
    if(-not ($s -match '(?i)\dZ$' -or $s -match ':\d{2}(\.\d+)?\s*[+-]\d{2}(:?\d{2})?$')){ $s+='Z' }
    try { $t=([datetime]$s).ToLocalTime() } catch { $t=$null }
   }
   if($t -and $t -gt (Get-Date) -and ((-not $pausedUntil) -or $t -gt $pausedUntil)){ $pausedUntil=$t }
  }
 } catch { }
 return $pausedUntil
}
function Add-RestartPendingCheck {
 try {
  $reasons=@()
  if(Test-MachineRegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){ $reasons+='Windows Update' }
  if(Test-MachineRegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){ $reasons+='Windows component servicing' }
  try {
   $wuRestart=Invoke-Bounded 'asking Windows Update whether a restart is needed' 20 { [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired } | Select-Object -First 1
   if($wuRestart -eq $true -and ($reasons -notcontains 'Windows Update')){ $reasons+='Windows Update' }
  } catch { }
  if($reasons.Count){
   Add-Check 'Restart pending' 'warning' "A restart is needed to finish installing updates ($($reasons -join ', '))." 'Save your work and restart the computer.'
  } else {
   Add-Check 'Restart pending' 'pass' 'No restart is waiting to finish an update.' 'No action needed.'
  }
 } catch { Add-Check 'Restart pending' 'unknown' ('Windows did not say whether a restart is waiting.'+(Get-FailureNote $_)) 'Check Windows Update in Settings for a restart prompt.' }
}
function Add-UpdateRecencyCheck($pausedUntil) {
 # Returns the last successful update check (or nothing), which the pending-updates check needs.
 $lastCheck=$null
 # Tells the pending-updates check that the check time is unknown, not missing.
 $script:UpdateCheckUnreadable=$false
 try {
  $parts=@(); $wuStatus='pass'; $staleInstall=$false; $staleCheck=$false; $checkUnreadable=$false
  try {
   $hf=Invoke-Bounded 'reading installed Windows updates' 60 {
    $latest=Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn -is [datetime] } | Sort-Object InstalledOn | Select-Object -Last 1
    if($latest){ New-Object PSObject -Property @{HotFixID=[string]$latest.HotFixID;InstalledOn=$latest.InstalledOn} }
   } | Select-Object -First 1
   if($hf -and $hf.InstalledOn -is [datetime]){
    $hfAge=Get-Floor ((Get-Date)-$hf.InstalledOn).TotalDays
    if($hfAge -lt 0){ $hfAge=0 }
    $parts+="Latest installed Windows update: $(Get-SafeText $hf.HotFixID 32) on $(Format-Date $hf.InstalledOn 'yyyy-MM-dd') ($hfAge days ago)."
    if($hfAge -gt 45){ $wuStatus='warning'; $staleInstall=$true }
   }
  } catch { }
  try {
   $lastSearch=Invoke-Bounded 'reading Windows Update history' 30 { (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastSearchSuccessDate } | Select-Object -First 1
   $lastCheck=ConvertFrom-WuDate $lastSearch
   if($lastCheck){
    $checkAge=Get-Floor ((Get-Date)-$lastCheck).TotalDays
    if($checkAge -lt 0){ $checkAge=0 }
    $parts+="Last successful check for updates: $(Format-Date $lastCheck 'yyyy-MM-dd HH:mm') ($checkAge days ago)."
    if($checkAge -gt 14){ $wuStatus='warning'; $staleCheck=$true }
   } else {
    $parts+='Windows has no successful check for updates on record.'
    $wuStatus='warning'; $staleCheck=$true
   }
  } catch { $checkUnreadable=$true; $script:UpdateCheckUnreadable=$true }
  if($parts.Count){
   if($checkUnreadable){ $parts+='The time of the last check for updates could not be read.' }
   $wuAction='No action needed.'
   if($staleCheck -or ($checkUnreadable -and $staleInstall)){ $wuAction='Open Windows Update in Settings and select Check for updates.' }
   elseif($staleInstall){
    # Checking works but nothing has been installed: paused or deferred updates, or a Windows version that is out of support.
    $parts+='Windows is checking for updates, but none has been installed recently.'
    $wuAction='Open Windows Update in Settings and select Check for updates. If nothing is offered, check whether this version of Windows is still supported.'
   }
   if($pausedUntil){
    $parts+="Windows updates are paused until $(Format-Date $pausedUntil 'yyyy-MM-dd')."
    $wuStatus='warning'
    $wuAction='Open Windows Update in Settings and select Resume updates when you are ready.'
   }
   Add-Check 'Windows Update recency' $wuStatus ($parts -join ' ') $wuAction
  } else {
   Add-Check 'Windows Update recency' 'unknown' 'Update history could not be read on this computer.' 'Open Windows Update in Settings to review update history.'
  }
 } catch { Add-Check 'Windows Update recency' 'unknown' ('Update history could not be read on this computer.'+(Get-FailureNote $_)) 'Open Windows Update in Settings to review update history.' }
 return $lastCheck
}
function Add-PendingUpdatesCheck($lastCheck,$pausedUntil,[bool]$checkUnreadable=$false) {
 try {
  # The COM objects stay inside the step; only plain values come back.
  $found=Invoke-Bounded 'reading Windows Update''s saved results' 120 {
   $searcher=(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
   $searcher.Online=$false
   $result=$searcher.Search('IsInstalled=0 and IsHidden=0 and BrowseOnly=0')
   $updates=@(foreach($u in $result.Updates){
    New-Object PSObject -Property @{Title=[string]$u.Title;RebootRequired=($u.RebootRequired -eq $true);CategoryIDs=@(foreach($c in $u.Categories){ [string]$c.CategoryID })}
   })
   New-Object PSObject -Property @{ResultCode=[int]$result.ResultCode;WarningCount=[int]@($result.Warnings).Count;Updates=$updates}
  } | Select-Object -First 1
  if(-not $found){ throw 'No update search result.' }
  # A successful COM call can still return partial results. Only orcSucceeded (2)
  # without warnings can establish that no other cached updates are waiting.
  $searchComplete=($found.ResultCode -eq 2 -and $found.WarningCount -eq 0)
  $incompleteDetail='Windows Update did not return a complete set of saved results, so other updates may be missing. No online check was made by this scan.'
  # Antivirus definition updates arrive several times a day and are covered by the signature check.
  $definitionCategory='E0789628-CE08-4437-BE74-2495B842F43B'
  $candidates=@($found.Updates | Where-Object { $_ -and @($_.CategoryIDs) -notcontains $definitionCategory })
  # Updates that are installed but waiting for a restart still report IsInstalled=0; the Restart pending check covers them.
  $awaitingRestart=@($candidates | Where-Object { $_.RebootRequired -eq $true })
  $pending=@($candidates | Where-Object { $_.RebootRequired -ne $true })
  if($pending.Count){
   # One update per line; the dashboard keeps the line breaks.
   $titles=@($pending | Select-Object -First 5 | ForEach-Object { "- $(Get-SafeText $_.Title 160)" }) -join "`n"
   if($pending.Count -gt 5){ $titles+="`n- and $($pending.Count-5) more" }
   $detail="$($pending.Count) update(s) waiting to install as of Windows' last update check:`n$titles"
   $action='Open Windows Update in Settings and install the available updates.'
   if(-not $searchComplete){
    $detail+="`n$incompleteDetail"
    $action='Open Windows Update in Settings, select Check for updates, and install the available updates.'
   }
   Add-Check 'Pending Windows updates' 'warning' $detail $action
  } elseif($awaitingRestart.Count){
   if($searchComplete){
    Add-Check 'Pending Windows updates' 'info' "$($awaitingRestart.Count) update(s) are installed and only need a restart to finish. No other updates were waiting as of Windows' last update check." 'Save your work and restart the computer.'
   } else {
    Add-Check 'Pending Windows updates' 'warning' "$($awaitingRestart.Count) update(s) need a restart to finish. $incompleteDetail" 'Save your work and restart the computer, then open Windows Update in Settings and select Check for updates.'
   }
  } elseif(-not $searchComplete){
   Add-Check 'Pending Windows updates' 'unknown' $incompleteDetail 'Open Windows Update in Settings and select Check for updates.'
  } elseif($checkUnreadable -and -not $lastCheck){
   Add-Check 'Pending Windows updates' 'unknown' 'The time of Windows'' last update check could not be read, so its saved results cannot show whether updates are waiting. No online check was made by this scan.' 'Open Windows Update in Settings and select Check for updates.'
  } elseif(-not $lastCheck){
   Add-Check 'Pending Windows updates' 'unknown' 'Windows has no successful update check on record, so its saved results cannot show whether updates are waiting. No online check was made by this scan.' 'Open Windows Update in Settings and select Check for updates.'
  } elseif($pausedUntil){
   Add-Check 'Pending Windows updates' 'info' "Windows updates are paused until $(Format-Date $pausedUntil 'yyyy-MM-dd'), so updates released during the pause are not listed. No online check was made by this scan." 'Open Windows Update in Settings and select Resume updates when you are ready.'
  } elseif(($checkAge=Get-Floor ((Get-Date)-$lastCheck).TotalDays) -gt 14){
   # Same 14-day limit as the recency check: older saved results miss updates released since.
   Add-Check 'Pending Windows updates' 'unknown' "Windows last checked for updates $checkAge days ago, so its saved results cannot show whether updates released since then are waiting. No online check was made by this scan." 'Open Windows Update in Settings and select Check for updates.'
  } else {
   Add-Check 'Pending Windows updates' 'pass' "No updates were waiting to install as of Windows' last update check. No online check was made by this scan." 'Open Windows Update in Settings and select Check for updates to confirm.'
  }
 } catch { Add-Check 'Pending Windows updates' 'unknown' ('Windows Update''s saved results could not be read.'+(Get-FailureNote $_)) 'Open Windows Update in Settings and select Check for updates.' }
}
Write-Host 'Checking Windows Update (this step can take several seconds)...'
$pausedUntil=Get-UpdatePauseEnd
Add-RestartPendingCheck
$lastCheck=Add-UpdateRecencyCheck $pausedUntil
Add-PendingUpdatesCheck $lastCheck $pausedUntil $script:UpdateCheckUnreadable

# --- System drive encryption ---
# Get-BitLockerVolume needs administrator. Without it, fall back to the status
# File Explorer shows, which is readable by a standard user.
function Add-EncryptionCheck {
 $encAction='Review Device encryption or BitLocker; back up recovery keys before changes. If Settings has no Device encryption page, search Start for "Manage BitLocker".'
 $encDone=$false
 try {
  $b=Invoke-Bounded 'reading BitLocker status' 30 {
   param($drive)
   $v=Get-BitLockerVolume -MountPoint $drive -ErrorAction Stop
   if($v){ New-Object PSObject -Property @{ProtectionStatus="$($v.ProtectionStatus)";VolumeStatus="$($v.VolumeStatus)"} }
  } @($env:SystemDrive) | Select-Object -First 1
  if($b -and $b.ProtectionStatus){
   $vs=$b.VolumeStatus
   if($b.ProtectionStatus -eq 'On'){
    Add-Check 'System drive encryption' 'pass' "BitLocker protection: On (volume status: $vs)" $encAction
   } elseif($vs -eq 'EncryptionInProgress'){
    # Same result as the non-administrator fallback below.
    Add-Check 'System drive encryption' 'info' 'BitLocker encryption is in progress' 'Let encryption finish, then run the scan again.'
   } elseif($vs -eq 'DecryptionInProgress'){
    Add-Check 'System drive encryption' 'warning' 'BitLocker decryption is in progress' $encAction
   } else {
    Add-Check 'System drive encryption' 'warning' "BitLocker protection: $($b.ProtectionStatus) (volume status: $vs)" $encAction
   }
   $encDone=$true
  }
 } catch { }
 if(-not $encDone){
  # BitLocker's own status needs administrator; an administrator run that got here gains nothing by running again.
  $unreadAction='Check Device encryption or BitLocker in Settings.'
  if(-not $script:IsElevated){ $unreadAction='Check Device encryption or BitLocker in Settings, or run this scan again as administrator.' }
  try {
   $code=Invoke-Bounded 'reading drive encryption status' 30 {
    param($drive)
    $shell=New-Object -ComObject Shell.Application
    [string]$shell.NameSpace("$drive\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
   } @($env:SystemDrive) | Select-Object -First 1
   switch([string]$code){
    '1' { Add-Check 'System drive encryption' 'pass' 'BitLocker protection: On' $encAction }
    '6' { Add-Check 'System drive encryption' 'pass' 'BitLocker protection: On (volume locked)' $encAction }
    '3' { Add-Check 'System drive encryption' 'info' 'BitLocker encryption is in progress' 'Let encryption finish, then run the scan again.' }
    '5' { Add-Check 'System drive encryption' 'warning' 'BitLocker protection is suspended' $encAction }
    '4' { Add-Check 'System drive encryption' 'warning' 'BitLocker decryption is in progress' $encAction }
    '2' { Add-Check 'System drive encryption' 'warning' 'BitLocker protection: Off' $encAction }
    # Device encryption has encrypted the drive, but the key stays unprotected until it is activated.
    '8' { Add-Check 'System drive encryption' 'warning' 'The drive is encrypted, but Windows reports that protection is waiting for activation, so the drive is not yet protected.' 'Open Settings > Privacy & security > Device encryption to finish turning it on (this usually needs a Microsoft account to back up the recovery key). If that page is missing, search Start for "Manage BitLocker".' }
    '0' { Add-Check 'System drive encryption' 'info' 'Windows reports that BitLocker is not available for this drive on this PC.' $encAction }
    default { Add-Check 'System drive encryption' 'unknown' 'Windows did not report an encryption status for this drive.' $unreadAction }
   }
  } catch { Add-Check 'System drive encryption' 'unknown' ('Encryption status could not be read.'+(Get-FailureNote $_)) $unreadAction }
 }
}
Write-Host 'Checking drive encryption...'
Add-EncryptionCheck

# --- Battery capacity ---
function Get-BatteryCheckId($instanceName) {
 $normalized=([string]$instanceName).Trim().ToUpperInvariant()
 if(-not $normalized){ return $null }
 # A missing ID only stops the dashboard matching this battery across scans; it must never stop the scan
 # (hashing can be refused, for example under Constrained Language Mode). The CryptoServiceProvider
 # class is FIPS-validated on every .NET Framework 4.x and gives the same SHA-256 value as before.
 try {
  $hasher=New-Object Security.Cryptography.SHA256CryptoServiceProvider
  try {
   $digest=$hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
   return 'battery:'+([BitConverter]::ToString($digest)).Replace('-','').ToLowerInvariant()
  } finally { $hasher.Dispose() }
 } catch { return $null }
}
function Add-BatteryChecks {
 $batteryAction='Review battery condition with the device manufacturer. Capacity estimates vary with calibration; this check does not predict runtime or battery safety.'
 try { $batteries=@(Get-CimInstance -ClassName Win32_Battery -OperationTimeoutSec 30 -ErrorAction Stop) }
 catch {
  Add-Check 'Battery health' 'unknown' 'Windows battery presence could not be read.' $batteryAction
  return
 }
 if(-not $batteries.Count){
  Add-Check 'Battery health' 'info' 'Windows did not report an installed battery.' 'No battery capacity review is needed for this inventory.'
  return
 }
 try {
  # These driver-backed WMI classes report capacity without creating a powercfg report.
  # https://learn.microsoft.com/en-us/windows/win32/api/batclass/ns-batclass-battery_wmi_static_data
  # https://learn.microsoft.com/en-us/windows/win32/api/batclass/ns-batclass-battery_wmi_full_charged_capacity
  $static=@(Get-CimInstance -Namespace 'root/wmi' -ClassName BatteryStaticData -OperationTimeoutSec 30 -ErrorAction Stop | Where-Object { $_.Active -eq $true } | Sort-Object InstanceName)
  $charged=@(Get-CimInstance -Namespace 'root/wmi' -ClassName BatteryFullChargedCapacity -OperationTimeoutSec 30 -ErrorAction Stop | Where-Object { $_.Active -eq $true })
 } catch {
  Add-Check 'Battery health' 'unknown' 'A battery is present, but Windows did not provide readable capacity data.' $batteryAction
  return
 }
 if(-not $static.Count){
  Add-Check 'Battery health' 'unknown' 'A battery is present, but no active design-capacity data was available.' $batteryAction
  return
 }
 if($static.Count -ne $batteries.Count){
  Add-Check 'Battery inventory' 'unknown' "Windows reported $($batteries.Count) battery entry(s), but capacity data covered $($static.Count) active pack(s). The inventory could not be fully matched." $batteryAction
 }
 $batteryNumber=0
 foreach($pack in $static){
  $batteryNumber++
  $name="Battery health: Battery $batteryNumber"
  $instance=([string]$pack.InstanceName).Trim()
  $matches=@($charged | Where-Object { ([string]$_.InstanceName).Trim() -eq $instance })
  $designMatches=@($static | Where-Object { ([string]$_.InstanceName).Trim() -eq $instance })
  # A stable hash matches the same driver-reported battery instance if another disappears.
  # A driver can reuse an instance name after replacement; this is not a physical serial ID.
  # No raw hardware instance name is included in the report; ambiguous names get no ID.
  $id=if($instance -and $designMatches.Count -eq 1){ Get-BatteryCheckId $instance }else{ $null }
  if((-not $instance) -or $matches.Count -ne 1 -or $designMatches.Count -ne 1){
   Add-Check $name 'unknown' 'The design and full-charge capacity records could not be matched to one battery.' $batteryAction $id
   continue
  }
  $full=$matches[0]
  # Tags change on battery replacement; never combine values collected across a swap.
  if($null -ne $pack.Tag -and $null -ne $full.Tag -and $pack.Tag -ne $full.Tag){
   Add-Check $name 'unknown' 'The battery changed while its capacity was being read. Run the scan again.' $batteryAction $id
   continue
  }
  try {
   if($null -eq $pack.Capabilities){ throw 'Capacity units unavailable.' }
   $capabilities=[uint32]$pack.Capabilities
   # BATTERY_CAPACITY_RELATIVE means driver-defined units, not mWh. This check
   # deliberately leaves such batteries unknown instead of assuming comparable units.
   # https://learn.microsoft.com/en-us/windows/win32/power/battery-information-str
   if(($capabilities -band 0x40000000) -ne 0){
    Add-Check $name 'unknown' 'This battery reports relative capacity units; this check supports capacity reported in mWh.' $batteryAction $id
    continue
   }
   $design=[double]$pack.DesignedCapacity
   $fullCapacity=[double]$full.FullChargedCapacity
   # BATTERY_UNKNOWN_CAPACITY is UINT32_MAX. Zero, missing and invalid values cannot
   # establish health; never turn them into a healthy ratio or divide by zero.
   if($null -eq $pack.DesignedCapacity -or $null -eq $full.FullChargedCapacity -or
      $design -le 0 -or $fullCapacity -le 0 -or $design -ge [uint32]::MaxValue -or
      $fullCapacity -ge [uint32]::MaxValue -or [double]::IsNaN($design) -or [double]::IsNaN($fullCapacity)){
    throw 'Capacity unavailable.'
   }
   $retained=100*$fullCapacity/$design
   $displayPercent=(Get-Floor ($retained*10))/10
   $status=if($retained -lt 80){'warning'}else{'pass'}
   $detail="Estimated full-charge capacity: $displayPercent% of design ($fullCapacity of $design mWh). This is capacity retention, not the current charge level. Below 80% is a review threshold, not a failure diagnosis."
   Add-Check $name $status $detail $batteryAction $id
  } catch {
   Add-Check $name 'unknown' 'Windows did not provide valid design capacity, full-charge capacity, or capacity units for this battery.' $batteryAction $id
  }
 }
}
Write-Host 'Checking battery capacity...'
try { Add-BatteryChecks }
catch { Add-Check 'Battery health' 'unknown' 'Battery information could not be read.' 'Review battery condition with the device manufacturer.' }

# --- Startup inventory ---
function Get-StartupDisplayName($value) {
 $name=[string]$value
 # Names are registry labels, not trusted display text. Omit path-like, address-like,
 # multiline and command-like labels instead of exposing them in an exported report.
 if((-not $name.Trim()) -or $name -match '[\\/:@%"'';&|<>\x00-\x1f\x7f]' -or $name -cmatch '\s-[A-Za-z]'){
  return 'Startup entry (name omitted)'
 }
 $name=(Remove-UserNames $name).Trim()
 if($name.Length -gt 64){ $name=$name.Substring(0,61)+'...' }
 return $name
}
function Get-StartupLocationLabel($value) {
 $location=[string]$value
 if($location -match '^(HKLM|HKEY_LOCAL_MACHINE)\\.*\\RunOnce$'){ return 'Machine RunOnce registry' }
 if($location -match '^(HKLM|HKEY_LOCAL_MACHINE)\\.*\\Run$'){ return 'Machine Run registry' }
 if($location -match '^(HKCU|HKEY_CURRENT_USER|HKU|HKEY_USERS)\\.*\\RunOnce$'){ return 'User RunOnce registry' }
 if($location -match '^(HKCU|HKEY_CURRENT_USER|HKU|HKEY_USERS)\\.*\\Run$'){ return 'User Run registry' }
 if($location -match '^(Common Startup|All Users Startup)$'){ return 'Shared startup folder' }
 if($location -eq 'Startup' -or $location -match '\\Start Menu\\Programs\\Startup$'){ return 'Startup folder' }
 return 'Other startup location'
}
function Add-StartupChecks {
 $startupAction='Open Task Manager > Startup apps to review enabled state and measured startup impact. Review unfamiliar entries with their publisher before changing them.'
 try {
  # Never include Command, User or UserSID in the report. Win32_StartupCommand is an inventory,
  # including potentially disabled entries, and does not establish startup impact.
  # https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-startupcommand
  $entries=@(Get-CimInstance -ClassName Win32_StartupCommand -Property Name,Location -OperationTimeoutSec 30 -ErrorAction Stop)
  # A foreach statement, not a pipeline: PowerShell module logging records pipeline input, and these
  # raw objects carry the command line and user of each entry.
  $rows=@()
  foreach($entry in $entries){
   $rows+=New-Object PSObject -Property @{Name=(Get-StartupDisplayName $entry.Name);Location=(Get-StartupLocationLabel $entry.Location)}
  }
  $rows=@($rows | Sort-Object Name,Location)
  $detail="Windows returned $($entries.Count) registered startup entry(s). This inventory does not establish whether entries are enabled or running, their startup impact, or every way apps can start. Visibility may depend on access rights."
  if($rows.Count){
   $lines=@($rows | Select-Object -First 12 | ForEach-Object { '- '+$_.Name+' ('+$_.Location+')' })
   $detail+="`n"+($lines -join "`n")
   if($rows.Count -gt 12){ $detail+="`n- $($rows.Count-12) more entries not shown." }
  }
  Add-Check 'Startup apps (inventory only)' 'info' $detail $startupAction
 } catch {
  Add-Check 'Startup apps (inventory only)' 'unknown' 'Windows startup entries could not be read with the available access. No startup settings were changed.' $startupAction
 }
}
Write-Host 'Reviewing startup inventory...'
Add-StartupChecks

# --- Windows version support ---
# End-of-servicing dates are a fixed list inside this script (the scan never goes online), so
# the list ages. $SupportListDate says when it was last reviewed; builds that are not in the
# list are reported as informational rather than guessed.
# https://learn.microsoft.com/en-us/lifecycle/products/windows-11-home-and-pro
# https://learn.microsoft.com/en-us/lifecycle/products/windows-11-enterprise-and-education
# https://learn.microsoft.com/en-us/lifecycle/products/windows-10-home-and-pro
$SupportListDate='2026-11'
function Get-WindowsSupportResult($build,$editionId,$installationType,$displayVersion,[datetime]$today) {
 $action='Open Windows Update in Settings to see whether a newer version of Windows is offered for this PC.'
 $buildNumber=([string]$build).Trim() -as [int]
 if($null -eq $buildNumber -or $buildNumber -le 0){
  return @{status='unknown';detail='The Windows build number could not be read.';action=$action}
 }
 $edition=[string]$editionId
 $label=$(if($displayVersion){"version $(Get-SafeText $displayVersion 16) (build $buildNumber)"}else{"build $buildNumber"})
 if([string]$installationType -and [string]$installationType -ne 'Client'){
  return @{status='info';detail="This is a Windows Server or other non-client installation ($label). Its support dates are not covered by this scan.";action='Check the Microsoft lifecycle page for this product.'}
 }
 # Long-term servicing editions follow their own, much longer schedules.
 if($edition -match 'EnterpriseS|IoTEnterpriseS'){
  return @{status='info';detail="This is a long-term servicing (LTSC) edition of Windows ($label). Its support dates are not covered by this scan.";action='Check the Microsoft lifecycle page for this LTSC release.'}
 }
 if($buildNumber -lt 22000){
  return @{status='warning';detail="This PC runs Windows 10 ($label). Windows 10 stopped receiving free security updates on 2025-10-14. It only stays protected while enrolled in Extended Security Updates, which this scan cannot see.";action='Upgrade to a supported version of Windows if this PC is eligible, or confirm it is enrolled in Extended Security Updates.'}
 }
 # Windows 11 feature releases. Dates are taken from Microsoft's lifecycle pages (roughly 24 months
 # for Home/Pro editions and 36 for Enterprise/Education); the lookup is an exact build match.
 $releases=@(
  @{build=22000;name='21H2';home='2023-10-10';ent='2024-10-08'},
  @{build=22621;name='22H2';home='2024-10-08';ent='2025-10-14'},
  @{build=22631;name='23H2';home='2025-11-11';ent='2026-11-10'},
  @{build=26100;name='24H2';home='2026-10-13';ent='2027-10-12'},
  @{build=26200;name='25H2';home='2027-10-12';ent='2028-10-10'},
  @{build=26300;name='26H2';home='2028-10-10';ent='2029-10-09'},
  @{build=28000;name='26H1';home='2028-03-14';ent='2029-03-13'}
 )
 $release=$releases | Where-Object { $_.build -eq $buildNumber } | Select-Object -First 1
 if(-not $release){
  return @{status='info';detail="This PC runs Windows 11 $label, which is not in this scan's support list (last reviewed $SupportListDate). It may be newer than the list or a preview build.";action=$action}
 }
 $longSchedule=$edition -match 'Enterprise|Education|ServerRdsh' -and $edition -notmatch '^ProfessionalEducation'
 $endText=$(if($longSchedule){$release.ent}else{$release.home})
 $end=[datetime]::ParseExact($endText,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
 $daysLeft=[int](Get-Floor ($end.Date-$today.Date).TotalDays)
 $which=$(if($longSchedule){'Enterprise and Education editions'}else{'Home and Pro editions'})
 if($daysLeft -lt 0){
  return @{status='warning';detail="Windows 11 $($release.name) (build $buildNumber) stopped receiving security updates for $which on $endText.";action='Open Windows Update in Settings and install the newer version of Windows 11 offered for this PC.'}
 }
 if($daysLeft -le 90){
  return @{status='warning';detail="Windows 11 $($release.name) (build $buildNumber) stops receiving security updates for $which on $endText ($daysLeft days from now).";action='Open Windows Update in Settings and install the newer version of Windows 11 offered for this PC.'}
 }
 return @{status='pass';detail="Windows 11 $($release.name) (build $buildNumber) receives security updates for $which until $endText. Support list last reviewed $SupportListDate.";action='No action needed. Install newer versions of Windows when Windows Update offers them.'}
}
function Add-WindowsSupportChecks {
 try {
  $cv=Get-MachineRegistryValues 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $result=Get-WindowsSupportResult $cv.CurrentBuildNumber $cv.EditionID $cv.InstallationType $cv.DisplayVersion (Get-Date)
  Add-Check 'Windows version support' $result.status $result.detail $result.action
 } catch {
  Add-Check 'Windows version support' 'unknown' 'The installed Windows version could not be read.' 'Open Settings > System > About to see the Windows version.'
 }
}
Write-Host 'Checking Windows version support...'
Add-WindowsSupportChecks

# --- Firmware security: Secure Boot and TPM ---
function ConvertTo-FirmwareMode($value) {
 # Culture-invariant: under Turkish regional settings a plain case-insensitive match fails on 'I'.
 $mode=([string]$value).Trim()
 if([regex]::IsMatch($mode,'^uefi$','IgnoreCase, CultureInvariant')){ return 'UEFI' }
 if([regex]::IsMatch($mode,'^(legacy|bios)$','IgnoreCase, CultureInvariant')){ return 'Legacy' }
 return ''
}
function Get-FirmwareMode {
 # 'UEFI', 'Legacy' or '' (not determined). Windows sets this variable for every process.
 return ConvertTo-FirmwareMode $env:firmware_type
}
function Add-SecureBootCheck {
 $action='To turn on Secure Boot, use the PC''s UEFI firmware settings. Check the manufacturer''s instructions first; changing firmware settings on a PC with BitLocker can ask for the recovery key.'
 if((Get-FirmwareMode) -eq 'Legacy'){
  # The registry can still report "0" here; advising a firmware change could leave the PC unable to start.
  Add-Check 'Secure Boot' 'info' 'This PC starts in legacy BIOS mode, where Secure Boot is not available.' 'No action needed. Do not change the firmware startup mode just for this: switching to UEFI needs the Windows disk converted first, and the PC may not start otherwise.'
  return
 }
 try {
  # Readable by a standard user; Confirm-SecureBootUEFI needs administrator.
  $state=Get-MachineRegistryValues 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
  if($null -eq $state.UEFISecureBootEnabled){ throw 'Value missing.' }
  if([int]$state.UEFISecureBootEnabled -eq 1){
   Add-Check 'Secure Boot' 'pass' 'Secure Boot is on. It helps stop tampered startup software from loading before Windows.' 'No action needed.'
  } else {
   Add-Check 'Secure Boot' 'warning' 'Secure Boot is off or not supported by this PC''s firmware configuration. Windows runs without it, but startup is less protected against tampering.' $action
  }
 } catch {
  Add-Check 'Secure Boot' 'unknown' 'Secure Boot status could not be read. This is normal on PCs that start in legacy BIOS mode.' $action
 }
}
function Add-TpmCheck {
 $action='If the PC has a TPM, it can be turned on in the PC''s UEFI firmware settings (often named fTPM, PTT or Security Device). Check the manufacturer''s instructions before changing firmware settings.'
 try {
  # Device presence only. Readiness and ownership details (Get-Tpm) need administrator.
  # TPM 2.0 devices carry the hardware ID MSFT0101; TPM 1.2 devices the compatible ID PNP0C31.
  $devices=@(Get-CimInstance -ClassName Win32_PnPEntity -Filter "ClassGuid='{d94ee5d8-d189-4994-83d2-f68d7d41b0e6}'" -Property HardwareID,CompatibleID,ConfigManagerErrorCode -OperationTimeoutSec 30 -ErrorAction Stop)
  $tpm=@()
  foreach($device in $devices){
   $ids=(@($device.HardwareID)+@($device.CompatibleID) | ForEach-Object { [string]$_ }) -join ';'
   if($ids -match 'MSFT0101'){ $tpm+=New-Object PSObject -Property @{Version='2.0';Error=$device.ConfigManagerErrorCode} }
   elseif($ids -match 'PNP0C31'){ $tpm+=New-Object PSObject -Property @{Version='1.2';Error=$device.ConfigManagerErrorCode} }
  }
  if(-not $tpm.Count){
   Add-Check 'TPM security chip' 'info' 'Windows did not list a TPM device. The PC may not have one, or it may be turned off in firmware settings. BitLocker and Windows 11 rely on a TPM.' $action
   return
  }
  $best=$tpm | Sort-Object Version -Descending | Select-Object -First 1
  if($null -ne $best.Error -and [int]$best.Error -ne 0){
   Add-Check 'TPM security chip' 'warning' "A TPM $($best.Version) device is present, but Windows reports a problem with it (Device Manager code $([int]$best.Error))." 'Open Device Manager > Security devices to review the TPM device.'
  } elseif($best.Version -eq '2.0'){
   Add-Check 'TPM security chip' 'pass' 'A TPM 2.0 device is present and Windows reports it is working. This scan does not check whether the TPM is provisioned; that needs administrator.' 'No action needed.'
  } else {
   Add-Check 'TPM security chip' 'info' 'A TPM 1.2 device is present. Windows 11 and newer security features expect TPM 2.0.' 'Check the PC manufacturer''s support site; some PCs can move to TPM 2.0 with a firmware update, others cannot.'
  }
 } catch {
  Add-Check 'TPM security chip' 'unknown' 'Windows device information for the TPM could not be read.' 'Search Start for "Device security" and look for Security processor details.'
 }
}
Write-Host 'Checking Secure Boot and TPM...'
Add-SecureBootCheck
Add-TpmCheck

# --- User Account Control ---
function Add-UacCheck {
 $action='Search Start for "Change User Account Control settings" and choose the default level (notify when apps try to make changes).'
 try {
  $policy=Get-MachineRegistryValues 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  if($null -eq $policy.EnableLUA){ throw 'Value missing.' }
  if([int]$policy.EnableLUA -ne 1){
   Add-Check 'User Account Control' 'warning' 'User Account Control is turned off, so programs can make system-wide changes without asking.' $action
  } elseif($null -ne $policy.ConsentPromptBehaviorAdmin -and [int]$policy.ConsentPromptBehaviorAdmin -eq 0){
   Add-Check 'User Account Control' 'warning' 'User Account Control is on but set to never notify, so administrator accounts approve system-wide changes without being asked.' $action
  } else {
   Add-Check 'User Account Control' 'pass' 'User Account Control is turned on and is not set to "never notify".' 'No action needed.'
  }
 } catch {
  Add-Check 'User Account Control' 'unknown' 'The User Account Control setting could not be read.' $action
 }
}
Write-Host 'Checking User Account Control...'
Add-UacCheck

# --- Stability and drive error events ---
# Counts come from the Windows event logs, read as a standard user. Only counts, dates and
# program file names are reported; event messages are never copied into the report.
function Get-HealthEvents($logName,$providers,$ids,$days) {
 $providerTest=(@($providers) | ForEach-Object { "@Name='$_'" }) -join ' or '
 $idTest=(@($ids) | ForEach-Object { "EventID=$_" }) -join ' or '
 $ms=[int64]$days*86400000
 $xpath="*[System[Provider[$providerTest] and ($idTest) and TimeCreated[timediff(@SystemTime) <= $ms]]]"
 return @(Invoke-Bounded "reading the Windows $logName event log" 60 {
  param($log,$query)
  try { @(Get-WinEvent -LogName $log -FilterXPath $query -ErrorAction Stop) }
  catch {
   # "No events found" is an answer, not a failure.
   if("$($_.FullyQualifiedErrorId)" -match '^NoMatchingEventsFound'){ return }
   throw
  }
 } @($logName,$xpath))
}
function Get-LogCoverageNote($logName,$days) {
 # An event log is a fixed-size rolling file; say so when it does not reach back the whole period.
 try {
  $oldest=Invoke-Bounded "reading the Windows $logName event log" 30 { param($log) (Get-WinEvent -LogName $log -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated } @($logName) | Select-Object -First 1
  if($oldest -is [datetime]){
   $covered=[int](Get-Floor ((Get-Date)-$oldest).TotalDays)
   if($covered -lt $days){ return " The Windows $logName log on this PC only goes back $covered day(s), so earlier events are not counted." }
  }
 } catch { return " The Windows $logName log coverage could not be verified; earlier events may be unavailable." }
 return " The Windows $logName log coverage could not be verified."
}
function Get-CrashProgramName($value) {
 $name=([string]$value).Trim()
 # File names only; anything that does not look like a plain program file name is omitted.
 # Case-sensitive matching: both cases are listed, and a case-insensitive match fails on 'I' under Turkish settings.
 if($name -cmatch '^[A-Za-z0-9 ._+()\-]{1,64}$' -and $name -cmatch '\.[A-Za-z0-9]{2,4}$'){
  # Whole-word match on the base name only, so a short username cannot mangle unrelated names.
  $dot=$name.LastIndexOf('.')
  return (Remove-UserNames $name.Substring(0,$dot))+$name.Substring($dot)
 }
 return 'program (name omitted)'
}
function Add-StabilityChecks {
 $days=30
 $action='Search Start for "View reliability history" to see what failed and when. Repeated blue screens or sudden shutdowns are worth having checked: common causes are drivers, overheating, failing memory or power problems.'
 try {
  $events=Get-HealthEvents 'System' @('Microsoft-Windows-WER-SystemErrorReporting','Microsoft-Windows-Kernel-Power') @(1001,41) $days
  $reported=@($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $_.Id -eq 1001 })
  $k41=@($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 })
  # Kernel-Power 41 carries the bug-check code as its first data field: non-zero means a stop
  # error, 0 a loss of power. Event 1001 is only written when a crash dump was saved, so a stop
  # error can appear as either or both; count the larger of the two so one crash is not counted twice.
  $stop41=@(); $powerLoss=@()
  foreach($e in $k41){
   $code=0
   try { if($e.Properties -and @($e.Properties).Count){ $code=[int64]$e.Properties[0].Value } } catch { $code=0 }
   if($code -ne 0){ $stop41+=$e }else{ $powerLoss+=$e }
  }
  # Kernel-Power 41 can carry code 0 even after a blue screen whose dump produced event 1001; both are
  # written at the next start. A code-0 event within 10 minutes of a 1001 is that crash, not a power loss.
  # Each 1001 accounts for at most one such event.
  $dumpTimes=@($reported | Where-Object { $_.TimeCreated -is [datetime] } | ForEach-Object { $_.TimeCreated })
  $used=@{}
  # A 1001 that already matches a 41 with a bug-check code belongs to that crash.
  foreach($e in $stop41){
   if($e.TimeCreated -isnot [datetime]){ continue }
   for($i=0;$i -lt $dumpTimes.Count;$i++){
    if($used.ContainsKey($i)){ continue }
    $minutes=($dumpTimes[$i]-$e.TimeCreated).TotalMinutes
    if($minutes -ge -10 -and $minutes -le 10){ $used[$i]=$true; break }
   }
  }
  $pairedStopCount=$used.Count
  $keep=@()
  foreach($e in $powerLoss){
   $paired=$false
   if($e.TimeCreated -is [datetime]){
    for($i=0;$i -lt $dumpTimes.Count;$i++){
     if($used.ContainsKey($i)){ continue }
     $minutes=($dumpTimes[$i]-$e.TimeCreated).TotalMinutes
     if($minutes -ge -10 -and $minutes -le 10){ $used[$i]=$true; $paired=$true; break }
    }
   }
   if(-not $paired){ $keep+=$e }
  }
  $powerLoss=$keep
  $stopCount=$reported.Count+$stop41.Count-$pairedStopCount
  $detail="In the last $days days Windows recorded $stopCount blue-screen stop error(s) and $($powerLoss.Count) unexpected shutdown(s). An unexpected shutdown means Windows was not shut down cleanly: a power cut, holding the power button, or a freeze."
  $latest=@($reported+$k41 | Sort-Object TimeCreated -Descending | Select-Object -First 1)
  if($latest.Count -and $latest[0].TimeCreated){ $detail+=" Most recent: $(Format-Date $latest[0].TimeCreated 'yyyy-MM-dd')." }
  $detail+=Get-LogCoverageNote 'System' $days
  $status=$(if($stopCount -ge 1 -or $powerLoss.Count -ge 3){'warning'}else{'pass'})
  Add-Check "System stability (last $days days)" $status $detail $(if($status -eq 'pass'){'No action needed.'}else{$action})
 } catch {
  Add-Check "System stability (last $days days)" 'unknown' $(if(Get-FailureNote $_){'The Windows System event log could not be read.'+(Get-FailureNote $_)}else{'The Windows System event log could not be read with the available access.'}) $action
 }
}
function Add-DriveErrorChecks {
 $days=30
 $action='Back up important files now. Then check the drive and its cable, and run the drive manufacturer''s diagnostic tool. Search Start for "Event Viewer" > Windows Logs > System to see the events.'
 try {
  # disk 7 = bad block, 11 = controller error, 51 = paging error, 153 = retried I/O; Ntfs 55 = file system corruption.
  $events=Get-HealthEvents 'System' @('disk','Ntfs','Microsoft-Windows-Ntfs') @(7,11,51,55,153) $days
  $bad=@($events | Where-Object { ($_.ProviderName -eq 'disk' -and @(7,11,51,153) -contains $_.Id) -or ($_.ProviderName -match 'Ntfs$' -and $_.Id -eq 55) })
  if(-not $bad.Count){
   Add-Check "Drive error events (last $days days)" 'pass' ("Windows recorded none of the common disk bad-block, controller, paging or file-system corruption events in the last $days days. Other storage events are not checked."+(Get-LogCoverageNote 'System' $days)) 'No action needed. Keep regular backups; drives can fail without warning.'
   return
  }
  $labels=@{7='bad block';11='controller error';51='error during paging';153='retried read or write';55='file system corruption'}
  $parts=@($bad | Group-Object Id | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) x $($labels[[int]$_.Name])" })
  $latest=$bad | Sort-Object TimeCreated -Descending | Select-Object -First 1
  $detail="Windows recorded $($bad.Count) disk or file-system error event(s) in the last $days days: $($parts -join ', ')."
  if($latest.TimeCreated){ $detail+=" Most recent: $(Format-Date $latest.TimeCreated 'yyyy-MM-dd')." }
  # Bad blocks and file-system corruption matter at once. Controller, paging and retry events are
  # also logged when a USB stick or memory card is pulled out, so they need to repeat first,
  # unless the event names an internal drive that is in this PC now.
  $serious=@($bad | Where-Object { $_.Id -eq 7 -or $_.Id -eq 55 })
  $soft=@($bad | Where-Object { $_.Id -ne 7 -and $_.Id -ne 55 })
  $internal=@(); $unmatched=@(); $otherDisk=@()
  if($soft.Count){
   $fixedDisks=$null
   try {
    $fixedDisks=@(foreach($dd in @(Get-CimInstance -ClassName Win32_DiskDrive -Property Index,MediaType,InterfaceType -OperationTimeoutSec 30 -ErrorAction Stop)){
     if("$($dd.MediaType)" -match '^Fixed' -and "$($dd.InterfaceType)" -ne 'USB' -and $null -ne $dd.Index){ [string]$dd.Index }
    })
   } catch { $fixedDisks=$null }
   foreach($e in $soft){
    # The event names its disk as \Device\HarddiskN\DRN; it is used here only, never reported.
    $diskNumber=$null
    foreach($property in @($e.Properties)){
     if($property -and "$($property.Value)" -match '^\\Device\\Harddisk(\d+)\\DR\d+$'){ $diskNumber=$Matches[1]; break }
    }
    if($null -eq $diskNumber -or $null -eq $fixedDisks){ $unmatched+=$e }
    elseif($fixedDisks -contains $diskNumber){ $internal+=$e }
    else { $otherDisk+=$e }
   }
  }
  # One unplugged stick can log several events at once, so events for a drive known not to be internal
  # count only when they repeat on another day; events that could not be matched also count at three or more.
  $softDays=@($soft | Where-Object { $_.TimeCreated } | ForEach-Object { Format-Date $_.TimeCreated 'yyyy-MM-dd' } | Select-Object -Unique)
  if($internal.Count){
   $detail+=' At least one controller, paging or retry event was logged for an internal drive that is in this PC now, so it is not explained by a removable drive being unplugged. It can point to a failing drive or a loose cable.'
   $detail+=Get-LogCoverageNote 'System' $days
   Add-Check "Drive error events (last $days days)" 'warning' $detail $action
  } elseif($serious.Count -or $unmatched.Count -ge 3 -or $softDays.Count -ge 2){
   $detail+=' These can point to a failing drive, a loose cable or a removable drive that was unplugged while in use.'
   $detail+=Get-LogCoverageNote 'System' $days
   Add-Check "Drive error events (last $days days)" 'warning' $detail $action
  } else {
   $detail+=' A small number on one day that could not be tied to an internal drive in this PC usually comes from a USB stick, memory card or external drive that was unplugged while in use, so this is below the review threshold.'
   $detail+=Get-LogCoverageNote 'System' $days
   Add-Check "Drive error events (last $days days)" 'pass' $detail 'No action needed if you unplugged a removable drive around that date. If these events repeat, back up important files and check the drive and its cable.'
  }
 } catch {
  Add-Check "Drive error events (last $days days)" 'unknown' $(if(Get-FailureNote $_){'The Windows System event log could not be read.'+(Get-FailureNote $_)}else{'The Windows System event log could not be read with the available access.'}) $action
 }
}
function Add-AppCrashChecks {
 $days=7
 $action='Search Start for "View reliability history" to see which programs failed. Updating or reinstalling a program that crashes often usually helps.'
 try {
  $events=Get-HealthEvents 'Application' @('Application Error','Application Hang') @(1000,1002) $days
  $crashes=@($events | Where-Object { $_.ProviderName -eq 'Application Error' -and $_.Id -eq 1000 })
  $hangs=@($events | Where-Object { $_.ProviderName -eq 'Application Hang' -and $_.Id -eq 1002 })
  $detail="In the last $days days Windows recorded $($crashes.Count) program crash(es) and $($hangs.Count) program hang(s). Occasional crashes are normal; this is an inventory, not a fault diagnosis."
  $detail+=Get-LogCoverageNote 'Application' $days
  $names=@($crashes+$hangs | ForEach-Object { if($_.Properties -and $_.Properties.Count){ Get-CrashProgramName $_.Properties[0].Value } } | Where-Object { $_ })
  if($names.Count){
   $lines=@($names | Group-Object | Sort-Object @{Expression='Count';Descending=$true},Name | Select-Object -First 5 | ForEach-Object { "- $($_.Name): $($_.Count)" })
   $detail+="`n"+($lines -join "`n")
  }
  Add-Check "Program crashes (last $days days, inventory only)" 'info' $detail $action
 } catch {
  Add-Check "Program crashes (last $days days, inventory only)" 'unknown' $(if(Get-FailureNote $_){'The Windows Application event log could not be read.'+(Get-FailureNote $_)}else{'The Windows Application event log could not be read with the available access.'}) $action
 }
}
Write-Host 'Checking stability and drive error events...'
Add-StabilityChecks
Add-DriveErrorChecks
Add-AppCrashChecks

# --- Hand over / save ---
# Close the step runspace (one stuck in a call was already left behind and is not waited for).
if($script:StepRunspace){ try { $script:StepRunspace.Dispose() } catch { }; $script:StepRunspace=$null }
# The computer name is how the dashboard pairs reports from the same PC, so it is kept as Windows
# reports it (one line, bounded) and is not username-redacted: a PC named after its user would
# otherwise get a different name in each account's reports and in older ones.
$report=[ordered]@{schemaVersion=1;source='windows-collector';collectorVersion=$CollectorVersion;collectedAt=(Get-Date).ToUniversalTime().ToString('o');device=(Get-OneLineText $env:COMPUTERNAME 64);os=$(if($os){Get-SafeText $os.Caption 128}else{'Windows'});checks=@($checks)}
if($EmitJson){ return ($report | ConvertTo-Json -Depth 6 -Compress) }
$json=$report | ConvertTo-Json -Depth 6
$dashboard=Join-Path $PSScriptRoot 'index.html'

# Report data is handed to files, the clipboard and the browser through .NET calls rather than
# cmdlet parameters: PowerShell module logging, when an organization turns it on, records cmdlet
# parameters and would copy the report into the event log. Constrained Language Mode refuses
# these calls, so there the cmdlets are used instead.
function Write-TextFile($path,[string]$text) {
 if($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'){ [IO.File]::WriteAllText($path,$text+"`r`n",[Text.Encoding]::UTF8) }
 else { $text | Set-Content -LiteralPath $path -Encoding UTF8 }
}
function Copy-TextToClipboard([string]$text) {
 if($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'){
  Add-Type -AssemblyName System.Windows.Forms
  [Windows.Forms.Clipboard]::SetText($text)
 } else { Set-Clipboard -Value $text }
}
function Start-BrowserProcess($exe,[string]$arguments) {
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=[string]$exe
 $info.Arguments=$arguments
 $info.UseShellExecute=$false
 [void][Diagnostics.Process]::Start($info)
}
function Get-DesktopFolder {
 try { return [Environment]::GetFolderPath('Desktop') } catch { return (Join-Path $env:USERPROFILE 'Desktop') }
}
function Get-SyncNote($path) {
 # Windows 11 setup turns on OneDrive folder backup by default, which moves the Desktop and
 # Documents into the OneDrive folder; a file saved there is copied to the user's cloud storage.
 foreach($root in @($env:OneDrive,$env:OneDriveConsumer,$env:OneDriveCommercial)){
  if($root){
   $prefix=([string]$root).TrimEnd('\')+'\'
   if(([string]$path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){
    return 'This folder is synced by OneDrive, so OneDrive will copy the saved report to your cloud storage. Move the file elsewhere if you do not want that.'
   }
  }
 }
 return ''
}
function Save-Report($primary,[string]$text){
 # The preferred folder can be unwritable (Controlled Folder Access protects the Desktop;
 # the app folder may be read-only), so fall back rather than lose the finished scan.
 $name='ComputerHealth-'+(Format-Date (Get-Date) 'yyyyMMdd-HHmmss')+'.json'
 foreach($dir in (@($primary,(Join-Path $env:LOCALAPPDATA 'HealthScan\reports'),$env:TEMP) | Where-Object { $_ })){
  try {
   if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
   $p=Join-Path $dir $name
   Write-TextFile $p $text
   return $p
  } catch { Write-Warning "Could not save the report in ${dir}." }
 }
 throw 'The report could not be saved to any folder.'
}
function Write-SavedReportNote($path) {
 Write-Host "Report saved: $path"
 $note=Get-SyncNote $path
 if($note){ Write-Host $note }
}

function Get-BrowserExe {
 # A report can only be passed in the page address if the browser is started directly:
 # opening a file:// address through Windows' default handler drops everything after '#'.
 # Use the default browser when it is one known to accept an address argument, else Edge.
 $known='msedge.exe','chrome.exe','firefox.exe','brave.exe','vivaldi.exe','opera.exe'
 try {
  $progId=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId
  $cmd=(Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command" -ErrorAction Stop).'(default)'
  if("$cmd" -match '^\s*"([^"]+\.exe)"' -or "$cmd" -match '^\s*(\S+\.exe)'){
   $exe=$Matches[1]
   if(($known -contains (Split-Path -Leaf $exe).ToLowerInvariant()) -and (Test-Path -LiteralPath $exe)){ return $exe }
  }
 } catch { }
 foreach($root in ${env:ProgramFiles(x86)},$env:ProgramFiles){
  if($root){
   $exe=Join-Path $root 'Microsoft\Edge\Application\msedge.exe'
   if(Test-Path -LiteralPath $exe){ return $exe }
  }
 }
 return $null
}
# Whether an organization policy turns private windows off in this browser (value 1 for all three
# policies). The machine policy wins over the user policy. Only reads the registry; false when unknown.
function Test-PrivateModeBlocked($browser) {
 $policy=switch(([string](Split-Path -Leaf ([string]$browser))).ToLowerInvariant()){
  'msedge.exe' { @('Software\Policies\Microsoft\Edge','InPrivateModeAvailability') }
  'chrome.exe' { @('Software\Policies\Google\Chrome','IncognitoModeAvailability') }
  'brave.exe' { @('Software\Policies\BraveSoftware\Brave','IncognitoModeAvailability') }
  default { $null }
 }
 if(-not $policy){ return $false }
 foreach($read in @(
  { (Get-MachineRegistryValues ('HKLM:\'+$policy[0])).($policy[1]) },
  { (Get-ItemProperty -Path ('HKCU:\'+$policy[0]) -ErrorAction Stop).($policy[1]) }
 )){
  $value=$null
  try { $value=& $read } catch { $value=$null }
  if($null -ne $value){ return ([string]$value).Trim() -eq '1' }
 }
 return $false
}
# A browser started from an elevated scan would itself run with administrator rights (and its
# path comes from per-user settings), so an elevated scan never starts a browser or opens a page.
$elevatedNote='This scan ran with administrator rights, so it does not open the browser itself: a browser started from here would also run as administrator.'

if(-not $OpenDashboard){
 # Manual mode: one JSON file on the Desktop, imported into the dashboard by hand. When another
 # account was used to elevate, its Desktop is not the signed-in user's, so use the app folder.
 $primary=if($script:SessionUserName -and $PSScriptRoot){ Join-Path $PSScriptRoot 'reports' }else{ Get-DesktopFolder }
 $path=Save-Report $primary $json
 Write-SavedReportNote $path
 Write-Host 'Import this JSON into Total Computer Health Scan. This tool uploaded nothing.'
} elseif($SaveReport){
 # One-click with history: keep the report in the app folder. The dashboard loads
 # latest-report.js with a <script> tag, which works from file:// without a server.
 $path=Save-Report (Join-Path $PSScriptRoot 'reports') $json
 Write-SavedReportNote $path
 $handed=$false
 try {
  Write-TextFile (Join-Path $PSScriptRoot 'latest-report.js') ('window.HEALTHSCAN_REPORT = '+$json+';')
  $handed=$true
 } catch {
  Write-Warning 'The dashboard could not be given the new report automatically.'
  Write-Warning "Use 'Import report' in the dashboard and choose: $path"
 }
 if($IsElevated){
  Write-Host $elevatedNote
  Write-Host "To see the results, open this file yourself from File Explorer: $dashboard"
  if(-not $handed){ Write-Host "Then use 'Import report' and choose the saved report." }
  Start-Sleep -Seconds 15
 } else {
  if($handed){ Write-Host 'Opening the dashboard. This tool uploaded nothing.' } else { Start-Sleep -Seconds 8 }
  Start-Process $dashboard
 }
} else {
 # One-click, read-only: this script writes no file and uploads nothing. The report travels in
 # the part of the page address after '#', which a browser never sends to a server. A normal
 # window would record that whole address in browser history, so a private window is requested;
 # the browser decides, and an organization policy can turn private windows off.
 # The address is also a command-line argument of the browser, so process monitoring on a
 # managed PC (command-line auditing, EDR) can see it; README.txt says so.
 $compact=$report | ConvertTo-Json -Depth 6 -Compress
 $url=$null
 try {
  $b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($compact)).TrimEnd('=').Replace('+','-').Replace('/','_')
  $url=([Uri]$dashboard).AbsoluteUri+'#report='+$b64
 } catch { $url=$null }
 $opened=$false
 $privateBlocked=$false
 if(-not $IsElevated){
  $browser=Get-BrowserExe
  if($browser){ $privateBlocked=Test-PrivateModeBlocked $browser }
  # Windows limits a command line to about 32,000 characters.
  if($browser -and $url -and $url.Length -lt 30000){
   $private=switch((Split-Path -Leaf $browser).ToLowerInvariant()){ 'msedge.exe'{'--inprivate'} 'firefox.exe'{'-private-window'} 'opera.exe'{'--private'} default{'--incognito'} }
   try { Start-BrowserProcess $browser ($private+' "'+$url+'"'); $opened=$true } catch { $opened=$false }
  }
 }
 if($opened){
  Write-Host 'Opening the dashboard with this scan. Asking your browser for a private window...'
  if($privateBlocked){
   Write-Host 'Warning: a policy set by your organization turns private windows off in this browser, so the'
   Write-Host 'results open in a normal window: installed browser extensions can read the page, and the'
   Write-Host 'address, which contains the report, stays in the browser history until you clear it.'
  }
  Write-Host 'This tool wrote no file and uploaded nothing. Use "Export JSON" in the dashboard to keep a copy.'
 } else {
  # Fallback that still writes no file: put the report on the clipboard for the dashboard's "Paste report".
  $copied=$false
  try { Copy-TextToClipboard $compact; $copied=$true } catch { }
  Write-Host ''
  if($IsElevated){
   Write-Host $elevatedNote
   Write-Host "Open this file yourself from File Explorer: $dashboard"
  } else {
   Start-Process $dashboard
  }
  if($copied){
   Write-Host $(if($IsElevated){'The scan was copied to the clipboard (replacing what was there).'}else{'The scan could not be passed to your browser directly, so it was copied to the clipboard (replacing what was there).'})
   Write-Host 'In the dashboard, choose "Paste report" and press Ctrl+V. No file was written.'
   Write-Host 'The report stays on the clipboard (and in Windows clipboard history or sync, if those are turned on) until you copy something else.'
  } else {
   Write-Warning 'The scan could not be passed to your browser or copied to the clipboard.'
   Write-Warning 'Run Open-HealthScan.cmd -SaveReport to save the report in the app folder instead.'
  }
  Start-Sleep -Seconds 15
 }
}
# The report is handed over and every message printed; do not wait for a step left behind.
Exit-Collector 0
