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
        var companyId = User.GetCompanyId();
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;

        var result = await _reportApi.GetDailyCollectionRegisterAsync(branchId, fDate, tDate, isDetailed, companyId);
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
        var companyId = User.GetCompanyId();
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;

        var result = await _reportApi.GetPatientRegisterAsync(branchId, fDate, tDate, dependentOnly, companyId);
        if (result.IsSuccess)
        {
            return Json(new { success = true, data = result.Data });
        }
        return Json(new { success = false, message = result.ErrorMessage });
    }

    // ── Reports > LAB > B2C Collection Register ─────────────────────────────
    /// <summary>Administrator (active role) or super admin sees every user's collections; others only their own.</summary>
    private bool CanSeeAllCollections() =>
        User.IsSuperAdmin() || string.Equals(User.GetActiveRole(), "Administrator", StringComparison.OrdinalIgnoreCase);

    [HttpGet]
    public IActionResult LabB2CCollectionRegister()
    {
        ViewBag.CanSeeAllCollections = CanSeeAllCollections();
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetLabB2CCollectionRegisterData(string fromDate, string toDate, int? paymentMethodId, int? collectedBy, string? search)
    {
        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;
        if (tDate < fDate) (fDate, tDate) = (tDate, fDate);
        if ((tDate - fDate).TotalDays > 366)
            return Json(new { success = false, message = "Please select a date range of up to one year." });

        var seeAll = CanSeeAllCollections();
        var result = await _reportApi.GetLabB2CCollectionRegisterAsync(branchId, fDate, tDate, paymentMethodId,
            seeAll ? collectedBy : User.GetUserId(), search, User.GetUserId(), seeAll, User.IsSuperAdmin());
        if (result.IsSuccess)
        {
            return Json(new { success = true, data = result.Data, scope = seeAll ? "ALL" : "SELF" });
        }
        return Json(new { success = false, message = result.ErrorMessage ?? "Unable to load the collection register." });
    }

    // ── Reports > LAB > Discount Register ────────────────────────────────────
    [HttpGet]
    public IActionResult LabDiscountRegister()
    {
        ViewBag.CanSeeAllCollections = CanSeeAllCollections();
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetLabDiscountRegisterData(string fromDate, string toDate, string? billingType, int? approvedBy, int? enteredBy, string? search)
    {
        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;
        if (tDate < fDate) (fDate, tDate) = (tDate, fDate);
        if ((tDate - fDate).TotalDays > 366)
            return Json(new { success = false, message = "Please select a date range of up to one year." });

        var seeAll = CanSeeAllCollections();
        var result = await _reportApi.GetLabDiscountRegisterAsync(branchId, fDate, tDate, billingType, approvedBy,
            seeAll ? enteredBy : User.GetUserId(), search, User.GetUserId(), seeAll, User.IsSuperAdmin());
        if (result.IsSuccess)
            return Json(new { success = true, data = result.Data, scope = seeAll ? "ALL" : "SELF" });
        return Json(new { success = false, message = result.ErrorMessage ?? "Unable to load the discount register." });
    }

    // ── Reports > LAB: Billing Register, Outstanding Dues, Patient-wise Orders, Cancellation & Refund ──
    // One page each (Views/Reports/Lab*.cshtml + wwwroot/js/lab-report.js), one data action for all of them.
    private static readonly Dictionary<string, string[]> LabReportFilters = new(StringComparer.OrdinalIgnoreCase)
    {
        ["billing-register"]    = new[] { "billingType", "paymentStatus", "createdBy" },
        ["outstanding-dues"]    = new[] { "ageBucket", "createdBy" },
        ["patient-orders"]      = new[] { "reportStatus", "createdBy" },
        ["cancellation-refund"] = new[] { "cancellationType", "refundStatus", "cancelledBy" },
        // B2B partner-account reports: branch-wide for every user of the branch
        ["b2b-partner-billing"] = new[] { "partnerType", "partner" },
        ["franchise-wallet"]    = new[] { "transactionType", "franchiseId" },
        ["b2b-outstanding"]     = new[] { "partnerType", "ageBucket" },
    };

    private IActionResult LabReportPage(string viewName)
    {
        ViewBag.CanSeeAllCollections = CanSeeAllCollections();
        return View(viewName);
    }

    [HttpGet] public IActionResult LabBillingRegister() => LabReportPage("LabBillingRegister");
    [HttpGet] public IActionResult LabOutstandingDues() => LabReportPage("LabOutstandingDues");
    [HttpGet] public IActionResult LabPatientOrders() => LabReportPage("LabPatientOrders");
    [HttpGet] public IActionResult LabCancellationRefund() => LabReportPage("LabCancellationRefund");
    [HttpGet] public IActionResult LabB2BPartnerBilling() => LabReportPage("LabB2BPartnerBilling");
    [HttpGet] public IActionResult LabFranchiseWallet() => LabReportPage("LabFranchiseWallet");
    [HttpGet] public IActionResult LabB2BOutstanding() => LabReportPage("LabB2BOutstanding");

    [HttpGet]
    public async Task<IActionResult> GetLabReportData(string report, string fromDate, string toDate, string? search)
    {
        if (string.IsNullOrWhiteSpace(report) || !LabReportFilters.TryGetValue(report, out var filters))
            return Json(new { success = false, message = "Unknown report." });

        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
        if (!DateTime.TryParse(fromDate, out var fDate)) fDate = DateTime.Today;
        if (!DateTime.TryParse(toDate, out var tDate)) tDate = DateTime.Today;
        if (tDate < fDate) (fDate, tDate) = (tDate, fDate);
        if ((tDate - fDate).TotalDays > 366)
            return Json(new { success = false, message = "Please select a date range of up to one year." });

        // who is asking always comes from the login, never from the page
        var seeAll = CanSeeAllCollections();
        var query = new Dictionary<string, string?>
        {
            ["branchId"] = branchId.ToString(),
            ["fromDate"] = fDate.ToString("yyyy-MM-dd"),
            ["toDate"] = tDate.ToString("yyyy-MM-dd"),
            ["search"] = search,
            ["userId"] = User.GetUserId().ToString(),
            ["isAdmin"] = seeAll ? "true" : "false",
            ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
        };
        foreach (var f in filters) query[f] = Request.Query[f].ToString();

        var result = await _reportApi.RunLabReportRawAsync(report, query);
        if (!result.IsSuccess)
            return Json(new { success = false, message = result.ErrorMessage ?? "Unable to load the report." });
        return Content("{\"success\":true,\"scope\":\"" + (seeAll ? "ALL" : "SELF") + "\",\"data\":" + result.Data + "}", "application/json");
    }
}
