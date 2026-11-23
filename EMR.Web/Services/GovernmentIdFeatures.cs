using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.Services;

/// <summary>Hospital Settings > OPD > ABHA / Ayushman Bharat (SQLScripts/2355): which optional fields the forms show.</summary>
public readonly record struct GovernmentIdOptions(bool Abha, bool AyushmanBharat);

/// <summary>
/// The switches are per company (saved on every branch's settings row). When off, OPD and LAB forms look exactly as before
/// and a saved number stays on the patient. The value is kept in memory per company and dropped when Hospital Settings are saved.
/// </summary>
public interface IGovernmentIdFeatures
{
    Task<GovernmentIdOptions> GetAsync(HttpContext http);
}

public sealed class GovernmentIdFeatures(ApplicationDbContext db, IMemoryCache cache) : IGovernmentIdFeatures
{
    private static string Key(int companyId) => "GovernmentIdFeatures:" + companyId;

    /// <summary>Forget the cached value of a company (Hospital Settings saved).</summary>
    public static void Invalidate(IMemoryCache cache, int companyId) => cache.Remove(Key(companyId));

    public async Task<GovernmentIdOptions> GetAsync(HttpContext http)
    {
        var companyId = http.User.GetCompanyId();
        if (cache.TryGetValue(Key(companyId), out GovernmentIdOptions options)) return options;

        var settings = db.HospitalSettings.AsNoTracking().Where(s => s.CompanyId == companyId);
        options = new GovernmentIdOptions(
            await settings.AnyAsync(s => s.EnableAbha),
            await settings.AnyAsync(s => s.EnableAyushmanBharat));
        cache.Set(Key(companyId), options, TimeSpan.FromMinutes(10));
        return options;
    }
}
