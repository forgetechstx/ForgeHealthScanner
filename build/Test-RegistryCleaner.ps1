# Exercises discovery and deletion only inside a disposable, uniquely named HKCU key.
$ErrorActionPreference = 'Stop'
$exePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'HealthScan.exe'
$assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exePath))
if (-not $assembly.GetType('RegistryAtomic')) { throw 'The executable lacks the transactional helper; rebuild first.' }
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'RegistryCleaner.ps1'
$resource=$assembly.GetManifestResourceStream('RegistryCleaner.ps1')
if (-not $resource) { throw 'The executable lacks the cleaner resource; rebuild first.' }
$sha=[Security.Cryptography.SHA256]::Create()
try { $embedded=[BitConverter]::ToString($sha.ComputeHash($resource)); $disk=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($scriptPath))); if($embedded -ne $disk){throw 'The executable contains an older cleaner; rebuild first.'} } finally { $resource.Dispose(); $sha.Dispose() }
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw "Cleaner syntax errors: $errors" }
foreach ($name in 'Test-MissingLocalExecutable','Get-MissingStartupEntries','Remove-ReviewedStartupEntries','Backup-StartupKey','Test-ElevatedOtherAccount','Assert-CleanupHistoryFits','Save-CleanupHistory','Read-CleanupHistory','Restore-CleanupEntries') {
 $node=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
 if (-not $node) { throw "Missing function $name" }
 . ([scriptblock]::Create($node.Extent.Text))
}
$leaf='HealthScan-Test-'+[guid]::NewGuid().ToString('N')
if ($leaf -notmatch '^HealthScan-Test-[a-f0-9]{32}$') { throw 'Invalid test key' }
$runPath='Software\'+$leaf
$base=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software',$true)
$key=$null
$backup=$null
$appeared=$null
$historyFile=$null
try {
 $key=$base.CreateSubKey($leaf)
 $missing=Join-Path $env:TEMP ('HealthScan-missing-'+[guid]::NewGuid().ToString('N')+'.exe')
 $missing2=Join-Path $env:TEMP ('HealthScan-missing-'+[guid]::NewGuid().ToString('N')+'.exe')
 $appeared=Join-Path $env:TEMP ('HealthScan-appeared-'+[guid]::NewGuid().ToString('N')+'.exe')
 $existing=Join-Path $env:WINDIR 'System32\notepad.exe'
 if (-not [IO.File]::Exists($existing)) { throw 'Expected Windows notepad.exe for test' }
 $key.SetValue('candidate','"'+$missing+'"',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('changed','"'+$missing2+'"',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('appeared','"'+$appeared+'"',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('existing','"'+$existing+'"',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('arguments','"'+$missing+'" --argument',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('relative','missing.exe',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('expand','%TEMP%\missing.exe',[Microsoft.Win32.RegistryValueKind]::ExpandString)
 $key.SetValue('network','\\server\share\missing.exe',[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('missing-parent','C:\HealthScan-nonexistent-parent-'+[guid]::NewGuid().ToString('N')+'\missing.exe',[Microsoft.Win32.RegistryValueKind]::String)
 # Force non-transacted writes between the transactional read and mutation.
 # Both operations must preserve the competing value or fail closed.
 $key.SetValue('race-delete','old',[Microsoft.Win32.RegistryValueKind]::String)
 $deleteHook=[Action]{ $key.SetValue('race-delete','new',[Microsoft.Win32.RegistryValueKind]::String) }
 $deleteResult=$false; try { $deleteResult=[RegistryAtomic]::Apply($key,'race-delete','old',$false,$deleteHook) } catch { }
 if ($deleteResult -or $key.GetValue('race-delete') -cne 'new') { throw 'Concurrent update was deleted by cleanup' }
 $restoreHook=[Action]{ $key.SetValue('race-restore','new',[Microsoft.Win32.RegistryValueKind]::String) }
 $restoreResult=$false; try { $restoreResult=[RegistryAtomic]::Apply($key,'race-restore','old',$true,$restoreHook) } catch { }
 if ($restoreResult -or $key.GetValue('race-restore') -cne 'new') { throw 'Concurrent update was overwritten by undo' }
 if (@($key.GetValueNames() | Where-Object { $_ -like 'HealthScan-Tx-*' }).Count) { throw 'A transaction marker leaked into the registry' }
 # Repeat both conflicts from a separate Windows process, as a real startup manager would.
 $externalKey='HKCU\'+$runPath
 $key.SetValue('external-delete','old',[Microsoft.Win32.RegistryValueKind]::String)
 $deleteExternal=[Action]{ & "$env:SystemRoot\System32\reg.exe" add $externalKey /v external-delete /t REG_SZ /d new /f 2>$null | Out-Null; if($LASTEXITCODE -ne 0){throw 'External delete-race writer failed'} }
 $deleteResult=$false; try { $deleteResult=[RegistryAtomic]::Apply($key,'external-delete','old',$false,$deleteExternal) } catch { }
 if ($deleteResult -or $key.GetValue('external-delete') -cne 'new') { throw 'A different process update was deleted by cleanup' }
 $restoreExternal=[Action]{ & "$env:SystemRoot\System32\reg.exe" add $externalKey /v external-restore /t REG_SZ /d new /f 2>$null | Out-Null; if($LASTEXITCODE -ne 0){throw 'External restore-race writer failed'} }
 $restoreResult=$false; try { $restoreResult=[RegistryAtomic]::Apply($key,'external-restore','old',$true,$restoreExternal) } catch { }
 if ($restoreResult -or $key.GetValue('external-restore') -cne 'new') { throw 'A different process update was overwritten by undo' }
 if (@($key.GetValueNames() | Where-Object { $_ -like 'HealthScan-Tx-*' }).Count) { throw 'A transaction marker leaked after an external-process conflict' }
 Write-Host 'PASS cleanup and undo preserve conflicting writes from a separate process'
 $found=@(Get-MissingStartupEntries)
 if ($found.Count -ne 3 -or @($found | Where-Object Name -eq 'candidate').Count -ne 1 -or @($found | Where-Object Name -eq 'changed').Count -ne 1 -or @($found | Where-Object Name -eq 'appeared').Count -ne 1) { throw "Unexpected candidates: $($found.Name -join ', ')" }
 $backup=Backup-StartupKey ('HKCU\'+$runPath) $env:TEMP
 $backupText=Get-Content -LiteralPath $backup -Raw
 if (-not $backupText.Contains('"candidate"') -or -not $backupText.Contains('"changed"')) { throw 'Backup omitted selected test entries' }
 $key.SetValue('changed','"'+$existing+'"',[Microsoft.Win32.RegistryValueKind]::String)
 [IO.File]::WriteAllBytes($appeared, [byte[]]@())
 $result=Remove-ReviewedStartupEntries $key $found
 if ($result.Removed -ne 1 -or $result.Skipped -ne 2) { throw 'Removal did not skip the changed value and newly present file' }
 if ($null -ne $key.GetValue('candidate') -or $null -eq $key.GetValue('changed') -or $null -eq $key.GetValue('appeared')) { throw 'Wrong values removed' }
 foreach($name in 'existing','arguments','relative','expand','network','missing-parent') { if ($null -eq $key.GetValue($name)) { throw "Unselected value was removed: $name" } }
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $record=[pscustomobject]@{Schema=1;Id=[guid]::NewGuid().ToString('N');Sid=$sid;State='prepared';CompletedAt='';Backup=$backup;Entries=@($found)}
 $historyFile=Save-CleanupHistory $record $env:TEMP
 $prepared=Read-CleanupHistory $historyFile $sid
 if ($prepared.State -ne 'prepared' -or @($prepared.Entries).Count -ne 3) { throw 'Interrupted history was not preserved for cautious recovery' }
 $recovered=Restore-CleanupEntries $key @($prepared.Entries)
 if ($recovered.Restored -ne 1 -or $recovered.Skipped -ne 2 -or $key.GetValue('candidate') -cne ('"'+$missing+'"')) { throw 'Interrupted cleanup could not selectively recover its removed value' }
 $key.DeleteValue('candidate',$true) # Only the disposable test key, to exercise completed-history undo below.
 $maxCount=[pscustomobject]@{Entries=@(1..1000 | ForEach-Object { [pscustomobject]@{Name="entry$_";Command='x'} })}
 Assert-CleanupHistoryFits $maxCount
 $overCount=[pscustomobject]@{Entries=@(1..1001 | ForEach-Object { [pscustomobject]@{Name="entry$_";Command='x'} })}
 $rejected=$false; try { Assert-CleanupHistoryFits $overCount } catch { $rejected=$true }; if (-not $rejected) { throw 'More than 1,000 entries must be rejected' }
 $overSize=[pscustomobject]@{Entries=@(1..100 | ForEach-Object { [pscustomobject]@{Name="entry$_";Command=('x'*12000)} })}
 $rejected=$false; try { Assert-CleanupHistoryFits $overSize } catch { $rejected=$true }; if (-not $rejected) { throw 'Oversized history must be rejected' }
 $record.State='completed'; $record.CompletedAt=[DateTime]::Now.ToString('o'); $record.Entries=@($found)
 [void](Save-CleanupHistory $record $env:TEMP)
 $loaded=Read-CleanupHistory $historyFile $sid
 try { Read-CleanupHistory $historyFile 'S-1-5-999' | Out-Null; throw 'Other accounts must not restore history' } catch { if ($_.Exception.Message -eq 'Other accounts must not restore history') { throw } }
 $restored=Restore-CleanupEntries $key @($loaded.Entries)
 if($restored.Restored -ne 1 -or $restored.Skipped -ne 2 -or $key.GetValue('changed') -cne ('"'+$existing+'"')){throw 'Selective undo overwrote an existing value or missed the removed value'}
 & "$env:SystemRoot\System32\reg.exe" import $backup | Out-Null
 if ($LASTEXITCODE -ne 0) { throw 'Importing the test backup failed' }
 if ($key.GetValue('candidate') -cne ('"'+$missing+'"') -or $key.GetValue('changed') -cne ('"'+$missing2+'"')) { throw 'Restoring the backup did not restore the original values' }
 Write-Host 'PASS candidate selection, changed-value protection, backup and restoration in a disposable test key'
 # The different-account warning must answer true or false and never throw (it runs before the window opens).
 $other = Test-ElevatedOtherAccount
 if ($other -isnot [bool]) { throw 'Test-ElevatedOtherAccount must return true or false.' }
 $elevated = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 if (-not $elevated -and $other) { throw 'A standard (not elevated) run must never show the different-account warning.' }
 Write-Host 'PASS the different-account warning returns a plain answer and stays quiet when not elevated'
} finally {
 if ($historyFile -and (Test-Path -LiteralPath $historyFile)) { Remove-Item -LiteralPath $historyFile }
 if ($backup -and (Test-Path -LiteralPath $backup)) { Remove-Item -LiteralPath $backup }
 if ($appeared -and (Test-Path -LiteralPath $appeared)) { Remove-Item -LiteralPath $appeared }
 if ($key) { $key.Dispose() }
 if ($base) { $base.DeleteSubKey($leaf,$false); $base.Dispose() }
}
