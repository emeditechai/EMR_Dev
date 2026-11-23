using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Sales > Loyalty Wallet (PHARMACY.LOYALTYWALLET, SQLScripts/2409): members and their wallets (available /
/// pending / expiring), the statement, manual credit / debit with a reason (ADJUST), and the total points liability.
/// </summary>
[Authorize]
public class PhLoyaltyController(IPharmacySaleService sales, IAuditLogService audit) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Settings = await sales.SettingsAsync(BranchId);
        return View("~/Views/PharmacySales/Loyalty.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> Members(string? q)
    {
        var (members, totals) = await sales.LoyaltyMembersAsync(CompanyId, BranchId, q);
        return Json(new { members, totals });
    }

    [HttpGet]
    public async Task<IActionResult> Statement(int? patientId, int? customerId, string? mobile)
    {
        var (wallet, rows) = await sales.LoyaltyStatementAsync(CompanyId, patientId, customerId, patientId is null && customerId is null ? mobile : null);
        return Json(new { wallet, rows });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Adjust(int? patientId, int? customerId, string? mobile, decimal points, string? reason)
    {
        var err = await sales.LoyaltyAdjustAsync(CompanyId, BranchId, User.GetUserId(), patientId, customerId, patientId is null && customerId is null ? mobile : null, points, reason);
        if (err == null)
            await audit.LogAsync("Pharmacy", "LoyaltyAdjust", $"Loyalty wallet {(points > 0 ? "credit" : "debit")} {points:0} points ({(patientId != null ? "patient #" + patientId : customerId != null ? "customer #" + customerId : "mobile " + mobile)}): {reason}", User.GetUserId(), BranchId);
        return Json(new { success = err == null, message = err ?? "Wallet updated." });
    }
}
