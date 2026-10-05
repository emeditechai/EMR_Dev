using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace EMR.Web.Services.Licensing;

/// <summary>
/// This machine's local licence keys (signing + encryption, 32 bytes each), created on first start when none are
/// configured. Kept outside the application folder, so a publish never replaces them:
///   Windows: %ProgramData%\eCare360\Licensing (folder limited to this app pool's identity, SYSTEM and Administrators;
///            the file is DPAPI-protected for this machine, so a copy is useless elsewhere)
///   others:  ~/.ecare360/licensing (owner-only file)
///   fallback: App_Data/Licensing under the application.
/// Losing them is harmless: the local licence copy is then untrusted, the licence server decides, and the copy is
/// re-signed with the new keys.
/// </summary>
public static class LocalKeyStore
{
    private const int KeyBytes = 64;
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("eCare360.Licensing.LocalKeys.v1");

    public static (byte[] Signing, byte[] Encryption)? LoadOrCreate(string contentRootPath, out string? location, out string? error)
    {
        location = null;
        error = null;
        // one key file per application folder, so two installations on one machine never share keys
        var root = Path.GetFullPath(contentRootPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToLowerInvariant();
        var name = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root)))[..16] + ".key";
        foreach (var dir in Candidates(contentRootPath))
        {
            try
            {
                var path = Path.Combine(dir, name);
                var keys = ReadOrCreate(dir, path);
                location = path;
                return (keys[..32], keys[32..]);
            }
            catch (Exception ex) { error = $"{dir}: {ex.Message}"; }
        }
        return null;
    }

    private static IEnumerable<string> Candidates(string contentRootPath)
    {
        if (OperatingSystem.IsWindows())
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "eCare360", "Licensing");
        else
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrEmpty(home)) yield return Path.Combine(home, ".ecare360", "licensing");
        }
        yield return Path.Combine(contentRootPath, "App_Data", "Licensing");
    }

    private static byte[] ReadOrCreate(string dir, string path)
    {
        if (File.Exists(path))
        {
            try
            {
                var keys = Unprotect(File.ReadAllBytes(path));
                if (keys.Length == KeyBytes) return keys;
            }
            catch (CryptographicException) { /* protected on another machine or damaged: replaced below */ }
            File.Delete(path);
        }

        CreateDirectory(dir);
        var fresh = RandomNumberGenerator.GetBytes(KeyBytes);
        try
        {
            // CreateNew: if another process of this application created it a moment ago, use that one
            using (var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                fs.Write(Protect(fresh));
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            return fresh;
        }
        catch (IOException) when (File.Exists(path))
        {
            var keys = Unprotect(File.ReadAllBytes(path));
            if (keys.Length == KeyBytes) return keys;
            throw;
        }
    }

    private static void CreateDirectory(string dir)
    {
        if (Directory.Exists(dir)) return;
        Directory.CreateDirectory(dir);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            return;
        }
        try
        {
            // only this identity (the IIS app pool), SYSTEM and Administrators
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            var me = WindowsIdentity.GetCurrent().User;
            if (me != null) security.AddAccessRule(new FileSystemAccessRule(me, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(dir).SetAccessControl(security);
        }
        catch { /* the DPAPI protection of the file still applies */ }
    }

    private static byte[] Protect(byte[] keys) =>
        OperatingSystem.IsWindows() ? ProtectedData.Protect(keys, Entropy, DataProtectionScope.LocalMachine) : keys;

    private static byte[] Unprotect(byte[] stored) =>
        OperatingSystem.IsWindows() ? ProtectedData.Unprotect(stored, Entropy, DataProtectionScope.LocalMachine) : stored;
}
