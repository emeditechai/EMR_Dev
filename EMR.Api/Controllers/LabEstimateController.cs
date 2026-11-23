using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using System.Text.Json;

namespace EMR.Api.Controllers;

public record LabEstimateCalcRequest(int BranchId, string? Items, string? DiscType, decimal DiscValue, string? DeptDisc, int? PatientId = null);
public record LabEstimateSaveRequest(int BranchId, int? PatientId, string? Salutation, string? PatientName, string? Gender, int? AgeYears, string? Mobile,
    string? EmailId, int? RefDoctorId, string? Items, string? DiscType, decimal DiscValue, string? DeptDisc, bool CanDiscount, int ValidDays, string? Remarks);
public record LabEstimateCancelRequest(int BranchId, string? Reason);
public record LabEstimateSentRequest(int BranchId, string? SentTo);

/// <summary>
/// LAB > B2C Bill Estimate (SQLScripts/2451). Every price and discount is worked out by usp_LabEstimate_Compute from the
/// branch's B2C rate list; the caller sends item ids, quantities and the discount asked for. Company and user come from the token.
/// </summary>
[ApiController]
[Route("api/lab-estimates")]
[Produces("application/json")]
public class LabEstimateController(IIpdProcService procs) : ControllerBase
{
    private (int CompanyId, int UserId)? Caller()
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return (companyId, userId);
    }
    private IActionResult NoCaller() => BadRequest(ApiResponse.Fail("A signed-in user is needed."));
    private IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    private IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));

    // ── membership card (as the B2C bill, SQLScripts/2241): the plan's benefits on the priced lines ───────────────
    private sealed record Member(string? MemberDisc, IDictionary<string, object?>? Card, IDictionary<string, object?>? Benefit);

    private static decimal Dec(object? v) => v is null or DBNull ? 0m : Convert.ToDecimal(v);

    /// <summary>For a registered patient: prices the lines (no discount), runs usp_Membership_LabBenefits on them (the
    /// procedure the bill uses) and returns the benefit per line as @MemberDisc for usp_LabEstimate_Compute.</summary>
    private async Task<Member> MembershipAsync(int companyId, int branchId, int? patientId, string? items)
    {
        if (patientId is not > 0) return new Member(null, null, null);
        var card = await procs.RowAsync("dbo.usp_Membership_CardForBilling", new { PatientId = patientId, Phone = (string?)null, CompanyId = companyId });
        var priced = await procs.SetsAsync("dbo.usp_Api_LabEstimate_Calc", new { CompanyId = companyId, BranchId = branchId, Items = items, DiscType = (string?)null, DiscValue = 0m, DeptDisc = (string?)null }, 3);
        if (priced[0].FirstOrDefault() is not { } t || !Convert.ToBoolean(t["Success"])) return new Member(null, card, null);
        var lines = priced[1].Select(l => new
        {
            key = "L" + l["LineSeq"],
            kind = (string?)l["ItemKind"] switch { "P" => "P", "M" => "M", _ => "T" },
            itemId = Convert.ToInt32(l["ItemId"]),
            price = Dec(l["Amount"])
        }).ToList();
        var ben = await procs.SetsAsync("dbo.usp_Membership_LabBenefits", new { PatientId = patientId, BranchId = branchId, LinesJson = JsonSerializer.Serialize(lines) }, 2);
        var benCard = ben[0].FirstOrDefault();
        if (benCard is null) return new Member(null, card, null);
        var disc = ben[1].Where(x => Dec(x["Discount"]) > 0)
            .Select(x => new { line = int.Parse(((string)x["LineKey"]!)[1..]), disc = Dec(x["Discount"]), rule = x["RuleText"] as string }).ToList();
        return new Member(disc.Count > 0 ? JsonSerializer.Serialize(disc) : null, card, benCard);
    }

    /// <summary>Simulate: lines, department heads and totals (membership benefits included); nothing is saved.</summary>
    [HttpPost("calc")]
    public async Task<IActionResult> Calc([FromBody] LabEstimateCalcRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        var m = await MembershipAsync(c.CompanyId, r.BranchId, r.PatientId, r.Items);
        var sets = await procs.SetsAsync("dbo.usp_Api_LabEstimate_Calc", new { c.CompanyId, r.BranchId, r.Items, r.DiscType, r.DiscValue, r.DeptDisc, MemberDisc = m.MemberDisc }, 3);
        return Ok(ApiResponse<object>.Ok(new { totals = sets[0].FirstOrDefault(), lines = sets[1], heads = sets[2], membership = m.Card, benefit = m.Benefit }));
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] LabEstimateSaveRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        // the membership benefits are worked out again here, never taken from the screen
        var m = await MembershipAsync(c.CompanyId, r.BranchId, r.PatientId, r.Items);
        return Row(await procs.RowAsync("dbo.usp_Api_LabEstimate_Save", new
        {
            c.CompanyId, r.BranchId, c.UserId, r.PatientId, r.Salutation, r.PatientName, r.Gender, r.AgeYears, r.Mobile, r.EmailId, r.RefDoctorId,
            r.Items, r.DiscType, r.DiscValue, r.DeptDisc, r.CanDiscount, r.ValidDays, r.Remarks,
            MemberDisc = m.MemberDisc, MemberCardNo = m.Benefit?["CardNo"] as string, MemberPlan = m.Benefit?["PlanName"] as string
        }));
    }

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] int branchId, [FromQuery] DateTime fromDate, [FromQuery] DateTime toDate, [FromQuery] string? search, [FromQuery] string? status)
    {
        if (Caller() is null) return NoCaller();
        return Rows(await procs.RowsAsync("dbo.usp_Api_LabEstimate_List", new { BranchId = branchId, FromDate = fromDate.Date, ToDate = toDate.Date, Search = search, Status = status }));
    }

    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id, [FromQuery] int branchId)
    {
        if (Caller() is null) return NoCaller();
        var sets = await procs.SetsAsync("dbo.usp_Api_LabEstimate_Get", new { EstimateId = id, BranchId = branchId, Token = (Guid?)null }, 3);
        return Ok(ApiResponse<object>.Ok(new { header = sets[0].FirstOrDefault(), lines = sets[1], deptDiscounts = sets[2] }));
    }

    /// <summary>The estimate behind the link sent to the patient (no sign-in; the web checks the token's format).</summary>
    [AllowAnonymous]
    [HttpGet("public/{token:guid}")]
    public async Task<IActionResult> GetPublic(Guid token)
    {
        var sets = await procs.SetsAsync("dbo.usp_Api_LabEstimate_Get", new { EstimateId = (int?)null, BranchId = (int?)null, Token = token }, 3);
        return Ok(ApiResponse<object>.Ok(new { header = sets[0].FirstOrDefault(), lines = sets[1], deptDiscounts = sets[2] }));
    }

    [HttpPost("{id:int}/cancel")]
    public async Task<IActionResult> Cancel(int id, [FromBody] LabEstimateCancelRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_LabEstimate_Cancel", new { r.BranchId, c.UserId, EstimateId = id, r.Reason }));
    }

    [HttpPost("{id:int}/sent")]
    public async Task<IActionResult> MarkSent(int id, [FromBody] LabEstimateSentRequest r)
    {
        if (Caller() is null) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_LabEstimate_MarkSent", new { r.BranchId, EstimateId = id, r.SentTo }));
    }

    /// <summary>Tests inside a profile (kind T, its Test_ID) or package (kind P), nested profiles included.</summary>
    [HttpGet("includes")]
    public async Task<IActionResult> Includes([FromQuery] string kind, [FromQuery] int id)
    {
        if (Caller() is null) return NoCaller();
        return Rows(await procs.RowsAsync("dbo.usp_Api_LabEstimate_Includes", new { Kind = kind == "P" ? "P" : "T", Id = id }));
    }

    [HttpGet("doctors")]
    public async Task<IActionResult> Doctors()
    {
        if (Caller() is not { } c) return NoCaller();
        return Rows(await procs.RowsAsync("dbo.usp_Api_LabEstimate_Doctors", new { c.CompanyId }));
    }

    [HttpGet("misc-charges")]
    public async Task<IActionResult> MiscCharges()
    {
        if (Caller() is not { } c) return NoCaller();
        return Rows(await procs.RowsAsync("dbo.usp_LabMiscCharge_ForBilling", new { c.CompanyId }));
    }
}
