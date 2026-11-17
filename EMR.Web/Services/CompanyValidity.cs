using System.Collections.Concurrent;
using EMR.Web.Data;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Settings > Companies > Valid From / Valid To (SQLScripts/2472): a company's users may use the web application only
/// within these dates (both days included, server date). Checked at sign-in (AccountController) and on every signed-in
/// request (cookie validation, after the idle check) - the dates are cached 5 minutes per company, so a request costs no
/// query; saving a company drops its cache. The Super Admin is never refused. Mobile apps are not affected.
/// </summary>
public static class CompanyValidity
{
    /// <summary>Short-lived cookie telling the sign-in page why a session was ended.</summary>
    public const string ReasonCookie = "emr_signout_reason";
    public const string ReasonCode = "company_validity";

    private static readonly TimeSpan CacheFor = TimeSpan.FromMinutes(5);
    private static readonly ConcurrentDictionary<int, (DateTime From, DateTime To, DateTime At)> Cache = new();

    public static bool IsValidOn(DateTime validFrom, DateTime validTo, DateTime day) =>
        day.Date >= validFrom.Date && day.Date <= validTo.Date;

    /// <summary>The sign-in refusal, or null when the dates allow today.</summary>
    public static string? RefusalFor(string? companyName, DateTime validFrom, DateTime validTo, DateTime today)
    {
        if (IsValidOn(validFrom, validTo, today)) return null;
        var who = string.IsNullOrWhiteSpace(companyName) ? "Your organisation" : companyName.Trim();
        return today.Date < validFrom.Date
            ? $"{who} can use the application from {validFrom:dd MMM yyyy}. Sign-in is not allowed before that date - contact your administrator."
            : $"{who}'s access to the application ended on {validTo:dd MMM yyyy}. Sign-in is not allowed - contact your administrator to renew it.";
    }

    public static void Invalidate(int companyId) => Cache.TryRemove(companyId, out _);

    /// <summary>Cookie validation step (Program.cs, after IdleSessionPolicy): ends a session whose company is outside its dates.</summary>
    public static async Task ValidateAsync(CookieValidatePrincipalContext context)
    {
        var principal = context.Principal;
        if (principal is null) return;                                           // already rejected (idle)
        if (principal.HasClaim("IsSuperAdmin", "true")) return;
        if (!int.TryParse(principal.FindFirst("CompanyId")?.Value, out var companyId) || companyId <= 0) return;

        (DateTime From, DateTime To)? dates = null;
        if (Cache.TryGetValue(companyId, out var hit) && DateTime.UtcNow - hit.At < CacheFor)
            dates = (hit.From, hit.To);
        else
        {
            try
            {
                var db = context.HttpContext.RequestServices.GetRequiredService<ApplicationDbContext>();
                var row = await db.CompanyMasters.AsNoTracking().Where(c => c.CompanyId == companyId)
                    .Select(c => new { c.ValidFrom, c.ValidTo }).FirstOrDefaultAsync();
                if (row is null) return;
                dates = (row.ValidFrom, row.ValidTo);
                Cache[companyId] = (row.ValidFrom, row.ValidTo, DateTime.UtcNow);
            }
            catch
            {
                return;                                                          // a database hiccup never signs anybody out
            }
        }

        if (IsValidOn(dates.Value.From, dates.Value.To, DateTime.Today)) return;
        context.RejectPrincipal();
        await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        context.HttpContext.Response.Cookies.Append(ReasonCookie, ReasonCode,
            new CookieOptions { HttpOnly = true, IsEssential = true, SameSite = SameSiteMode.Lax, Expires = DateTimeOffset.UtcNow.AddMinutes(5) });
    }
}
