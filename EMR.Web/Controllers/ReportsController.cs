using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

[Authorize]
public class ReportsController : Controller
{
    private readonly IReportApiClient _reportApi;

    public ReportsController(IReportApiClient reportApi)
    {
        _reportApi = reportApi;
    }

    [HttpGet]
    public IActionResult OPDReport()
    {
        return View();
    }

    [HttpGet]
    public IActionResult DailyCollection()
    {
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetDailyCollectionData(string fromDate, string toDate, bool isDetailed)
    {
        var branchId = User.GetCurrentBranchId() ?? 1; // Fallback to 1 if not set
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;

        var result = await _reportApi.GetDailyCollectionRegisterAsync(branchId, fDate, tDate, isDetailed);
        if (result.IsSuccess)
        {
            return Json(new { success = true, data = result.Data });
        }
        return Json(new { success = false, message = result.ErrorMessage });
    }

    [HttpGet]
    public IActionResult PatientRegister()
    {
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetPatientRegisterData(string fromDate, string toDate, bool dependentOnly)
    {
        var branchId = User.GetCurrentBranchId() ?? 1; // Fallback to 1 if not set
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;

        var result = await _reportApi.GetPatientRegisterAsync(branchId, fDate, tDate, dependentOnly);
        if (result.IsSuccess)
        {
            return Json(new { success = true, data = result.Data });
        }
        return Json(new { success = false, message = result.ErrorMessage });
    }
}
