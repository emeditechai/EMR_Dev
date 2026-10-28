using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Sales > Schedule H1 / X Register (PHARMACY.SCHEDULEREGISTER, SQLScripts/2348): made automatically from the bills.</summary>
[Authorize]
public class PhScheduleRegisterController(IPharmacySaleService sales) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(DateTime? from, DateTime? to, string? schedule)
    {
        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
        var f = from ?? new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1); var t = to ?? DateTime.Today;
        ViewBag.Filter = (f, t, schedule);
        return View("~/Views/PharmacySales/Register.cshtml", await sales.ScheduleRegisterAsync(User.GetCompanyId(), branchId, f, t, string.IsNullOrWhiteSpace(schedule) ? null : schedule));
    }
}
