# Tests for HealthScan.exe as built and committed:
#  1. the exe carries byte-identical copies of Collect-Health.ps1 and index.html and the same version,
#     which proves it was built from the files beside it (run build\Build.ps1 when this fails);
#  2. its page building, browser choice, private-window policy check, quick-scan request rule, report
#     hand-over rule, -Version text and scan time limit, called directly in a copy loaded from bytes,
#     plus Build.ps1's version check on temporary copies;
#  3. end to end: -Version, then one real read-only scan with -NoBrowser, the page fetched over
#     127.0.0.1 exactly as a browser would, the embedded report checked, and the page checked again
#     after the grace period (served without the report).
# No browser is started and nothing is changed; only quick-scan requests that must be refused are sent.
# -ExerciseRegistryWindow additionally opens the real registry-cleaner window without removing entries.
# Step 3 runs the real collector (about a minute) and waits about 25 seconds more.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Exe.ps1
param([switch]$ExerciseRegistryWindow)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'HealthScan.exe'
$script:passed = 0
function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAILED: $message" }
    $script:passed++
}
if (-not (Test-Path -LiteralPath $exe)) { throw 'HealthScan.exe was not found; build it with build\Build.ps1.' }

# --- 1. The exe matches the sources -------------------------------------------------------------
$sha = [Security.Cryptography.SHA256]::Create()
# Why an embedded copy differs from the file on disk, or $null when they are the same. A difference
# in line endings only is a checkout problem (git converting LF to CRLF), not a stale exe.
function Get-EmbeddedMismatch([string]$name, [byte[]]$embedded, [byte[]]$onDisk) {
    if ([BitConverter]::ToString($sha.ComputeHash($embedded)) -eq [BitConverter]::ToString($sha.ComputeHash($onDisk))) { return $null }
    $a = [Text.Encoding]::UTF8.GetString($embedded).Replace("`r`n", "`n")
    $b = [Text.Encoding]::UTF8.GetString($onDisk).Replace("`r`n", "`n")
    if ([string]::Equals($a, $b, [StringComparison]::Ordinal)) {
        return "HealthScan.exe carries the same $name as the one on disk except for line endings (LF versus CRLF). " +
               "This usually means git converted line endings on checkout, not that the exe is stale: check git's core.autocrlf " +
               "setting and .gitattributes (*.ps1 and *.html are checked out with LF), then check the files out again."
    }
    return "HealthScan.exe carries a different $name than the one on disk; rebuild with build\Build.ps1."
}
$crlf = [Text.Encoding]::UTF8.GetBytes("a`r`nb`r`n"); $lf = [Text.Encoding]::UTF8.GetBytes("a`nb`n")
Assert ($null -eq (Get-EmbeddedMismatch 'x' $lf $lf)) 'Identical copies were reported as different.'
Assert ((Get-EmbeddedMismatch 'x' $lf $crlf) -like '*line endings*core.autocrlf*.gitattributes*') 'A line-ending-only difference was not explained as one.'
Assert ((Get-EmbeddedMismatch 'x' $lf ([Text.Encoding]::UTF8.GetBytes("a`nB`n"))) -like '*rebuild with build\Build.ps1*') 'A content difference was not reported as a stale exe.'

$asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))   # from bytes: the file is not locked
foreach ($name in 'Collect-Health.ps1', 'index.html', 'RegistryCleaner.ps1') {
    $s = $asm.GetManifestResourceStream($name)
    Assert ($null -ne $s) "HealthScan.exe does not embed $name."
    try { $ms = New-Object IO.MemoryStream; $s.CopyTo($ms); $embedded = $ms.ToArray() } finally { $s.Dispose() }
    $mismatch = Get-EmbeddedMismatch $name $embedded ([IO.File]::ReadAllBytes((Join-Path $root $name)))
    Assert ($null -eq $mismatch) $mismatch
}
# Versions are X.Y or X.Y.Z; a missing patch number counts as .0 (1.4 is 1.4.0).
function ConvertTo-FullVersion([string]$version) { if ($version -match '^\d+\.\d+$') { "$version.0" } else { $version } }
$collectorText = [IO.File]::ReadAllText((Join-Path $root 'Collect-Health.ps1'))
$collectorVersion = if ($collectorText -match "(?m)^\`$CollectorVersion='(\d+\.\d+(?:\.\d+)?)'") { $Matches[1] } else { $null }
Assert ($null -ne $collectorVersion) 'Could not read $CollectorVersion from Collect-Health.ps1.'
$v = $asm.GetName().Version
Assert ("$($v.Major).$($v.Minor).$($v.Build)" -eq (ConvertTo-FullVersion $collectorVersion) -and $v.Revision -eq 0) "HealthScan.exe is version $v but the collector is $collectorVersion."

# Build.ps1's version check accepts X.Y and X.Y.Z, treats 1.4 and 1.4.0 alike, and refuses mismatches.
$buildScript = Join-Path $PSScriptRoot 'Build.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$vt = Join-Path ([IO.Path]::GetTempPath()) ('HealthScanTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $vt 'build') | Out-Null
try {
    foreach ($case in @(
        @('1.4',   @('v1.4'),                    '1.4.0.0', '1.4.0.0', $true,  'two-part versions'),
        @('1.4.1', @('v1.4.1', 'Version 1.4.1'), '1.4.1.0', '1.4.1.0', $true,  'three-part versions'),
        @('1.4.0', @('v1.4', 'Version 1.4.0'),   '1.4.0.0', '1.4.0.0', $true,  'a trailing .0 against none'),
        @('1.4.1', @('Version 1.4.1'),           '1.4.1.0', '1.4.1.0', $true,  'only the About text in the page'),
        @('1.4.1', @('v1.4'),                    '1.4.1.0', '1.4.1.0', $false, 'an older page badge'),
        @('1.4.1', @('v1.4.1', 'Version 1.4'),   '1.4.1.0', '1.4.1.0', $false, 'an older About text'),
        @('1.4.1', @('v1.4.1'),                  '1.4.1.0', '1.4.0.0', $false, 'differing assembly attributes'),
        @('1.4.1', @('v1.4.1'),                  '1.4.1.3', '1.4.1.3', $false, 'a non-zero fourth part'),
        @('1.4',   @(),                          '1.4.0.0', '1.4.0.0', $false, 'no version in the page'))) {
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $vt 'Collect-Health.ps1'), "param()`n`$CollectorVersion='$($case[0])'`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $vt 'index.html'), '<html>' + (($case[1] | ForEach-Object { if ($_ -like 'v*') { "<span class=`"ver`">$_</span>" } else { "<p>$_ &middot; Windows edition</p>" } }) -join '') + '</html>', $utf8)
        [IO.File]::WriteAllText((Join-Path $vt 'build\HealthScan.cs'), "[assembly: AssemblyVersion(`"$($case[2])`")]`n[assembly: AssemblyFileVersion(`"$($case[3])`")]`n", $utf8)
        # The refusal arrives on stderr; it must not stop this script.
        & { $ErrorActionPreference = 'Continue'; & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $buildScript -VersionCheckOnly -AppFolder $vt 2>&1 | Out-Null }
        Assert (($LASTEXITCODE -eq 0) -eq $case[4]) "Build.ps1's version check $(if ($case[4]) { 'refused' } else { 'accepted' }) $($case[5]) (exit code $LASTEXITCODE)."
    }
} finally { Remove-Item -LiteralPath $vt -Recurse -Force }

# --- 2. Internals, called directly ----------------------------------------------------------------
$program = $asm.GetType('Program')
$flags = [Reflection.BindingFlags]'NonPublic, Static'
function Invoke-Program([string]$method, [object[]]$arguments) {
    $m = $program.GetMethod($method, $flags)
    if (-not $m) { throw "HealthScan.exe has no method $method." }
    try { return $m.Invoke($null, $arguments) }
    catch {
        $e = $_.Exception
        while (($e -is [Management.Automation.MethodInvocationException] -or $e -is [Reflection.TargetInvocationException]) -and $e.InnerException) { $e = $e.InnerException }
        throw $e
    }
}

# The report is placed into the page so that no value can end the script block or a JavaScript line.
$hostile = '{"a":"</script><script>alert(1)</script>","b":"x' + [char]0x2028 + 'y' + [char]0x2029 + 'z","c":"<!-- & -->"}'
$page = Invoke-Program 'BuildPage' @($hostile)
$start = $page.IndexOf('<script>window.HEALTHSCAN_HOST="exe";window.HEALTHSCAN_LIVE=')
Assert ($start -ge 0) 'BuildPage did not inject the report script.'
Assert (-not $page.Contains('<script src="latest-report.js"')) 'BuildPage left the saved-scan script tag in place.'
$jsonStart = $page.IndexOf('HEALTHSCAN_LIVE=', $start) + 'HEALTHSCAN_LIVE='.Length
$jsonEnd = $page.IndexOf(';</script>', $jsonStart)
$injected = $page.Substring($jsonStart, $jsonEnd - $jsonStart)
Assert (-not ($injected -match '[<>&\u2028\u2029]')) 'The injected report contains a character that could end the script block or line.'
$back = $injected | ConvertFrom-Json
Assert ($back.a -eq '</script><script>alert(1)</script>' -and $back.c -eq '<!-- & -->') 'The escaped report no longer decodes to the same values.'
Assert ($back.b -eq ('x' + [char]0x2028 + 'y' + [char]0x2029 + 'z')) 'Line separators did not survive escaping.'

# Browser choice: never a browser when elevated; a private window in a known browser; else the default.
Assert ((Invoke-Program 'LaunchPlan' @($true, $false, 'C:\b\chrome.exe')) -eq 'print') '-NoBrowser must only print the address.'
Assert ((Invoke-Program 'LaunchPlan' @($false, $true, 'C:\b\chrome.exe')) -eq 'elevated') 'An elevated exe must not start a browser.'
Assert ((Invoke-Program 'LaunchPlan' @($false, $true, $null)) -eq 'elevated') 'An elevated exe must not fall back to the default browser.'
Assert ((Invoke-Program 'LaunchPlan' @($false, $false, 'C:\b\chrome.exe')) -eq 'private') 'A known browser must get a private window.'
Assert ((Invoke-Program 'LaunchPlan' @($false, $false, $null)) -eq 'default') 'Without a known browser the default browser is the fallback.'
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Assert ((Invoke-Program 'IsElevated' @()) -eq $isAdmin) 'IsElevated disagrees with this process''s administrator status.'
foreach ($pair in @(@('C:\x\msedge.exe', '--inprivate'), @('C:\x\FIREFOX.EXE', '-private-window'), @('C:\x\opera.exe', '--private'),
                   @('C:\x\chrome.exe', '--incognito'), @('C:\x\brave.exe', '--incognito'), @('C:\x\vivaldi.exe', '--incognito'))) {
    Assert ((Invoke-Program 'PrivateSwitch' @($pair[0])) -eq $pair[1]) "Wrong private-window switch for $($pair[0])."
}

# Without the report: the page still says it is served by the exe (for the quick-scan button).
$plain = Invoke-Program 'BuildPage' @(,$null)
Assert ($plain.Contains('<script>window.HEALTHSCAN_HOST="exe";</script>')) 'BuildPage without a report does not mark the page as served by the exe.'
Assert (-not $plain.Contains('window.HEALTHSCAN_LIVE={') -and -not $plain.Contains('<script src="latest-report.js"')) 'BuildPage without a report still carries a report or the saved-scan tag.'
Assert ($plain.Length -lt $page.Length) 'BuildPage without a report is not smaller than the page with one.'

# The report is served until the first GET and for a short grace after it, then no longer.
$t0 = [DateTime]::UtcNow
Assert ((Invoke-Program 'ReportStillServed' @($false, [DateTime]::MinValue, $t0)) -eq $true) 'The report must be served before its first delivery.'
Assert ((Invoke-Program 'ReportStillServed' @($true, $t0, $t0.AddSeconds(5))) -eq $true) 'The report must still be served within the grace period.'
Assert ((Invoke-Program 'ReportStillServed' @($true, $t0, $t0.AddSeconds(11))) -eq $false) 'The report must not be served after the grace period.'
Assert ((Invoke-Program 'ReportStillServed' @($true, $t0, $t0.AddMinutes(20))) -eq $false) 'The report must not be served again minutes later.'

# The quick-scan request is accepted only with this exact Host and Origin; Origin: null never.
$qHost = '127.0.0.1:50123'; $qPath = '/0123456789abcdef0123456789abcdef/'
Assert ((Invoke-Program 'QuickScanAllowed' @('POST', "${qPath}quickscan", $qHost, "http://$qHost", $qHost, $qPath)) -eq $true) 'The dashboard''s own quick-scan request was refused.'
Assert ((Invoke-Program 'RegistryCleanerAllowed' @('POST', "${qPath}registrycleaner", $qHost, "http://$qHost", $qHost, $qPath)) -eq $true) 'The dashboard''s own cleaner request was refused.'
Assert ((Invoke-Program 'RegistryCleanerAllowed' @('POST', "${qPath}registrycleaner", $qHost, 'http://example.invalid', $qHost, $qPath)) -eq $false) 'A cross-origin cleaner request was accepted.'
Assert ((Invoke-Program 'RegistryCleanerAllowed' @('GET', "${qPath}registrycleaner", $qHost, "http://$qHost", $qHost, $qPath)) -eq $false) 'A GET cleaner request was accepted.'
Assert ((Invoke-Program 'RegistryCleanerAllowed' @('POST', '/wrong/registrycleaner', $qHost, "http://$qHost", $qHost, $qPath)) -eq $false) 'A cleaner request with the wrong token was accepted.'
foreach ($bad in @(
    @('POST', "${qPath}quickscan", $qHost, 'null'),
    @('POST', "${qPath}quickscan", $qHost, $null),
    @('POST', "${qPath}quickscan", $qHost, ''),
    @('POST', "${qPath}quickscan", $qHost, 'http://localhost:50123'),
    @('POST', "${qPath}quickscan", $qHost, 'https://127.0.0.1:50123'),
    @('POST', "${qPath}quickscan", $qHost, 'http://127.0.0.1:50124'),
    @('POST', "${qPath}quickscan", $qHost, 'http://example.invalid'),
    @('POST', "${qPath}quickscan", 'localhost:50123', "http://$qHost"),
    @('POST', "${qPath}quickscan", $null, "http://$qHost"),
    @('POST', "${qPath}QUICKSCAN", $qHost, "http://$qHost"),
    @('POST', "/$('0' * 32)/quickscan", $qHost, "http://$qHost"),
    @('POST', $qPath, $qHost, "http://$qHost"),
    @('GET', "${qPath}quickscan", $qHost, "http://$qHost"),
    @('post', "${qPath}quickscan", $qHost, "http://$qHost"))) {
    Assert ((Invoke-Program 'QuickScanAllowed' @($bad[0], $bad[1], $bad[2], $bad[3], $qHost, $qPath)) -eq $false) "A quick-scan request was accepted: $($bad[0]) $($bad[1]) Host '$($bad[2])' Origin '$($bad[3])'."
}

# -Version prints Major.Minor, plus the patch number when it is not 0.
Assert ((Invoke-Program 'VersionText' @([Version]'1.4.0.0')) -eq '1.4') 'Version 1.4.0.0 must print as 1.4.'
Assert ((Invoke-Program 'VersionText' @([Version]'1.4.1.0')) -eq '1.4.1') 'Version 1.4.1.0 must print as 1.4.1.'

# An organization policy that turns private windows off is recognised for the browsers that have one.
Assert ((Invoke-Program 'PrivateModePolicy' @('C:\x\MSEDGE.EXE'))[1] -eq 'InPrivateModeAvailability') 'Edge''s InPrivate policy is not checked.'
Assert ((Invoke-Program 'PrivateModePolicy' @('C:\x\msedge.exe'))[0] -eq 'Software\Policies\Microsoft\Edge') 'Edge''s policy key is wrong.'
Assert ((Invoke-Program 'PrivateModePolicy' @('C:\x\chrome.exe'))[0] -eq 'Software\Policies\Google\Chrome') 'Chrome''s policy key is wrong.'
Assert ((Invoke-Program 'PrivateModePolicy' @('C:\x\chrome.exe'))[1] -eq 'IncognitoModeAvailability') 'Chrome''s Incognito policy is not checked.'
Assert ((Invoke-Program 'PrivateModePolicy' @('C:\x\brave.exe'))[0] -eq 'Software\Policies\BraveSoftware\Brave') 'Brave''s policy key is wrong.'
Assert ((Invoke-Program 'PrivateModePolicy' @('C:\x\brave.exe'))[1] -eq 'IncognitoModeAvailability') 'Brave''s Incognito policy is not checked.'
Assert ($null -eq (Invoke-Program 'PrivateModePolicy' @('C:\x\vivaldi.exe'))) 'An unknown policy was assumed for Vivaldi.'
Assert ((Invoke-Program 'PolicyDisablesPrivate' @([int]1)) -eq $true) 'Policy value 1 must mean private windows are off.'
Assert ((Invoke-Program 'PolicyDisablesPrivate' @('1')) -eq $true) 'Policy value "1" must mean private windows are off.'
foreach ($ok in @([int]0, [int]2, '0', '2', 'x')) { Assert ((Invoke-Program 'PolicyDisablesPrivate' @($ok)) -eq $false) "Policy value '$ok' must not mean private windows are off." }
Assert ((Invoke-Program 'PolicyDisablesPrivate' @(,$null)) -eq $false) 'A missing policy value must not mean private windows are off.'
Assert ((Invoke-Program 'PrivateModeBlocked' @('C:\x\vivaldi.exe')) -eq $false) 'A browser without a known policy was reported as blocked.'
$askOnly = Invoke-Program 'PrivateWindowMessage' @($false)
Assert ($askOnly -like '*Asking your browser for a private window*' -and $askOnly -notlike '*Opening the results in a private*' -and $askOnly -notlike '*Warning*') "The private-window message overclaims or warns without cause: $askOnly"
$askBlocked = Invoke-Program 'PrivateWindowMessage' @($true)
Assert ($askBlocked -like '*Asking your browser for a private window*' -and $askBlocked -like '*Warning:*policy*normal window*') "A policy that turns private windows off is not warned about: $askBlocked"
# This computer's real setting, read the same way (machine policy before user policy).
foreach ($b in 'msedge.exe', 'chrome.exe', 'brave.exe') {
    $pol = Invoke-Program 'PrivateModePolicy' @("C:\x\$b")
    $expect = $false
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $val = (Get-ItemProperty -LiteralPath "$hive\$($pol[0])" -Name $pol[1] -ErrorAction SilentlyContinue).($pol[1])
        if ($null -ne $val) { $expect = ("$val".Trim() -eq '1'); break }
    }
    Assert ((Invoke-Program 'PrivateModeBlocked' @("C:\x\$b")) -eq $expect) "PrivateModeBlocked disagrees with this computer's policy for $b."
}

# Main always ends the process with Environment.Exit, so a thread left behind by an abandoned
# collector step cannot keep HealthScan.exe running.
$main = $program.GetMethod('Main', $flags)
$il = $main.GetMethodBody().GetILAsByteArray()
$exitsExplicitly = $false
for ($i = 0; $i -le $il.Length - 5; $i++) {
    if ($il[$i] -ne 0x28) { continue }   # call
    try { $callee = $main.Module.ResolveMethod([BitConverter]::ToInt32($il, $i + 1)) } catch { continue }
    if ($callee.DeclaringType.FullName -eq 'System.Environment' -and $callee.Name -eq 'Exit') { $exitsExplicitly = $true }
}
Assert $exitsExplicitly 'Main does not end the process with Environment.Exit.'

$fake = Join-Path ([IO.Path]::GetTempPath()) ('HealthScanTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fake | Out-Null
try {
    $chrome = Join-Path $fake 'chrome.exe'; [IO.File]::WriteAllBytes($chrome, [byte[]]@())
    $other = Join-Path $fake 'notabrowser.exe'; [IO.File]::WriteAllBytes($other, [byte[]]@())
    Assert ((Invoke-Program 'BrowserFromCommand' @("`"$chrome`" --single-argument %1")) -eq $chrome) 'A quoted known browser was not accepted.'
    if ($chrome -notmatch '\s') { Assert ((Invoke-Program 'BrowserFromCommand' @("$chrome -- %1")) -eq $chrome) 'An unquoted known browser was not accepted.' }
    Assert ($null -eq (Invoke-Program 'BrowserFromCommand' @("`"$other`" %1"))) 'An unknown program was accepted as a browser.'
    Assert ($null -eq (Invoke-Program 'BrowserFromCommand' @("`"$(Join-Path $fake 'gone\chrome.exe')`" %1"))) 'A missing browser was accepted.'
    Assert ($null -eq (Invoke-Program 'BrowserFromCommand' @('chrome.exe %1'))) 'A browser without a full path (resolved from the current folder) was accepted.'
    Assert ($null -eq (Invoke-Program 'BrowserFromCommand' @(''))) 'An empty command was accepted.'
    Assert ($null -eq (Invoke-Program 'BrowserFromCommand' @(,$null))) 'A missing command was accepted.'
} finally { Remove-Item -LiteralPath $fake -Recurse -Force }
$found = Invoke-Program 'FindBrowser' @()
if ($null -ne $found) {
    Assert ((Test-Path -LiteralPath $found) -and (@('msedge.exe','chrome.exe','firefox.exe','brave.exe','vivaldi.exe','opera.exe') -contains (Split-Path -Leaf $found).ToLower())) "FindBrowser returned an unexpected program: $found"
} else { $script:passed++ }

# The scan has an overall time limit with a clear message, and the parameters still reach the script.
$policyBefore = $env:PSExecutionPolicyPreference
$quick = 'param([switch]$EmitJson,[switch]$QuickScan) if($EmitJson){ ''{"quick":'' + [int][bool]$QuickScan + ''}'' }'
Assert ((Invoke-Program 'RunScript' @($quick, $false, [TimeSpan]::FromSeconds(60))) -eq '{"quick":0}') 'RunScript did not pass -EmitJson or return the report.'
Assert ((Invoke-Program 'RunScript' @($quick, $true, [TimeSpan]::FromSeconds(60))) -eq '{"quick":1}') 'RunScript did not pass -QuickScan.'
$slow = 'param([switch]$EmitJson,[switch]$QuickScan) Start-Sleep -Seconds 120; ''{}'''
$timer = [Diagnostics.Stopwatch]::StartNew()
$caught = $null
try { Invoke-Program 'RunScript' @($slow, $false, [TimeSpan]::FromSeconds(2)) | Out-Null } catch { $caught = $_.Exception }
$timer.Stop()
Assert ($caught -is [TimeoutException]) "A stalled scan did not end with a time-out (got: $caught)."
Assert ($caught.Message -like '*did not finish within 2 seconds*Nothing was changed*') "The time-out message is not clear: $($caught.Message)"
Assert ($timer.Elapsed.TotalSeconds -lt 20) "The time limit took $([int]$timer.Elapsed.TotalSeconds) s to end a stalled scan."
Assert ($env:PSExecutionPolicyPreference -eq $policyBefore) 'RunScript left PSExecutionPolicyPreference changed after a time-out.'

# --- 3. End to end ---------------------------------------------------------------------------------
$said = (& $exe -Version | Out-String).Trim()
$saidVersion = if ($said -match '^Total Computer Health Scan (\d+\.\d+(?:\.\d+)?)$') { $Matches[1] }
Assert ($LASTEXITCODE -eq 0 -and $saidVersion -eq (Invoke-Program 'VersionText' @($v)) -and (ConvertTo-FullVersion $saidVersion) -eq (ConvertTo-FullVersion $collectorVersion)) "-Version printed '$said' (exit code $LASTEXITCODE)."
& $exe -NoSuchSwitch | Out-Null
Assert ($LASTEXITCODE -eq 2) 'An unknown switch must exit with code 2 without scanning.'

function Invoke-Raw([int]$port, [string]$request) {
    $client = New-Object Net.Sockets.TcpClient('127.0.0.1', $port)
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $ms = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 65536
        while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $ms.Write($buffer, 0, $n) }
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    } finally { $client.Close() }
    $split = $text.IndexOf("`r`n`r`n")
    if ($split -lt 0) { throw "Incomplete HTTP response: $text" }
    [pscustomobject]@{
        Status = $text.Substring(0, $text.IndexOf("`r`n"))
        Head   = $text.Substring(0, $split)
        Body   = $text.Substring($split + 4)
    }
}

$psi = New-Object Diagnostics.ProcessStartInfo($exe, '-NoBrowser')
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$proc = [Diagnostics.Process]::Start($psi)
$lines = New-Object Collections.Generic.List[string]
try {
    $deadline = (Get-Date).AddMinutes(12)
    $url = $null
    while (-not $url) {
        $left = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($left -le 0) { throw 'HealthScan.exe -NoBrowser printed no address within 12 minutes.' }
        $read = $proc.StandardOutput.ReadLineAsync()
        if (-not $read.Wait($left)) { throw 'HealthScan.exe -NoBrowser printed no address within 12 minutes.' }
        if ($null -eq $read.Result) { throw "HealthScan.exe ended without printing an address:`n$($lines -join "`n")" }
        $lines.Add($read.Result)
        if ($read.Result -match '^http://127\.0\.0\.1:(\d+)(/[0-9a-f]{32}/)$') { $url = $read.Result; $port = [int]$Matches[1]; $path = $Matches[2] }
    }
    $hostName = "127.0.0.1:$port"
    Assert (($lines -join "`n") -like '*Scan complete.*') 'The exe did not say the scan was complete.'
    # A HEAD first: it must not count as the delivery, so the report is still there well after it.
    $headAt = Get-Date
    $head = Invoke-Raw $port "HEAD $path HTTP/1.1`r`nHost: $hostName`r`n`r`n"
    Assert ($head.Status -eq 'HTTP/1.1 200 OK' -and $head.Body.Length -eq 0) "HEAD of the page returned $($head.Status) with a body of $($head.Body.Length) characters."

    # Requests a browser or another site could make, which must all be refused without ending the wait.
    $refused = @(
        "GET /$('0' * 32)/ HTTP/1.1`r`nHost: $hostName`r`n`r`n",
        "GET $($path.TrimEnd('/')) HTTP/1.1`r`nHost: $hostName`r`n`r`n",
        "GET $path HTTP/1.1`r`nHost: localhost:$port`r`n`r`n",
        "GET $path HTTP/1.1`r`nHost: attacker.example`r`n`r`n",
        "GET $path HTTP/1.1`r`n`r`n",
        "POST $path HTTP/1.1`r`nHost: $hostName`r`nContent-Length: 0`r`n`r`n"
    )
    foreach ($r in $refused) {
        $resp = Invoke-Raw $port $r
        Assert ($resp.Status -eq 'HTTP/1.1 404 Not Found' -and $resp.Body.Length -eq 0) "Expected 404 for: $($r.Split("`r")[0]) / $(($r -split "`r`n")[1]); got $($resp.Status)"
    }
    Assert (-not $proc.HasExited) 'The exe stopped waiting before the page was delivered.'
    $wait = 11 - ((Get-Date) - $headAt).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }

    $getRequest = "GET $path HTTP/1.1`r`nHost: $hostName`r`nUser-Agent: Test-Exe`r`n`r`n"
    $get = Invoke-Raw $port $getRequest
    $firstGetAt = Get-Date
    Assert ($get.Status -eq 'HTTP/1.1 200 OK') "GET of the page returned $($get.Status)."
    # A browser repeating the request at once still gets the report.
    $again = Invoke-Raw $port $getRequest
    Assert ($again.Status -eq 'HTTP/1.1 200 OK' -and $again.Body.Contains('window.HEALTHSCAN_LIVE=')) 'A GET repeated within the grace period did not get the report.'
    Assert ($get.Head -match '(?m)^Referrer-Policy: same-origin\r?$') 'The page must use Referrer-Policy: same-origin, so the quick-scan button''s Origin is sent.'
    Assert ($get.Head -match "(?m)^Content-Security-Policy: default-src 'none';") 'The page lacks its Content-Security-Policy.'
    Assert ($get.Head -match '(?m)^Cache-Control: no-store') 'The page may be cached.'
    Assert ($get.Head -match '(?m)^Content-Type: text/html; charset=utf-8') 'The page has the wrong content type.'
    $body = $get.Body
    Assert ($body.Contains('<html') -and -not $body.Contains('<script src="latest-report.js"')) 'The served page is not the dashboard with the report swapped in.'
    $s0 = $body.IndexOf('window.HEALTHSCAN_LIVE=')
    Assert ($s0 -ge 0) 'The served page carries no report.'
    $s0 += 'window.HEALTHSCAN_LIVE='.Length
    $reportText = $body.Substring($s0, $body.IndexOf(';</script>', $s0) - $s0)
    Assert (-not ($reportText -match '[<>\u2028\u2029]')) 'The served report contains an unescaped character.'
    $report = $reportText | ConvertFrom-Json
    Assert ($report.schemaVersion -eq 1 -and $report.source -eq 'windows-collector') 'The served report has the wrong schema or source.'
    Assert ($report.collectorVersion -eq $collectorVersion) "The served report says collector $($report.collectorVersion), expected $collectorVersion."
    Assert (@($report.checks).Count -ge 5) "The served report has only $(@($report.checks).Count) checks."
    $badStatus = @($report.checks | Where-Object { @('pass', 'warning', 'unknown', 'info') -notcontains $_.status })
    Assert ($badStatus.Count -eq 0) "Checks with an invalid status: $(($badStatus | ForEach-Object { $_.name }) -join ', ')"
    $texts = ($report.checks | ForEach-Object { "$($_.name) $($_.detail) $($_.action)" }) -join "`n"
    Assert ($texts.IndexOf($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'The served report contains the user profile path.'
    Assert (-not ($texts -match 'S-1-5-21-\d+')) 'The served report contains a SID.'

    Assert (-not $proc.HasExited) 'The local session must remain available for the quick-scan button.'
    # Only refused quick-scan requests are sent: an accepted one would start an administrator prompt.
    foreach ($origin in 'Origin: http://example.invalid', 'Origin: null', "Origin: http://localhost:$port", '') {
        $originLine = if ($origin) { "$origin`r`n" } else { '' }
        $denied = Invoke-Raw $port "POST ${path}quickscan HTTP/1.1`r`nHost: $hostName`r`n${originLine}Content-Length: 0`r`n`r`n"
        Assert ($denied.Status -eq 'HTTP/1.1 404 Not Found') "A quick-scan request with '$origin' was not rejected."
    }
    foreach ($origin in 'Origin: http://example.invalid', 'Origin: null', '') {
        $originLine = if ($origin) { "$origin`r`n" } else { '' }
        $denied = Invoke-Raw $port "POST ${path}registrycleaner HTTP/1.1`r`nHost: $hostName`r`n${originLine}Content-Length: 0`r`n`r`n"
        Assert ($denied.Status -eq 'HTTP/1.1 404 Not Found') "A registry-cleaner request with '$origin' was not rejected."
    }
    if ($ExerciseRegistryWindow) {
        $opened = Invoke-Raw $port "POST ${path}registrycleaner HTTP/1.1`r`nHost: $hostName`r`nOrigin: http://$hostName`r`nContent-Length: 0`r`n`r`n"
        Assert ($opened.Status -eq 'HTTP/1.1 200 OK' -and $opened.Body -like '*cleanup opened*') 'The authorized registry-cleaner launch failed.'
    }

    # After the grace period the same address serves the dashboard without the report (after a
    # Clear report, a reload, or for the next person at this computer), still marked as the exe's page.
    $wait = 11 - ((Get-Date) - $firstGetAt).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    foreach ($method in 'GET', 'HEAD') {
        $late = Invoke-Raw $port "$method $path HTTP/1.1`r`nHost: $hostName`r`n`r`n"
        Assert ($late.Status -eq 'HTTP/1.1 200 OK') "A later $method of the page returned $($late.Status)."
        $length = if ($late.Head -match '(?m)^Content-Length: (\d+)') { [int]$Matches[1] } else { -1 }
        Assert ($length -gt 0 -and $length -lt [Text.Encoding]::UTF8.GetByteCount($body)) "A later $method announced $length bytes; expected the smaller page without the report."
        if ($method -eq 'GET') {
            Assert (-not $late.Body.Contains('window.HEALTHSCAN_LIVE={')) 'The report was served again after the grace period.'
            # Exactly the dashboard without a report, still marked as the exe's page for the quick-scan button.
            Assert ([string]::Equals($late.Body, $plain, [StringComparison]::Ordinal)) 'The later page is not the dashboard without the report.'
        }
    }
    Assert (-not $proc.HasExited) 'The exe must keep listening for the quick-scan button after the report was handed over.'
} finally {
    if (-not $proc.HasExited) { $proc.Kill() }
    $proc.Dispose()
}

Write-Host "$script:passed exe checks passed. No browser was started and no setting was changed."
