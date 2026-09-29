using EMR.Web.Data;
using EMR.Web.Extensions;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Services;

/// <summary>
/// "Super admin, or a user holding the Administrator role in the current branch" - the users some screens do not
/// restrict (Lab Reporting eligibility, Doctor Dashboard's "own doctor only"). Answered once per request.
/// </summary>
public interface IAdministratorCheck
{
    Task<bool> IsSuperAdminOrAdministratorAsync(HttpContext http);
}

public sealed class AdministratorCheck(ApplicationDbContext db) : IAdministratorCheck
{
    private const string ItemKey = "AdministratorCheck";

    public async Task<bool> IsSuperAdminOrAdministratorAsync(HttpContext http)
    {
        if (http.Items[ItemKey] is bool cached) return cached;
        var user = http.User;
        var userId = user.GetUserId();
        var branchId = user.GetCurrentBranchId();
        var result = user.IsSuperAdmin()
                     || await db.UserRoles.AsNoTracking()
                            .Where(ur => ur.UserId == userId && ur.IsActive && (ur.Branch_ID == null || ur.Branch_ID == branchId))
                            .Join(db.Roles, ur => ur.RoleId, r => r.Id, (ur, r) => r.Name)
                            .AnyAsync(name => name == "Administrator");
        http.Items[ItemKey] = result;
        return result;
    }
}
