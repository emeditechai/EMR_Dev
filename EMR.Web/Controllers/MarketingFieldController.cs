using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Reports > LAB > Marketing Field Report (REPORTS.LABMARKETINGFIELD: VIEW, SQLScripts/2462): what the Marketing Executive App recorded, for the
/// office to check - visits with the distance from the clinic and how the clinic location was set, field days with km covered
/// and the route on a map, and the forecast doctors with address. Read only. Branch = the signed-in branch; an executive login
/// sees its own records only (in the procedures). Web -> EMR.Api api/marketing-executives/field/* -> procedures.
/// </summary>
[Authorize]
public class MarketingFieldController(MarketingExecutiveApiClient api, ILogger<MarketingFieldController> logger) : Controller
{
    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private int Branch => User.GetCurrentBranchId() ?? 0;

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        if (Branch <= 0) return Fail("Your branch could not be found - sign in again.");
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "Marketing field report API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    [HttpGet]
    public IActionResult Index() => View();

    [HttpGet]
    public Task<IActionResult> VisitData(DateTime fromDate, DateTime toDate, int? executiveId, string? status, string? search) =>
        Read(async () => await api.GetAsync("/field/visits" + IpdApiClient.Q(("branchId", Branch.ToString()), ("fromDate", fromDate.ToString("yyyy-MM-dd")),
            ("toDate", toDate.ToString("yyyy-MM-dd")), ("executiveId", executiveId?.ToString()), ("status", status), ("search", search))));

    [HttpGet]
    public Task<IActionResult> DayData(DateTime fromDate, DateTime toDate, int? executiveId) =>
        Read(async () => await api.GetAsync("/field/days" + IpdApiClient.Q(("branchId", Branch.ToString()), ("fromDate", fromDate.ToString("yyyy-MM-dd")),
            ("toDate", toDate.ToString("yyyy-MM-dd")), ("executiveId", executiveId?.ToString()))));

    [HttpGet]
    public Task<IActionResult> RouteData(int dayId) =>
        Read(async () => await api.GetAsync($"/field/days/{dayId}/route" + IpdApiClient.Q(("branchId", Branch.ToString()))));

    [HttpGet]
    public Task<IActionResult> DoctorData(int? executiveId, string? stage, string? pin, string? search) =>
        Read(async () => await api.GetAsync("/field/doctors" + IpdApiClient.Q(("branchId", Branch.ToString()), ("executiveId", executiveId?.ToString()),
            ("stage", stage), ("pin", pin), ("search", search))));
}
