using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record PaymentQrSaveRequest(int BranchId, string? UpiId, string? PayeeName, string? MerchantCode, string? AmountMode, bool IncludeReference, string? Caption, bool IsActive);
public record PaymentQrStatusRequest(bool IsActive);

/// <summary>Settings > Payment QR Configuration (SQLScripts/2452): the UPI QR setup of each branch. Company and user from the token.</summary>
[ApiController]
[Route("api/payment-qr")]
[Produces("application/json")]
public class PaymentQrController(IIpdProcService procs) : ControllerBase
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
    public async Task<IActionResult> List()
    {
        if (Caller() is not { } c) return NoCaller();
        return Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(await procs.RowsAsync("dbo.usp_Api_PaymentQr_List", new { c.CompanyId })));
    }

    /// <summary>One branch's setup (null when none) - also read by the B2B invoice.</summary>
    [HttpGet("branch/{branchId:int}")]
    public async Task<IActionResult> Get(int branchId)
    {
        if (Caller() is null) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_PaymentQr_Get", new { BranchId = branchId }));
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] PaymentQrSaveRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_PaymentQr_Save", new
        { c.CompanyId, c.UserId, r.BranchId, r.UpiId, r.PayeeName, r.MerchantCode, r.AmountMode, r.IncludeReference, r.Caption, r.IsActive }));
    }

    [HttpPost("branch/{branchId:int}/status")]
    public async Task<IActionResult> SetStatus(int branchId, [FromBody] PaymentQrStatusRequest r)
    {
        if (Caller() is not { } c) return NoCaller();
        return Row(await procs.RowAsync("dbo.usp_Api_PaymentQr_SetStatus", new { c.CompanyId, c.UserId, BranchId = branchId, r.IsActive }));
    }
}
