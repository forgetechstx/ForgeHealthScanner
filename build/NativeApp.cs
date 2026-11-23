using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("ForgeHealthScanner")]
[assembly: AssemblyDescription("Portable Windows health scanner")]
[assembly: AssemblyProduct("ForgeHealthScanner")]
[assembly: AssemblyCompany("Forge Technologies")]
[assembly: AssemblyVersion("2.0.1.0")]
[assembly: AssemblyFileVersion("2.0.1.0")]

internal static class NativeApp
{
    internal static readonly string Version = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool AttachConsole(uint process);

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 1 && string.Equals(args[0], "-Version", StringComparison.OrdinalIgnoreCase))
        {
            if (!Console.IsOutputRedirected) AttachConsole(uint.MaxValue);
            Console.WriteLine("ForgeHealthScanner " + Version);
            return 0;
        }
        if (args.Length == 2 && args[0] == "--self-test") return SelfTest(args[1]);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 1 && string.Equals(args[0], "-RegistryCleaner", StringComparison.OrdinalIgnoreCase))
        {
            try { NativeCleanup.Show(null); return 0; }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Startup cleanup"); return 1; }
        }
        bool quick = args.Length == 1 && string.Equals(args[0], "-QuickScan", StringComparison.OrdinalIgnoreCase);
        if (args.Length != 0 && !quick)
        {
            MessageBox.Show("Supported options are -Version, -QuickScan and -RegistryCleaner.", "ForgeHealthScanner");
            return 2;
        }
        using (var window = new NativeWindow(quick))
        {
            Application.Run(window);
            return window.CommandResult;
        }
    }

    static int SelfTest(string output)
    {
        var lines = new List<string>();
        string folder = Path.Combine(Path.GetTempPath(), "ForgeHealthScanner-test-" + Guid.NewGuid().ToString("N"));
        string keyName = @"Software\ForgeHealthScanner-test-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(folder);
            ScanReport older = new ScanReport {
                schemaVersion = 1, source = "windows-collector", collectorVersion = Version,
                device = "Synthetic test PC", os = "Windows", collectedAt = "2026-11-18T00:00:00Z",
                checks = new List<ScanCheck> {
                    NativeCollector.Check("Disk space C:", "warning", "Test", "Test"),
                    NativeCollector.Check("System uptime", "pass", "Test", "Test"),
                    NativeCollector.Check("Windows Update recency", "warning", "Test", "Test")
                }
            };
            ScanReport newer = new ScanReport {
                schemaVersion = 1, source = "windows-collector", collectorVersion = Version,
                device = older.device, os = "Windows", collectedAt = "2026-11-19T00:00:00Z",
                checks = new List<ScanCheck> {
                    NativeCollector.Check("Disk space C:", "pass", "Test", "Test"),
                    NativeCollector.Check("System uptime", "warning", "Test", "Test")
                }
            };
            string first = ScanReports.WriteHistory(older, folder);
            string second = ScanReports.WriteHistory(newer, folder);
            var delta = ScanReports.Compare(ScanReports.Read(first), ScanReports.Read(second));
            if (delta.Count(c => c.State == "New warning") != 1 || delta.Count(c => c.State == "Resolved warning") != 1
                || delta.Count(c => c.State == "Needs review") != 1 || ScanReports.SavedFiles(folder).Count() != 2)
                throw new Exception("History comparison produced incorrect warning counts.");
            lines.Add("PASS saved history round-trip and warning comparison");

            string missing = Path.Combine(folder, "missing.exe");
            using (var key = Registry.CurrentUser.CreateSubKey(keyName))
            {
                key.SetValue("Disposable", "\"" + missing + "\"", RegistryValueKind.String);
                key.SetValue("Arguments", "\"" + missing + "\" -arg", RegistryValueKind.String);
                var entries = NativeCleanup.Find(key);
                if (entries.Count != 1 || entries[0].Name != "Disposable") throw new Exception("Startup candidate selection failed.");
                File.WriteAllText(missing, "");
                if (NativeCleanup.Apply(key, entries[0], false)) throw new Exception("Reappearing executable was not protected.");
                File.Delete(missing);
                string removal = NativeCleanup.Remove(entries, keyName, folder);
                var recovery = NativeCleanup.Records(folder).Single();
                if (recovery.State != "completed" || !File.Exists(recovery.Backup) || !removal.StartsWith("Removed 1") || key.GetValue("Disposable") != null
                    || !NativeCleanup.Apply(key, recovery.Entries.Single(), true) || (string)key.GetValue("Disposable") != entries[0].Command
                    || NativeCleanup.Apply(key, entries[0], true)) throw new Exception("Transactional cleanup or undo failed.");
            }
            lines.Add("PASS disposable startup key removal, fresh file recheck, and undo");

            using (var token = new CancellationTokenSource())
            {
                token.Cancel();
                try { NativeCollector.Collect((step, i, n) => { }, token.Token); throw new Exception("Cancellation failed."); }
                catch (OperationCanceledException) { }
            }
            var report = NativeCollector.Collect((step, i, n) => { }, CancellationToken.None);
            if (report.checks.Count < 21 || !report.checks.Any(c => c.name.StartsWith("Disk space", StringComparison.Ordinal)))
                throw new Exception("The real Windows collection did not produce the expected storage result.");
            lines.Add("PASS real Windows collection (" + report.checks.Count + " checks) and cancellation guard");
            using (var window = new NativeWindow())
            {
                window.ShowReport(ScanReports.Read(second));
                if (!window.Text.Contains(Version)) throw new Exception("Native window does not identify its version.");
            }
            lines.Add("PASS native window and embedded splash load");
            File.WriteAllLines(output, lines);
            return 0;
        }
        catch (Exception ex) { lines.Add("FAIL " + ex); File.WriteAllLines(output, lines); return 1; }
        finally
        {
            Registry.CurrentUser.DeleteSubKey(keyName, false);
            if (Directory.Exists(folder))
            {
                foreach (var file in Directory.EnumerateFiles(folder)) File.Delete(file);
                Directory.Delete(folder);
            }
        }
    }
}

internal sealed class NativeWindow : Form
{
    static readonly Color Ink = Color.FromArgb(19, 36, 48);
    static readonly Color Surface = Color.FromArgb(245, 248, 250);
    static readonly Color Accent = Color.FromArgb(22, 76, 168);
    readonly Label progress = new Label { AutoSize = true, Text = "Preparing to scan…" };
    readonly Label summary = new Label { Dock = DockStyle.Top, AutoSize = false, Height = 48, Padding = new Padding(12, 8, 8, 0) };
    readonly ProgressBar activity = new ProgressBar { Width = 210, Height = 19, Margin = new Padding(6, 9, 8, 0) };
    readonly CheckBox saveHistory = new CheckBox { Text = "Save this scan locally", AutoSize = true, Margin = new Padding(8, 10, 8, 0) };
    readonly Button scan = Button("Scan again", true), cancel = Button("Cancel"), history = Button("Scan history");
    readonly Button import = Button("Import"), export = Button("Export JSON"), cleanup = Button("Startup cleanup"), defender = Button("Defender quick scan");
    readonly ComboBox filter = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    readonly DataGridView checks = Grid("Status", "Check", "Details");
    readonly DataGridView changes = Grid("Change", "Check", "Details");
    readonly TextBox details = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, BorderStyle = BorderStyle.FixedSingle };
    readonly TabControl tabs = new TabControl { Dock = DockStyle.Fill };
    readonly Panel splash = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(15, 21, 30), Padding = new Padding(26) };
    readonly Label splashCaption = new Label { Dock = DockStyle.Bottom, Height = 38, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.White };
    readonly PictureBox artwork = new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, AccessibleName = "Forge Technologies logo" };
    readonly Stopwatch elapsed = new Stopwatch();
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 1000 };
    string currentStep = "";
    CancellationTokenSource pending;
    ScanReport current;
    bool unsaved;

    internal int CommandResult { get; private set; }
    bool quickRunning;
    readonly Button print = Button("Print"), programs = Button("Remove a program"), about = Button("About");

    internal NativeWindow() : this(false) { }

    internal NativeWindow(bool quick)
    {
        Text = "ForgeHealthScanner " + NativeApp.Version;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(1030, 660);
        MinimumSize = new Size(850, 520);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Surface;
        ForeColor = Ink;
        Font = new Font("Segoe UI", 10F);
        if (File.Exists(Application.ExecutablePath)) Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("ForgeSplash.png"))
        using (var image = Image.FromStream(stream)) artwork.Image = new Bitmap(image);

        var heading = new Label { Text = "ForgeHealthScanner", Font = new Font(Font.FontFamily, 20F, FontStyle.Bold), AutoSize = true, ForeColor = Ink };
        var edition = new Label { Text = "FORGE TECHNOLOGIES  /  " + NativeApp.Version, AutoSize = true, ForeColor = Accent, Padding = new Padding(2, 2, 0, 0) };
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, FlowDirection = FlowDirection.TopDown, WrapContents = false, Height = 85, Padding = new Padding(16, 8, 12, 0) };
        top.Controls.AddRange(new Control[] { edition, heading });
        var actionBar = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(12, 0, 10, 5) };
        actionBar.Controls.AddRange(new Control[] { scan, history, import, export, print, cleanup, defender, programs, about });
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(12, 6, 10, 8) };
        progress.Margin = new Padding(8, 10, 8, 0);
        progress.MaximumSize = new Size(385, 0);
        bottom.Controls.AddRange(new Control[] { saveHistory, activity, cancel, progress });
        splashCaption.Text = "Forge Technologies  |  Version " + NativeApp.Version;
        splash.Controls.Add(artwork);
        splash.Controls.Add(splashCaption);

        filter.Items.AddRange(new object[] { "All checks", "Warnings", "Passed", "Needs review", "Information" });
        filter.SelectedIndex = 0;
        filter.SelectedIndexChanged += (s, e) => RenderChecks();
        var filterBar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 37, Padding = new Padding(9, 1, 0, 0) };
        filterBar.Controls.Add(filter);
        var checkDetails = new Panel { Dock = DockStyle.Bottom, Height = 110, Padding = new Padding(5) };
        checkDetails.Controls.Add(details);
        var results = new TabPage("Scan results");
        results.Controls.Add(checks);
        results.Controls.Add(checkDetails);
        results.Controls.Add(filterBar);
        results.Controls.Add(summary);
        var comparison = new TabPage("Warning changes");
        comparison.Controls.Add(changes);
        tabs.TabPages.AddRange(new[] { results, comparison });
        Controls.Add(tabs);
        Controls.Add(splash);
        Controls.Add(bottom);
        Controls.Add(actionBar);
        Controls.Add(top);
        splash.BringToFront();

        checks.CurrentCellChanged += (s, e) => ShowSelectedCheck();
        scan.Click += async (s, e) => await RunScan();
        cancel.Click += (s, e) => { if (pending != null) { pending.Cancel(); cancel.Enabled = false; } };
        history.Click += (s, e) => OpenHistory();
        import.Click += (s, e) => ImportReport();
        export.Click += (s, e) => ExportReport();
        cleanup.Click += (s, e) => { try { NativeCleanup.Show(this); } catch (Exception ex) { Error(ex.Message); } };
        defender.Click += async (s, e) => await QuickScan();
        programs.Click += (s, e) => {
            try { using (Process.Start(new ProcessStartInfo("ms-settings:appsfeatures") { UseShellExecute = true })) { } }
            catch (Win32Exception) { Error("Open Settings > Apps > Installed apps to select a program and choose Uninstall."); }
        };
        about.Click += (s, e) => NativeTools.About(this, artwork.Image);
        print.Click += (s, e) => {
            try { if (current != null) NativeTools.Print(this, current); }
            catch (Exception ex) { Error("Printing failed. " + ex.Message); }
        };
        timer.Tick += (s, e) => UpdateProgress();
        Shown += async (s, e) => {
            if (quick)
            {
                CommandResult = 1223;
                CommandResult = await QuickScan();
                if (IsDisposed) return;
                if (CommandResult != 0) { Close(); return; }
            }
            await RunScan();
        };
        FormClosing += (s, e) => {
            if (quickRunning && MessageBox.Show(this, "Defender may continue scanning. Close this window and stop monitoring it?", "Defender quick scan",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) e.Cancel = true;
            else if (!KeepCurrent()) e.Cancel = true;
            else if (pending != null) pending.Cancel();
        };
        SetBusy(false);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            timer.Dispose();
            if (artwork.Image != null) artwork.Image.Dispose();
        }
        base.Dispose(disposing);
    }

    internal static Button Button(string text, bool primary = false)
    {
        var control = new Button { Text = text, AutoSize = true, Height = 34, Padding = new Padding(6, 2, 6, 2), Cursor = Cursors.Hand };
        if (primary) { control.FlatStyle = FlatStyle.Flat; control.BackColor = Accent; control.ForeColor = Color.White; }
        return control;
    }

    static DataGridView Grid(params string[] headings)
    {
        var grid = new DataGridView { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false,
            AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, RowHeadersVisible = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect,
            MultiSelect = false, BackgroundColor = Color.White, BorderStyle = BorderStyle.None, ClipboardCopyMode = DataGridViewClipboardCopyMode.Disable };
        grid.RowTemplate.Height = 31;
        for (int i = 0; i < headings.Length; i++) grid.Columns.Add(new DataGridViewTextBoxColumn {
            Name = headings[i], HeaderText = headings[i], FillWeight = i == 0 ? 25 : i == 1 ? 70 : 115,
            SortMode = DataGridViewColumnSortMode.NotSortable
        });
        return grid;
    }

    void SetBusy(bool busy)
    {
        scan.Enabled = history.Enabled = import.Enabled = cleanup.Enabled = defender.Enabled = !busy;
        cancel.Enabled = busy;
        saveHistory.Enabled = busy;
        print.Enabled = !busy && current != null;
        activity.Visible = busy;
        export.Enabled = !busy && current != null;
    }

    async Task<int> QuickScan()
    {
        if (quickRunning || MessageBox.Show(this, "Start a Microsoft Defender quick scan? Windows may ask for administrator approval.",
            "Defender quick scan", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return 1223;
        quickRunning = true;
        SetBusy(true);
        cancel.Enabled = false;
        saveHistory.Enabled = false;
        progress.Text = "Waiting for Microsoft Defender…";
        try
        {
            int code = await Task.Run((Func<int>)NativeCollector.DefenderQuickScan);
            if (!IsDisposed) MessageBox.Show(this, code == 0 ? "Defender finished the quick scan. Review Protection history for results." :
                "Defender returned code " + code + ". Open Windows Security > Protection history for details.", "Defender quick scan");
            return code;
        }
        catch (Win32Exception ex)
        {
            if (!IsDisposed) Error(ex.NativeErrorCode == 1223 ? "Defender scan canceled at Windows approval." : "Defender could not start. " + ex.Message);
            return ex.NativeErrorCode == 0 ? 1 : ex.NativeErrorCode;
        }
        catch (Exception ex) { if (!IsDisposed) Error(ex.Message); return 1; }
        finally
        {
            quickRunning = false;
            if (!IsDisposed) { progress.Text = "Ready"; SetBusy(false); }
        }
    }

    bool KeepCurrent()
    {
        return !unsaved || MessageBox.Show(this, "Discard the current unsaved scan? Choose No to keep it open for export.",
            "Unsaved scan", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
    }

    void UpdateProgress() { progress.Text = currentStep + "  •  " + elapsed.Elapsed.ToString(@"mm\:ss"); }
    void Error(string message) { MessageBox.Show(this, message, "ForgeHealthScanner", MessageBoxButtons.OK, MessageBoxIcon.Warning); }

    async Task RunScan()
    {
        if (pending != null || !KeepCurrent()) return;
        saveHistory.Checked = false;
        var source = pending = new CancellationTokenSource();
        SetBusy(true);
        splash.Visible = current == null;
        currentStep = "Preparing scan…";
        elapsed.Restart();
        activity.Value = 0;
        UpdateProgress();
        timer.Start();
        var updates = new Progress<Tuple<string, int, int>>(update => {
            if (pending != source || IsDisposed) return;
            currentStep = "Checking " + update.Item1;
            activity.Maximum = update.Item3;
            activity.Value = update.Item2;
            UpdateProgress();
        });
        try
        {
            var report = await Task.Run(() => NativeCollector.Collect((step, n, total) =>
                ((IProgress<Tuple<string, int, int>>)updates).Report(Tuple.Create(step, n, total)), source.Token));
            source.Token.ThrowIfCancellationRequested();
            if (IsDisposed) return;
            ShowReport(report);
            unsaved = true;
            if (saveHistory.Checked)
            {
                try { ScanReports.WriteHistory(report, ScanReports.Folder); unsaved = false; }
                catch (Exception) { Error("The scan completed, but history could not be saved. Use Export JSON to keep it."); }
            }
            progress.Text = unsaved ? "Scan complete" : "Scan saved to local history";
        }
        catch (OperationCanceledException) { if (!IsDisposed) progress.Text = "Scan canceled"; }
        catch (Exception) { if (!IsDisposed) { progress.Text = "Scan stopped"; Error("The scan could not be completed."); } }
        finally
        {
            pending = null;
            source.Dispose();
            if (!IsDisposed) { timer.Stop(); splash.Hide(); SetBusy(false); }
        }
    }

    internal void ShowReport(ScanReport report)
    {
        current = report;
        unsaved = false;
        int warnings = report.checks.Count(c => c.status == "warning");
        int unknown = report.checks.Count(c => c.status == "unknown");
        summary.Text = report.device + "  |  " + report.Timestamp.ToLocalTime().ToString("g") + Environment.NewLine
            + report.checks.Count + " checks  •  " + warnings + " warnings  •  " + unknown + " need review";
        changes.Rows.Clear();
        tabs.SelectedIndex = 0;
        filter.SelectedIndex = 0;
        splash.Hide();
        RenderChecks();
        print.Enabled = export.Enabled = true;
    }

    void RenderChecks()
    {
        checks.Rows.Clear();
        if (current == null) return;
        var keys = new[] { "", "warning", "pass", "unknown", "info" };
        var labels = new[] { "", "Warning", "Passed", "Needs review", "Information" };
        foreach (var item in current.checks)
        {
            int index = Array.IndexOf(keys, item.status);
            if (filter.SelectedIndex != 0 && index != filter.SelectedIndex) continue;
            int row = checks.Rows.Add(labels[index], item.name, item.detail);
            checks.Rows[row].Tag = item;
            if (item.status == "warning") checks.Rows[row].Cells[0].Style.ForeColor = Color.SaddleBrown;
        }
        if (checks.Rows.Count != 0) checks.CurrentCell = checks.Rows[0].Cells[0];
        ShowSelectedCheck();
    }

    void ShowSelectedCheck()
    {
        var check = checks.CurrentRow == null ? null : checks.CurrentRow.Tag as ScanCheck;
        details.Text = check == null ? "" : check.detail + Environment.NewLine + Environment.NewLine + check.action;
    }

    void OpenHistory()
    {
        using (var dialog = new HistoryWindow())
        {
            if (dialog.ShowDialog(this) != DialogResult.OK || !KeepCurrent()) return;
            ShowReport(dialog.Newer);
            if (dialog.Older == null) return;
            foreach (var change in dialog.Changes) changes.Rows.Add(change.State, change.Name, change.Detail);
            if (dialog.Changes.Count == 0) changes.Rows.Add("No warning changes", "", "");
            tabs.SelectedIndex = 1;
            progress.Text = "Compared scans from " + dialog.Older.Timestamp.ToLocalTime().ToString("g") + " and " + dialog.Newer.Timestamp.ToLocalTime().ToString("g");
        }
    }

    void ImportReport()
    {
        using (var dialog = new OpenFileDialog { Filter = "Health reports (*.json)|*.json", RestoreDirectory = true })
        {
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            try { var report = ScanReports.Read(dialog.FileName); if (KeepCurrent()) ShowReport(report); }
            catch (Exception ex) { Error(ex.Message); }
        }
    }

    void ExportReport()
    {
        if (current == null) return;
        using (var dialog = new SaveFileDialog { Filter = "Health reports (*.json)|*.json", FileName = "health-report.json", AddExtension = true, RestoreDirectory = true })
        {
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            try { ScanReports.WriteAtomic(dialog.FileName, current, true); unsaved = false; }
            catch (Exception ex) { Error(ex.Message); }
        }
    }
}

internal sealed class HistoryWindow : Form
{
    internal ScanReport Older, Newer;
    internal List<WarningChange> Changes;
    sealed class Entry
    {
        public FileInfo File;
        public override string ToString()
        {
            DateTime date;
            return DateTime.TryParseExact(File.Name.Substring(0, 15), "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out date)
                ? date.ToLocalTime().ToString("g") + "  |  " + File.Name.Substring(16, 6)
                : File.Name;
        }
    }

    internal HistoryWindow()
    {
        Text = "Saved scans";
        ClientSize = new Size(560, 226);
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        Font = new Font("Segoe UI", 10F);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(14), AutoScroll = true };
        var title = new Label { AutoSize = true, Text = "Open one saved scan, or choose two to compare warnings." };
        var first = new ComboBox { Width = 510, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "First scan" };
        var second = new ComboBox { Width = 510, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = "Second scan" };
        var open = NativeWindow.Button("Open first scan");
        var compare = NativeWindow.Button("Compare saved scans", true);
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        buttons.Controls.AddRange(new Control[] { open, compare });
        try
        {
            var options = ScanReports.SavedFiles(ScanReports.Folder).Select(f => (object)new Entry { File = f }).ToArray();
            first.Items.AddRange(options);
            second.Items.AddRange(options);
            if (options.Length > 0) first.SelectedIndex = 0;
            else title.Text = "No saved scans yet. Enable local history before completing a scan.";
            if (options.Length > 1) second.SelectedIndex = 1;
        }
        catch (Exception) { title.Text = "Saved scans could not be listed."; }
        Action update = () => {
            open.Enabled = first.SelectedIndex >= 0;
            compare.Enabled = open.Enabled && second.SelectedIndex >= 0 && second.SelectedIndex != first.SelectedIndex;
        };
        first.SelectedIndexChanged += (s, e) => update();
        second.SelectedIndexChanged += (s, e) => update();
        Action<bool> choose = comparePair => {
            try
            {
                var a = ScanReports.Read(((Entry)first.SelectedItem).File.FullName);
                if (comparePair)
                {
                    var b = ScanReports.Read(((Entry)second.SelectedItem).File.FullName);
                    Older = a.Timestamp < b.Timestamp ? a : b;
                    Newer = a.Timestamp < b.Timestamp ? b : a;
                    Changes = ScanReports.Compare(Older, Newer);
                }
                else { Older = null; Newer = a; }
                DialogResult = DialogResult.OK;
                Close();
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Saved scans"); }
        };
        open.Click += (s, e) => choose(false);
        compare.Click += (s, e) => choose(true);
        layout.Controls.Add(title);
        layout.Controls.Add(new Label { Text = "First scan", AutoSize = true });
        layout.Controls.Add(first);
        layout.Controls.Add(new Label { Text = "Second scan", AutoSize = true });
        layout.Controls.Add(second);
        layout.Controls.Add(buttons);
        Controls.Add(layout);
        update();
    }
}
