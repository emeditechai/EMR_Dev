using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record MarketingExecutiveSaveRequest(int? ExecutiveId, string? ExecutiveType, string? ExecutiveName, string? ExecutiveCode, string? PhoneNumber,
    string? EmailId, string? Address, decimal MonthlyTarget, bool IsActive,
    int? BranchId = null, string? LoginPasswordHash = null, string? LoginSalt = null);   // 2444: the executive's login (hash made by the web)
public record MarketingExecutiveStatusRequest(bool IsActive);
public record DoctorMarketingExecutiveRequest(int? ExecutiveId);
public record MarketingTargetSaveRequest(int BranchId, int ExecutiveId, DateTime FyStart, string? Frequency, string? Buckets, string? Remarks);
public record MarketingVisitSaveRequest(int BranchId, int? ExecutiveId, int DoctorId, DateTime? VisitDate, string? Purpose, string? Remarks);
public record MarketingVisitDeleteRequest(int BranchId);

/// <summary>
/// Master > General > Marketing Executive (SQLScripts/2440). Company and user come from the token; the rules (unique code,
/// 10-digit mobile, e-mail, target) are in the stored procedures. Procedures run through the generic procedure runner.
/// </summary>
[ApiController]
[Route("api/marketing-executives")]
[Produces("application/json")]
public class MarketingExecutiveController(IIpdProcService procs) : ControllerBase
{
    private (int CompanyId, int UserId)? Caller()
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return (companyId, userId);
    }
    private IActionResult NoCaller() => BadRequest(ApiResponse.Fail("A signed-in user is needed."));
    private IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] string? type, [FromQuery] string? search, [FromQuery] string? status)
    {
        if (Caller() is not { } c) return NoCaller();
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await procs.RowsAsync("dbo.usp_Api_MarketingExecutive_List", new { c.CompanyId, Type = type, Search = search, Status = status })));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MarketingExecutive_Get", new { c.CompanyId, ExecutiveId = id }));
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] MarketingExecutiveSaveRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MarketingExecutive_Save", new
        {
            c.CompanyId, c.UserId, r.ExecutiveId, r.ExecutiveType, r.ExecutiveName, r.ExecutiveCode, r.PhoneNumber, r.EmailId, r.Address, r.MonthlyTarget, r.IsActive,
            r.BranchId, r.LoginPasswordHash, r.LoginSalt
        }));
    }

    /// <summary>Is the e-mail free for the executive's login (SQLScripts/2444)? The save checks it again.</summary>
    [HttpGet("check-email")]
    public async Task<IActionResult> CheckEmail([FromQuery] string? email, [FromQuery] int? executiveId)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MarketingExecutive_CheckEmail", new { c.CompanyId, ExecutiveId = executiveId, EmailId = email }));
    }

    [HttpPost("{id:int}/status")]
    public async Task<IActionResult> SetStatus(int id, [FromBody] MarketingExecutiveStatusRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MarketingExecutive_SetStatus", new { c.CompanyId, c.UserId, ExecutiveId = id, r.IsActive }));
    }

    [HttpPost("{id:int}/delete")]
    public async Task<IActionResult> Delete(int id)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MarketingExecutive_Delete", new { c.CompanyId, c.UserId, ExecutiveId = id }));
    }

    // ── a doctor's marketing executive (Doctor Master, SQLScripts/2441) ───────────────────────────────────────
    [HttpGet("doctor/{doctorId:int}")]
    public async Task<IActionResult> DoctorExecutive(int doctorId)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_Doctor_GetMarketingExecutive", new { c.CompanyId, DoctorId = doctorId }));
    }

    [HttpPost("doctor/{doctorId:int}")]
    public async Task<IActionResult> SetDoctorExecutive(int doctorId, [FromBody] DoctorMarketingExecutiveRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_Doctor_SetMarketingExecutive", new { c.CompanyId, c.UserId, DoctorId = doctorId, r.ExecutiveId }));
    }

    // ── LAB > Marketing Executive Sales Target and Doctor Visit Log (SQLScripts/2447). Branch from the web (signed-in branch). ──
    [HttpGet("targets/years")]
    public async Task<IActionResult> TargetYears()
    {
        if (Caller() is not { } c) return NoCaller();
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await procs.RowsAsync("dbo.usp_Api_MktTarget_Years", new { c.CompanyId })));
    }

    [HttpGet("targets")]
    public async Task<IActionResult> Targets([FromQuery] int branchId, [FromQuery] DateTime fyStart)
    {
        if (Caller() is not { } c) return NoCaller();
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await procs.RowsAsync("dbo.usp_Api_MktTarget_List", new { c.CompanyId, BranchId = branchId, FyStart = fyStart.Date, c.UserId })));
    }

    [HttpGet("targets/{executiveId:int}")]
    public async Task<IActionResult> Target(int executiveId, [FromQuery] int branchId, [FromQuery] DateTime fyStart, [FromQuery] string? frequency)
    {
        if (Caller() is not { } c) return NoCaller();
        try
        {
            var sets = await procs.SetsAsync("dbo.usp_Api_MktTarget_Get", new { c.CompanyId, BranchId = branchId, ExecutiveId = executiveId, FyStart = fyStart.Date, Frequency = frequency, c.UserId }, 2);
            return Ok(ApiResponse<object>.Ok(new { header = sets[0].FirstOrDefault(), buckets = sets[1] }));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000) { return BadRequest(ApiResponse.Fail(ex.Message)); }
    }

    [HttpPost("targets")]
    public async Task<IActionResult> SaveTarget([FromBody] MarketingTargetSaveRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MktTarget_Save", new { c.CompanyId, r.BranchId, c.UserId, r.ExecutiveId, FyStart = r.FyStart.Date, r.Frequency, r.Buckets, r.Remarks }));
    }

    [HttpGet("visits")]
    public async Task<IActionResult> Visits([FromQuery] int branchId, [FromQuery] DateTime fromDate, [FromQuery] DateTime toDate, [FromQuery] int? executiveId, [FromQuery] string? search)
    {
        if (Caller() is not { } c) return NoCaller();
        var sets = await procs.SetsAsync("dbo.usp_Api_MktVisit_List", new { c.CompanyId, BranchId = branchId, c.UserId, FromDate = fromDate.Date, ToDate = toDate.Date, ExecutiveId = executiveId, Search = search }, 2);
        return Ok(ApiResponse<object>.Ok(new { visits = sets[0], executives = sets[1] }));
    }

    [HttpGet("visits/doctors")]
    public async Task<IActionResult> VisitDoctors([FromQuery] int? executiveId)
    {
        if (Caller() is not { } c) return NoCaller();
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await procs.RowsAsync("dbo.usp_Api_MktVisit_Doctors", new { c.CompanyId, ExecutiveId = executiveId })));
    }

    [HttpPost("visits")]
    public async Task<IActionResult> SaveVisit([FromBody] MarketingVisitSaveRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MktVisit_Save", new { c.CompanyId, r.BranchId, c.UserId, r.ExecutiveId, r.DoctorId, r.VisitDate, r.Purpose, r.Remarks }));
    }

    [HttpPost("visits/{id:int}/delete")]
    public async Task<IActionResult> DeleteVisit(int id, [FromBody] MarketingVisitDeleteRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_MktVisit_Delete", new { c.CompanyId, r.BranchId, c.UserId, VisitId = id }));
    }
}
