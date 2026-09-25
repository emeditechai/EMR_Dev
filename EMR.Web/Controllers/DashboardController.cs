using System.Security.Claims;
using EMR.Web.Data;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class DashboardController(ApplicationDbContext dbContext) : Controller
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
            model.SignedInAt = await dbContext.Users
                .Where(x => x.Id == userId)
                .Select(x => x.LastLoginDate)
                .FirstOrDefaultAsync();

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

            // Real work in this branch only: opening a page or signing in is not an activity.
            var lastActivity = await dbContext.AuditLogs
                .Where(x => x.UserId == userId
                            && x.BranchId == branchId
                            && (x.ModuleCode == null || x.ModuleCode != "PAGE_VIEW")
                            && x.EventType != "AuthSuccess" && x.EventType != "AuthFailure" && x.EventType != "Auth")
                .OrderByDescending(x => x.Id)
                .Select(x => new { x.Description, x.CreatedDate, x.ModuleCode, x.ControllerName, x.ActionName })
                .FirstOrDefaultAsync();

            if (lastActivity != null)
            {
                model.LastActivityDescription = lastActivity.Description;
                model.LastActivityAt = lastActivity.CreatedDate;
                model.LastActivityModule = lastActivity.ModuleCode;
                model.LastActivityScreen = string.IsNullOrWhiteSpace(lastActivity.ControllerName)
                    ? lastActivity.ActionName
                    : $"{lastActivity.ControllerName} / {lastActivity.ActionName}";
            }
        }


        ViewData["IsSuperAdmin"] = User.HasClaim("IsSuperAdmin", "true");
        ViewData["CurrentUserId"] = userId;

        return View(model);
    }
}
