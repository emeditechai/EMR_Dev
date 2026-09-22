using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

[Route("api/[controller]")]
[ApiController]
public class ReportsController : ControllerBase
{
    private readonly IReportService _reportService;

    public ReportsController(IReportService reportService)
    {
        _reportService = reportService;
    }

    [HttpGet("daily-collection")]
    public async Task<IActionResult> GetDailyCollectionRegister(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] bool isDetailed = false,
        [FromQuery] int? companyId = null)
    {
        var result = await _reportService.GetDailyCollectionRegisterAsync(companyId, branchId, fromDate, toDate, isDetailed);
        return Ok(result);
    }

    [HttpGet("patient-register")]
    public async Task<IActionResult> GetPatientRegister(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] bool dependentOnly = false,
        [FromQuery] int? companyId = null)
    {
        var result = await _reportService.GetPatientRegisterAsync(companyId, branchId, fromDate, toDate, dependentOnly);
        return Ok(result);
    }

    /// <summary>Reports > LAB > B2C Collection Register: money receipts collected on B2C lab bills.</summary>
    [HttpGet("lab/b2c-collection-register")]
    public async Task<IActionResult> GetLabB2CCollectionRegister(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] int? paymentMethodId = null,
        [FromQuery] int? collectedBy = null,
        [FromQuery] string? search = null,
        [FromQuery] int userId = 0,
        [FromQuery] bool isAdmin = false,
        [FromQuery] bool isSuperAdmin = false)
    {
        if (branchId <= 0) return BadRequest(new { message = "Valid branchId is required." });
        if ((toDate.Date - fromDate.Date).TotalDays > 366)
            return BadRequest(new { message = "Please select a date range of up to one year." });

        try
        {
            var result = await _reportService.GetLabB2CCollectionRegisterAsync(branchId, fromDate, toDate, paymentMethodId, collectedBy, search,
                userId, isAdmin, isSuperAdmin);
            return Ok(result);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            // visibility rules (branch access / signed-in user) enforced by the procedure
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    /// <summary>Reports > LAB > Discount Register: discounted LAB bills with reason, approver and who entered them.</summary>
    [HttpGet("lab/discount-register")]
    public async Task<IActionResult> GetLabDiscountRegister(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] string? billingType = null,
        [FromQuery] int? approvedBy = null,
        [FromQuery] int? enteredBy = null,
        [FromQuery] string? search = null,
        [FromQuery] int userId = 0,
        [FromQuery] bool isAdmin = false,
        [FromQuery] bool isSuperAdmin = false)
    {
        if (branchId <= 0) return BadRequest(new { message = "Valid branchId is required." });
        if (Math.Abs((toDate.Date - fromDate.Date).TotalDays) > 366)
            return BadRequest(new { message = "Please select a date range of up to one year." });
        try
        {
            var result = await _reportService.GetLabDiscountRegisterAsync(branchId, fromDate, toDate, billingType?.ToUpperInvariant(),
                approvedBy, enteredBy, search, userId, isAdmin, isSuperAdmin);
            return Ok(result);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    // ── Reports > LAB: registered reports that share one result shape (see SQLScripts/2124) ──
    // Only these procedures can be run, and only with their own filters; everything else in the query is ignored.
    private static readonly Dictionary<string, (string Procedure, string[] TextFilters, string[] IdFilters)> LabReports =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["billing-register"]    = ("dbo.usp_Api_LabReport_BillingRegister",    new[] { "BillingType", "PaymentStatus" },       new[] { "CreatedBy" }),
            ["outstanding-dues"]    = ("dbo.usp_Api_LabReport_OutstandingDues",    new[] { "AgeBucket" },                          new[] { "CreatedBy" }),
            ["patient-orders"]      = ("dbo.usp_Api_LabReport_PatientOrders",      new[] { "ReportStatus" },                       new[] { "CreatedBy" }),
            ["cancellation-refund"] = ("dbo.usp_Api_LabReport_CancellationRefund", new[] { "CancellationType", "RefundStatus" },   new[] { "CancelledBy" }),
            // B2B partner-account reports: branch-wide, not limited to the user's own records (SQLScripts/2125)
            ["b2b-partner-billing"] = ("dbo.usp_Api_LabReport_B2BPartnerBilling",  new[] { "PartnerType", "Partner" },              Array.Empty<string>()),
            ["franchise-wallet"]    = ("dbo.usp_Api_LabReport_FranchiseWallet",    new[] { "TransactionType" },                     new[] { "FranchiseId" }),
            ["b2b-outstanding"]     = ("dbo.usp_Api_LabReport_B2BOutstanding",     new[] { "PartnerType", "AgeBucket" },            Array.Empty<string>()),
        };

    [HttpGet("lab/run/{report}")]
    public async Task<IActionResult> RunLabReport(
        string report,
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] string? search = null,
        [FromQuery] int userId = 0,
        [FromQuery] bool isAdmin = false,
        [FromQuery] bool isSuperAdmin = false)
    {
        if (!LabReports.TryGetValue(report, out var def)) return NotFound(new { message = "Unknown report." });
        if (branchId <= 0) return BadRequest(new { message = "Valid branchId is required." });
        if (Math.Abs((toDate.Date - fromDate.Date).TotalDays) > 366)
            return BadRequest(new { message = "Please select a date range of up to one year." });

        var parameters = new Dictionary<string, object?>
        {
            ["BranchId"] = branchId, ["FromDate"] = fromDate.Date, ["ToDate"] = toDate.Date,
            ["Search"] = string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
            ["UserId"] = userId, ["IsAdmin"] = isAdmin, ["IsSuperAdmin"] = isSuperAdmin
        };
        foreach (var f in def.TextFilters)
        {
            var v = Request.Query[char.ToLowerInvariant(f[0]) + f[1..]].ToString();
            parameters[f] = string.IsNullOrWhiteSpace(v) ? null : v.Trim()[..Math.Min(v.Trim().Length, 20)];
        }
        foreach (var f in def.IdFilters)
        {
            var v = Request.Query[char.ToLowerInvariant(f[0]) + f[1..]].ToString();
            parameters[f] = int.TryParse(v, out var id) && id > 0 ? id : null;
        }

        try
        {
            return Ok(await _reportService.RunLabReportAsync(def.Procedure, parameters));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }
}
