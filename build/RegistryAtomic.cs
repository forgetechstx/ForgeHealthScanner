// Conditional, transacted updates to current-user registry values.
// If transactions are unavailable or conflict, no non-transactional fallback is used.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

public static class RegistryAtomic
{
    const int Success = 0, FileNotFound = 2, RegSz = 1;
    const int QueryValue = 1, SetValue = 2;
    [DllImport("ktmw32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateTransaction(IntPtr attributes, IntPtr uow, uint options, uint isolationLevel, uint isolationFlags, uint timeout, string description);
    [DllImport("ktmw32.dll", SetLastError = true)] static extern bool CommitTransaction(IntPtr transaction);
    [DllImport("ktmw32.dll", SetLastError = true)] static extern bool RollbackTransaction(IntPtr transaction);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegOpenKeyTransacted(IntPtr root, string subkey, int options, int access, out IntPtr key, IntPtr transaction, IntPtr extended);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegQueryValueEx(IntPtr key, string name, IntPtr reserved, out int type, byte[] data, ref int size);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegDeleteValue(IntPtr key, string name);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegSetValueEx(IntPtr key, string name, int reserved, int type, byte[] data, int size);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);

    static string Subkey(RegistryKey key)
    {
        const string prefix = "HKEY_CURRENT_USER\\";
        if (key == null || !key.Name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Only a current-user key can be changed.");
        return key.Name.Substring(prefix.Length);
    }

    // The callback is supplied only by isolated regression tests to force interleavings.
    public static bool Apply(RegistryKey original, string name, string expected, bool restore, Action afterRead)
    {
        if (string.IsNullOrEmpty(name) || expected == null) throw new ArgumentException("A name and value are required.");
        string subkey = Subkey(original);
        IntPtr tx = CreateTransaction(IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 15000, "HealthScan startup cleanup");
        if (tx == new IntPtr(-1) || tx == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr key = IntPtr.Zero;
        bool committed = false;
        try
        {
            int status = RegOpenKeyTransacted(Registry.CurrentUser.Handle.DangerousGetHandle(), subkey, 0, QueryValue | SetValue, out key, tx, IntPtr.Zero);
            if (status != Success) throw new Win32Exception(status);
            // A transacted read alone does not reserve the key: a normal writer can change a
            // value after the read. Acquire a write intent first; the private marker is removed
            // inside the same transaction and is never committed as a persistent value.
            string marker = "HealthScan-Tx-" + Guid.NewGuid().ToString("N");
            byte[] markerBytes = Encoding.Unicode.GetBytes("\0");
            status = RegSetValueEx(key, marker, 0, RegSz, markerBytes, markerBytes.Length);
            if (status != Success) throw new Win32Exception(status);
            int type, size = 0;
            status = RegQueryValueEx(key, name, IntPtr.Zero, out type, null, ref size);
            if (restore)
            {
                if (status != FileNotFound) { if (status != Success) throw new Win32Exception(status); return false; }
            }
            else
            {
                if (status == FileNotFound) return false;
                if (status != Success) throw new Win32Exception(status);
                if (type != RegSz || size < 0 || size > 65536) return false;
                byte[] bytes = new byte[size];
                status = RegQueryValueEx(key, name, IntPtr.Zero, out type, bytes, ref size);
                if (status != Success) throw new Win32Exception(status);
                if (type != RegSz || (size & 1) != 0 || !string.Equals(Encoding.Unicode.GetString(bytes, 0, size).TrimEnd('\0'), expected, StringComparison.Ordinal)) return false;
            }
            if (afterRead != null) afterRead();
            if (restore)
            {
                byte[] bytes = Encoding.Unicode.GetBytes(expected + "\0");
                status = RegSetValueEx(key, name, 0, RegSz, bytes, bytes.Length);
            }
            else status = RegDeleteValue(key, name);
            if (status != Success) throw new Win32Exception(status);
            status = RegDeleteValue(key, marker);
            if (status != Success) throw new Win32Exception(status);
            if (!CommitTransaction(tx)) throw new Win32Exception(Marshal.GetLastWin32Error());
            committed = true;
            return true;
        }
        finally
        {
            if (key != IntPtr.Zero) RegCloseKey(key);
            if (!committed) RollbackTransaction(tx);
            CloseHandle(tx);
        }
    }
}
