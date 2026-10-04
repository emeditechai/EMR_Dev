using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Controllers;

/// <summary>
/// OPD doctor payout (SQLScripts/2213): share earned on collection, day-end doctor-wise settlement, maker-checker
/// approval, payment, TDS and the doctor payout profile. Business rules are in the procedures; their messages
/// (50020) come back as 400, branch access (50010 / 50011) as 403.
/// </summary>
[ApiController]
[Route("api/doctor-payouts")]
[Produces("application/json")]
public class DoctorPayoutsController(IReportService reportService) : ControllerBase
{
    [HttpGet("board")]
    public Task<IActionResult> Board([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] DateTime date,
        [FromQuery] int userId = 0, [FromQuery] bool isSuperAdmin = false) =>
        Sections("dbo.usp_DoctorPayout_Board", new()
        {
            ["CompanyId"] = companyId, ["BranchId"] = branchId, ["Date"] = date.Date, ["UserId"] = userId, ["IsSuperAdmin"] = isSuperAdmin
        }, "summary", "doctors", "lines", "noShare");

    [HttpGet("settlements")]
    public Task<IActionResult> Settlements([FromQuery] int branchId, [FromQuery] DateTime fromDate, [FromQuery] DateTime toDate,
        [FromQuery] string? status = null, [FromQuery] int? doctorId = null, [FromQuery] int userId = 0, [FromQuery] bool isSuperAdmin = false) =>
        Sections("dbo.usp_DoctorPayout_Settlements", new()
        {
            ["BranchId"] = branchId, ["FromDate"] = fromDate.Date, ["ToDate"] = toDate.Date,
            ["Status"] = string.IsNullOrWhiteSpace(status) ? null : status.Trim(), ["DoctorId"] = doctorId is > 0 ? doctorId : null,
            ["UserId"] = userId, ["IsSuperAdmin"] = isSuperAdmin
        }, "rows");

    [HttpGet("settlements/{id:int}")]
    public Task<IActionResult> Settlement(int id, [FromQuery] int branchId, [FromQuery] int userId = 0, [FromQuery] bool isSuperAdmin = false) =>
        Sections("dbo.usp_DoctorPayout_SettlementGet", new()
        {
            ["BranchId"] = branchId, ["SettlementId"] = id, ["UserId"] = userId, ["IsSuperAdmin"] = isSuperAdmin
        }, "header", "lines");

    [HttpGet("approvers")]
    public Task<IActionResult> Approvers([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int userId = 0, [FromQuery] bool isSuperAdmin = false) =>
        Sections("dbo.usp_DoctorPayout_Approvers", new()
        {
            ["CompanyId"] = companyId, ["BranchId"] = branchId, ["UserId"] = userId, ["IsSuperAdmin"] = isSuperAdmin
        }, "rows");

    [HttpGet("profiles")]
    public Task<IActionResult> Profiles([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int userId = 0, [FromQuery] bool isSuperAdmin = false) =>
        Sections("dbo.usp_DoctorPayout_Profiles", new()
        {
            ["CompanyId"] = companyId, ["BranchId"] = branchId, ["UserId"] = userId, ["IsSuperAdmin"] = isSuperAdmin
        }, "rows");

    [HttpPost("profiles")]
    public Task<IActionResult> SaveProfile([FromBody] DoctorPayoutProfileRequest req) =>
        Execute("dbo.usp_DoctorPayout_ProfileSave", new()
        {
            ["CompanyId"] = req.CompanyId, ["DoctorId"] = req.DoctorId, ["PayeeName"] = req.PayeeName, ["PAN"] = req.Pan,
            ["TdsApplicable"] = req.TdsApplicable, ["TdsPercent"] = req.TdsPercent, ["PreferredMode"] = req.PreferredMode,
            ["BankName"] = req.BankName, ["AccountNo"] = req.AccountNo, ["IFSC"] = req.Ifsc, ["UpiId"] = req.UpiId,
            ["Remarks"] = req.Remarks, ["UserId"] = req.UserId
        });

    [HttpPost("prepare")]
    public Task<IActionResult> Prepare([FromBody] DoctorPayoutPrepareRequest req) =>
        Execute("dbo.usp_DoctorPayout_Prepare", new()
        {
            ["CompanyId"] = req.CompanyId, ["BranchId"] = req.BranchId, ["DoctorId"] = req.DoctorId, ["UpTo"] = req.UpTo.Date,
            ["OtherAdjustment"] = req.OtherAdjustment, ["OtherAdjustmentReason"] = req.OtherAdjustmentReason, ["Remarks"] = req.Remarks,
            ["UserId"] = req.UserId, ["IsSuperAdmin"] = req.IsSuperAdmin
        });

    [HttpPost("prepare-day")]
    public Task<IActionResult> PrepareDay([FromBody] DoctorPayoutPrepareRequest req) =>
        Sections("dbo.usp_DoctorPayout_PrepareDay", new()
        {
            ["CompanyId"] = req.CompanyId, ["BranchId"] = req.BranchId, ["UpTo"] = req.UpTo.Date,
            ["UserId"] = req.UserId, ["IsSuperAdmin"] = req.IsSuperAdmin
        }, "results");

    [HttpPost("action")]
    public Task<IActionResult> Action([FromBody] DoctorPayoutActionRequest req) =>
        Execute("dbo.usp_DoctorPayout_Action", new()
        {
            ["BranchId"] = req.BranchId, ["SettlementId"] = req.SettlementId, ["Action"] = req.Action, ["Remarks"] = req.Remarks,
            ["PaymentDate"] = req.PaymentDate?.Date, ["PaymentMode"] = req.PaymentMode, ["PaymentReference"] = req.PaymentReference,
            ["UserId"] = req.UserId, ["IsSuperAdmin"] = req.IsSuperAdmin
        });

    private async Task<IActionResult> Sections(string procedure, Dictionary<string, object?> parameters, params string[] sections)
    {
        try
        {
            return Ok(await reportService.RunLabSectionsAsync(procedure, parameters, sections));
        }
        catch (SqlException ex) when (ex.Number == 50020)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }

    private async Task<IActionResult> Execute(string procedure, Dictionary<string, object?> parameters)
    {
        try
        {
            return Ok(new { id = await reportService.ExecuteLabActionAsync(procedure, parameters) });
        }
        catch (SqlException ex) when (ex.Number == 50020)
        {
            return BadRequest(new { message = ex.Message });
        }
        catch (SqlException ex) when (ex.Number is 50010 or 50011)
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { message = ex.Message });
        }
    }
}

public sealed class DoctorPayoutProfileRequest
{
    public int CompanyId { get; set; }
    public int DoctorId { get; set; }
    public string? PayeeName { get; set; }
    public string? Pan { get; set; }
    public bool TdsApplicable { get; set; } = true;
    public decimal TdsPercent { get; set; } = 10;
    public string? PreferredMode { get; set; }
    public string? BankName { get; set; }
    public string? AccountNo { get; set; }
    public string? Ifsc { get; set; }
    public string? UpiId { get; set; }
    public string? Remarks { get; set; }
    public int UserId { get; set; }
}

public sealed class DoctorPayoutPrepareRequest
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int DoctorId { get; set; }
    public DateTime UpTo { get; set; }
    public decimal OtherAdjustment { get; set; }
    public string? OtherAdjustmentReason { get; set; }
    public string? Remarks { get; set; }
    public int UserId { get; set; }
    public bool IsSuperAdmin { get; set; }
}

public sealed class DoctorPayoutActionRequest
{
    public int BranchId { get; set; }
    public int SettlementId { get; set; }
    public string Action { get; set; } = string.Empty;
    public string? Remarks { get; set; }
    public DateTime? PaymentDate { get; set; }
    public string? PaymentMode { get; set; }
    public string? PaymentReference { get; set; }
    public int UserId { get; set; }
    public bool IsSuperAdmin { get; set; }
}
