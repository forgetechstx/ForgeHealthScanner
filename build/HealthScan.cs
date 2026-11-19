// Total Computer Health Scan - single-file launcher.
//
// One exe, nothing to install; a scan saves no report and creates no file of its own (the optional
// -RegistryCleaner writes a backup before removing entries the user confirms). It carries
// Collect-Health.ps1 and index.html inside itself, runs the collector in-process, then hands the
// dashboard to the browser on a loopback-only address (127.0.0.1): only requests for one
// unguessable address are answered. The report itself is handed over once (plus a few seconds
// for a browser that repeats the request); for the rest of the 30 minutes the address serves the
// dashboard without the report, so its quick-scan button keeps working.
//
// Built with the C# compiler that ships with Windows (.NET Framework 4.x), so the source
// sticks to C# 5. See build\Build.ps1.
using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

[assembly: AssemblyTitle("ForgeHealthScanner")]
[assembly: AssemblyDescription("Local Windows status with opt-in history and explicitly confirmed startup cleanup. No project telemetry.")]
[assembly: AssemblyProduct("ForgeHealthScanner")]
[assembly: AssemblyCompany("Forge Technologies")]
[assembly: AssemblyCopyright("Copyright 2026 Forge Technologies (forgetechstx)")]
[assembly: AssemblyVersion("1.6.0.0")]
[assembly: AssemblyFileVersion("1.6.0.0")]

static class Program
{
    // The marker in index.html that is swapped for the embedded report.
    const string SavedScanTag = "<script src=\"latest-report.js\" onload=\"window.HEALTHSCAN_REPORT_FILE=true\"></script>";
    const int WaitForBrowserSeconds = 120;   // how long to wait for the browser to ask for the page
    const int LingerSeconds = 1800;          // keep the local button available for 30 minutes
    const int MaxConnections = 32;         // only a guard against runaway thread creation
    const int HeadReadMilliseconds = 5000;   // total time a connection gets to send its request head
    const int MaxHeadBytes = 65536;
    // A part of Windows that stops answering (Windows Update, a sleeping disk, a stuck WMI provider)
    // must not leave the scan waiting for ever; the slowest normal step takes a few minutes.
    const int ScanTimeLimitMinutes = 10;
    // Browsers known to accept an address and a private-window switch on their command line.
    static readonly string[] KnownBrowsers = { "msedge.exe", "chrome.exe", "firefox.exe", "brave.exe", "vivaldi.exe", "opera.exe" };
    // After the first delivery the report is still served for this long, for a browser that repeats
    // the request (a prefetch, a restored tab); after that, reloads get the dashboard without it.
    const int ReportGraceSeconds = 10;
    static int activeConnections;
    static int quickScanLaunching;

    static readonly object deliveryLock = new object();
    static bool pageDelivered;          // guarded by deliveryLock
    static DateTime deliveredAtUtc;     // guarded by deliveryLock

    [STAThread]
    static int Main(string[] args)
    {
        int code = Run(args);
        // A step the collector abandoned can leave a runspace thread inside Windows that would keep
        // this process alive; the work is done, so end the process with the exit code regardless.
        Console.Out.Flush();
        Environment.Exit(code);
        return code;
    }

    static string VersionText(Version v)
    {
        return v.Major + "." + v.Minor + (v.Build > 0 ? "." + v.Build : "");
    }

    static int Run(string[] args)
    {
        if (args.Length == 1 && string.Equals(args[0].TrimStart('-', '/'), "RegistryCleaner", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                InitialSessionState cleanerState = InitialSessionState.CreateDefault();
                cleanerState.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                using (Runspace cleanerRunspace = RunspaceFactory.CreateRunspace(cleanerState))
                {
                    cleanerRunspace.ApartmentState = ApartmentState.STA;
                    cleanerRunspace.ThreadOptions = PSThreadOptions.ReuseThread;
                    cleanerRunspace.Open();
                    using (PowerShell cleaner = PowerShell.Create())
                    {
                        cleaner.Runspace = cleanerRunspace;
                        cleaner.AddScript(ReadResource("RegistryCleaner.ps1"));
                        cleaner.Invoke();
                        if (cleaner.HadErrors) throw new InvalidOperationException(cleaner.Streams.Error[0].ToString());
                    }
                }
                return 0;
            }
            catch (Exception ex) { Console.WriteLine("Startup cleanup could not run: " + ex.Message); Pause(false); return 1; }
        }
        bool quickScan = false, noBrowser = false;
        foreach (string a in args)
        {
            string s = a.TrimStart('-', '/').ToLowerInvariant();
            if (s == "quickscan") quickScan = true;
            else if (s == "nobrowser") noBrowser = true;
            else if (s == "version")
            {
                Version v = Assembly.GetExecutingAssembly().GetName().Version;
                Console.WriteLine("Total Computer Health Scan " + VersionText(v));
                return 0;
            }
            else
            {
                Console.WriteLine("Total Computer Health Scan");
                Console.WriteLine();
                Console.WriteLine("  HealthScan.exe              scan this computer and open the results in your browser");
                Console.WriteLine("  HealthScan.exe -QuickScan   also request a Microsoft Defender quick scan (run as administrator)");
                Console.WriteLine("  HealthScan.exe -NoBrowser   print the local address instead of opening a browser");
                Console.WriteLine("  HealthScan.exe -RegistryCleaner   review missing current-user startup entries");
                Console.WriteLine("  HealthScan.exe -Version     print the version and exit");
                Console.WriteLine();
                Console.WriteLine("The scan is read-only: no settings are changed, nothing is uploaded and no report is saved.");
                Console.WriteLine("-RegistryCleaner changes only the startup entries you select and confirm, after a backup.");
                return s == "?" || s == "h" || s == "help" ? 0 : 2;
            }
        }

        try { Console.Title = "Total Computer Health Scan"; } catch (IOException) { }
        Console.WriteLine("Collecting local health status. No settings are changed and nothing is uploaded.");
        Console.WriteLine("The scan stops by itself after " + ScanTimeLimitMinutes + " minutes; to cancel it sooner, press Ctrl+C or close this window.");
        Console.WriteLine();
        try
        {
            string json;
            try {
                if (!noBrowser) OpenProgress();
                json = RunCollector(quickScan);
                if (keepHistory != null && keepHistory.Checked)
                {
                    try { SaveHistory(json); }
                    catch (IOException) { ShowProgressWarning("The scan finished, but the local history file could not be saved."); }
                    catch (UnauthorizedAccessException) { ShowProgressWarning("The scan finished, but the local history folder is not writable."); }
                }
            } finally {
                if (progressWindow != null) { cancelRequested = true; progressWindow.Close(); progressWindow.Dispose(); progressWindow = null; }
                if (splashArtwork != null) { splashArtwork.Dispose(); splashArtwork = null; }
            }
            byte[] page = Encoding.UTF8.GetBytes(BuildPage(json));
            byte[] pageWithoutReport = Encoding.UTF8.GetBytes(BuildPage(null));
            return Serve(page, pageWithoutReport, noBrowser) ? 0 : 1;
        }
        catch (OperationCanceledException) { Console.WriteLine("Scan cancelled. No report was saved."); return 0; }
        catch (TimeoutException ex)
        {
            Console.WriteLine();
            Console.WriteLine(ex.Message);
            Pause(noBrowser);
            // The stuck step may still hold a thread inside Windows; end the process regardless.
            Environment.Exit(1);
            return 1;
        }
        catch (Exception ex)
        {
            Console.WriteLine();
            Console.WriteLine("The scan could not be completed: " + ex.Message);
            Pause(noBrowser);
            return 1;
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetConsoleProcessList(uint[] processList, uint processCount);

    static void Pause(bool noBrowser)
    {
        // Only when started by double-click (this process is the only one attached to its console)
        // would the window vanish before the message can be read. From an existing console, a
        // .cmd file or a scheduler, return at once so the exit code is delivered.
        if (noBrowser) return;
        try
        {
            if (Console.IsInputRedirected) return;
            if (GetConsoleProcessList(new uint[4], 4) != 1) return;
            Console.WriteLine("Press any key to close this window.");
            Console.ReadKey(true);
        }
        catch (InvalidOperationException) { }
        catch (EntryPointNotFoundException) { }
    }

    static string ReadResource(string name)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (s == null) throw new InvalidOperationException("This copy of HealthScan.exe is incomplete (missing " + name + ").");
            using (StreamReader r = new StreamReader(s, Encoding.UTF8)) return r.ReadToEnd();
        }
    }

    static System.Windows.Forms.Form progressWindow;
    static System.Windows.Forms.Label progressLabel;
    static System.Drawing.Image splashArtwork;
    static System.Windows.Forms.CheckBox keepHistory;
    static bool historySaved;
    static volatile bool cancelRequested;
    static volatile string currentStep = "Preparing scan...";
    static string HistoryDirectory { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HealthScan", "scan-history"); } }

    static void ShowProgressWarning(string message)
    {
        Console.WriteLine(message);
        System.Windows.Forms.MessageBox.Show(progressWindow, message, "ForgeHealthScanner",
            System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Warning);
    }

    static void OpenProgress()
    {
        cancelRequested = false;
        string version = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
        System.Windows.Forms.Application.EnableVisualStyles();
        progressWindow = new System.Windows.Forms.Form
        {
            Text = "ForgeHealthScanner " + version,
            ClientSize = new System.Drawing.Size(560, 462),
            AutoScaleDimensions = new System.Drawing.SizeF(96F, 96F),
            AutoScaleMode = System.Windows.Forms.AutoScaleMode.Dpi,
            StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen,
            FormBorderStyle = System.Windows.Forms.FormBorderStyle.FixedDialog,
            MaximizeBox = false
        };
        using (Stream artwork = Assembly.GetExecutingAssembly().GetManifestResourceStream("ForgeSplash.png"))
        using (System.Drawing.Image original = System.Drawing.Image.FromStream(artwork))
            splashArtwork = new System.Drawing.Bitmap(original);
        var banner = new System.Windows.Forms.PictureBox
        {
            Left = 20, Top = 14, Width = 520, Height = 244,
            Image = splashArtwork, SizeMode = System.Windows.Forms.PictureBoxSizeMode.Zoom,
            AccessibleName = "Forge Technologies logo", TabStop = false
        };
        var branding = new System.Windows.Forms.Label
        {
            Left = 20, Top = 268, Width = 520, Height = 25,
            TextAlign = System.Drawing.ContentAlignment.MiddleCenter,
            Text = "Forge Technologies  |  ForgeHealthScanner " + version
        };
        string location = Assembly.GetExecutingAssembly().Location;
        if (File.Exists(location)) progressWindow.Icon = System.Drawing.Icon.ExtractAssociatedIcon(location);
        progressLabel = new System.Windows.Forms.Label { Left = 20, Top = 300, Width = 520, Height = 50, Text = currentStep };
        var bar = new System.Windows.Forms.ProgressBar { Left = 20, Top = 352, Width = 520, Height = 14, Style = System.Windows.Forms.ProgressBarStyle.Marquee };
        keepHistory = new System.Windows.Forms.CheckBox { Left = 20, Top = 380, Width = 520, Text = "Save this completed scan to local history (contains PC details)" };
        var history = new System.Windows.Forms.Button { Left = 20, Top = 418, Width = 160, Height = 28, Text = "Open local history" };
        history.Click += delegate
        {
            try
            {
                Directory.CreateDirectory(HistoryDirectory);
                using (Process.Start(new ProcessStartInfo(HistoryDirectory) { UseShellExecute = true, Verb = "open" })) { }
            }
            catch (IOException) { ShowProgressWarning("The local history folder could not be opened."); }
            catch (UnauthorizedAccessException) { ShowProgressWarning("The local history folder is not accessible."); }
            catch (System.ComponentModel.Win32Exception) { ShowProgressWarning("Windows could not open the local history folder."); }
        };
        var cancel = new System.Windows.Forms.Button { Left = 420, Top = 418, Width = 120, Height = 28, Text = "Cancel" };
        cancel.Click += delegate { cancelRequested = true; cancel.Enabled = false; };
        progressWindow.FormClosing += delegate(object sender, System.Windows.Forms.FormClosingEventArgs e) { if (!cancelRequested) { cancelRequested = true; e.Cancel = true; } };
        progressWindow.Controls.AddRange(new System.Windows.Forms.Control[] { banner, branding, progressLabel, bar, keepHistory, history, cancel });
        progressWindow.Show();
        System.Windows.Forms.Application.DoEvents();
    }

    static void SaveHistory(string json)
    {
        Directory.CreateDirectory(HistoryDirectory);
        string destination = Path.Combine(HistoryDirectory, DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".json");
        string stagingPath = destination + ".tmp";
        try
        {
            File.WriteAllText(stagingPath, json, new UTF8Encoding(false));
            File.Move(stagingPath, destination);
        }
        finally
        {
            try { File.Delete(stagingPath); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        historySaved = true;
        Console.WriteLine("Saved local history: " + destination);
    }

    // Runs the embedded collector inside this process and returns the report as JSON.
    static string RunCollector(bool quickScan)
    {
        return RunScript(ReadResource("Collect-Health.ps1"), quickScan, TimeSpan.FromMinutes(ScanTimeLimitMinutes));
    }

    // Runs a collector script with -EmitJson and returns its JSON report; throws TimeoutException
    // when the script has not finished within the limit.
    static string RunScript(string script, bool quickScan, TimeSpan limit)
    {
        // Opening a runspace with a Bypass policy sets PSExecutionPolicyPreference in this process's
        // environment. Put it back afterwards so the browser started later does not inherit it.
        const string PolicyVariable = "PSExecutionPolicyPreference";
        string policyBefore = Environment.GetEnvironmentVariable(PolicyVariable);
        Runspace runspace = null;
        PowerShell ps = null;
        bool timedOut = false;
        try
        {
            InitialSessionState state = InitialSessionState.CreateDefault();
            // Windows' own modules (Defender, Storage, Firewall) are script modules, and the default
            // "Restricted" policy refuses to load them. This lasts for the scan only, changes no
            // setting, and a policy enforced by an organization still takes precedence.
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            runspace = RunspaceFactory.CreateRunspace(state);
            // Same threading model as powershell.exe, which the COM objects the collector uses expect.
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.ReuseThread;
            runspace.Open();
            ps = PowerShell.Create();
            ps.Runspace = runspace;
            ps.AddScript(script).AddParameter("EmitJson", true);
            if (quickScan) ps.AddParameter("QuickScan", true);
            // The collector's "Checking ..." lines arrive on the information stream.
            ps.Streams.Information.DataAdded += delegate(object sender, DataAddedEventArgs e)
            {
                InformationRecord record = ((PSDataCollection<InformationRecord>)sender)[e.Index];
                if (record != null && record.MessageData != null) { currentStep = record.MessageData.ToString(); Console.WriteLine(currentStep); }
            };
            ps.Streams.Warning.DataAdded += delegate(object sender, DataAddedEventArgs e)
            {
                WarningRecord record = ((PSDataCollection<WarningRecord>)sender)[e.Index];
                if (record != null) Console.WriteLine("Warning: " + record.Message);
            };

            IAsyncResult pending = ps.BeginInvoke();
            Stopwatch elapsed = Stopwatch.StartNew();
            while (!pending.AsyncWaitHandle.WaitOne(100)) {
                if (progressWindow != null) {
                    string display = currentStep + Environment.NewLine + "Elapsed: " + elapsed.Elapsed.ToString(@"mm\:ss");
                    if (progressLabel.Text != display) progressLabel.Text = display;
                    System.Windows.Forms.Application.DoEvents();
                }
                if (cancelRequested) {
                    timedOut = true;
                    try { ps.BeginStop(null, null); } catch (Exception) { }
                    throw new OperationCanceledException();
                }
                if (elapsed.Elapsed >= limit) break;
            }
            if (!pending.IsCompleted)
            {
                timedOut = true;
                // Ask the scan to stop. A call stuck inside Windows may not react, so do not
                // wait long, and leave the runspace undisposed (disposing it would wait too).
                try { ps.BeginStop(null, null).AsyncWaitHandle.WaitOne(5000); }
                catch (Exception) { }
                throw new TimeoutException(
                    "The scan did not finish within " + FormatLimit(limit) + ", so it was stopped and no results are shown. " +
                    "A part of Windows (often Windows Update or a slow or sleeping drive) did not answer in time. " +
                    "Nothing was changed. Try again later, or after restarting the computer.");
            }
            if (cancelRequested) { timedOut = true; throw new OperationCanceledException(); }
            PSDataCollection<PSObject> output = ps.EndInvoke(pending);
            string json = null;
            foreach (PSObject item in output)
            {
                string text = item == null ? null : item.BaseObject as string;
                if (text != null && text.TrimStart().StartsWith("{", StringComparison.Ordinal)) json = text;
            }
            if (json == null)
            {
                string reason = ps.Streams.Error.Count > 0 ? ps.Streams.Error[0].ToString() : "the collector returned no report";
                throw new InvalidOperationException(reason);
            }
            return json;
        }
        finally
        {
            if (!timedOut)
            {
                if (ps != null) ps.Dispose();
                if (runspace != null) runspace.Dispose();
            }
            // null removes the variable when it was not set before.
            Environment.SetEnvironmentVariable(PolicyVariable, policyBefore);
        }
    }

    static string FormatLimit(TimeSpan limit)
    {
        if (limit.TotalMinutes >= 1 && limit.Seconds == 0) return (int)limit.TotalMinutes + (limit.TotalMinutes == 1 ? " minute" : " minutes");
        return (int)Math.Ceiling(limit.TotalSeconds) + " seconds";
    }

    // Puts the report into the dashboard page in place of the saved-scan script tag. With a null
    // report, the page only says it is served by the exe (for the quick-scan button) and carries no report.
    static string BuildPage(string json)
    {
        string html = ReadResource("index.html");
        int at = html.IndexOf(SavedScanTag, StringComparison.Ordinal);
        if (at < 0) throw new InvalidOperationException("This copy of HealthScan.exe is incomplete (dashboard marker not found).");
        string inject;
        if (json == null) inject = "<script>window.HEALTHSCAN_HOST=\"exe\";</script>";
        else
        {
            // JSON is valid JavaScript once the characters that could end a <script> block or a
            // JavaScript line are escaped. The dashboard still validates the report before showing it.
            string safe = json.Replace("<", "\\u003c").Replace(">", "\\u003e").Replace("&", "\\u0026")
                              .Replace("\u2028", "\\u2028").Replace("\u2029", "\\u2029");
            inject = "<script>window.HEALTHSCAN_HOST=\"exe\";window.HEALTHSCAN_LIVE=" + safe + ";</script>";
        }
        return html.Substring(0, at) + inject + html.Substring(at + SavedScanTag.Length);
    }

    // Hands the page to the browser: listens on 127.0.0.1 only, on a port Windows picks, and answers
    // only the one address that contains a random token. Nothing outside this computer can connect.
    static bool Serve(byte[] page, byte[] pageWithoutReport, bool noBrowser)
    {
        byte[] random = new byte[16];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) rng.GetBytes(random);
        string token = BitConverter.ToString(random).Replace("-", "").ToLowerInvariant();

        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            string host = "127.0.0.1:" + port;
            string path = "/" + token + "/";
            string url = "http://" + host + path;

            Console.WriteLine();
            string browser = noBrowser ? null : FindBrowser();
            string plan = LaunchPlan(noBrowser, !noBrowser && IsElevated(), browser);
            bool opened = false;
            if (plan == "private")
            {
                bool privateBlocked = PrivateModeBlocked(browser);
                // ShellExecute (not CreateProcess) so the browser inherits none of this process's handles.
                try
                {
                    using (Process.Start(new ProcessStartInfo(browser, PrivateSwitch(browser) + " " + url) { UseShellExecute = true })) { }
                    Console.WriteLine(PrivateWindowMessage(privateBlocked));
                    opened = true;
                }
                catch (Exception) { plan = "default"; }
            }
            if (plan == "default")
            {
                try
                {
                    using (Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })) { }
                    Console.WriteLine("Scan complete. Opening the results in your default browser.");
                    Console.WriteLine("This is a normal window, not a private one: installed browser extensions can read the page,");
                    Console.WriteLine("and the one-time address stays in the browser's history (it stops working once this window closes).");
                    opened = true;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("The browser could not be opened automatically (" + ex.Message + ").");
                }
            }
            if (plan == "elevated")
            {
                Console.WriteLine("Scan complete. This window runs as administrator, so it does not open a browser:");
                Console.WriteLine("a browser started from here would also run with administrator rights.");
            }
            if (!opened)
            {
                if (noBrowser) Console.WriteLine("Scan complete.");
                Console.WriteLine("Open this address in a browser on this computer within " + WaitForBrowserSeconds + " seconds, preferably in a private window:");
                Console.WriteLine(url);
            }

            DateTime giveUpUtc = DateTime.UtcNow.AddSeconds(WaitForBrowserSeconds);
            bool announced = false;
            while (true)
            {
                bool delivered;
                DateTime deliveredAt;
                lock (deliveryLock) { delivered = pageDelivered; deliveredAt = deliveredAtUtc; }
                if (delivered)
                {
                    if (!announced)
                    {
                        announced = true;
                        Console.WriteLine();
                        Console.WriteLine(historySaved ? "Results delivered. Your opted-in local history was saved; nothing was uploaded." : "Results delivered. This tool saved no report and uploaded nothing.");
                        Console.WriteLine("The report is handed over once: reloading the page or opening the address again later");
                        Console.WriteLine("shows the dashboard without it. Use \"Export JSON\" to keep a copy.");
                        Console.WriteLine("This window stays open for 30 minutes so the dashboard's quick-scan button works; you can close it at any time.");
                    }
                    if (DateTime.UtcNow > deliveredAt.AddSeconds(LingerSeconds)) break;
                }
                else if (DateTime.UtcNow > giveUpUtc) break;

                if (listener.Pending())
                {
                    TcpClient client = listener.AcceptTcpClient();
                    // Browsers open spare connections that never send anything; each connection gets its own
                    // thread (not the slow-growing thread pool) so idle ones cannot hold up the real request.
                    if (Interlocked.Increment(ref activeConnections) > MaxConnections)
                    {
                        Interlocked.Decrement(ref activeConnections);
                        client.Close();
                    }
                    else
                    {
                        Thread worker = new Thread(delegate()
                        {
                            try { Handle(client, host, path, page, pageWithoutReport); }
                            finally { Interlocked.Decrement(ref activeConnections); }
                        }, 256 * 1024);
                        worker.IsBackground = true;
                        worker.Start();
                    }
                }
                else Thread.Sleep(40);
            }
        }
        finally { listener.Stop(); }

        bool wasDelivered;
        lock (deliveryLock) wasDelivered = pageDelivered;
        if (wasDelivered)
        {
            Console.WriteLine("The 30 minutes are over; the local address no longer answers.");
            return true;
        }
        Console.WriteLine("No browser asked for the results within " + WaitForBrowserSeconds + " seconds, so they were discarded.");
        Console.WriteLine("Run HealthScan.exe again to scan again.");
        Pause(noBrowser);
        return false;
    }

    // How the results are handed over: "print" (-NoBrowser), "elevated" (print; never start a
    // browser with administrator rights), "private" (a private window of a known browser) or
    // "default" (the default browser through Windows, in a normal window).
    static string LaunchPlan(bool noBrowser, bool elevated, string browser)
    {
        if (noBrowser) return "print";
        if (elevated) return "elevated";
        return browser != null ? "private" : "default";
    }

    static bool IsElevated()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        // If it cannot be told, assume administrator: printing the address is always safe.
        catch (Exception) { return true; }
    }

    // The same choice as Get-BrowserExe in Collect-Health.ps1: the default browser when it is one
    // known to accept a private-window switch, else Microsoft Edge, else null.
    static string FindBrowser()
    {
        try
        {
            using (RegistryKey choice = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice"))
            {
                string progId = choice == null ? null : choice.GetValue("ProgId") as string;
                if (!string.IsNullOrEmpty(progId))
                {
                    using (RegistryKey command = Registry.ClassesRoot.OpenSubKey(progId + @"\shell\open\command"))
                    {
                        string exe = command == null ? null : BrowserFromCommand(command.GetValue("") as string);
                        if (exe != null) return exe;
                    }
                }
            }
        }
        catch (Exception) { }
        foreach (string root in new string[] { Environment.GetEnvironmentVariable("ProgramFiles(x86)"), Environment.GetEnvironmentVariable("ProgramFiles") })
        {
            if (string.IsNullOrEmpty(root)) continue;
            string edge = Path.Combine(root, @"Microsoft\Edge\Application\msedge.exe");
            if (File.Exists(edge)) return edge;
        }
        return null;
    }

    // The browser exe named at the start of a shell\open\command value, when it is a known browser
    // given by full path and the file exists; otherwise null.
    static string BrowserFromCommand(string command)
    {
        if (string.IsNullOrEmpty(command)) return null;
        Match m = Regex.Match(command, "^\\s*\"([^\"]+\\.exe)\"", RegexOptions.IgnoreCase);
        if (!m.Success) m = Regex.Match(command, "^\\s*(\\S+\\.exe)", RegexOptions.IgnoreCase);
        if (!m.Success) return null;
        string exe = m.Groups[1].Value;
        try
        {
            if (!Path.IsPathRooted(exe)) return null;
            if (Array.IndexOf(KnownBrowsers, Path.GetFileName(exe).ToLowerInvariant()) < 0) return null;
            return File.Exists(exe) ? exe : null;
        }
        catch (ArgumentException) { return null; }
    }

    static string PrivateSwitch(string browser)
    {
        switch (Path.GetFileName(browser).ToLowerInvariant())
        {
            case "msedge.exe": return "--inprivate";
            case "firefox.exe": return "-private-window";
            case "opera.exe": return "--private";
            default: return "--incognito";
        }
    }

    // What is said after asking the browser for a private window. The browser decides whether the
    // window really is private, so this only says it was asked for, and warns when a policy says no.
    static string PrivateWindowMessage(bool privateBlocked)
    {
        string text = "Scan complete. Asking your browser for a private window...";
        if (privateBlocked)
            text += Environment.NewLine +
                "Warning: a policy set by your organization turns private windows off in this browser," + Environment.NewLine +
                "so the results will open in a normal window: installed browser extensions can read the page," + Environment.NewLine +
                "and the one-time address stays in the browser's history (it stops working once this window closes).";
        return text;
    }

    // The browser policy that can turn private windows off, as { subkey, value name } under
    // HKLM/HKCU; null for browsers without a policy this tool knows.
    static string[] PrivateModePolicy(string browser)
    {
        switch (Path.GetFileName(browser).ToLowerInvariant())
        {
            case "msedge.exe": return new string[] { @"Software\Policies\Microsoft\Edge", "InPrivateModeAvailability" };
            case "chrome.exe": return new string[] { @"Software\Policies\Google\Chrome", "IncognitoModeAvailability" };
            case "brave.exe": return new string[] { @"Software\Policies\BraveSoftware\Brave", "IncognitoModeAvailability" };
            default: return null;
        }
    }

    // 1 means "private windows not available" for all three policies (2 forces them, 0 is the default).
    static bool PolicyDisablesPrivate(object value)
    {
        if (value is int) return (int)value == 1;
        if (value is long) return (long)value == 1;
        string text = value as string;
        return text != null && text.Trim() == "1";
    }

    // Whether an organization policy turns private windows off in this browser. A machine policy
    // takes precedence over a user policy. Only reads the registry; when it cannot be read, false.
    static bool PrivateModeBlocked(string browser)
    {
        string[] policy = PrivateModePolicy(browser);
        if (policy == null) return false;
        foreach (RegistryKey root in new RegistryKey[] { Registry.LocalMachine, Registry.CurrentUser })
        {
            try
            {
                using (RegistryKey key = root.OpenSubKey(policy[0]))
                {
                    object value = key == null ? null : key.GetValue(policy[1]);
                    if (value != null) return PolicyDisablesPrivate(value);
                }
            }
            catch (Exception) { }
        }
        return false;
    }

    // The quick-scan request is accepted only from the dashboard's own button: a POST to the
    // quick-scan address with this exact Host and an Origin of exactly this address. The page is
    // served with Referrer-Policy: same-origin so browsers send that Origin; "Origin: null" (sent by
    // sandboxed frames, file: pages and no-referrer pages) and a missing Origin are refused.
    static bool QuickScanAllowed(string method, string target, string hostHeader, string originHeader, string host, string path)
    {
        if (method != "POST" || host == null || path == null || originHeader == null) return false;
        return string.Equals(hostHeader, host, StringComparison.OrdinalIgnoreCase)
            && string.Equals(originHeader, "http://" + host, StringComparison.OrdinalIgnoreCase)
            && string.Equals(target, path + "quickscan", StringComparison.Ordinal);
    }

    static bool RegistryCleanerAllowed(string method, string target, string hostHeader, string originHeader, string host, string path)
    {
        return path != null && string.Equals(target, path + "registrycleaner", StringComparison.Ordinal)
            && QuickScanAllowed(method, path + "quickscan", hostHeader, originHeader, host, path);
    }

    // Whether a page request now still gets the report: until the first GET has been delivered, and
    // for a short grace after it (a browser may repeat the request); later, the page comes without it.
    static bool ReportStillServed(bool delivered, DateTime deliveredAt, DateTime now)
    {
        return !delivered || now <= deliveredAt.AddSeconds(ReportGraceSeconds);
    }

    static readonly Regex HistoryFileName = new Regex(@"\A[0-9]{8}-[0-9]{6}-[a-f0-9]{32}\.json\z",
        RegexOptions.CultureInvariant);
    const int HistoryFileLimit = 1024 * 1024;

    static bool IsHistoryFile(FileInfo file)
    {
        return HistoryFileName.IsMatch(file.Name) &&
            (file.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0 &&
            file.Length > 0 && file.Length <= HistoryFileLimit;
    }

    static void ServeHistory(NetworkStream stream, string name)
    {
        try
        {
            var directory = new DirectoryInfo(HistoryDirectory);
            if (directory.Exists &&
                ((directory.Attributes | directory.Parent.Attributes) & FileAttributes.ReparsePoint) != 0)
            {
                Send(stream, "403 Forbidden", null, false);
                return;
            }
            if (name == "")
            {
                var names = directory.Exists
                    ? directory.EnumerateFiles("*.json").Where(IsHistoryFile)
                        .Select(file => file.Name).OrderByDescending(fileName => fileName, StringComparer.Ordinal)
                        .Take(250).Select(fileName => "\"" + fileName + "\"").ToArray()
                    : new string[0];
                // The filename allowlist contains only ASCII digits, lowercase hex, dashes and a suffix.
                Send(stream, "200 OK", Encoding.UTF8.GetBytes("[" + string.Join(",", names) + "]"), false, "application/json");
                return;
            }

            var selected = new FileInfo(Path.Combine(directory.FullName, name));
            if (!selected.Exists || !IsHistoryFile(selected))
            {
                Send(stream, "404 Not Found", null, false);
                return;
            }
            using (var file = new FileStream(selected.FullName, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (file.Length > HistoryFileLimit)
                {
                    Send(stream, "413 Content Too Large", null, false);
                    return;
                }
                byte[] data = new byte[(int)file.Length];
                int read = 0;
                while (read < data.Length)
                {
                    int count = file.Read(data, read, data.Length - read);
                    if (count == 0) throw new EndOfStreamException();
                    read += count;
                }
                Send(stream, "200 OK", data, false, "application/json");
            }
        }
        catch (IOException) { Send(stream, "404 Not Found", null, false); }
        catch (UnauthorizedAccessException) { Send(stream, "403 Forbidden", null, false); }
    }

    static void Handle(TcpClient client, string host, string path, byte[] page, byte[] pageWithoutReport)
    {
        try
        {
            using (client)
            {
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                NetworkStream stream = client.GetStream();

                // Read the request head only; requests with a body are not supported or needed.
                // The browser sends every cookie it holds for 127.0.0.1 (any port), so allow a large head,
                // and give the whole head one deadline so a slow sender cannot hold a thread for long.
                byte[] buffer = new byte[8192];
                int used = 0, headEnd = -1;
                Stopwatch headTimer = Stopwatch.StartNew();
                while (headEnd < 0)
                {
                    if (used == buffer.Length)
                    {
                        if (buffer.Length >= MaxHeadBytes) break;
                        Array.Resize(ref buffer, buffer.Length * 2);
                    }
                    int left = HeadReadMilliseconds - (int)headTimer.ElapsedMilliseconds;
                    if (left <= 0) return;
                    client.ReceiveTimeout = left;
                    int n = stream.Read(buffer, used, buffer.Length - used);
                    if (n <= 0) return;
                    int from = Math.Max(0, used - 3);
                    used += n;
                    headEnd = Encoding.ASCII.GetString(buffer, from, used - from).IndexOf("\r\n\r\n", StringComparison.Ordinal);
                    if (headEnd >= 0) headEnd += from;
                }
                if (headEnd < 0) { Send(stream, "431 Request Header Fields Too Large", null, false); return; }

                string[] lines = Encoding.ASCII.GetString(buffer, 0, headEnd).Split(new string[] { "\r\n" }, StringSplitOptions.None);
                string[] request = lines[0].Split(' ');
                string hostHeader = null;
                string originHeader = null;
                for (int i = 1; i < lines.Length; i++)
                {
                    if (lines[i].StartsWith("Host:", StringComparison.OrdinalIgnoreCase)) hostHeader = lines[i].Substring(5).Trim();
                    if (lines[i].StartsWith("Origin:", StringComparison.OrdinalIgnoreCase)) originHeader = lines[i].Substring(7).Trim();
                }

                string historyPath = path + "history/";
                if (request.Length == 3 && request[1].StartsWith(historyPath, StringComparison.Ordinal)
                    && QuickScanAllowed(request[0], path + "quickscan", hostHeader, originHeader, host, path))
                {
                    string name = request[1].Substring(historyPath.Length);
                    if (name == "" || HistoryFileName.IsMatch(name)) ServeHistory(stream, name);
                    else Send(stream, "404 Not Found", null, false);
                    return;
                }

                bool quickRequest = request.Length == 3
                    && QuickScanAllowed(request[0], request[1], hostHeader, originHeader, host, path);
                bool cleanerRequest = request.Length == 3
                    && RegistryCleanerAllowed(request[0], request[1], hostHeader, originHeader, host, path);
                if (cleanerRequest)
                {
                    try
                    {
                        ProcessStartInfo start = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "-RegistryCleaner");
                        start.UseShellExecute = true;
                        using (Process launched = Process.Start(start)) { }
                        Send(stream, "200 OK", Encoding.UTF8.GetBytes("Startup cleanup opened in a separate window. Review entries before selecting any to remove."), false);
                    }
                    catch (Exception)
                    {
                        Send(stream, "500 Internal Server Error", Encoding.UTF8.GetBytes("Startup cleanup could not be opened. Run HealthScan.exe -RegistryCleaner manually."), false);
                    }
                    return;
                }
                if (quickRequest)
                {
                    if (Interlocked.Exchange(ref quickScanLaunching, 1) != 0) { Send(stream, "409 Conflict", null, false); return; }
                    try
                    {
                        ProcessStartInfo start = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "-QuickScan");
                        start.UseShellExecute = true;
                        start.Verb = "runas";
                        using (Process launched = Process.Start(start)) { }
                        Send(stream, "200 OK", Encoding.UTF8.GetBytes("Quick scan started. Follow the administrator prompt and the new HealthScan window."), false);
                    }
                    catch (Exception)
                    {
                        Send(stream, "500 Internal Server Error", Encoding.UTF8.GetBytes("The quick scan could not be started. Approve the administrator prompt, or run HealthScan.exe -QuickScan as administrator."), false);
                    }
                    finally { Interlocked.Exchange(ref quickScanLaunching, 0); }
                    return;
                }

                bool isGet = request.Length == 3 && request[0] == "GET";
                bool isHead = request.Length == 3 && request[0] == "HEAD";
                // The Host check stops another site reaching this address under its own name (DNS rebinding);
                // the token stops anything that was not given the address from reading the report.
                bool allowed = (isGet || isHead)
                    && string.Equals(hostHeader, host, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(request[1], path, StringComparison.Ordinal);

                if (!allowed) { Send(stream, "404 Not Found", null, false); return; }
                bool withReport;
                lock (deliveryLock) withReport = ReportStillServed(pageDelivered, deliveredAtUtc, DateTime.UtcNow);
                Send(stream, "200 OK", withReport ? page : pageWithoutReport, isHead);
                // Only a GET that was sent completely counts as the delivery (HEAD does not). The grace
                // period and the 30 minutes start at the first one; later requests cannot extend them.
                if (isGet)
                {
                    lock (deliveryLock)
                    {
                        if (!pageDelivered)
                        {
                            deliveredAtUtc = DateTime.UtcNow;
                            pageDelivered = true;
                        }
                    }
                }
            }
        }
        catch (IOException) { }
        catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }

    static void Send(NetworkStream stream, string status, byte[] body, bool headOnly, string contentType = "text/html")
    {
        if (body == null) body = new byte[0];
        string head =
            "HTTP/1.1 " + status + "\r\n" +
            "Content-Type: " + contentType + "; charset=utf-8\r\n" +
            "Content-Length: " + body.Length + "\r\n" +
            "Connection: close\r\n" +
            // Keep the report out of the browser's cache, and let the page load nothing from anywhere else.
            "Cache-Control: no-store\r\n" +
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            // same-origin, not no-referrer: with no-referrer, browsers send "Origin: null" on the
            // dashboard's quick-scan POST, which QuickScanAllowed refuses. Nothing is sent to other sites.
            "Referrer-Policy: same-origin\r\n" +
            "\r\n";
        byte[] headBytes = Encoding.ASCII.GetBytes(head);
        stream.Write(headBytes, 0, headBytes.Length);
        if (!headOnly && body.Length > 0) stream.Write(body, 0, body.Length);
        stream.Flush();
    }
}
