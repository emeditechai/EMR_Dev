using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;

namespace EMR.Web.Services;

/// <summary>
/// Idle sign-out enforced by the server (default 60 minutes; Security:IdleTimeoutMinutes in appsettings).
///
/// The sign-in cookie slides, so ANY request renews it - including requests the user never made: the bell's poll
/// every minute (SignalR falls back to it when IIS has WebSockets off), auto-refreshing dashboards, the notification
/// hub. On IIS that kept a session alive forever. The time of the last REAL activity is therefore kept in the cookie
/// itself ("emr.la") and only real requests move it; background ones (the hub, and requests the browser marks with
/// X-EMR-Background: 1) do not. Once it is older than the limit, the cookie is rejected on the next request of any
/// kind and the user is sent to the login page.
/// </summary>
public static class IdleSessionPolicy
{
    public const string ActivityKey = "emr.la";
    public const string BackgroundHeader = "X-EMR-Background";
    public static int IdleMinutes { get; private set; } = 60;

    public static void Configure(IConfiguration config)
    {
        var m = config.GetValue<int?>("Security:IdleTimeoutMinutes");
        if (m is >= 5 and <= 24 * 60) IdleMinutes = m.Value;
    }

    /// <summary>A request the user did not make: the notification hub, or one the page marked as background.</summary>
    public static bool IsBackground(HttpRequest r) =>
        r.Path.StartsWithSegments("/hubs")
        || string.Equals(r.Headers[BackgroundHeader], "1", StringComparison.Ordinal);

    public static async Task ValidateAsync(CookieValidatePrincipalContext context)
    {
        var props = context.Properties;
        var now = DateTimeOffset.UtcNow;
        DateTimeOffset last = props.Items.TryGetValue(ActivityKey, out var s) && long.TryParse(s, out var ticks)
            ? new DateTimeOffset(ticks, TimeSpan.Zero)
            : props.IssuedUtc ?? now;

        if (now - last > TimeSpan.FromMinutes(IdleMinutes))
        {
            context.RejectPrincipal();
            await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return;
        }

        // real activity moves the clock (at most once a minute, so the cookie is not re-issued on every request)
        if (!IsBackground(context.Request) && now - last > TimeSpan.FromMinutes(1))
        {
            props.Items[ActivityKey] = now.UtcTicks.ToString();
            context.ShouldRenew = true;
        }
    }
}
