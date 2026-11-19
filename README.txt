TOTAL COMPUTER HEALTH SCAN - LOCAL WINDOWS EDITION

Nothing to install. The scan only reads status: it changes no settings,
uploads nothing, and by default writes no report and no file of its own.
Optional local history saves a completed report only when you check the box
in the progress window. Reports are JSON files under
%LOCALAPPDATA%\HealthScan\scan-history. Open local history opens that folder;
use Import report in the dashboard to reopen a saved scan. The choice is
off by default for every run. Cancel stops collection without saving a report.
The progress bar indicates activity; current step and elapsed time are shown.

Another exception is the optional startup cleanup in HealthScan.exe (see
below). It never runs during a scan: it changes only the startup entries you
tick and confirm, and saves a backup file first.

SINGLE FILE: HealthScan.exe
Double-click HealthScan.exe. That one file is the whole tool: copy it to a
folder that only you can change (your Desktop, your own USB stick, a
read-only share) and run it. It needs nothing else and nothing installed; it
uses the .NET Framework and Windows PowerShell that are part of Windows 10
and 11.

It runs the scan (about 15 seconds), then asks your browser (Edge, Chrome,
Firefox, Brave, Vivaldi or Opera) to open the results in a private window.
The browser decides whether the window really is private. If your
organization has turned private windows off by policy in Edge, Chrome or
Brave, the exe warns that the results will open in a normal window; other
policies or browsers can also give a normal window without a warning. If
none of these browsers is found, your default browser opens the results in
a normal window and the exe says so. In a normal window, installed browser
extensions can read the page and the address stays in the browser's
history (opened again later, it shows no report; see below).

A scan with the exe saves no report and creates no file of its own. The results page is
handed to the browser over a local-only address (127.0.0.1) that nothing
outside this computer can reach. Only requests for one unguessable address
are answered, and the page is marked not to be cached. If no browser asks
for the page within 2 minutes, the results are discarded. The report is
handed over once: it goes to the first page load and to any repeat of that
request within 10 seconds. After that, reloading the page or opening the
address again shows the dashboard without the report, so anyone on this
computer who has the address can read the report only during those first
seconds. Use "Export JSON" to keep a copy, and run HealthScan.exe again for a
new scan. The exe window stays open for 30 minutes after the page is
delivered so the dashboard's "Run Defender quick scan" button works, then
the exe exits; you can close the window sooner.

If a part of Windows stops answering, slow steps are skipped one by one (see
NOTES), and the exe stops the whole scan, a quick scan included, after 10
minutes and shows no results. To cancel sooner, press Ctrl+C or close the window.

From a Command Prompt opened in the exe's folder (in Windows PowerShell,
type .\HealthScan.exe instead):
   HealthScan.exe -QuickScan   run a Microsoft Defender quick scan first and
                               wait for it, then scan as usual. This needs an
                               administrator Command Prompt and can take
                               several minutes.
   HealthScan.exe -NoBrowser   print the local address instead of opening a
                               browser
   HealthScan.exe -Version     print the version and exit

An administrator Command Prompt starts in C:\Windows\System32, so give the
exe's full path, in quotes if it contains spaces, for example:
   "D:\HealthScan\HealthScan.exe" -QuickScan
When HealthScan.exe runs as administrator it does not open a browser,
because a browser started from it would run as administrator too. It prints
the address instead: open it in your browser, preferably in a private
window, within 2 minutes.

The dashboard's "Review startup registry" button opens an optional cleaner
for this Windows user's startup entries. It lists only simple absolute paths
to missing executables on available fixed drives. Entries with arguments,
environment variables, network paths, inaccessible folders, or linked folders
are skipped. Review the list, check only entries you recognize, then explicitly
confirm removal. Before removal, the entire current-user Run key is exported to
%LOCALAPPDATA%\HealthScan\registry-backups. The backup contains startup command
data; keep it private. Review and import the .reg backup in Windows to restore.
Entries are checked again before removal and skipped if they changed or the
target is no longer clearly missing. No entries are removed during scanning.
The standalone entry point is HealthScan.exe -RegistryCleaner. This cleanup
feature changes selected startup entries only when explicitly confirmed.
The cleaner's Details button shows the original command and why an entry was
listed. History & undo lists completed cleanup sessions and can restore only
the selected removed values; values that already exist are skipped. Cleanup
history and backups are stored locally in the registry-backups folder and may
contain private command lines. An interrupted cleanup appears as an uncertain
recovery item: its list can include entries that were never removed, so verify
each entry before restoring it. Its .reg backup remains available. Older backups
created before history was added can be inspected in Backups, but cannot be
selectively restored through History & undo. Backups can be previewed or
individually deleted after confirmation. Cleanup and restore use conditional
Windows registry transactions; if a transaction is unavailable or conflicts
with another writer, the entry is skipped without an unsafe fallback. Cleanup
selections are limited to 1,000 entries and must fit the history size limit.
It changes the startup entries of the Windows account it runs as, and shows
that account's name. If HealthScan.exe was started as administrator with a
different account, the cleanup warns about it; close it and run
HealthScan.exe as yourself instead.

The dashboard's "Run Defender quick scan" button starts a new HealthScan
window with -QuickScan and asks Windows for administrator approval. That
window runs as administrator, so follow its instructions to open its updated
report. The button works only while the first HealthScan window is still
open, that is for up to 30 minutes after the results page was delivered;
after that, run HealthScan.exe again to use it. The button is accepted only
from the dashboard page that this HealthScan window served.

Notes on the exe:
- It is not code-signed. A copy downloaded from the internet will show
  "Windows protected your PC" (choose More info > Run anyway), and some
  antivirus products are suspicious of unsigned programs.
- On Windows 11 PCs where Smart App Control is turned on, Windows blocks the
  unsigned exe outright, with no "Run anyway" option, and unblocking the file
  does not change that. Use the script version instead (unblock the ZIP
  before extracting, then double-click Open-HealthScan.cmd), which should
  still work. Leave Smart App Control on.
- Like any .NET Framework program, HealthScan.exe reads a file named
  HealthScan.exe.config placed next to it. Run it from a folder that other
  people cannot write to, not from a shared or public folder.
- Like the launcher below, it lets PowerShell load Windows' own modules for
  the duration of the scan only. No setting is changed, and a policy enforced
  by your organization still applies.
- Windows keeps its own record that a scan ran; see "Limits on 'writes
  nothing'" below. The exe cannot turn that off without changing system
  settings.
- The scan script and dashboard inside it are the same Collect-Health.ps1 and
  index.html in this folder. To rebuild it after changing them, open Windows
  PowerShell or a Command Prompt in this folder and run:
     powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build.ps1
  It uses the compiler built into Windows; nothing is installed, and the
  bypass applies to that one process only. It checks that the new exe starts
  and carries identical copies of the two files. The source is
  build\HealthScan.cs.

The rest of this file describes the script version, which does the same scan
without the exe.

QUICK START WITH THE SCRIPTS (ONE CLICK)
1. Extract this ZIP into any folder (for example D:\HealthScan). A USB stick
   or a read-only folder works too.
2. Review Collect-Health.ps1 before running it.
3. Double-click Open-HealthScan.cmd.
   It runs the collector (about 15 seconds) and asks your browser to open
   the dashboard, with the new report loaded, in a private window.

   The scan tool writes no report and no file of its own. The report is
   handed to the browser in the page address, and a private window is asked
   for so the browser does not keep that address in its history; the
   browser decides whether the window really is private. The dashboard
   marks such a report "FROM PAGE ADDRESS". Use "Export JSON" in the
   dashboard to keep a copy; reloading or closing the page clears it.

   Limits on "writes nothing":
   - If private browsing is turned off by policy, the browser opens a normal
     window and its history will hold the report until you clear it. Both
     the launcher and the exe warn when they find such a policy for Edge,
     Chrome or Brave. (The exe's address in history gives no report after
     the first page load.)
   - On a work-managed PC with process monitoring, the report can be recorded
     by that monitoring, because it is passed to the browser as a start-up
     argument.
   - Windows keeps its own record that a scan ran. The "Windows PowerShell"
     event log notes that PowerShell was started (by Open-HealthScan.cmd or
     HealthScan.exe). On PCs with PowerShell logging turned on (common on
     work-managed PCs) the text of the scan script is logged too. PowerShell
     module logging can also record pieces of report text that pass through
     PowerShell commands while the scan works, such as pending update titles
     and security product names. The finished report itself is handed to
     files, the clipboard and the browser without going through those
     commands, except on PCs with application control (see NOTES), where the
     scan has to use them and the log can hold the whole report.
   - Windows PowerShell keeps its usual small housekeeping files
     (ModuleAnalysisCache and StartupProfileData-* under
     %LOCALAPPDATA%\Microsoft\Windows\PowerShell). None of them contain the
     report.

   If the report cannot be handed over directly, it is copied to the
   clipboard instead (replacing what was there): choose "Paste report" in the
   dashboard and press Ctrl+V. It stays on the clipboard, and in Windows
   clipboard history or sync if those are on, until you copy something else.

   The launcher starts PowerShell with "-ExecutionPolicy Bypass" for that one
   process only. No system or user setting is changed, and an execution policy
   enforced by your organization still applies. If the collector cannot run,
   the dashboard opens without a new report; use the manual steps below.

   If Windows shows "Windows protected your PC" for a downloaded copy,
   right-click the ZIP before extracting, choose Properties, tick Unblock,
   then extract again.

KEEPING A HISTORY (OPTIONAL)
In Windows PowerShell, go to the app folder and run the launcher, for example:
   cd "D:\HealthScan"
   .\Open-HealthScan.cmd -SaveReport
or, from a Command Prompt, using the full path, for example:
   "D:\HealthScan\Open-HealthScan.cmd" -SaveReport
(A switch cannot be added by double-clicking.) This saves each report in the
reports\ folder, and latest-report.js holds the most recent one so the
dashboard shows it whenever index.html is opened. A saved scan that is more
than a few minutes old is clearly marked with its age. "Clear report" in the
dashboard clears the current tab only; to remove saved reports, delete
latest-report.js and the reports\ folder.

MANUAL STEPS
1. Open index.html in Edge or Chrome.
2. Open Windows PowerShell, go to the app folder, and run the collector.
   Windows does not run scripts by default, so start it like this; the
   bypass lasts for this one run and changes no setting:
   cd "D:\HealthScan"
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-Health.ps1
   (Use the folder you extracted to.)
3. Import the ComputerHealth JSON report from your Desktop into the dashboard.
   The collector prints the path it used. Delete the file when you no
   longer need it.

If script execution is blocked, follow your organization's approved process.

Saved reports and OneDrive: on many Windows 11 PCs OneDrive backs up the
Desktop and Documents folders. A report saved there (manual steps), or in an
app folder inside OneDrive (-SaveReport), is copied to your OneDrive cloud
storage by OneDrive; the collector says so when this applies. This tool
itself uploads nothing.

OPTIONAL DEFENDER QUICK SCAN (as administrator)
-QuickScan runs a Microsoft Defender quick scan first and waits for it to
finish, which can take several minutes, then runs the usual scan. Leave the
window open until it is done. An administrator window starts in
C:\Windows\System32, so use the app folder's full path.

From an administrator Command Prompt, for example:
   "D:\HealthScan\Open-HealthScan.cmd" -QuickScan
A scan that runs as administrator does not open a browser, because a browser
started from it would run as administrator too. Instead it copies the report
to the clipboard and prints the path of index.html: open that file yourself
from File Explorer, choose "Paste report" and press Ctrl+V. If you add
-SaveReport as well, it saves the report in reports\ and writes
latest-report.js, so opening index.html shows the new report.

Or, in an administrator Windows PowerShell, for a JSON file to import:
   cd "D:\HealthScan"
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-Health.ps1 -QuickScan

If you approve the administrator prompt with a different administrator
account, the scan runs as that account: per-user results such as startup
apps describe that account, and the manual steps save the report in the app
folder's reports\ instead of a Desktop. The collector prints a note when this
happens.

READING THE RESULTS
- The dashboard includes a scored-check ring, device summary,
  and a next-steps panel that jumps directly to checks needing attention.
- Use Protection, Storage, System, and Updates to browse by category. Search
  matches check names, details, and suggested actions; press / to jump to
  Search and Escape to clear it. Status tabs and the four summary tiles
  filter the results; Reset filters restores the full view.
- Snapshot age refreshes every 30 seconds and when you return to the tab.
  Reports older than 10 minutes are marked as earlier snapshots; timestamps
  more than 10 minutes ahead prompt you to check the clock.
- A report handed over in the page address is marked "FROM PAGE ADDRESS".
  Open-HealthScan.cmd works this way, but any link to index.html could carry
  a report, so if you did not just run the scan, treat it as unverified.
- Explore demo and Clear report ask before replacing a new scan that has not
  been exported. Import report and Paste report ask too, once you have chosen
  or pasted a valid report; an invalid one leaves the scan as it was.
- The moon/sun button switches light and dark appearance for the current tab.
  No preference or report is stored by the dashboard automatically.
- Print report includes every check and its suggested next step, even if the
  screen is filtered. The previous view is restored after printing or cancelling.
  You can choose your browser's Save as PDF destination in the print dialog.
  Before saving a PDF to share, turn off "Headers and footers" there: some
  browsers print the page address, which can include your Windows user name.
- Checks that need attention are listed first, each with a next step and,
  where one exists, a button that opens the matching Windows settings page.
  Your browser may ask before opening it. Passed checks are folded into one
  line you can expand.
- Informational checks (for example, the last quick scan time) are listed but
  do not count toward the checks-passed score.

COMPARING TWO SCANS
1. Run a new scan, or import the newer JSON report as your current snapshot.
2. Under "See what changed", choose "Compare with older report" and select a
   JSON report collected earlier from the same computer.
3. Review improved, worsened, and other changed checks. Expand a row for its
   older and current details. Unchanged checks are folded together.

Only Attention-to-Passed is an improvement, and only Passed-to-Attention is
a worsening. Unknown/Info transitions are "Status changed". New checks and
checks missing from the current report are explicit; missing does not mean fixed.
Comparisons match the computer name (case-insensitive), not a hardware ID.
Checks match by optional stable identifier, or by name for older reports.
Different device names, mixed demo/real reports, newer baselines, and ambiguous
duplicate checks are rejected without losing the existing report or comparison.
The computer name is kept in the report as Windows gives it (on one line, at
most 64 characters), so reports from the same PC can be paired.

Both reports stay in this tab only. Nothing is saved or uploaded automatically.
Export JSON keeps the CURRENT snapshot; Print report includes the comparison.
Importing a new current report, clearing it, or selecting Remove comparison
clears the older comparison. Explore demo includes a fictional comparison.

NOTES
- Running as administrator is optional. Without it, drive encryption is read
  from the status File Explorer shows, drive wear and temperature are left
  out, and a quick scan cannot be started.
- A report contains the computer name, the Windows edition, drive model
  names, the antivirus product name, the titles of pending updates and the
  check results. The computer name is kept unchanged (it identifies the PC
  when two reports are compared), so if it contains your name, so does the
  report. Your Windows user name is removed from every other name the
  report carries. It is built never to contain error message text, file
  paths, user names (apart from any inside the computer name), account SIDs
  or event log message text.
- Slow steps: when a part of Windows takes more than 10 seconds to answer,
  the scan prints "Still waiting for Windows to answer: ...". After that
  step's time limit (20 seconds to 2 minutes) it prints "Skipped: ..." and
  that check shows as unknown; the rest of the scan carries on. A skipped
  step may still be waiting inside Windows when the scan is done, so after a
  skip the scan's PowerShell process ends as soon as the report has been
  handed over or saved and its messages printed, and the one-click window
  closes instead of staying open. If the scan stops on an error after a
  skip, it prints the error and ends with exit code 1.
- On PCs with application control (for example WDAC or AppLocker, which put
  PowerShell in Constrained Language Mode) the scan still runs, but some
  checks show unknown (pending updates, update history read from Windows
  Update) and the battery has no comparison identifier. An update pause set
  in Settings is still read. Slow steps have no time limit there.
- If another antivirus is registered with Windows Security Center and enabled,
  it is reported in place of Microsoft Defender, and its definitions are
  reported as out of date when it says so. Likewise, when Windows Firewall
  is off but Security Center reports another firewall that is on, the
  firewall check passes and names it. Where Security Center does not answer
  (for example on Windows Server), Defender being off is shown as unknown
  rather than as a warning. These paths have not been tested on a machine
  with third-party antivirus or firewall software installed.
- The firewall check also warns when a turned-on profile lets in all
  incoming connections by default.
- Disk space warns when a drive has under 15% free and also under 50 GB free,
  or when the system drive has under 10 GB free (Windows needs room for
  updates). A drive whose size cannot be read is shown as unknown.
- System uptime suggests Restart from the Start menu after 14 days. With
  Fast Startup on (the Windows default), Shut down does not reset the count.
- Windows Update checks (restart pending, update recency, pending updates)
  read only what this computer already knows. The scan never contacts
  Microsoft, so "pending updates" is as of Windows' own last update check;
  if that check is more than 14 days old, or its time cannot be read,
  pending updates is shown as unknown rather than passed.
  Incomplete cached searches are explicitly marked unknown or warning;
  an empty partial result is never treated as proof that no updates are waiting.
- Drive health is the status Windows reports for each physical drive. Wear
  and temperature are added only when the collector runs as administrator.
  A "Healthy" result does not guarantee a drive will not fail; keep backups.
- Battery health appears under System. Each reported battery is assessed
  separately using full-charge capacity as a percentage of design capacity;
  this is not its current charge level. Below 80% is a review threshold, not
  a failure diagnosis or prediction of runtime. Missing, invalid, or relative-
  unit capacity measurements appear as Unknown. No installed battery is Info.
  Reports contain a hashed driver-reported battery instance identifier for
  comparison; raw instance strings are excluded from the report. A driver may
  reuse an instance identifier after a battery replacement.
- Startup apps appears under System as an informational inventory, with up to
  12 sanitized entry names and coarse location labels. Disabled entries may
  be included; visibility depends on access rights. No app is disabled and
  no performance impact is inferred. Use the Startup apps shortcut or Task
  Manager for enabled status and measured impact. Startup command lines,
  usernames, SIDs, and raw location paths are excluded from the report.
- Windows version support appears under Updates. It compares the installed
  Windows build with a list of end-of-servicing dates built into the scan
  (the scan never goes online). The list was last reviewed in 2026-11 and
  will age: a build that is not in it is shown as informational, not judged.
  Windows 10 is reported as out of support; the scan cannot see Extended
  Security Updates enrolment. Server and LTSC editions are not judged.
- Secure Boot, TPM security chip and User Account Control appear under
  Protection. They are read without administrator rights, so the TPM check
  shows only that a working TPM device is present, not that it is set up.
  Secure Boot and TPM are changed in the PC's firmware settings; the scan
  never changes them.
- System stability counts blue-screen stop errors and unexpected shutdowns in
  the last 30 days. One stop error, or three unexpected shutdowns, is the
  review threshold; a blue screen and the restart that follows it count as
  one stop error. Drive error events (under Storage) counts disk and
  file-system error events in the same period; an error on an internal
  drive warns at once, while a few on one day from a removable drive do not.
  Program crashes is an informational list for the last 7 days. All three
  read the Windows event
  logs: only counts, dates and program file names go into the report, never
  event messages, and a log that does not reach back the whole period is
  called out.
- When a report is saved (manual steps or -SaveReport) and its usual folder
  cannot be written, it is saved under %LOCALAPPDATA%\HealthScan\reports or
  your temp folder; the collector prints the path it used.
- The dashboard runs offline and reports are not uploaded.
- No automatic fixes are performed: the scan changes nothing, and the optional
  startup cleanup removes only entries you select and confirm. This is not an
  independent malware engine.

DEVELOPMENT CHECKS
Run these from Windows PowerShell in the app folder. The first five use mock
data and do not run a health scan or change settings; Test-RegistryCleaner
creates, tests and removes only its own uniquely named temporary key under
HKEY_CURRENT_USER\Software:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Collector.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Extras.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Platform.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Robustness.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Launcher.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-RegistryCleaner.ps1
   node .\build\Test-Dashboard.js
Test-Robustness takes under a minute; it starts a few short-lived Windows
PowerShell processes (one of them the 32-bit one, to read two registry
values) and one empty cmd.exe command. Test-Launcher runs no scan and starts
no browser.
This one tests the built HealthScan.exe and fails if it was not rebuilt after
a change to Collect-Health.ps1, index.html or RegistryCleaner.ps1. It runs one real read-only scan
with -NoBrowser (about a minute) and starts no browser:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-Exe.ps1
Node.js is needed only for the dashboard development tests, not to run the app.

VERSION
This is version 1.6.0. The version is shown at the bottom of the dashboard, by
"HealthScan.exe -Version", and in each report (collectorVersion), so a saved
report says which version of the scan produced it. It is written in
Collect-Health.ps1, index.html and build\HealthScan.cs; build\Build.ps1
refuses to build if they disagree. The folder is a git repository, so earlier
versions can be recovered with git.

1.6.0  Added Scan history to the portable dashboard. Choose two locally saved
       scans to review new and resolved warnings without importing files.
1.5.3  Added the Forge Technologies startup splash and audited local reports,
       update status, event-log coverage, and portable package validation.
1.5.2  Added scan progress, cancellation, and per-scan opt-in local JSON history.

1.4.1  New: an optional startup cleanup in HealthScan.exe ("Review
       startup registry" button, or HealthScan.exe -RegistryCleaner). It lists
       current-user startup entries whose program file is missing, removes
       only the ones you tick and confirm, backs them up first, and re-checks
       each entry just before removing it. The scan itself stays read-only.
       Fixes from a review of privacy, accuracy and reliability:
       - Reports no longer carry error message text, and names from other
         software or Windows are cleaned of your user name. The computer
         name is kept as it is, so two reports from one PC can be compared.
       - Fewer false alarms and false all-clears: other firewalls and
         antivirus products, out-of-date definitions, firewalls that let
         everything in, large or nearly full drives, Fast Startup, old update
         checks, drive errors on internal drives, and blue screens counted
         twice are all handled.
       - The scan no longer gets stuck when part of Windows stops answering,
         and its window closes when it is done even if a skipped step is
         still waiting. It works on PCs with application control (where an
         update pause is now read too), in 32-bit PowerShell and with any
         regional setting, and warns when a saved report goes to OneDrive.
       - Scans run as administrator no longer open a browser with
         administrator rights; -QuickScan says it waits for the scan.
       - HealthScan.exe hands the report to the first page load only, keeps
         its window open for 30 minutes just for the "Run Defender quick
         scan" button, accepts that button only from its own page, says it
         asks for a private window rather than promising one, and warns
         when a browser policy turns private windows off.
       - The dashboard asks before replacing an unsaved scan (Import and
         Paste only once a valid report is chosen), labels reports that
         arrive in the page address, says when a report cannot be brought
         back by reloading, is easier to use with a keyboard, a screen
         reader and high-contrast themes, and helps keep the page address
         out of printed reports.
       - build\Build.ps1 checks that the version numbers agree before it
         compiles.
       - This file now gives commands that work on a default Windows PC,
         and notes Smart App Control, OneDrive and what Windows logs.
1.4    Added Windows version support, Secure Boot, TPM, User Account Control,
       system stability, drive error events and program crashes. Reports now
       carry the scan version.
1.3    Baseline when version control was added.
