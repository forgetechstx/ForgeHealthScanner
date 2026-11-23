using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

public sealed class StartupEntry
{
    public string Name { get; set; }
    public string Command { get; set; }
    public string Path { get; set; }
    public override string ToString() { return Name + "   |   " + Command; }
}

public sealed class CleanupRecord
{
    public int Schema { get; set; }
    public string Id { get; set; }
    public string Sid { get; set; }
    public string State { get; set; }
    public string CompletedAt { get; set; }
    public string Backup { get; set; }
    public List<StartupEntry> Entries { get; set; }
    public override string ToString() { return State == "prepared" ? "Interrupted cleanup (" + Entries.Count + " candidates)" : CompletedAt + "   |   " + Entries.Count + " removed"; }
}

internal static class NativeCleanup
{
    internal const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HealthScan", "registry-backups");
    static readonly Regex CommandPattern = new Regex(@"\A\s*(?:""([A-Za-z]:\\[^""\r\n]+\.exe)""|([A-Za-z]:\\[^\s""\r\n]+\.exe))\s*\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    static readonly Regex IdPattern = new Regex(@"\A[a-f0-9]{32}\z");

    internal static string ExecutablePath(string command)
    {
        if (string.IsNullOrEmpty(command) || command.Length > 32767 || command.IndexOfAny(new[] { '%', '*', '?', '\0' }) >= 0) return null;
        Match match = CommandPattern.Match(command);
        if (!match.Success) return null;
        string path = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
        if (path.IndexOf(':', 2) >= 0) return null;
        try { return Path.GetFullPath(path); }
        catch (Exception) { return null; }
    }

    internal static bool MissingLocalExecutable(string path)
    {
        if (path == null) return false;
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(path));
            if (drive.DriveType != DriveType.Fixed || !drive.IsReady) return false;
            var directory = new DirectoryInfo(Path.GetDirectoryName(path));
            if (!directory.Exists) return false;
            for (DirectoryInfo parent = directory; parent != null; parent = parent.Parent)
                if ((parent.Attributes & FileAttributes.ReparsePoint) != 0) return false;
            // Windows resolves the complete path, including 8.3 aliases. Access failures stay inconclusive.
            try { File.GetAttributes(path); return false; }
            catch (FileNotFoundException) { return true; }
        }
        catch (Exception) { return false; }
    }

    internal static List<StartupEntry> Find(RegistryKey key)
    {
        var matches = new List<StartupEntry>();
        if (key == null) return matches;
        foreach (string name in key.GetValueNames())
        {
            if (name.Length == 0) continue;
            try
            {
                if (key.GetValueKind(name) != RegistryValueKind.String) continue;
                string command = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                string path = ExecutablePath(command);
                if (MissingLocalExecutable(path)) matches.Add(new StartupEntry { Name = name, Command = command, Path = path });
            }
            catch (IOException) { } // A value can disappear while the list is being read.
        }
        return matches;
    }

    static string CurrentSid() { using (var identity = WindowsIdentity.GetCurrent()) return identity.User.Value; }

    static string Backup(string runPath, string folder)
    {
        ScanReports.CheckLocalFolder(folder);
        Directory.CreateDirectory(folder);
        var directory = new DirectoryInfo(folder);
        if (((directory.Attributes | directory.Parent.Attributes) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("The backup folder cannot be a redirected link.");
        string file = Path.Combine(folder, "startup-run-" + Guid.NewGuid().ToString("N") + ".reg");
        string args = "export \"HKCU\\" + runPath + "\" \"" + file + "\"";
        using (var process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "reg.exe"), args)
            { UseShellExecute = false, CreateNoWindow = true }))
        {
            if (!process.WaitForExit(15000)) throw new IOException("Creating the registry backup timed out.");
            if (process.ExitCode != 0 || !File.Exists(file) || new FileInfo(file).Length < 32)
                throw new IOException("Windows could not create the registry backup.");
        }
        return file;
    }

    internal static bool Apply(RegistryKey key, StartupEntry item, bool restore)
    {
        if (item == null || string.IsNullOrWhiteSpace(item.Name) || item.Name.IndexOf('\0') >= 0) return false;
        string path = ExecutablePath(item.Command);
        if (path == null || !string.Equals(path, item.Path, StringComparison.OrdinalIgnoreCase) || (!restore && !MissingLocalExecutable(path))) return false;
        return RegistryAtomic.Apply(key, item.Name, item.Command, restore, null);
    }

    internal static string Remove(List<StartupEntry> entries, string runPath, string folder)
    {
        var record = new CleanupRecord {
            Schema = 1, Id = Guid.NewGuid().ToString("N"), State = "prepared", Sid = CurrentSid(),
            CompletedAt = "", Backup = "", Entries = entries
        };
        if (entries.Count > 1000 || Encoding.UTF8.GetByteCount(ScanReports.Serializer().Serialize(record)) > 1024 * 1024 - 4096)
            throw new InvalidDataException("Select fewer entries before removing them.");
        using (var key = Registry.CurrentUser.OpenSubKey(runPath, true))
        {
            if (key == null) throw new IOException("The current-user Run key is unavailable.");
            record.Backup = Backup(runPath, folder);
            string path = Path.Combine(folder, "cleanup-" + record.Id + ".json");
            ScanReports.WriteAtomic(path, record, false);
            var removed = new List<StartupEntry>();
            foreach (StartupEntry item in entries)
            {
                try { if (Apply(key, item, false)) removed.Add(item); }
                catch (System.ComponentModel.Win32Exception) { }
            }
            record.Entries = removed;
            record.State = "completed";
            record.CompletedAt = DateTimeOffset.UtcNow.ToString("o");
            try { ScanReports.WriteAtomic(path, record, true); }
            catch (Exception)
            {
                return "Removed " + removed.Count + " entries. The backup is available, but the recovery journal could not be finalized.";
            }
            return "Removed " + removed.Count + ", skipped " + (entries.Count - removed.Count) + ". A registry backup and recovery journal were saved.";
        }
    }

    internal static IEnumerable<CleanupRecord> Records(string location)
    {
        ScanReports.CheckLocalFolder(location);
        if (!Directory.Exists(location)) yield break;
        var folder = new DirectoryInfo(location);
        if (((folder.Attributes | folder.Parent.Attributes) & FileAttributes.ReparsePoint) != 0) yield break;
        string sid = CurrentSid();
        foreach (var file in folder.EnumerateFiles("cleanup-*.json").OrderByDescending(f => f.LastWriteTimeUtc).Take(250))
        {
            if ((file.Attributes & FileAttributes.ReparsePoint) != 0) continue;
            CleanupRecord record;
            try { record = ScanReports.Serializer().Deserialize<CleanupRecord>(Encoding.UTF8.GetString(ScanReports.ReadBounded(file.FullName)).TrimStart('\uFEFF')); }
            catch (Exception) { continue; }
            if (record != null && record.Schema == 1 && record.Sid == sid && record.Id != null && IdPattern.IsMatch(record.Id)
                && file.Name == "cleanup-" + record.Id + ".json" && (record.State == "prepared" || record.State == "completed")
                && record.Entries != null && record.Entries.Count > 0 && record.Entries.Count <= 1000
                && record.Entries.All(e => e != null && !string.IsNullOrWhiteSpace(e.Name) && ExecutablePath(e.Command) != null && string.Equals(ExecutablePath(e.Command), e.Path, StringComparison.OrdinalIgnoreCase)))
                yield return record;
        }
    }

    static void Restore(IWin32Window owner)
    {
        using (var form = new Form { Text = "Startup cleanup recovery", Size = new Size(760, 430), StartPosition = FormStartPosition.CenterParent })
        {
            var records = new ComboBox { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDownList };
            var entries = new CheckedListBox { Dock = DockStyle.Fill, CheckOnClick = true, HorizontalScrollbar = true };
            var confirm = new Button { Text = "Restore selected", Dock = DockStyle.Bottom, Height = 36 };
            records.Items.AddRange(Records(Folder).Cast<object>().ToArray());
            records.SelectedIndexChanged += (s, e) => {
                entries.Items.Clear();
                var record = records.SelectedItem as CleanupRecord;
                if (record != null) entries.Items.AddRange(record.Entries.Cast<object>().ToArray());
            };
            if (records.Items.Count == 0) { MessageBox.Show(owner, "No readable recovery journals were found."); return; }
            records.SelectedIndex = 0;
            confirm.Click += (s, e) => {
                var record = (CleanupRecord)records.SelectedItem;
                var selected = entries.CheckedItems.Cast<StartupEntry>().ToArray();
                if (selected.Length == 0) return;
                string prompt = record.State == "prepared"
                    ? "This cleanup was interrupted. Only restore entries you know were removed. Restore the selected entries?"
                    : "Restore the selected entries? Existing startup values will be kept.";
                if (MessageBox.Show(form, prompt + Environment.NewLine + string.Join(Environment.NewLine, selected.Select(item => item.ToString()).Take(10)) + (selected.Length > 10 ? Environment.NewLine + "See the checked list for all remaining commands." : ""), "Confirm restore", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                int restored = 0;
                using (var key = Registry.CurrentUser.OpenSubKey(RunPath, true))
                {
                    if (key == null) { MessageBox.Show(form, "The current-user Run key is unavailable."); return; }
                    foreach (var item in selected)
                    {
                        try { if (Apply(key, item, true)) restored++; }
                        catch (System.ComponentModel.Win32Exception) { }
                    }
                }
                MessageBox.Show(form, "Restored " + restored + ", skipped " + (selected.Length - restored) + ".");
            };
            form.Controls.Add(entries);
            form.Controls.Add(records);
            form.Controls.Add(confirm);
            form.ShowDialog(owner);
        }
    }

    internal static void Show(IWin32Window owner)
    {
        if (NativeCollector.Elevated())
        {
            MessageBox.Show(owner, "Open ForgeHealthScanner normally to review your own startup entries.", "Startup cleanup");
            return;
        }
        using (var form = new Form { Text = "Review startup entries", Size = new Size(780, 480), StartPosition = FormStartPosition.CenterParent })
        {
            var list = new CheckedListBox { Dock = DockStyle.Fill, CheckOnClick = true, HorizontalScrollbar = true };
            var info = new Label { Dock = DockStyle.Top, Height = 42, Padding = new Padding(7), Text = "Review missing local executables for your current Windows account. Check only entries you want to remove." };
            var toolbar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 42 };
            var remove = NativeWindow.Button("Remove selected");
            var recovery = NativeWindow.Button("History and undo");
            var backups = NativeWindow.Button("Open backups");
            toolbar.Controls.AddRange(new Control[] { remove, recovery, backups });
            Func<Task> refresh = async () => {
                toolbar.Enabled = false;
                try
                {
                    var found = await Task.Run(() => {
                        using (var key = Registry.CurrentUser.OpenSubKey(RunPath)) return Find(key);
                    });
                    if (form.IsDisposed) return;
                    list.Items.Clear();
                    list.Items.AddRange(found.Cast<object>().ToArray());
                    remove.Enabled = found.Count != 0;
                }
                catch (Exception ex) { if (!form.IsDisposed) MessageBox.Show(form, ex.Message, "Could not read startup entries"); }
                finally { if (!form.IsDisposed) toolbar.Enabled = true; }
            };
            remove.Click += async (s, e) => {
                var selected = list.CheckedItems.Cast<StartupEntry>().ToList();
                if (selected.Count == 0) return;
                if (MessageBox.Show(form, "Back up the Run key and remove the selected missing entries?", "Confirm removal", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                try { MessageBox.Show(form, Remove(selected, RunPath, Folder), "Startup cleanup"); await refresh(); }
                catch (Exception ex) { MessageBox.Show(form, ex.Message, "Startup cleanup could not finish"); }
            };
            recovery.Click += async (s, e) => {
                try { Restore(form); await refresh(); }
                catch (Exception ex) { MessageBox.Show(form, ex.Message, "Recovery could not finish"); }
            };
            backups.Click += (s, e) => {
                try { NativeTools.Backups(form, Folder); }
                catch (Exception ex) { MessageBox.Show(form, ex.Message, "Could not open backups"); }
            };
            form.Controls.Add(list);
            form.Controls.Add(info);
            form.Controls.Add(toolbar);
            form.Shown += async (s, e) => await refresh();
            form.ShowDialog(owner);
        }
    }
}
