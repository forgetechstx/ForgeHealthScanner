# Run the cleaner's embedded functions from a standalone copy of the executable.
# All writes are restricted to a unique disposable HKCU key and test directory.
$ErrorActionPreference='Stop'
$id=[guid]::NewGuid().ToString('N')
$testDir=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('HealthScan-PortableAudit-'+$id)))
$tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
if (-not $testDir.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($testDir) -notmatch '^HealthScan-PortableAudit-[a-f0-9]{32}$') { throw 'Unsafe test directory.' }
$leaf='HealthScan-PortableAudit-'+$id
$runPath='Software\'+$leaf
$base=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software',$true)
$key=$null
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
 $exe=Join-Path $testDir 'HealthScan.exe'
 Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'HealthScan.exe') -Destination $exe
 $version=(& $exe -Version | Out-String).Trim()
 if ($LASTEXITCODE -ne 0 -or $version -notmatch '^Total Computer Health Scan ') { throw 'The isolated executable did not start.' }
 if (@(Get-ChildItem -LiteralPath $testDir -File).Count -ne 1) { throw 'Portable test folder contains unexpected files.' }
 $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
 $stream=$assembly.GetManifestResourceStream('RegistryCleaner.ps1')
 if (-not $stream -or -not $assembly.GetType('RegistryAtomic')) { throw 'The standalone executable is missing cleaner components.' }
 try { $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8); $source=$reader.ReadToEnd() } finally { if($reader){$reader.Dispose()}else{$stream.Dispose()} }
 $tokens=$null; $errors=$null
 $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
 if ($errors.Count) { throw "Embedded cleaner syntax error: $errors" }
 foreach($name in 'Test-MissingLocalExecutable','Get-MissingStartupEntries','Remove-ReviewedStartupEntries','Backup-StartupKey','Assert-CleanupHistoryFits','Save-CleanupHistory','Read-CleanupHistory','Restore-CleanupEntries') {
  $node=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
  if (-not $node) { throw "Embedded function missing: $name" }; . ([scriptblock]::Create($node.Extent.Text))
 }
 $key=$base.CreateSubKey($leaf)
 $missing=Join-Path $testDir 'missing.exe'; $command='"'+$missing+'"'
 $key.SetValue('candidate',$command,[Microsoft.Win32.RegistryValueKind]::String)
 $key.SetValue('untouched','original',[Microsoft.Win32.RegistryValueKind]::String)
 $entries=@(Get-MissingStartupEntries)
 if ($entries.Count -ne 1 -or $entries[0].Name -ne 'candidate') { throw 'Embedded discovery failed.' }
 if($null -ne $script:DiscoveryFolders){throw 'Discovery cache leaked beyond the scan.'}
 [IO.File]::WriteAllText($missing,'test-only placeholder')
 try {
  $fresh=Remove-ReviewedStartupEntries $key $entries
  if($fresh.Removed -ne 0 -or $fresh.Skipped -ne 1 -or $key.GetValue('candidate') -cne $command){throw 'Cleanup trusted stale discovery after the target reappeared.'}
 } finally {[IO.File]::Delete($missing)}
 Write-Host 'PASS discovery cache is cleared and removal rechecks a target that reappeared'
 $backup=Backup-StartupKey ('HKCU\'+$runPath) $testDir
 $record=[pscustomobject]@{Schema=1;Id=[guid]::NewGuid().ToString('N');Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;State='prepared';CompletedAt='';Backup=$backup;Entries=@($entries)}
 $history=Save-CleanupHistory $record $testDir
 $removed=Remove-ReviewedStartupEntries $key $entries
 if ($removed.Removed -ne 1 -or $removed.Errors -ne 0 -or $null -ne $key.GetValue('candidate') -or $key.GetValue('untouched') -cne 'original') { throw 'Embedded cleanup failed or changed another value.' }
 $prepared=Read-CleanupHistory $history $record.Sid
 if ($prepared.State -ne 'prepared') { throw 'Interrupted history was not readable.' }
 $restored=Restore-CleanupEntries $key @($prepared.Entries)
 if ($restored.Restored -ne 1 -or $restored.Errors -ne 0 -or $key.GetValue('candidate') -cne $command) { throw 'Interrupted cleanup could not be undone.' }
 $again=Restore-CleanupEntries $key @($prepared.Entries)
 if ($again.Restored -ne 0 -or $again.Skipped -ne 1) { throw 'Undo did not skip an existing value.' }
 $externalKey='HKCU\'+$runPath
 $key.SetValue('race-delete','old',[Microsoft.Win32.RegistryValueKind]::String)
 $hook=[Action]{ & "$env:SystemRoot\System32\reg.exe" add $externalKey /v race-delete /t REG_SZ /d new /f 2>$null | Out-Null; if($LASTEXITCODE -ne 0){throw 'Competing writer failed'} }
 $ok=$false; try {$ok=[RegistryAtomic]::Apply($key,'race-delete','old',$false,$hook)}catch{}
 if ($ok -or $key.GetValue('race-delete') -cne 'new') { throw 'Portable cleanup lost a competing update.' }
 $hook=[Action]{ & "$env:SystemRoot\System32\reg.exe" add $externalKey /v race-restore /t REG_SZ /d new /f 2>$null | Out-Null; if($LASTEXITCODE -ne 0){throw 'Competing writer failed'} }
 $ok=$false; try {$ok=[RegistryAtomic]::Apply($key,'race-restore','old',$true,$hook)}catch{}
 if ($ok -or $key.GetValue('race-restore') -cne 'new') { throw 'Portable undo overwrote a competing update.' }
 if (@($key.GetValueNames() | Where-Object { $_ -like 'HealthScan-Tx-*' }).Count) { throw 'Transaction marker remained after a conflict.' }
 $record.Entries=@(1..1001 | ForEach-Object {[pscustomobject]@{Name="entry$_";Command='x'}})
 $rejected=$false; try{Assert-CleanupHistoryFits $record}catch{$rejected=$true}
 if(-not $rejected -or $key.GetValue('candidate') -cne $command){throw 'Oversized selection was not rejected safely.'}
 $record.Entries=@(1..100 | ForEach-Object {[pscustomobject]@{Name="entry$_";Command=('x'*12000)}})
 $rejected=$false; try{Assert-CleanupHistoryFits $record}catch{$rejected=$true}
 if(-not $rejected -or $key.GetValue('candidate') -cne $command){throw 'Oversized history was not rejected safely.'}
 Write-Host 'PASS standalone executable: discovery, backup, interrupted recovery, undo, both external-process races, and history limits'
} finally {
 if ($key) { $key.Dispose() }
 if ($base) { if($leaf -match '^HealthScan-PortableAudit-[a-f0-9]{32}$'){$base.DeleteSubKey($leaf,$false)}; $base.Dispose() }
 if (Test-Path -LiteralPath $testDir) {
  $items=@(Get-ChildItem -LiteralPath $testDir -Force)
  $unexpected=@($items | Where-Object { $_.PSIsContainer -or ($_.Name -ne 'HealthScan.exe' -and $_.Name -notmatch '^(startup-run-[a-f0-9]{32}\.reg|cleanup-[a-f0-9]{32}\.json)$') })
  if ($unexpected.Count) { Write-Warning "Unexpected files; preserving $testDir" }
  else { foreach($item in $items){Remove-Item -LiteralPath $item.FullName -ErrorAction Stop}; Remove-Item -LiteralPath $testDir -ErrorAction Stop }
 }
}
