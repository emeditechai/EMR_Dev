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

        var hospitalSettings = branchId > 0
            ? await dbContext.HospitalSettings
                .Where(x => x.BranchId == branchId)
                .Select(x => new { x.HospitalName, x.LogoPath })
                .FirstOrDefaultAsync()
            : null;

        var currentBranchName = User.FindFirstValue("BranchName") ?? "N/A";

        var model = new DashboardViewModel
        {
            UserDisplayName = User.FindFirstValue("DisplayName") ?? User.Identity?.Name ?? "User",
            CurrentBranchName = currentBranchName,
            CurrentHospitalName = string.IsNullOrWhiteSpace(hospitalSettings?.HospitalName)
                ? currentBranchName
                : hospitalSettings.HospitalName!,
            HospitalLogoPath = hospitalSettings?.LogoPath,
            TotalUsers = await dbContext.Users.CountAsync(),
            TotalBranches = await dbContext.BranchMasters.CountAsync(x => x.IsActive),
            ActiveMappings = await dbContext.UserBranches.CountAsync(x => x.IsActive),
        };

        ViewData["IsSuperAdmin"] = User.HasClaim("IsSuperAdmin", "true");
        ViewData["CurrentUserId"] = userId;

        return View(model);
    }
}
