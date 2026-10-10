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
        [FromQuery] int? companyId = null,
        [FromQuery] string? moduleCode = null)
    {
        var result = await _reportService.GetDailyCollectionRegisterAsync(companyId, branchId, fromDate, toDate, isDetailed, moduleCode);
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
            ["b2b-partner-billing"] = ("dbo.usp_Api_LabReport_B2BPartnerBilling",  new[] { "PartnerType", "Partner", "PaymentMethod" }, Array.Empty<string>()),
            ["franchise-wallet"]    = ("dbo.usp_Api_LabReport_FranchiseWallet",    new[] { "TransactionType" },                     new[] { "FranchiseId" }),
            ["b2b-outstanding"]     = ("dbo.usp_Api_LabReport_B2BOutstanding",     new[] { "PartnerType", "AgeBucket" },            Array.Empty<string>()),
            // Sample stage: LR-10 / LR-11 / LR-12 (SQLScripts/2183)
            ["samples-pending"]     = ("dbo.usp_Api_LabReport_SamplesPendingCollection", new[] { "CollectionType", "WaitBand", "PendingStatus" }, new[] { "CreatedBy", "PhlebotomistId" }),
            ["sample-rejection"]    = ("dbo.usp_Api_LabReport_SampleRejection",   new[] { "Outcome" },                             new[] { "ReasonId", "CollectedBy" }),
            ["sample-transfer"]     = ("dbo.usp_Api_LabReport_SampleTransfer",    new[] { "Direction", "TransferStatus" },          new[] { "OtherBranchId" }),
            // LR-13 (SQLScripts/2185); outside lab names are long, the prefix is enough to filter on
            ["outsourced-tests"]    = ("dbo.usp_Api_LabReport_OutsourcedTests",   new[] { "OutsourceStatus", "OutsideLab" },        Array.Empty<string>()),
            // LR-03 cashier hand-over; LR-14 to LR-18 bench work, TAT and result quality (SQLScripts/2201)
            ["cashier-closing"]     = ("dbo.usp_Api_LabReport_CashierClosing",    Array.Empty<string>(),                           new[] { "PaymentMethodId", "CollectedBy" }),
            ["work-pending"]        = ("dbo.usp_Api_LabReport_WorkPending",       new[] { "Stage", "WaitBand" },                    new[] { "DepartmentId" }),
            ["turnaround"]          = ("dbo.usp_Api_LabReport_Turnaround",        new[] { "TatStatus" },                            new[] { "DepartmentId" }),
            ["critical-values"]     = ("dbo.usp_Api_LabReport_CriticalValues",    new[] { "Severity", "ResultStatus", "Communication" }, new[] { "DepartmentId" }),
            ["delta-check"]         = ("dbo.usp_Api_LabReport_DeltaCheck",        new[] { "Direction" },                            new[] { "DeltaLimit", "DepartmentId" }),
            ["abnormal-results"]    = ("dbo.usp_Api_LabReport_AbnormalResults",   new[] { "Signal" },                               new[] { "DepartmentId" }),
            // LR-19 / LR-20 / LR-22 approval & dispatch (SQLScripts/2209)
            ["sign-off"]            = ("dbo.usp_Api_LabReport_SignOff",           new[] { "Show", "Level", "Source" },              new[] { "PathologistId", "DepartmentId" }),
            ["dispatch-print"]      = ("dbo.usp_Api_LabReport_DispatchPrint",     new[] { "DispatchStatus", "BillingType" },        new[] { "PrintedBy" }),
            ["unauthorized"]        = ("dbo.usp_Api_LabReport_Unauthorized",      new[] { "WithdrawAction", "Outcome", "Amended" }, new[] { "UnapprovedBy", "DepartmentId" }),
            // LR-24 / LR-26 / LR-27 management (SQLScripts/2210)
            ["revenue-trend"]       = ("dbo.usp_Api_LabReport_RevenueTrend",      new[] { "BillingType" },                          new[] { "CreatedBy" }),
            ["patient-analytics"]   = ("dbo.usp_Api_LabReport_PatientAnalytics",  new[] { "PatientType", "AgeBand", "Gender" },     new[] { "CreatedBy" }),
            ["staff-productivity"]  = ("dbo.usp_Api_LabReport_StaffProductivity", new[] { "Activity" },                             new[] { "StaffId" }),
            // Doctor IP (referral doctor commission) reports: branch-wide (SQLScripts/2222)
            ["doctorip-statement"]    = ("dbo.usp_Api_LabReport_DoctorIpStatement",    new[] { "ItemType" },              new[] { "DoctorId" }),
            ["doctorip-itemwise"]     = ("dbo.usp_Api_LabReport_DoctorIpStatement",    new[] { "ItemType" },              new[] { "DoctorId" }),
            ["doctorip-business"]     = ("dbo.usp_Api_LabReport_DoctorIpBusiness",     new[] { "CommissionStatus" },      new[] { "DoctorId" }),
            ["doctorip-pending"]      = ("dbo.usp_Api_LabReport_DoctorIpPending",      new[] { "ItemType", "Frequency" }, new[] { "DoctorId" }),
            ["doctorip-unconfigured"] = ("dbo.usp_Api_LabReport_DoctorIpUnconfigured", new[] { "Reason" },                new[] { "DoctorId" }),
        };

    /// <summary>LR-13: an outsourced test sent to an outside lab (or its sending details corrected). Validated by the procedure.</summary>
    [HttpPost("lab/outsource/sent")]
    public Task<IActionResult> MarkOutsourceSent([FromBody] LabOutsourceActionRequest req) =>
        RunOutsourceAction("dbo.usp_LabOutsource_MarkSent", req, new Dictionary<string, object?>
        {
            ["OutsideLab"] = req.OutsideLab, ["ExternalRefNo"] = req.ExternalRefNo, ["SentOn"] = req.ActionOn
        });

    /// <summary>LR-13: the outside lab's result of an outsourced test received.</summary>
    [HttpPost("lab/outsource/received")]
    public Task<IActionResult> MarkOutsourceReceived([FromBody] LabOutsourceActionRequest req) =>
        RunOutsourceAction("dbo.usp_LabOutsource_MarkReceived", req, new Dictionary<string, object?> { ["ReceivedOn"] = req.ActionOn });

    private async Task<IActionResult> RunOutsourceAction(string procedure, LabOutsourceActionRequest req, Dictionary<string, object?> extra)
    {
        if (req == null || req.BranchId <= 0 || req.LabOrderId <= 0 || string.IsNullOrWhiteSpace(req.SampleIds))
            return BadRequest(new { message = "Select the outsourced test first." });
        var parameters = new Dictionary<string, object?>
        {
            ["BranchId"] = req.BranchId, ["LabOrderId"] = req.LabOrderId, ["SampleIds"] = req.SampleIds,
            ["Remarks"] = req.Remarks, ["UserId"] = req.UserId, ["IsSuperAdmin"] = req.IsSuperAdmin
        };
        foreach (var kv in extra) parameters[kv.Key] = kv.Value;
        try
        {
            return Ok(new { rows = await _reportService.ExecuteLabActionAsync(procedure, parameters) });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50020)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    private static readonly string[] OwnerMisSections =
        { "summary", "trend", "tests", "departments", "doctors", "partners", "quality", "ageing", "modes", "branches" };

    /// <summary>LF-18 Owner MIS: revenue by test / department / doctor / partner, TAT, quality, collection and ageing.</summary>
    [HttpGet("lab/owner-mis")]
    public async Task<IActionResult> GetLabOwnerMis(
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] bool allBranches = false,
        [FromQuery] int userId = 0,
        [FromQuery] bool isSuperAdmin = false)
    {
        if (branchId <= 0) return BadRequest(new { message = "Valid branchId is required." });
        if (Math.Abs((toDate.Date - fromDate.Date).TotalDays) > 366)
            return BadRequest(new { message = "Please select a date range of up to one year." });

        var parameters = new Dictionary<string, object?>
        {
            ["BranchId"] = branchId, ["FromDate"] = fromDate.Date, ["ToDate"] = toDate.Date, ["AllBranches"] = allBranches,
            ["UserId"] = userId, ["IsSuperAdmin"] = isSuperAdmin
        };
        try
        {
            return Ok(await _reportService.RunLabSectionsAsync("dbo.usp_Api_LabReport_OwnerMis", parameters, OwnerMisSections));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    [HttpGet("lab/run/{report}")]
    public Task<IActionResult> RunLabReport(
        string report,
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] string? search = null,
        [FromQuery] int userId = 0,
        [FromQuery] bool isAdmin = false,
        [FromQuery] bool isSuperAdmin = false)
        => RunRegisteredReport(LabReports, report, branchId, fromDate, toDate, search, userId, isAdmin, isSuperAdmin);

    // ── Reports > OPD: same register shape as the LAB reports (SQLScripts/2211) ──
    private static readonly Dictionary<string, (string Procedure, string[] TextFilters, string[] IdFilters)> OpdReports =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["billing-register"]    = ("dbo.usp_Api_OpdReport_BillingRegister",    new[] { "PaymentStatus" },                    new[] { "DoctorId", "CreatedBy" }),
            ["cashier-closing"]     = ("dbo.usp_Api_OpdReport_CashierClosing",     Array.Empty<string>(),                        new[] { "PaymentMethodId", "CollectedBy" }),
            ["outstanding-dues"]    = ("dbo.usp_Api_OpdReport_OutstandingDues",    new[] { "AgeBucket" },                        new[] { "DoctorId", "CreatedBy" }),
            ["discount-register"]   = ("dbo.usp_Api_OpdReport_DiscountRegister",   new[] { "ReasonStatus" },                     new[] { "ApprovedBy", "DoctorId", "EnteredBy" }),
            ["cancellation-refund"] = ("dbo.usp_Api_OpdReport_CancellationRefund", new[] { "CancellationType", "RefundStatus" }, new[] { "CancelledBy" }),
            // OR-24 / OR-25 / OR-26 (SQLScripts/2212)
            ["revenue-trend"]          = ("dbo.usp_Api_OpdReport_RevenueTrend",          new[] { "VisitMode" },                          new[] { "DoctorId", "CreatedBy" }),
            ["patient-analytics"]      = ("dbo.usp_Api_OpdReport_PatientAnalytics",      new[] { "PatientType", "AgeBand", "Gender" },   new[] { "DoctorId", "CreatedBy" }),
            ["speciality-performance"] = ("dbo.usp_Api_OpdReport_SpecialityPerformance", new[] { "VisitMode" },                          new[] { "SpecialityId", "DoctorId" }),
            // OR-31 to OR-36 doctor payout (SQLScripts/2214)
            ["doctor-share"]           = ("dbo.usp_Api_OpdReport_DoctorShareRegister",   new[] { "LineType", "SettleStatus" },           new[] { "DoctorId" }),
            ["doctor-payout"]          = ("dbo.usp_Api_OpdReport_DoctorPayoutRegister",  new[] { "Status", "PaymentMode" },              new[] { "DoctorId" }),
            ["doctor-payable"]         = ("dbo.usp_Api_OpdReport_DoctorPayable",         new[] { "Stage", "AgeBucket" },                 new[] { "DoctorId" }),
            ["doctor-statement"]       = ("dbo.usp_Api_OpdReport_DoctorStatement",       new[] { "EntryType" },                          new[] { "DoctorId" }),
            ["doctor-tds"]             = ("dbo.usp_Api_OpdReport_DoctorTdsRegister",     new[] { "PanStatus" },                          new[] { "DoctorId" }),
            ["doctor-revenue-share"]   = ("dbo.usp_Api_OpdReport_DoctorRevenueShare",    new[] { "RuleStatus" },                         new[] { "SpecialityId", "DoctorId" }),
        };

    [HttpGet("opd/run/{report}")]
    public Task<IActionResult> RunOpdReport(
        string report,
        [FromQuery] int branchId,
        [FromQuery] DateTime fromDate,
        [FromQuery] DateTime toDate,
        [FromQuery] string? search = null,
        [FromQuery] int userId = 0,
        [FromQuery] bool isAdmin = false,
        [FromQuery] bool isSuperAdmin = false)
        => RunRegisteredReport(OpdReports, report, branchId, fromDate, toDate, search, userId, isAdmin, isSuperAdmin);

    /// <summary>Runs a whitelisted register procedure with the common parameters and only its own filters.</summary>
    private async Task<IActionResult> RunRegisteredReport(
        Dictionary<string, (string Procedure, string[] TextFilters, string[] IdFilters)> reports,
        string report, int branchId, DateTime fromDate, DateTime toDate, string? search, int userId, bool isAdmin, bool isSuperAdmin)
    {
        if (!reports.TryGetValue(report, out var def)) return NotFound(new { message = "Unknown report." });
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

/// <summary>LR-13 Mark sent / Mark result received: one billed outsourced test (its sample ids) of a lab order.</summary>
public sealed class LabOutsourceActionRequest
{
    public int BranchId { get; set; }
    public int LabOrderId { get; set; }
    public string SampleIds { get; set; } = string.Empty;
    public string? OutsideLab { get; set; }
    public string? ExternalRefNo { get; set; }
    public DateTime? ActionOn { get; set; }
    public string? Remarks { get; set; }
    public int UserId { get; set; }
    public bool IsSuperAdmin { get; set; }
}
