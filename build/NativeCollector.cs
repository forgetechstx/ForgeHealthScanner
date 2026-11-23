using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

internal static class NativeCollector
{
    const string Cim = @"root\cimv2";
    const string Defender = @"root\Microsoft\Windows\Defender";
    static readonly TimeSpan ProviderTimeout = TimeSpan.FromSeconds(12);
    // A stalled provider retains only its own slot. Other checks and later scans can proceed.
    static readonly ConcurrentDictionary<string, byte> RunningChecks = new ConcurrentDictionary<string, byte>();
    [DllImport("kernel32.dll")]
    static extern ulong GetTickCount64();

    internal static ScanCheck Check(string name, string status, string detail, string action)
    {
        return new ScanCheck { name = name, status = status, detail = detail, action = action };
    }

    static string Safe(object value)
    {
        var text = Regex.Replace(Convert.ToString(value, CultureInfo.InvariantCulture) ?? "", @"[\x00-\x1f\x7f]", " ").Trim();
        if (Environment.UserName.Length > 0)
            text = Regex.Replace(text, @"\b" + Regex.Escape(Environment.UserName) + @"\b", "[user]", RegexOptions.IgnoreCase);
        return text.Length > 180 ? text.Substring(0, 180) : text;
    }

    static long Number(object value) { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
    static string GiB(long bytes) { return (bytes / 1073741824d).ToString("0.0", CultureInfo.CurrentCulture) + " GB"; }

    internal static List<Dictionary<string, object>> Query(string scope, string query)
    {
        var options = new EnumerationOptions { Timeout = ProviderTimeout, ReturnImmediately = true, Rewindable = false };
        var result = new List<Dictionary<string, object>>();
        using (var searcher = new ManagementObjectSearcher(new ManagementScope(scope), new ObjectQuery(query), options))
        using (var objects = searcher.Get())
        {
            foreach (ManagementObject row in objects)
            {
                using (row) result.Add(row.Properties.Cast<PropertyData>().ToDictionary(p => p.Name, p => p.Value));
                if (result.Count >= 250) break;
            }
        }
        return result;
    }

    internal static ScanReport Collect(Action<string, int, int> progress, CancellationToken token)
    {
        var report = new ScanReport {
            schemaVersion = 1, source = "windows-collector", collectorVersion = NativeApp.Version,
            os = OperatingSystemLabel(), device = Environment.MachineName,
            checks = new List<ScanCheck>()
        };
        var steps = new[] {
            Step("Memory availability", Memory), Step("System uptime", Uptime),
            Step("Disk space", Disks), Step("Drive health", Drives),
            Step("Real-time antivirus protection", Antivirus), Step("Defender signatures", Signatures),
            Step("Active Defender detections", Threats), Step("Windows Firewall profiles", Firewall),
            Step("Restart pending", Restart), Step("Windows Update recency", UpdateRecency), Step("Pending Windows updates", PendingUpdates),
            Step("System drive encryption", Encryption), Step("Battery health", Battery),
            Step("Startup apps (inventory only)", Startup), Step("Windows version support", WindowsVersion),
            Step("Secure Boot", SecureBoot), Step("TPM security chip", Tpm), Step("User Account Control", Uac),
            Step("System stability (last 30 days)", Stability),
            Step("Drive error events (last 30 days)", DriveEvents),
            Step("Program crashes (last 7 days, inventory only)", AppEvents)
        };
        for (int i = 0; i < steps.Length; i++)
        {
            token.ThrowIfCancellationRequested();
            var step = steps[i];
            progress(step.Key, i, steps.Length);
            ScanCheck[] checks = ReadStep(step, token);
            report.checks.AddRange(checks);
        }
        token.ThrowIfCancellationRequested();
        report.collectedAt = DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        return report;
    }

    static KeyValuePair<string, Func<ScanCheck[]>> Step(string name, Func<ScanCheck[]> action)
    { return new KeyValuePair<string, Func<ScanCheck[]>>(name, action); }

    static ScanCheck[] ReadStep(KeyValuePair<string, Func<ScanCheck[]>> step, CancellationToken token)
    {
        if (!RunningChecks.TryAdd(step.Key, 0)) return Unknown(step.Key, "The previous request for this check is still running.");
        var work = Task.Run(() =>
        {
            try { return step.Value(); }
            catch (Exception) { return Unknown(step.Key, "Windows did not provide this check. It may be unavailable or require more access."); }
            finally { byte ignored; RunningChecks.TryRemove(step.Key, out ignored); }
        });
        if (!work.Wait(18000, token)) return Unknown(step.Key, "The Windows provider did not respond before the time limit.");
        return work.Result;
    }

    static ScanCheck[] One(string name, string status, string detail, string action = "Review the corresponding Windows settings.")
    { return new[] { Check(name, status, detail, action) }; }
    static ScanCheck[] Unknown(string name, string detail) { return One(name, "unknown", detail); }

    static string OperatingSystemLabel()
    {
        try
        {
            using (var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            using (var key = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
            {
                string build = key == null ? null : key.GetValue("CurrentBuildNumber") as string;
                return string.IsNullOrWhiteSpace(build) ? "Windows" : "Windows (build " + Safe(build) + ")";
            }
        }
        catch (System.Security.SecurityException) { return "Windows"; }
        catch (UnauthorizedAccessException) { return "Windows"; }
        catch (IOException) { return "Windows"; }
    }

    internal static bool LowDiskSpace(long free, long total, bool system)
    {
        const long gib = 1073741824L;
        return (Math.Round(100d * free / total) < 15 && free < 50 * gib) || (system && free < 10 * gib);
    }

    static ScanCheck[] Memory()
    {
        var data = Query(Cim, "SELECT FreePhysicalMemory,TotalVisibleMemorySize FROM Win32_OperatingSystem").First();
        long free = Number(data["FreePhysicalMemory"]), total = Number(data["TotalVisibleMemorySize"]);
        if (total <= 0 || free < 0 || free > total) return Unknown("Memory availability", "Windows did not report valid memory totals.");
        return One("Memory availability", free < total / 10 ? "warning" : "pass", GiB(free * 1024) + " available of " + GiB(total * 1024) + ".");
    }

    static ScanCheck[] Uptime()
    {
        double days = TimeSpan.FromMilliseconds(GetTickCount64()).TotalDays;
        return One("System uptime", days >= 14 ? "warning" : "pass", "Windows has been running for " + days.ToString("0.0") + " days.", "Restart when convenient if Windows has been running for a long time.");
    }

    static ScanCheck[] Disks()
    {
        var checks = new List<ScanCheck>();
        foreach (var drive in DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed))
        {
            string name = "Disk space " + drive.Name.TrimEnd('\\');
            try
            {
                if (!drive.IsReady || drive.TotalSize <= 0) throw new IOException();
                long free = drive.TotalFreeSpace, total = drive.TotalSize;
                double ratio = free / (double)total;
                checks.Add(Check(name, LowDiskSpace(free, total, string.Equals(drive.Name, Path.GetPathRoot(Environment.SystemDirectory), StringComparison.OrdinalIgnoreCase)) ? "warning" : "pass", ratio.ToString("P0") + " free (" + GiB(free) + ").", "Review Windows Storage settings."));
            }
            catch (IOException) { checks.Add(Check(name, "unknown", "Drive space could not be read.", "Review Windows Storage settings.")); }
        }
        return checks.Count == 0 ? Unknown("Disk space", "No fixed volumes were reported.") : checks.ToArray();
    }

    static ScanCheck[] Drives()
    {
        var disks = Query(@"root\Microsoft\Windows\Storage", "SELECT DeviceId,FriendlyName,HealthStatus FROM MSFT_PhysicalDisk");
        if (disks.Count == 0) return Unknown("Drive health", "No physical disk health data was returned.");
        return disks.Select(d => {
            var state = d["HealthStatus"];
            return Check("Drive health: Disk " + Safe(d["DeviceId"]) + " (" + Safe(d["FriendlyName"]) + ")",
                state == null ? "unknown" : Number(state) == 0 ? "pass" : Number(state) <= 2 ? "warning" : "unknown",
                state == null ? "Storage provider did not report a health state." : "Windows storage health code: " + Number(state) + ".",
                "Check drive health in Windows Storage settings and keep backups.");
        }).ToArray();
    }

    static ScanCheck[] Antivirus()
    {
        var names = Query(@"root\SecurityCenter2", "SELECT displayName FROM AntiVirusProduct").Select(p => Safe(p["displayName"])).ToArray();
        try
        {
            var state = Query(Defender, "SELECT RealTimeProtectionEnabled,AMRunningMode FROM MSFT_MpComputerStatus").First();
            if (!string.Equals(Convert.ToString(state["AMRunningMode"]), "Normal", StringComparison.OrdinalIgnoreCase))
                return Unknown("Real-time antivirus protection", "Defender is not in active mode. Registered antivirus: " + string.Join(", ", names) + ".");
            if (state["RealTimeProtectionEnabled"] is bool)
                return One("Real-time antivirus protection", (bool)state["RealTimeProtectionEnabled"] ? "pass" : "warning", "Registered antivirus: " + string.Join(", ", names) + ".", "Check Virus & threat protection in Windows Security.");
        }
        catch (ManagementException) { }
        return Unknown("Real-time antivirus protection", "Windows did not verify active protection. Registered antivirus: " + string.Join(", ", names) + ".");
    }

    internal static bool DefenderActive(object mode, object realtime)
    {
        return string.Equals(mode as string, "Normal", StringComparison.OrdinalIgnoreCase) && true.Equals(realtime);
    }

    static ScanCheck[] Signatures()
    {
        var data = Query(Defender, "SELECT AMRunningMode,RealTimeProtectionEnabled,AntivirusSignatureAge FROM MSFT_MpComputerStatus").First();
        if (!DefenderActive(data["AMRunningMode"], data["RealTimeProtectionEnabled"]))
            return Unknown("Defender signatures", "Defender is not providing verified real-time protection.");
        object age = data["AntivirusSignatureAge"];
        if (age == null || Number(age) >= UInt32.MaxValue) return Unknown("Defender signatures", "Signature age is unavailable.");
        return One("Defender signatures", Number(age) > 2 ? "warning" : "pass", "Defender signatures are " + Number(age) + " day(s) old.", "Review protection updates in Windows Security.");
    }

    static ScanCheck[] Threats()
    {
        var active = Query(Defender, "SELECT IsActive FROM MSFT_MpThreat WHERE IsActive=TRUE");
        if (active.Count > 0)
            return One("Active Defender detections", "warning", (active.Count == 250 ? "At least " : "") + active.Count + " active Defender detection(s).", "Review protection history in Windows Security.");
        var data = Query(Defender, "SELECT AMRunningMode,RealTimeProtectionEnabled FROM MSFT_MpComputerStatus").First();
        if (!DefenderActive(data["AMRunningMode"], data["RealTimeProtectionEnabled"]))
            return Unknown("Active Defender detections", "Defender is not providing verified real-time protection.");
        return One("Active Defender detections", "pass", "Defender reports no active detections.", "Review protection history in Windows Security.");
    }

    static T WithCom<T>(string program, Func<dynamic, T> use)
    {
        var type = Type.GetTypeFromProgID(program, true);
        object instance = Activator.CreateInstance(type);
        try { return use(instance); }
        finally { if (Marshal.IsComObject(instance)) Marshal.FinalReleaseComObject(instance); }
    }

    internal static string FirewallStatus(bool? enabled, int? inbound)
    {
        if (enabled == false || inbound == 1) return "warning";
        return enabled == true && inbound == 0 ? "pass" : "unknown";
    }

    static ScanCheck[] Firewall()
    {
        return WithCom("HNetCfg.FwPolicy2", firewall => {
            string overall = "pass";
            var details = new List<string>();
            foreach (int profile in new[] { 1, 2, 4 })
            {
                bool? enabled = null;
                int? inbound = null;
                try { enabled = (bool)firewall.FirewallEnabled[profile]; } catch (COMException) { }
                try { inbound = (int)firewall.DefaultInboundAction[profile]; } catch (COMException) { }
                string status = FirewallStatus(enabled, inbound);
                if (status == "warning" || overall == "pass") overall = status;
                details.Add((profile == 1 ? "Domain" : profile == 2 ? "Private" : "Public") + ": " +
                    (enabled == false ? "off" : inbound == 1 ? "allows inbound by default" : status == "pass" ? "enabled, blocks inbound by default" : "policy unavailable"));
            }
            return One("Windows Firewall profiles", overall, string.Join(". ", details) + ".", "Review Firewall & network protection.");
        });
    }

    static bool HasKey(string path) { using (var key = Registry.LocalMachine.OpenSubKey(path)) return key != null; }
    static ScanCheck[] Restart()
    {
        bool pending = HasKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
            || HasKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")
            || WithCom("Microsoft.Update.SystemInfo", system => (bool)system.RebootRequired);
        return One("Restart pending", pending ? "warning" : "pass", pending ? "Windows reports a pending restart." : "No update restart is pending.", "Review Windows Update settings.");
    }

    static ScanCheck[] PendingUpdates()
    {
        return WithCom("Microsoft.Update.Session", session => {
            object searcherObject = session.CreateUpdateSearcher();
            try
            {
                dynamic searcher = searcherObject;
                searcher.Online = false;
                searcher.CanAutomaticallyUpgradeService = false;
                object resultObject = searcher.Search("IsInstalled=0 and IsHidden=0 and BrowseOnly=0");
                try
                {
                    dynamic result = resultObject;
                    if ((int)result.ResultCode != 2) return Unknown("Pending Windows updates", "The offline update search did not complete.");
                    object collection = result.Updates;
                    try
                    {
                        int count = (int)((dynamic)collection).Count;
                        return One("Pending Windows updates", count > 0 ? "warning" : "info", count + " pending update(s) in the local Windows Update cache.", "Open Windows Update for the current status.");
                    }
                    finally { Marshal.FinalReleaseComObject(collection); }
                }
                finally { Marshal.FinalReleaseComObject(resultObject); }
            }
            finally { Marshal.FinalReleaseComObject(searcherObject); }
        });
    }

    static ScanCheck[] UpdateRecency()
    {
        return WithCom("Microsoft.Update.AutoUpdate", update => {
            object results = update.Results;
            try
            {
                DateTime last = (DateTime)((dynamic)results).LastSearchSuccessDate;
                if (last.Year < 2000) return Unknown("Windows Update recency", "Windows did not report a successful update search date.");
                if (last > DateTime.Now.AddDays(1)) return Unknown("Windows Update recency", "The last update search date is in the future.");
                using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"))
                {
                    foreach (string value in new[] { "PauseUpdatesExpiryTime", "PauseQualityUpdatesEndTime", "PauseFeatureUpdatesEndTime" })
                    {
                        DateTimeOffset until;
                        if (key != null && DateTimeOffset.TryParse(key.GetValue(value) as string, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out until) && until > DateTimeOffset.UtcNow)
                            return One("Windows Update recency", "warning", "Windows updates are paused until " + until.ToLocalTime().ToString("d") + ".", "Review the pause in Windows Update.");
                    }
                }
                return One("Windows Update recency", (DateTime.Now - last).TotalDays > 14 ? "warning" : "info", "Last successful update search: " + last.ToString("g") + ".", "Review recent installs in Windows Update history.");
            }
            finally { Marshal.FinalReleaseComObject(results); }
        });
    }

    static ScanCheck[] Encryption()
    {
        string drive = Path.GetPathRoot(Environment.SystemDirectory).TrimEnd('\\');
        var volume = Query(@"root\CIMV2\Security\MicrosoftVolumeEncryption", "SELECT ProtectionStatus,DriveLetter FROM Win32_EncryptableVolume")
            .FirstOrDefault(row => string.Equals(row["DriveLetter"] as string, drive, StringComparison.OrdinalIgnoreCase));
        if (volume == null || volume["ProtectionStatus"] == null) return Unknown("System drive encryption", "Windows did not report system drive protection.");
        long status = Number(volume["ProtectionStatus"]);
        return One("System drive encryption", status == 1 ? "pass" : status == 0 ? "warning" : "unknown",
            status == 1 ? "BitLocker protection is on." : status == 0 ? "BitLocker protection is off." : "Protection could not be verified.", "Check Device encryption or BitLocker settings.");
    }

    static ScanCheck[] Battery()
    {
        if (Query(Cim, "SELECT DeviceID FROM Win32_Battery").Count == 0) return One("Battery health", "info", "Windows did not report a battery.");
        var designs = Query(@"root\wmi", "SELECT * FROM BatteryStaticData WHERE Active=TRUE");
        var actual = Query(@"root\wmi", "SELECT * FROM BatteryFullChargedCapacity WHERE Active=TRUE");
        if (designs.Count == 0) return Unknown("Battery health", "Windows did not return battery capacity.");
        return designs.Select((d, index) => {
            string name = "Battery health: Battery " + (index + 1);
            string instance = Convert.ToString(d["InstanceName"]).Trim();
            bool unique = instance.Length > 0 && designs.Count(a => string.Equals(Convert.ToString(a["InstanceName"]).Trim(), instance, StringComparison.OrdinalIgnoreCase)) == 1;
            var row = actual.Where(a => unique && string.Equals(Convert.ToString(a["InstanceName"]).Trim(), instance, StringComparison.OrdinalIgnoreCase)).ToArray();
            long design = Number(d["DesignedCapacity"]);
            long full = row.Length == 1 ? Number(row[0]["FullChargedCapacity"]) : 0;
            object designTag, chargeTag;
            bool changed = row.Length == 1 && d.TryGetValue("Tag", out designTag) && row[0].TryGetValue("Tag", out chargeTag)
                && designTag != null && chargeTag != null && !object.Equals(designTag, chargeTag);
            bool capacityKnown = row.Length == 1 && !changed && design > 0 && full > 0 && design < UInt32.MaxValue && full < UInt32.MaxValue
                && d["Capabilities"] != null && (Number(d["Capabilities"]) & 0x40000000) == 0;
            var check = Check(name, capacityKnown ? (full / (double)design < 0.80 ? "warning" : "pass") : "unknown",
                capacityKnown ? (full / (double)design).ToString("P0") + " of design capacity." : "Battery capacity could not be verified.", "Review battery health with the manufacturer.");
            if (unique)
                using (var sha = SHA256.Create()) check.id = "battery:" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(instance.ToUpperInvariant()))).Replace("-", "").ToLowerInvariant();
            return check;
        }).ToArray();
    }

    static ScanCheck[] Startup()
    {
        int count = Query(Cim, "SELECT Name FROM Win32_StartupCommand").Count;
        return One("Startup apps (inventory only)", "info", (count == 250 ? "At least " : "") + count + " startup entries reported by Windows.", "Review Startup apps in Settings.");
    }

    static ScanCheck[] WindowsVersion()
    {
        using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
        {
            if (key == null) return Unknown("Windows version support", "Version information was unavailable.");
            return One("Windows version support", "info", "Version " + Safe(key.GetValue("DisplayVersion")) + ", build " + Safe(key.GetValue("CurrentBuildNumber")) + ".", "Check Microsoft Windows lifecycle for the servicing status of this edition.");
        }
    }

    static ScanCheck[] SecureBoot()
    {
        object state = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecureBoot\State", "UEFISecureBootEnabled", null);
        if (!(state is int) || ((int)state != 0 && (int)state != 1)) return Unknown("Secure Boot", "Windows did not report Secure Boot state.");
        bool enabled = (int)state == 1;
        return One("Secure Boot", enabled ? "pass" : "warning", enabled ? "Secure Boot is on." : "Secure Boot is off.", "Review the device security page in Windows Security.");
    }

    static ScanCheck[] Tpm()
    {
        var tpm = Query(@"root\CIMV2\Security\MicrosoftTpm", "SELECT IsEnabled_InitialValue,IsActivated_InitialValue FROM Win32_Tpm").FirstOrDefault();
        if (tpm == null || !(tpm["IsEnabled_InitialValue"] is bool) || !(tpm["IsActivated_InitialValue"] is bool))
            return Unknown("TPM security chip", "Windows did not report TPM status.");
        bool ready = (bool)tpm["IsEnabled_InitialValue"] && (bool)tpm["IsActivated_InitialValue"];
        return One("TPM security chip", ready ? "pass" : "warning", ready ? "TPM is enabled and activated." : "TPM is not enabled and activated.", "Review the security processor in Windows Security.");
    }

    static ScanCheck[] Uac()
    {
        const string key = @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";
        object enabled = Registry.GetValue(key, "EnableLUA", null);
        object prompts = Registry.GetValue(key, "ConsentPromptBehaviorAdmin", null);
        if (!(enabled is int) || !(prompts is int)) return Unknown("User Account Control", "Windows did not report the UAC policy.");
        bool on = (int)enabled == 1 && (int)prompts != 0;
        return One("User Account Control", on ? "pass" : "warning", on ? "UAC is enabled and administrator elevation uses prompts." : "UAC or administrator elevation prompts are disabled.", "Review User Account Control settings.");
    }

    static ScanCheck[] Events(string name, string log, int days, string match, bool warn)
    {
        string query = "*[System[(" + match + ") and TimeCreated[timediff(@SystemTime) <= " + (days * 86400000L).ToString(CultureInfo.InvariantCulture) + "]]]";
        int count = 0;
        using (var reader = new EventLogReader(new EventLogQuery(log, PathType.LogName, query)))
        {
            while (count < 500)
            {
                using (var entry = reader.ReadEvent(TimeSpan.FromSeconds(2)))
                {
                    if (entry == null) break;
                    count++;
                }
            }
        }
        string detail = (count >= 500 ? "At least " : "") + count + " matching events in the available Windows log.";
        using (var reader = new EventLogReader(new EventLogQuery(log, PathType.LogName)))
        using (var oldest = reader.ReadEvent(TimeSpan.FromSeconds(2)))
        {
            if (oldest == null || !oldest.TimeCreated.HasValue || oldest.TimeCreated.Value > DateTime.Now.AddDays(-days))
                detail += " Log coverage is shorter than the requested period or unavailable.";
        }
        return One(name, warn && count > 0 ? "warning" : "info", detail, "Review Reliability Monitor or Event Viewer for context.");
    }
    static ScanCheck[] Stability() { return Events("System stability (last 30 days)", "System", 30, "Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=41", true); }
    static ScanCheck[] DriveEvents() { return Events("Drive error events (last 30 days)", "System", 30, "(Provider[@Name='disk'] and (EventID=7 or EventID=11 or EventID=51 or EventID=153)) or (Provider[@Name='Ntfs'] and EventID=55)", true); }
    static ScanCheck[] AppEvents() { return Events("Program crashes (last 7 days, inventory only)", "Application", 7, "(Provider[@Name='Application Error'] and EventID=1000) or (Provider[@Name='Application Hang'] and EventID=1002)", false); }

    internal static bool Elevated()
    {
        using (var identity = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    internal static int DefenderQuickScan()
    {
        string binary = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Windows Defender", "MpCmdRun.exe");
        if (!File.Exists(binary)) throw new FileNotFoundException("Microsoft Defender's scan tool was unavailable.");
        return WaitForScan(new ProcessStartInfo(binary, "-Scan -ScanType 1") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden });
    }

    internal static int WaitForScan(ProcessStartInfo start)
    {
        using (var process = Process.Start(start))
        {
            if (process == null) throw new IOException("Windows did not start Defender.");
            process.WaitForExit();
            return process.ExitCode;
        }
    }
}
