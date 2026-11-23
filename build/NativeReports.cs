using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public sealed class ScanCheck
{
    public string name { get; set; }
    public string status { get; set; }
    public string detail { get; set; }
    public string action { get; set; }
    public string id { get; set; }
}

public sealed class ScanReport
{
    public int schemaVersion { get; set; }
    public string source { get; set; }
    public string collectorVersion { get; set; }
    public string collectedAt { get; set; }
    public string device { get; set; }
    public string os { get; set; }
    public List<ScanCheck> checks { get; set; }
    internal DateTimeOffset Timestamp { get { return DateTimeOffset.Parse(collectedAt, CultureInfo.InvariantCulture); } }
}

internal sealed class WarningChange
{
    public readonly string Name, State, Detail;
    public WarningChange(string name, string state, string detail) { Name = name; State = state; Detail = detail; }
}

internal static class ScanReports
{
    const int MaxBytes = 1024 * 1024;
    static readonly Regex SavedName = new Regex(@"\A[0-9]{8}-[0-9]{6}-[a-f0-9]{32}\.json\z");
    internal static string Folder { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HealthScan", "scan-history"); } }
    internal static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = MaxBytes, RecursionLimit = 16 }; }

    internal static byte[] ReadBounded(string path)
    {
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (file.Length < 1 || file.Length > MaxBytes) throw new InvalidDataException("The file must be a JSON report smaller than 1 MB.");
            var bytes = new byte[(int)file.Length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int read = file.Read(bytes, offset, bytes.Length - offset);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
            }
            return bytes;
        }
    }

    internal static ScanReport Read(string path)
    {
        var report = Serializer().Deserialize<ScanReport>(Encoding.UTF8.GetString(ReadBounded(path)).TrimStart('\uFEFF'));
        DateTimeOffset timestamp;
        if (report == null || report.schemaVersion != 1 || report.source != "windows-collector"
            || string.IsNullOrWhiteSpace(report.device) || report.device.Length > 1000 || report.os == null || report.os.Length > 1000
            || !DateTimeOffset.TryParse(report.collectedAt, CultureInfo.InvariantCulture, DateTimeStyles.None, out timestamp)
            || report.checks == null || report.checks.Count == 0 || report.checks.Count > 500
            || report.checks.Any(c => c == null || string.IsNullOrWhiteSpace(c.name) || c.name.Length > 1000
                || c.detail == null || c.detail.Length > 10000 || c.action == null || c.action.Length > 10000
                || (c.status != "pass" && c.status != "warning" && c.status != "unknown" && c.status != "info")
                || (c.id != null && !Regex.IsMatch(c.id, @"\A[A-Za-z0-9:_-]{1,128}\z"))))
            throw new InvalidDataException("This is not a supported Windows health report.");
        return report;
    }

    internal static void CheckLocalFolder(string folder)
    {
        for (var dir = new DirectoryInfo(folder); dir != null; dir = dir.Parent)
        {
            try
            {
                if ((File.GetAttributes(dir.FullName) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Local storage cannot use a redirected folder.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    internal static string WriteHistory(ScanReport report, string folder)
    {
        CheckLocalFolder(folder);
        Directory.CreateDirectory(folder);
        CheckLocalFolder(folder);
        string name = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N") + ".json";
        string path = Path.Combine(folder, name);
        WriteAtomic(path, report, false);
        return path;
    }

    internal static void WriteAtomic(string path, object value, bool replace)
    {
        string stage = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        // Older dashboards accept an omitted identifier, but reject a JSON null identifier.
        string json = Serializer().Serialize(value);
        if (value is ScanReport)
        {
            var data = Serializer().Deserialize<Dictionary<string, object>>(json);
            foreach (var entry in (System.Collections.IEnumerable)data["checks"])
            {
                var check = (Dictionary<string, object>)entry;
                if (check["id"] == null) check.Remove("id");
            }
            json = Serializer().Serialize(data);
        }
        var bytes = new UTF8Encoding(false).GetBytes(json);
        if (bytes.Length > MaxBytes) throw new InvalidDataException("The report is larger than the supported limit.");
        try
        {
            using (var output = new FileStream(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(bytes, 0, bytes.Length);
                output.Flush(true);
            }
            if (replace && File.Exists(path)) File.Replace(stage, path, null);
            else File.Move(stage, path);
        }
        finally { if (File.Exists(stage)) File.Delete(stage); }
    }

    internal static IEnumerable<FileInfo> SavedFiles(string folder)
    {
        CheckLocalFolder(folder);
        var dir = new DirectoryInfo(folder);
        if (!dir.Exists || (dir.Attributes & FileAttributes.ReparsePoint) != 0) return new FileInfo[0];
        return dir.EnumerateFiles("*.json").Where(f => SavedName.IsMatch(f.Name)
                && (f.Attributes & FileAttributes.ReparsePoint) == 0)
            .OrderByDescending(f => f.Name, StringComparer.Ordinal).Take(250).ToArray();
    }

    internal static List<WarningChange> Compare(ScanReport older, ScanReport newer)
    {
        if (!string.Equals(older.device.Trim(), newer.device.Trim(), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Choose two scans from the same PC.");
        if (older.Timestamp >= newer.Timestamp) throw new InvalidDataException("Choose scans from different times.");
        Func<ScanCheck, string> key = c => c.id == null ? "name:" + c.name : "id:" + c.id;
        var oldChecks = older.checks.GroupBy(key).ToDictionary(g => g.Key, g => g.ToList());
        var newChecks = newer.checks.GroupBy(key).ToDictionary(g => g.Key, g => g.ToList());
        if (oldChecks.Values.Concat(newChecks.Values).Any(group => group.Count != 1))
            throw new InvalidDataException("These reports contain duplicate check identifiers or names.");
        var changes = new List<WarningChange>();
        var matched = new HashSet<ScanCheck>();
        foreach (var check in newer.checks)
        {
            List<ScanCheck> group;
            ScanCheck previous = oldChecks.TryGetValue(key(check), out group) ? group[0] : null;
            if (previous == null)
            {
                var candidates = older.checks.Where(c => c.name == check.name && (c.id == null || check.id == null)).ToArray();
                if (candidates.Length == 1 && newer.checks.Count(c => c.name == check.name) == 1) previous = candidates[0];
            }
            if (previous != null) matched.Add(previous);
            bool changedRules = !string.Equals(older.collectorVersion, newer.collectorVersion, StringComparison.Ordinal);
            bool uncertainBattery = check.name.StartsWith("Battery health:", StringComparison.Ordinal) &&
                (check.id == null || (previous != null && previous.id == null));
            if ((changedRules || uncertainBattery) && (check.status == "warning" || (previous != null && previous.status == "warning")) &&
                (previous == null || previous.status != check.status))
                changes.Add(new WarningChange(check.name, "Needs review", uncertainBattery ? "Battery identity could not be verified." : "Collector versions differ. Review the results because the check rules may have changed."));
            else if (check.status == "warning" && (previous == null || previous.status != "warning"))
                changes.Add(new WarningChange(check.name, "New warning", check.detail));
            else if (previous != null && previous.status == "warning" && check.status != "warning")
                changes.Add(new WarningChange(check.name, check.status == "pass" ? "Resolved warning" : "Needs review", check.detail));
        }
        foreach (var check in older.checks.Where(c => c.status == "warning" && !matched.Contains(c)))
            changes.Add(new WarningChange(check.name, "Needs review", "This check is missing from the newer report."));
        return changes;
    }
}
