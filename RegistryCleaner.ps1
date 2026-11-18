# Review-only discovery followed by individually selected, backed-up cleanup.
# Only HKCU Run values with a simple, absolute local executable path are considered.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$runPath = 'Software\Microsoft\Windows\CurrentVersion\Run'

function Test-MissingLocalExecutable($path) {
 try {
  $path = [IO.Path]::GetFullPath($path)
  $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($path))
  if ($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady) { return $false }
  $parent = [IO.Path]::GetDirectoryName($path)
  if (-not [IO.Directory]::Exists($parent) -or [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { return $false }
  # Avoid junctions and symlinks, including ancestors that could lead to another volume.
  $dir = New-Object IO.DirectoryInfo $parent
  while ($dir) { if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }; $dir = $dir.Parent }
  # An inaccessible folder must not be mistaken for a missing file.
  $items=if($null -ne $script:DiscoveryFolders -and $script:DiscoveryFolders.ContainsKey($parent)){$script:DiscoveryFolders[$parent]}else{@([IO.Directory]::EnumerateFileSystemEntries($parent))}
  if($null -ne $script:DiscoveryFolders){$script:DiscoveryFolders[$parent]=$items}
  foreach ($item in $items) {
   if ([string]::Equals([IO.Path]::GetFileName($item), [IO.Path]::GetFileName($path), [StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
 } catch { return $false }
}
function Get-MissingStartupEntries {
 $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $false)
 if (-not $key) { return }
 try {
  $pathResults=@{}; $script:DiscoveryFolders=@{}
  foreach ($name in $key.GetValueNames()) {
   if (-not $name) { continue }
   $kind = $key.GetValueKind($name)
   if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String) { continue }
   $raw = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
   if ($raw -notmatch '^\s*(?:"([A-Za-z]:\\[^"\r\n]+\.exe)"|([A-Za-z]:\\[^\s"\r\n]+\.exe))\s*$') { continue }
   $path = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
   try {
    $path = [IO.Path]::GetFullPath($path)
    if(-not $pathResults.ContainsKey($path)){$pathResults[$path]=Test-MissingLocalExecutable $path}
    if (-not $pathResults[$path]) { continue }
    [pscustomobject]@{ Name=$name; Command=$raw; Path=$path }
   } catch { continue }
  }
 } finally { $key.Dispose(); $script:DiscoveryFolders=$null }
}
function Remove-ReviewedStartupEntries($key, $selected) {
 $removed = 0; $skipped = 0; $errors = 0
 $removedEntries = @()
 foreach ($entry in $selected) {
  try {
   if (-not (Test-MissingLocalExecutable $entry.Path)) { $skipped++; continue }
   if ([RegistryAtomic]::Apply($key, [string]$entry.Name, [string]$entry.Command, $false, $null)) { $removed++; $removedEntries += $entry } else { $skipped++ }
  } catch { $skipped++; $errors++ }
 }
 return [pscustomobject]@{ Removed=$removed; Skipped=$skipped; Errors=$errors; Entries=@($removedEntries) }
}
function Assert-CleanupHistoryFits($record) {
 if (@($record.Entries).Count -gt 1000) { throw 'Select no more than 1,000 entries per cleanup. No entries were removed.' }
 $json = $record | ConvertTo-Json -Depth 6
 # Reserve room for the completion timestamp and state change before any deletion.
 if ([Text.Encoding]::UTF8.GetByteCount($json) -gt (1MB - 1024)) { throw 'This selection is too large for cleanup history. Select fewer entries. No entries were removed.' }
}
function Save-CleanupHistory($record, $directory) {
 Assert-CleanupHistoryFits $record
 [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
 if ($record.Id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid cleanup identifier.' }
 $path = Join-Path $directory ('cleanup-' + $record.Id + '.json')
 $temp = Join-Path $directory ('cleanup-' + $record.Id + '-' + [guid]::NewGuid().ToString('N') + '.tmp')
 $previous = $temp + '.previous'
 try {
  $json = $record | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
  if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp, $path, $previous) } else { [IO.File]::Move($temp, $path) }
  return $path
 } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }; if ([IO.File]::Exists($previous)) { [IO.File]::Delete($previous) } }
}
function Restore-CleanupEntries($key, $entries) {
 $restored=0; $skipped=0; $errors=0
 foreach ($entry in $entries) {
  try {
   if (-not $entry.Name -or $entry.Name -isnot [string] -or $entry.Command -isnot [string] -or $entry.Command.Length -gt 32767) { $skipped++; continue }
   if ([RegistryAtomic]::Apply($key, $entry.Name, $entry.Command, $true, $null)) { $restored++ } else { $skipped++ }
  } catch { $skipped++; $errors++ }
 }
 return [pscustomobject]@{ Restored=$restored; Skipped=$skipped; Errors=$errors }
}
function Read-CleanupHistory($path, $expectedSid) {
 $item=Get-Item -LiteralPath $path -ErrorAction Stop
 if ($item.Length -gt 1MB -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'History file is not supported.' }
 $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
 if ($record.Schema -ne 1 -or @('prepared','completed') -notcontains $record.State -or $record.Id -notmatch '^[a-f0-9]{32}$' -or $item.Name -ne ('cleanup-'+$record.Id+'.json') -or $record.Sid -ne $expectedSid -or @($record.Entries).Count -gt 1000) { throw 'History is invalid or belongs to another account.' }
 foreach($entry in @($record.Entries)) { if (-not $entry.Name -or $entry.Name -isnot [string] -or $entry.Command -isnot [string] -or $entry.Command.Length -gt 32767) { throw 'History contains invalid entries.' } }
 return $record
}
function Test-ElevatedOtherAccount {
 try {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return $false }
  $console = [string](Get-CimInstance -ClassName Win32_ComputerSystem -Property UserName -OperationTimeoutSec 10 -ErrorAction Stop).UserName
  return [bool]($console -and -not [string]::Equals($console, $identity.Name, [StringComparison]::OrdinalIgnoreCase))
 } catch { return $false }
}
function Backup-StartupKey($sourceKey, $backupDir) {
 [void](New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop)
 $backup = Join-Path $backupDir ('startup-run-' + [guid]::NewGuid().ToString('N') + '.reg')
 & "$env:SystemRoot\System32\reg.exe" export $sourceKey $backup /y | Out-Null
 if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Item -LiteralPath $backup).Length -eq 0) { throw 'Backup failed; no entries were removed.' }
 return $backup
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Startup registry cleanup'; $form.Size = New-Object Drawing.Size(820,520)
$form.StartPosition = 'CenterScreen'; $form.MinimumSize = New-Object Drawing.Size(680,420)
$intro = New-Object Windows.Forms.Label
$intro.Text = 'Review missing per-user startup programs for ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name + '. Only simple local executable paths are shown. Select entries to remove; a backup of your entire current-user Run key is saved first.'
# Elevated with another administrator account, HKCU belongs to that account, not the signed-in user.
if (Test-ElevatedOtherAccount) { $intro.Text += ' WARNING: this window runs as administrator under a different account from the one signed in, so it shows and changes that account''s startup entries. Close it and run HealthScan.exe as yourself if that is not what you want.' }
$intro.AutoSize = $false; $intro.SetBounds(16,16,770,48); $intro.Anchor = 'Top,Left,Right'
$list = New-Object Windows.Forms.ListView
$list.SetBounds(16,68,770,315); $list.Anchor = 'Top,Bottom,Left,Right'; $list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.GridLines = $true
[void]$list.Columns.Add('Startup entry',190); [void]$list.Columns.Add('Missing executable',550)
$status = New-Object Windows.Forms.Label
$status.SetBounds(16,392,770,42); $status.Anchor = 'Bottom,Left,Right'; $status.Text = 'Nothing has been changed.'
$refresh = New-Object Windows.Forms.Button
$refresh.Text = 'Scan again'; $refresh.SetBounds(16,438,105,32); $refresh.Anchor = 'Bottom,Left'
$details = New-Object Windows.Forms.Button
$details.Text = 'Details'; $details.SetBounds(128,438,80,32); $details.Anchor = 'Bottom,Left'
$history = New-Object Windows.Forms.Button
$history.Text = 'History & undo'; $history.SetBounds(215,438,120,32); $history.Anchor = 'Bottom,Left'
$backups = New-Object Windows.Forms.Button
$backups.Text = 'Backups'; $backups.SetBounds(342,438,80,32); $backups.Anchor = 'Bottom,Left'
$remove = New-Object Windows.Forms.Button
$remove.Text = 'Remove selected'; $remove.SetBounds(565,438,135,32); $remove.Anchor = 'Bottom,Right'
$close = New-Object Windows.Forms.Button
$close.Text = 'Close'; $close.SetBounds(708,438,78,32); $close.Anchor = 'Bottom,Right'; $close.Add_Click({ $form.Close() })
$details.Add_Click({
 if ($list.SelectedItems.Count -ne 1) { [void][Windows.Forms.MessageBox]::Show($form, 'Select one entry to see its details.', 'Candidate details'); return }
 $entry=$list.SelectedItems[0].Tag
 [void][Windows.Forms.MessageBox]::Show($form, "Name: $($entry.Name)`n`nOriginal command: $($entry.Command)`n`nMissing executable: $($entry.Path)`n`nThis entry was listed because its simple local executable path could not be found in an accessible folder. Confirm it is no longer needed before removal.", 'Candidate details')
})
$history.Add_Click({
 $dir=Join-Path $env:LOCALAPPDATA 'HealthScan\registry-backups'
 $dialog=New-Object Windows.Forms.Form; $dialog.Text='Cleanup history and undo'; $dialog.Size=New-Object Drawing.Size(760,490); $dialog.StartPosition='CenterParent'
 $note=New-Object Windows.Forms.Label; $note.SetBounds(15,12,710,40); $note.Text='Choose a cleanup or interrupted recovery, then select entries to restore. Existing values are skipped.'
 $runs=New-Object Windows.Forms.ComboBox; $runs.SetBounds(15,55,710,28); $runs.DropDownStyle='DropDownList'
 $entries=New-Object Windows.Forms.CheckedListBox; $entries.SetBounds(15,95,710,265); $entries.CheckOnClick=$true
 $restore=New-Object Windows.Forms.Button; $restore.Text='Restore selected'; $restore.SetBounds(455,385,135,32)
 $done=New-Object Windows.Forms.Button; $done.Text='Close'; $done.SetBounds(600,385,125,32); $done.Add_Click({$dialog.Close()})
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $records=@(); $unreadable=0
 if (Test-Path -LiteralPath $dir) {
  foreach($f in @(Get-ChildItem -LiteralPath $dir -Filter 'cleanup-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
   try { $r=Read-CleanupHistory $f.FullName $sid; $records += $r; $description=if($r.State -eq 'prepared'){'INTERRUPTED: possible removals; review carefully'}else{$r.CompletedAt+'  |  '+@($r.Entries).Count+' removed'}; [void]$runs.Items.Add(($description+'  |  '+$r.Backup)) } catch { $unreadable++ }
  }
 }
 if($unreadable){$note.Text="$unreadable history file(s) could not be read. Use Backups to inspect available recovery files."}
 $runs.Add_SelectedIndexChanged({
  $entries.Items.Clear(); if($runs.SelectedIndex -lt 0){return}; $rec=$records[$runs.SelectedIndex]
  foreach($entry in @($rec.Entries)){ [void]$entries.Items.Add(($entry.Name+'  |  '+$entry.Command)) }
 })
 $restore.Add_Click({
  if($runs.SelectedIndex -lt 0 -or $entries.CheckedIndices.Count -eq 0){ [void][Windows.Forms.MessageBox]::Show($dialog,'Select a cleanup and the entries to restore.','Undo cleanup'); return }
  $rec=$records[$runs.SelectedIndex]; $chosen=@($entries.CheckedIndices | ForEach-Object { @($rec.Entries)[$_] })
  $warning=if($rec.State -eq 'prepared'){"`n`nThis cleanup was interrupted. The list includes all selected entries, including entries that might never have been removed. Restore only entries you have independently verified."}else{''}
  $answer=[Windows.Forms.MessageBox]::Show($dialog,"Restore $($chosen.Count) selected startup entry(s)? Existing values will be skipped.$warning",'Confirm restore',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
  if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
  try { $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath,$true); if(-not $key){throw 'Startup key is unavailable.'}; try {$result=Restore-CleanupEntries $key $chosen} finally {$key.Dispose()}; [void][Windows.Forms.MessageBox]::Show($dialog,"Restored: $($result.Restored)`nSkipped: $($result.Skipped)`nTransaction errors: $($result.Errors). No unsafe fallback was used.",'Undo cleanup') } catch { [void][Windows.Forms.MessageBox]::Show($dialog,"Restore failed: $($_.Exception.Message)",'Undo cleanup') }
 })
 $dialog.Controls.AddRange(@($note,$runs,$entries,$restore,$done)); if($runs.Items.Count){$runs.SelectedIndex=0}else{$note.Text=if($unreadable){"$unreadable history file(s) could not be read. Use Backups to inspect recovery files."}else{'No cleanup history is available. Earlier .reg backups can be inspected using Backups.'}}; [void]$dialog.ShowDialog($form)
})
$backups.Add_Click({
 $dir=Join-Path $env:LOCALAPPDATA 'HealthScan\registry-backups'
 $dialog=New-Object Windows.Forms.Form; $dialog.Text='Registry backups'; $dialog.Size=New-Object Drawing.Size(780,540); $dialog.StartPosition='CenterParent'
 $note=New-Object Windows.Forms.Label; $note.SetBounds(15,10,735,35); $note.Text='Select a backup to inspect its contents. Backups may contain private startup commands.'
 $files=New-Object Windows.Forms.ListBox; $files.SetBounds(15,48,735,110)
 $preview=New-Object Windows.Forms.TextBox; $preview.SetBounds(15,168,735,260); $preview.Multiline=$true; $preview.ReadOnly=$true; $preview.ScrollBars='Both'; $preview.WordWrap=$false
 $delete=New-Object Windows.Forms.Button; $delete.Text='Delete selected backup'; $delete.SetBounds(15,445,165,32)
 $done=New-Object Windows.Forms.Button; $done.Text='Close'; $done.SetBounds(625,445,125,32); $done.Add_Click({$dialog.Close()})
 $items=@(); if(Test-Path -LiteralPath $dir){$items=@(Get-ChildItem -LiteralPath $dir -Filter 'startup-run-*.reg' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^startup-run-[a-f0-9]{32}\.reg$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Sort-Object LastWriteTime -Descending); foreach($item in $items){[void]$files.Items.Add(($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')+'  |  '+$item.Name))}}
 $files.Add_SelectedIndexChanged({ if($files.SelectedIndex -lt 0){return}; try {$item=$items[$files.SelectedIndex]; if($item.Length -gt 2MB){throw 'Backup is too large to preview.'}; $preview.Text=Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop} catch {$preview.Text='Unable to preview this backup.'} })
 $delete.Add_Click({ if($files.SelectedIndex -lt 0){return}; $item=$items[$files.SelectedIndex]; $answer=[Windows.Forms.MessageBox]::Show($dialog,"Permanently delete $($item.Name)? This cannot be undone.",'Delete backup',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning); if($answer -ne [Windows.Forms.DialogResult]::Yes){return}; try {Remove-Item -LiteralPath $item.FullName -ErrorAction Stop; $dialog.Close()} catch {[void][Windows.Forms.MessageBox]::Show($dialog,'The backup could not be deleted.','Registry backups')} })
 $dialog.Controls.AddRange(@($note,$files,$preview,$delete,$done)); [void]$dialog.ShowDialog($form)
})
$scan = {
 $list.Items.Clear()
 try {
  $entries = @(Get-MissingStartupEntries)
  foreach ($entry in $entries) { $item = New-Object Windows.Forms.ListViewItem($entry.Name); [void]$item.SubItems.Add($entry.Path); $item.Tag = $entry; [void]$list.Items.Add($item) }
  $status.Text = "$($entries.Count) potential missing startup target(s). Entries with arguments, variables, or unavailable folders are not evaluated."
 } catch { $status.Text = 'The startup registry key could not be read. No entries were changed.' }
}
$refresh.Add_Click($scan)
$remove.Add_Click({
 $selected = @($list.CheckedItems | ForEach-Object { $_.Tag })
 if (-not $selected.Count) { [void][Windows.Forms.MessageBox]::Show($form, 'Select the entries you want to remove first.', 'Startup registry cleanup'); return }
 $answer = [Windows.Forms.MessageBox]::Show($form, "Remove $($selected.Count) selected startup entry(s)? A backup of the current-user Run key will be saved under Local AppData before changes.", 'Confirm startup cleanup', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
 if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
 $backup = $null
 try {
  $backupDir = Join-Path $env:LOCALAPPDATA 'HealthScan\registry-backups'
  $backup = Backup-StartupKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' $backupDir
  $record=[pscustomobject]@{Schema=1;Id=[guid]::NewGuid().ToString('N');Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;State='prepared';CompletedAt='';Backup=$backup;Entries=@($selected)}
  Assert-CleanupHistoryFits $record
  [void](Save-CleanupHistory $record $backupDir)
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runPath, $true)
  if (-not $key) { throw 'The startup registry key is unavailable.' }
  try {
   $result = Remove-ReviewedStartupEntries $key $selected
  } finally { $key.Dispose() }
  $record.State='completed'; $record.CompletedAt=[DateTime]::Now.ToString('o'); $record.Entries=@($result.Entries)
  [void](Save-CleanupHistory $record $backupDir)
  & $scan
  $status.Text = "Removed $($result.Removed); skipped $($result.Skipped); transaction errors $($result.Errors). Backup: $backup"
  [void][Windows.Forms.MessageBox]::Show($form, "Removed: $($result.Removed)`nSkipped: $($result.Skipped)`nTransaction errors: $($result.Errors). No unsafe fallback was used.`n`nBackup: $backup`n`nUse History & undo to review recovery options.", 'Startup registry cleanup')
 } catch {
  $message = "Cleanup stopped: $($_.Exception.Message)`nNo further entries were removed."
  if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) { $message += "`n`nBackup: $backup" }
  [void][Windows.Forms.MessageBox]::Show($form, $message, 'Startup registry cleanup')
 }
})
$form.Controls.AddRange(@($intro,$list,$status,$refresh,$details,$history,$backups,$remove,$close))
$form.Add_Shown($scan)
[void]$form.ShowDialog()
