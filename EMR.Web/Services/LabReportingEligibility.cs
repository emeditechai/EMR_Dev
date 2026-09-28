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

public sealed class LabReportingEligibility(ApplicationDbContext db) : ILabReportingEligibility
{
    private const string ItemKey = "LabReportingEligibility";
    public static readonly string[] PageCodes = ["LAB.LABREPORTING", "LAB.LABIMAGEREPORTING"];

    public async Task<LabReportingEligibilityResult> CheckAsync(HttpContext http)
    {
        if (http.Items[ItemKey] is LabReportingEligibilityResult cached) return cached;

        var user = http.User;
        var userId = user.GetUserId();
        var branchId = user.GetCurrentBranchId();
        var profile = await db.Users.AsNoTracking()
            .Where(u => u.Id == userId)
            .Select(u => new { u.FullName, u.IsActive, u.IsPathologist, u.IsLabTechnician })
            .FirstOrDefaultAsync();

        var allowed = profile is { IsActive: true }
                      && (user.IsSuperAdmin()
                          || profile.IsLabTechnician || profile.IsPathologist
                          || await db.UserRoles.AsNoTracking()
                                 .Where(ur => ur.UserId == userId && ur.IsActive && (ur.Branch_ID == null || ur.Branch_ID == branchId))
                                 .Join(db.Roles, ur => ur.RoleId, r => r.Id, (ur, r) => r.Name)
                                 .AnyAsync(name => name == "Administrator"));

        var result = new LabReportingEligibilityResult(allowed, profile?.FullName ?? user.Identity?.Name);
        http.Items[ItemKey] = result;
        return result;
    }
}
