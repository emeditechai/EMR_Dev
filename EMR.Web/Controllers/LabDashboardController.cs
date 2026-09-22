using System;
using System.Linq;
using System.Security.Claims;
using System.Threading.Tasks;
using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

[Authorize]
public class LabDashboardController(
    ILabDashboardApiClient labDashboardApiClient,
    ApplicationDbContext dbContext) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(string? date, string? clientType)
    {
        var branchId = User.GetCurrentBranchId();
        if (branchId is null)
        {
            TempData["Error"] = "Please select a branch first.";
            return RedirectToAction("SelectBranch", "Account");
        }

        var selectedDate = DateTime.TryParse(date, out var d) ? d : DateTime.Today;
        var dateStr = selectedDate.ToString("yyyy-MM-dd");

        var hospitalSettings = await dbContext.HospitalSettings
            .Where(x => x.BranchId == branchId.Value)
            .Select(x => new { x.HospitalName, x.LogoPath })
            .FirstOrDefaultAsync();

        var currentBranchName = User.FindFirstValue("BranchName") ?? "N/A";
        var client = clientType?.Trim().ToUpperInvariant() is "B2B" or "B2C" ? clientType!.Trim().ToUpperInvariant() : "ALL";
        var labData = await labDashboardApiClient.GetDashboardStatsAsync(branchId.Value, dateStr, client)
                      ?? new ApiClients.Models.LabDashboardData();

        var model = new LabDashboardViewModel
        {
            UserDisplayName = User.FindFirstValue("DisplayName") ?? User.Identity?.Name ?? "User",
            CurrentBranchName = currentBranchName,
            CurrentHospitalName = string.IsNullOrWhiteSpace(hospitalSettings?.HospitalName)
                ? currentBranchName
                : hospitalSettings.HospitalName!,
            HospitalLogoPath = hospitalSettings?.LogoPath,
            SelectedDate = dateStr,
            ClientType = client,
            Data = labData
        };

        ViewData["Title"] = "LAB Dashboard";
        return View(model);
    }
}
