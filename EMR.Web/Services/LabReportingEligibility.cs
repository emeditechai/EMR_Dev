using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// Who may work on Lab Reporting Entry and Image Reporting (on top of the page permission in Settings > Security):
///   - a super admin, or a user holding the Administrator role in the current branch - not checked further;
///   - otherwise an active user flagged "Is Lab Technician" or "Is Pathologist" in User Master.
/// Answered once per request.
/// </summary>
public interface ILabReportingEligibility
{
    Task<LabReportingEligibilityResult> CheckAsync(HttpContext http);
}

public sealed record LabReportingEligibilityResult(bool Allowed, string? UserName);

public sealed class LabReportingEligibility(ApplicationDbContext db, IAdministratorCheck administrators) : ILabReportingEligibility
{
    private const string ItemKey = "LabReportingEligibility";
    public static readonly string[] PageCodes = ["LAB.LABREPORTING", "LAB.LABIMAGEREPORTING"];

    public async Task<LabReportingEligibilityResult> CheckAsync(HttpContext http)
    {
        if (http.Items[ItemKey] is LabReportingEligibilityResult cached) return cached;

        var user = http.User;
        var userId = user.GetUserId();
        var profile = await db.Users.AsNoTracking()
            .Where(u => u.Id == userId)
            .Select(u => new { u.FullName, u.IsActive, u.IsPathologist, u.IsLabTechnician })
            .FirstOrDefaultAsync();

        var allowed = profile is { IsActive: true }
                      && (profile.IsLabTechnician || profile.IsPathologist
                          || await administrators.IsSuperAdminOrAdministratorAsync(http));

        var result = new LabReportingEligibilityResult(allowed, profile?.FullName ?? user.Identity?.Name);
        http.Items[ItemKey] = result;
        return result;
    }
}
