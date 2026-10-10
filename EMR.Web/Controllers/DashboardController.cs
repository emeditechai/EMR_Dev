using System.Security.Claims;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class DashboardController(ApplicationDbContext dbContext, IHomeDashboardService home) : Controller
{
    public async Task<IActionResult> Index()
    {
        if (!User.HasClaim(x => x.Type == "BranchId"))
        {
            return RedirectToAction("SelectBranch", "Account");
        }

        var userId = int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var id) ? id : 0;
        var branchId = int.TryParse(User.FindFirstValue("BranchId"), out var bid) ? bid : 0;

        var branch = branchId > 0
            ? await dbContext.BranchMasters
                .Include(x => x.Company)
                .FirstOrDefaultAsync(x => x.BranchId == branchId)
            : null;

        var hospitalSettings = branchId > 0
            ? await dbContext.HospitalSettings
                .Where(x => x.BranchId == branchId)
                .Select(x => new { x.HospitalName, x.LogoPath })
                .FirstOrDefaultAsync()
            : null;

        var currentBranchName = User.FindFirstValue("BranchName") ?? branch?.BranchName ?? "N/A";
        var companyName = branch?.Company?.CompanyName ?? User.FindFirstValue("CompanyName") ?? "Primary Healthcare Network";
        var companyCode = branch?.Company?.CompanyCode ?? User.FindFirstValue("CompanyCode") ?? "CMP-001";

        var model = new DashboardViewModel
        {
            UserDisplayName = User.FindFirstValue("DisplayName") ?? User.Identity?.Name ?? "User",
            CurrentBranchName = currentBranchName,
            CurrentHospitalName = string.IsNullOrWhiteSpace(hospitalSettings?.HospitalName)
                ? currentBranchName
                : hospitalSettings.HospitalName!,
            CompanyName = companyName,
            CompanyCode = companyCode,
            HospitalLogoPath = hospitalSettings?.LogoPath,
        };

        // Sign-in and activity of the person looking at the page - nothing else on this dashboard.
        if (userId > 0)
        {
            var account = await dbContext.Users
                .Where(x => x.Id == userId)
                .Select(x => new { x.LastLoginDate, x.PasswordLastChanged, x.MustChangePassword, x.Username })
                .FirstOrDefaultAsync();
            model.SignedInAt = account?.LastLoginDate;
            model.PasswordLastChanged = account?.PasswordLastChanged;
            model.MustChangePassword = account?.MustChangePassword ?? false;

            // Where this session came from: the credentials check that started it.
            model.SignedInFromIp = await dbContext.AuditLogs
                .Where(x => x.UserId == userId && x.EventType == "AuthSuccess" && x.ActionName == "Login")
                .OrderByDescending(x => x.Id)
                .Select(x => x.IpAddress)
                .FirstOrDefaultAsync();

            // The sign-in before this one, into THIS branch. A session into another branch is not shown here.
            var sessionStart = model.SignedInAt ?? DateTime.Now;
            model.PreviousSignInAt = await dbContext.AuditLogs
                .Where(x => x.UserId == userId && x.BranchId == branchId
                            && x.EventType == "AuthSuccess" && x.ActionName == "SelectBranch"
                            && x.CreatedDate < sessionStart)
                .OrderByDescending(x => x.Id)
                .Select(x => (DateTime?)x.CreatedDate)
                .FirstOrDefaultAsync();

            // The previous session in ANY branch, and the sign-ins refused on this account since then.
            model.LastSessionAt = await dbContext.AuditLogs
                .Where(x => x.UserId == userId && x.EventType == "AuthSuccess" && x.ActionName == "SelectBranch"
                            && x.CreatedDate < sessionStart)
                .OrderByDescending(x => x.Id)
                .Select(x => (DateTime?)x.CreatedDate)
                .FirstOrDefaultAsync();

            var failedFrom = model.LastSessionAt ?? DateTime.Now.AddDays(-30);
            var failedText = $"Failed login attempt for username: {account?.Username ?? User.Identity?.Name}";
            var failed = dbContext.AuditLogs
                .Where(x => x.EventType == "AuthFailure" && x.ActionName == "Login" && x.CreatedDate > failedFrom
                            && (x.UserId == userId || x.Description == failedText));
            model.FailedSignInsSinceLast = await failed.CountAsync();
            model.LastFailedSignInAt = model.FailedSignInsSinceLast > 0
                ? await failed.MaxAsync(x => (DateTime?)x.CreatedDate)
                : null;

            // Shortcuts and recent work - only pages and records the user may open.
            var catalog = await home.GetPageCatalogAsync(HttpContext);
            model.PageCatalog = catalog.ToList();
            model.RecentScreens = (await home.GetRecentScreensAsync(HttpContext, catalog, userId, branchId, 8)).ToList();
            model.RecentActivity = (await home.GetRecentActivityAsync(HttpContext, catalog, userId, branchId, 6)).ToList();

            // The user's own work only: page views, sign-in steps and system notifications are left out (see the service).
            if (model.RecentActivity.FirstOrDefault() is { } lastActivity)
            {
                model.LastActivityDescription = lastActivity.Description;
                model.LastActivityAt = lastActivity.At;
                model.LastActivityModule = lastActivity.Module;
                model.LastActivityScreen = lastActivity.ScreenTitle;
            }
        }

        model.ActiveRole = User.GetActiveRole();
        model.RoleCount = User.FindAll(ClaimTypes.Role).Select(x => x.Value)
            .Where(x => !string.Equals(x, "SuperAdmin", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase).Count();
        model.BranchCount = int.TryParse(User.FindFirstValue("BranchCount"), out var bc) ? bc : 1;


        ViewData["IsSuperAdmin"] = User.HasClaim("IsSuperAdmin", "true");
        ViewData["CurrentUserId"] = userId;

        return View(model);
    }
}
