using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>IPD > IPD Dashboard (SQLScripts/2423 usp_Api_Ipd_Dashboard): census, beds by ward, patients in the hospital now.</summary>
[Authorize]
public class IPDController(IpdApiClient api, ILogger<IPDController> logger) : Controller
{
    public IActionResult Index() => User.GetCurrentBranchId() is null ? RedirectToAction("SelectBranch", "Account") : View();

    [HttpGet]
    public async Task<IActionResult> DashboardData()
    {
        try
        {
            var sets = await api.SetsAsync("/dashboard");
            return Json(new { success = true, data = new { tiles = sets.First(0), wards = sets.ElementAtOrDefault(1), patients = sets.ElementAtOrDefault(2) } });
        }
        catch (InvalidOperationException ex) { return Json(new { success = false, error = ex.Message }); }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "IPD dashboard: API unreachable");
            return Json(new { success = false, error = "The EMR API is not reachable. Try again in a moment." });
        }
    }
}
