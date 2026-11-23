using System.Net;
using System.Text.RegularExpressions;
using EMR.Shared.Security;

namespace EMR.Web.Services;

/// <summary>
/// Login screen (SQLScripts/2383): a WhatsApp security alert to the user after repeated wrong passwords on their
/// account - when the count reaches Hospital Settings > Login Alert After Wrong Attempts, and once more if the account
/// gets locked. The message names the time, the public IP the attempt came from and the browser / device.
/// A failure here never changes the sign-in result.
/// </summary>
public interface ILoginAlertNotifier
{
    Task NotifyFailureAsync(int userId, bool justLocked, HttpContext http);
}

public class LoginAlertNotifier(ILoginSecurity loginSecurity, IWhatsAppService whatsApp, IAuditLogService audit,
    ILogger<LoginAlertNotifier> logger) : ILoginAlertNotifier
{
    public async Task NotifyFailureAsync(int userId, bool justLocked, HttpContext http)
    {
        try
        {
            var a = await loginSecurity.FailureAlertAsync(userId, justLocked);
            if (a is null || !a.ShouldAlert) return;
            if (string.IsNullOrWhiteSpace(a.Mobile) || a.BranchId is not int branchId)
            {
                await audit.LogAsync("AuthFailure", "Login", $"Wrong-password alert not sent to {a?.UserName}: no mobile number in User Master.", userId);
                return;
            }
            var config = await whatsApp.GetActiveConfigAsync(branchId);
            if (config is null || !config.IsEnabled)
            {
                await audit.LogAsync("AuthFailure", "Login", $"Wrong-password alert not sent to {a.UserName}: WhatsApp is not configured for the branch.", userId);
                return;
            }

            var ip = ClientIp(http);
            var browser = Browser(http.Request.Headers.UserAgent.ToString());
            var text =
                $"⚠️ *Security alert - eCare360Plus+*\n\n" +
                $"Hello {a.UserName},\n" +
                $"there {(a.FailedAttempts == 1 ? "was 1 wrong password attempt" : $"were {a.FailedAttempts} wrong password attempts")} to sign in to your account" +
                $"{(string.IsNullOrWhiteSpace(a.Email) ? "" : $" ({a.Email})")}.\n\n" +
                $"🕒 Time: {DateTime.Now:dd-MMM-yyyy hh:mm tt}\n" +
                $"🌐 IP address: {ip}\n" +
                $"💻 Browser: {browser}\n" +
                (a.LockedUntil > DateTime.Now ? $"🔒 Your account is locked until {a.LockedUntil:hh:mm tt}.\n" : "") +
                "\nIf this was not you, please change your password and inform the administrator.";

            var result = await whatsApp.SendTextMessageAsync(a.Mobile!, text, branchId, "LOGIN", userId);
            await audit.LogAsync("AuthFailure", "Login",
                result.Success ? $"Wrong-password alert sent on WhatsApp to {a.UserName} ({a.FailedAttempts} attempts, IP {ip})."
                               : $"Wrong-password alert to {a.UserName} failed: {result.ErrorMessage}", userId);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Wrong-password WhatsApp alert failed for user {UserId}", userId);
        }
    }

    /// <summary>The client's address (the forwarded-headers middleware has already applied X-Forwarded-For), marked when
    /// it is not a public address (same network as the server).</summary>
    private static string ClientIp(HttpContext http)
    {
        var raw = http.Request.Headers["CF-Connecting-IP"].FirstOrDefault();
        var addr = IPAddress.TryParse(raw, out var cf) ? cf : http.Connection.RemoteIpAddress;
        if (addr is null) return "unknown";
        if (addr.IsIPv4MappedToIPv6) addr = addr.MapToIPv4();
        var s = addr.ToString();
        return IsPrivate(addr) ? $"{s} (local network)" : s;
    }

    private static bool IsPrivate(IPAddress a)
    {
        if (IPAddress.IsLoopback(a)) return true;
        if (a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6) return a.IsIPv6LinkLocal || a.IsIPv6SiteLocal || a.IsIPv6UniqueLocal;
        var b = a.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
    }

    /// <summary>"Chrome 141 on macOS" from the User-Agent (the raw text when it is not recognised).</summary>
    private static string Browser(string ua)
    {
        if (string.IsNullOrWhiteSpace(ua)) return "unknown";
        static string? V(string ua, string pattern) { var m = Regex.Match(ua, pattern); return m.Success ? m.Groups[1].Value.Split('.')[0] : null; }
        string? name = null, ver = null;
        if ((ver = V(ua, @"Edg[A-Za-z]*/([\d.]+)")) != null) name = "Edge";
        else if ((ver = V(ua, @"OPR/([\d.]+)")) != null) name = "Opera";
        else if ((ver = V(ua, @"SamsungBrowser/([\d.]+)")) != null) name = "Samsung Internet";
        else if ((ver = V(ua, @"Firefox/([\d.]+)")) != null) name = "Firefox";
        else if ((ver = V(ua, @"(?:Chrome|CriOS)/([\d.]+)")) != null) name = "Chrome";
        else if (ua.Contains("Safari") && (ver = V(ua, @"Version/([\d.]+)")) != null) name = "Safari";

        var os = ua.Contains("Windows NT") ? "Windows"
               : ua.Contains("Android") ? "Android"
               : ua.Contains("iPhone") || ua.Contains("iPad") ? "iOS"
               : ua.Contains("Mac OS X") ? "macOS"
               : ua.Contains("Linux") ? "Linux" : null;
        if (name is null) return ua.Length > 120 ? ua[..120] : ua;
        return $"{name} {ver}{(os is null ? "" : " on " + os)}";
    }
}
