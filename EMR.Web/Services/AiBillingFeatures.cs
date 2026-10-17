using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace EMR.Web.Services;

/// <summary>
/// Hospital Settings > LAB > "Enable AI Features at Billing" (SQLScripts/2286), per branch. When off, B2C / B2B booking
/// show no AI prescription assist and no Smart ID Scan, and their endpoints refuse - billing works exactly as before.
/// The server switch PrescriptionAssist:Enabled (appsettings) must be on as well. The value is kept in memory per
/// branch (no database call per page) and dropped when Hospital Settings are saved.
/// </summary>
public interface IAiBillingFeatures
{
    Task<bool> IsEnabledAsync(HttpContext http);
}

public sealed class AiBillingFeatures(ApplicationDbContext db, IMemoryCache cache,
    IOptionsMonitor<PrescriptionAssist.PrescriptionAssistOptions> options) : IAiBillingFeatures
{
    private static string Key(int branchId) => "AiBillingFeatures:" + branchId;

    /// <summary>Forget the cached value of a branch (Hospital Settings saved).</summary>
    public static void Invalidate(IMemoryCache cache, int branchId) => cache.Remove(Key(branchId));

    public async Task<bool> IsEnabledAsync(HttpContext http)
    {
        if (!options.CurrentValue.Enabled) return false;
        var branchId = http.Session.GetInt32("SelectedBranchId") ?? http.User.GetCurrentBranchId() ?? 0;
        if (cache.TryGetValue(Key(branchId), out bool on)) return on;

        on = await db.HospitalSettings.AsNoTracking()
            .Where(s => s.BranchId == branchId)
            .OrderByDescending(s => s.IsActive).ThenByDescending(s => s.Id)
            .Select(s => (bool?)s.EnableAiBillingFeatures)
            .FirstOrDefaultAsync() ?? false;
        cache.Set(Key(branchId), on, TimeSpan.FromMinutes(10));
        return on;
    }
}
