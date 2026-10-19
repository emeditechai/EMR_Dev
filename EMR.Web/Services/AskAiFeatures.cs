using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.Services;

/// <summary>
/// Hospital Settings > LAB > "Enable Ask AI Features" (SQLScripts/2302), per branch. When off, the AI Help Assistant is
/// not offered: no Ask AI box or button on the Home dashboard, no assistant panel, no assistant in the Help Center, and
/// questions are refused (the Help Center guides, workflows and FAQs stay). The value is kept in memory per branch (no
/// database call per page) and dropped when Hospital Settings are saved.
/// </summary>
public interface IAskAiFeatures
{
    Task<bool> IsEnabledAsync(HttpContext http);
}

public sealed class AskAiFeatures(ApplicationDbContext db, IMemoryCache cache) : IAskAiFeatures
{
    private static string Key(int branchId) => "AskAiFeatures:" + branchId;

    /// <summary>Forget the cached value of a branch (Hospital Settings saved).</summary>
    public static void Invalidate(IMemoryCache cache, int branchId) => cache.Remove(Key(branchId));

    public async Task<bool> IsEnabledAsync(HttpContext http)
    {
        if (http.User.Identity?.IsAuthenticated != true) return false;
        var branchId = http.Session.GetInt32("SelectedBranchId") ?? http.User.GetCurrentBranchId() ?? 0;
        if (cache.TryGetValue(Key(branchId), out bool on)) return on;

        on = await db.HospitalSettings.AsNoTracking()
            .Where(s => s.BranchId == branchId)
            .OrderByDescending(s => s.IsActive).ThenByDescending(s => s.Id)
            .Select(s => (bool?)s.EnableAskAiFeatures)
            .FirstOrDefaultAsync() ?? false;
        cache.Set(Key(branchId), on, TimeSpan.FromMinutes(10));
        return on;
    }
}
