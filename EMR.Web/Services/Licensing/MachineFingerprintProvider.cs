using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// Reads this server's MAC address, disk serial and motherboard id once per process (the same sources and
/// normalisation the vendor's other products use, so a licence row reads the same everywhere):
///   Windows  active NIC (Ethernet before Wi-Fi) · Win32_DiskDrive serial, Win32_PhysicalMedia, wmic, MachineGuid ·
///            Win32_BaseBoard serial, wmic, MachineGuid
///   macOS    networksetup (en0 first) · diskutil partition UUID, NVMe/SATA serial · IOPlatformUUID, hardware UUID
///   Linux    active NIC · lsblk serial, product_uuid, machine-id · board_serial, product_serial, product_uuid
/// Every value is upper-case letters and digits only; an empty value becomes UNAVAILABLE.
/// </summary>
public interface IMachineFingerprintProvider
{
    MachineFingerprint Current { get; }
    void Reset();
}

public sealed class MachineFingerprintProvider : IMachineFingerprintProvider
{
    private static readonly object Gate = new();
    private static MachineFingerprint? _cached;

    public MachineFingerprint Current
    {
        get
        {
            if (_cached != null) return _cached;
            lock (Gate)
            {
                if (_cached != null) return _cached;
                var (mac, disk, board) = OperatingSystem.IsWindows() ? ReadWindows()
                    : OperatingSystem.IsMacOS() ? ReadMac()
                    : OperatingSystem.IsLinux() ? ReadLinux()
                    : (string.Empty, string.Empty, string.Empty);
                mac = Normalize(string.IsNullOrWhiteSpace(mac) ? PrimaryMac() : mac);
                disk = Normalize(disk);
                board = Normalize(board);
                _cached = new MachineFingerprint
                {
                    ServerMacID = mac, HardDiskNumber = disk, MotherboardNumber = board,
                    Hash = HashOf(mac, disk, board), CapturedAt = DateTime.Now
                };
                return _cached;
            }
        }
    }

    public void Reset() { lock (Gate) _cached = null; }

    public static string Normalize(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "UNAVAILABLE";
        var normalized = new string(value.Trim().ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());
        return normalized.Length == 0 ? "UNAVAILABLE" : normalized;
    }

    public static string HashOf(string mac, string disk, string board) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{Normalize(mac)}|{Normalize(disk)}|{Normalize(board)}")));

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static (string, string, string) ReadWindows()
    {
        var disk = Run("powershell.exe", "-NoProfile -NonInteractive -Command \"try { (Get-CimInstance Win32_DiskDrive | Where-Object { $_.SerialNumber } | Select-Object -First 1 -ExpandProperty SerialNumber).Trim() } catch {}\"");
        if (string.IsNullOrWhiteSpace(disk))
            disk = Run("powershell.exe", "-NoProfile -NonInteractive -Command \"try { (Get-CimInstance Win32_PhysicalMedia | Where-Object { $_.SerialNumber } | Select-Object -First 1 -ExpandProperty SerialNumber).Trim() } catch {}\"");
        if (string.IsNullOrWhiteSpace(disk)) disk = Run("wmic", "diskdrive get serialnumber");
        if (string.IsNullOrWhiteSpace(disk)) disk = WindowsMachineGuid();

        var board = Run("powershell.exe", "-NoProfile -NonInteractive -Command \"try { (Get-CimInstance Win32_BaseBoard | Select-Object -First 1 -ExpandProperty SerialNumber).Trim() } catch {}\"");
        if (string.IsNullOrWhiteSpace(board)) board = Run("wmic", "baseboard get serialnumber");
        if (string.IsNullOrWhiteSpace(board)) board = WindowsMachineGuid();
        return (PrimaryMac(), disk, board);
    }

    private static string WindowsMachineGuid()
    {
        var output = RunRaw("reg", @"query ""HKLM\SOFTWARE\Microsoft\Cryptography"" /v MachineGuid");
        foreach (var line in Lines(output))
        {
            var i = line.IndexOf("REG_SZ", StringComparison.OrdinalIgnoreCase);
            if (i >= 0) return line[(i + 6)..].Trim().Trim('{', '}');
        }
        return string.Empty;
    }

    private static (string, string, string) ReadMac()
    {
        var mac = MacOsPrimaryMac();
        var disk = ByLabel(RunRaw("diskutil", "info /"), "Disk / Partition UUID", "Volume UUID");
        if (string.IsNullOrWhiteSpace(disk)) disk = ByLabel(RunRaw("system_profiler", "SPNVMeDataType SPSerialATADataType"), "Serial Number");
        var board = ByKey(RunRaw("ioreg", "-rd1 -c IOPlatformExpertDevice"), "IOPlatformUUID", "IOPlatformSerialNumber");
        if (string.IsNullOrWhiteSpace(board)) board = ByLabel(RunRaw("system_profiler", "SPHardwareDataType"), "Hardware UUID", "Serial Number (system)");
        return (mac, disk, board);
    }

    private static (string, string, string) ReadLinux()
    {
        var disk = Run("lsblk", "-ndo SERIAL");
        if (string.IsNullOrWhiteSpace(disk)) disk = FirstFile("/sys/class/dmi/id/product_uuid", "/etc/machine-id");
        var board = FirstFile("/sys/class/dmi/id/board_serial", "/sys/class/dmi/id/product_serial", "/sys/class/dmi/id/product_uuid");
        return (PrimaryMac(), disk, board);
    }

    private static string PrimaryMac()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up
                            && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                            && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                .Select(n => new { Address = n.GetPhysicalAddress()?.ToString(), Score = Priority(n) })
                .Where(x => !string.IsNullOrWhiteSpace(x.Address))
                .OrderByDescending(x => x.Score)
                .FirstOrDefault()?.Address ?? string.Empty;
        }
        catch { return string.Empty; }
    }

    private static int Priority(NetworkInterface n)
    {
        var name = n.Name ?? string.Empty;
        if (string.Equals(name, "en0", StringComparison.OrdinalIgnoreCase)) return 500;
        if (n.NetworkInterfaceType == NetworkInterfaceType.Ethernet) return 450;
        if (n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211) return 400;
        if (name.StartsWith("eth", StringComparison.OrdinalIgnoreCase)) return 350;
        if (name.StartsWith("en", StringComparison.OrdinalIgnoreCase)) return 300;
        return 100;
    }

    private static string MacOsPrimaryMac()
    {
        var output = RunRaw("networksetup", "-listallhardwareports");
        if (string.IsNullOrWhiteSpace(output)) return PrimaryMac();
        var found = new List<(string Device, string Port, string Address)>();
        string port = string.Empty, device = string.Empty;
        foreach (var line in Lines(output))
        {
            if (line.StartsWith("Hardware Port:", StringComparison.OrdinalIgnoreCase)) port = line[14..].Trim();
            else if (line.StartsWith("Device:", StringComparison.OrdinalIgnoreCase)) device = line[7..].Trim();
            else if (line.StartsWith("Ethernet Address:", StringComparison.OrdinalIgnoreCase))
            {
                var address = line[17..].Trim();
                if (!string.IsNullOrWhiteSpace(address)) found.Add((device, port, address));
            }
        }
        var pick = found.FirstOrDefault(x => string.Equals(x.Device, "en0", StringComparison.OrdinalIgnoreCase));
        if (string.IsNullOrWhiteSpace(pick.Address))
            pick = found.FirstOrDefault(x => x.Port.Contains("Wi-Fi", StringComparison.OrdinalIgnoreCase) || x.Port.Contains("Ethernet", StringComparison.OrdinalIgnoreCase));
        return string.IsNullOrWhiteSpace(pick.Address) ? PrimaryMac() : pick.Address;
    }

    private static IEnumerable<string> Lines(string? text) =>
        (text ?? string.Empty).Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim());

    private static string Run(string file, string args) =>
        Lines(RunRaw(file, args)).FirstOrDefault(l => l.Length > 0 && !l.Equals("SerialNumber", StringComparison.OrdinalIgnoreCase)) ?? string.Empty;

    private static string RunRaw(string file, string args)
    {
        try
        {
            using var p = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = file, Arguments = args, RedirectStandardOutput = true, RedirectStandardError = true,
                    UseShellExecute = false, CreateNoWindow = true
                }
            };
            if (!p.Start()) return string.Empty;
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(10000))
            {
                try { p.Kill(entireProcessTree: true); } catch { /* best effort */ }
                return string.Empty;
            }
            Task.WaitAll(new Task[] { stdout, stderr }, 1000);
            var output = stdout.Result;
            return (string.IsNullOrWhiteSpace(output) ? stderr.Result : output).Trim();
        }
        catch { return string.Empty; }
    }

    private static string ByLabel(string? output, params string[] labels)
    {
        foreach (var line in Lines(output))
            foreach (var label in labels)
                if (line.StartsWith(label + ":", StringComparison.OrdinalIgnoreCase))
                    return line[(label.Length + 1)..].Trim().Trim('"');
        return string.Empty;
    }

    private static string ByKey(string? output, params string[] keys)
    {
        foreach (var line in Lines(output))
            foreach (var key in keys)
            {
                var marker = $"\"{key}\" = ";
                var i = line.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
                if (i >= 0) return line[(i + marker.Length)..].Trim().Trim('"');
            }
        return string.Empty;
    }

    private static string FirstFile(params string[] paths)
    {
        foreach (var path in paths)
        {
            try
            {
                if (!File.Exists(path)) continue;
                var text = File.ReadAllText(path).Trim();
                if (text.Length > 0) return text;
            }
            catch { /* unreadable: try the next source */ }
        }
        return string.Empty;
    }
}
