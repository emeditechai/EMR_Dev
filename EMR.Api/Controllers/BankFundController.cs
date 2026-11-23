using System.Security.Claims;
using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record BankSaveRequest(int? BankId, string? BankName, string? AccountHolderName, string? AccountNumber, string? AccountType, string? IFSCCode,
    string? MICRCode, string? SwiftCode, string? BranchName, string? BranchAddress, string? City, string? UpiId, string? UpiHolderName,
    string? ContactPerson, string? ContactPhone, string? ContactEmail, string? Remarks, bool IsPrimary, bool IsActive);
public record FundSaveRequest(int? FundId, int? BranchId, string? FundCode, string? FundName, string? FundType, int? BankId,
    decimal OpeningBalance, DateTime? OpeningDate, string? Remarks, bool IsActive);
public record FundTopUpRequest(int FundId, int? BranchId, decimal Amount, DateTime? TxnDate, string? PaymentMode, string? ReferenceNo, string? Remarks);
public record MasterStatusRequest(bool IsActive);

/// <summary>Shared: company and user from the token; rows as the procedures return them (Success / Error on a save).</summary>
public abstract class CompanyProcController(IIpdProcService procs) : ControllerBase
{
    protected IIpdProcService Procs => procs;
    protected (int CompanyId, int UserId)? Caller()
    {
        if (!int.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier), out var userId) || userId <= 0) return null;
        var companyId = int.TryParse(User.FindFirstValue("CompanyId"), out var c) && c > 0 ? c : 1;
        return (companyId, userId);
    }
    protected IActionResult NoCaller() => BadRequest(ApiResponse.Fail("A signed-in user is needed."));
    protected IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));
    protected IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
}

/// <summary>Master > General > Bank Master (SQLScripts/2522): the company's own bank accounts.</summary>
[ApiController]
[Route("api/banks")]
[Produces("application/json")]
public class BanksController(IIpdProcService procs) : CompanyProcController(procs)
{
    [HttpGet]
    public async Task<IActionResult> List([FromQuery] string? search, [FromQuery] string? status) =>
        Caller() is { } c ? Rows(await Procs.RowsAsync("dbo.usp_Api_Bank_List", new { c.CompanyId, Search = search, Status = status })) : NoCaller();

    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Bank_Get", new { c.CompanyId, BankId = id })) : NoCaller();

    /// <summary>SQLScripts/2523: the standard bank directory - bank name, IFSC bank code, category.</summary>
    [HttpGet("directory")]
    public async Task<IActionResult> Directory() =>
        Caller() is not null ? Rows(await Procs.RowsAsync("dbo.usp_Api_Bank_Directory", new { })) : NoCaller();

    /// <summary>Active accounts a Bank fund can use (and the fund's own one).</summary>
    [HttpGet("options")]
    public async Task<IActionResult> Options([FromQuery] int? fundId) =>
        Caller() is { } c ? Rows(await Procs.RowsAsync("dbo.usp_Api_Bank_Options", new { c.CompanyId, FundId = fundId })) : NoCaller();

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] BankSaveRequest r) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Bank_Save", new
        {
            c.CompanyId, c.UserId, r.BankId, r.BankName, r.AccountHolderName, r.AccountNumber, r.AccountType, r.IFSCCode, r.MICRCode, r.SwiftCode,
            r.BranchName, r.BranchAddress, r.City, r.UpiId, r.UpiHolderName, r.ContactPerson, r.ContactPhone, r.ContactEmail, r.Remarks, r.IsPrimary, r.IsActive
        })) : NoCaller();

    [HttpPost("{id:int}/status")]
    public async Task<IActionResult> SetStatus(int id, [FromBody] MasterStatusRequest r) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Bank_SetStatus", new { c.CompanyId, c.UserId, BankId = id, r.IsActive })) : NoCaller();
}

/// <summary>Utility > Accounts > Fund Master (SQLScripts/2522): funds (wallet / bank), opening balance, top-ups, history.</summary>
[ApiController]
[Route("api/funds")]
[Produces("application/json")]
public class FundsController(IIpdProcService procs) : CompanyProcController(procs)
{
    [HttpGet]
    public async Task<IActionResult> List([FromQuery] string? search, [FromQuery] string? type, [FromQuery] string? status) =>
        Caller() is { } c ? Rows(await Procs.RowsAsync("dbo.usp_Api_Fund_List", new { c.CompanyId, Search = search, Type = type, Status = status })) : NoCaller();

    [HttpGet("{id:int}")]
    public async Task<IActionResult> Get(int id) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Fund_Get", new { c.CompanyId, FundId = id })) : NoCaller();

    [HttpGet("{id:int}/history")]
    public async Task<IActionResult> History(int id, [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate) =>
        Caller() is { } c ? Rows(await Procs.RowsAsync("dbo.usp_Api_Fund_History", new { c.CompanyId, FundId = id, FromDate = fromDate?.Date, ToDate = toDate?.Date })) : NoCaller();

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] FundSaveRequest r) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Fund_Save", new
        {
            c.CompanyId, c.UserId, r.BranchId, r.FundId, r.FundCode, r.FundName, r.FundType, r.BankId, r.OpeningBalance,
            OpeningDate = r.OpeningDate?.Date, r.Remarks, r.IsActive
        })) : NoCaller();

    [HttpPost("{id:int}/topup")]
    public async Task<IActionResult> TopUp(int id, [FromBody] FundTopUpRequest r) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Fund_TopUp", new
        {
            c.CompanyId, c.UserId, r.BranchId, FundId = id, r.Amount, TxnDate = r.TxnDate?.Date, r.PaymentMode, r.ReferenceNo, r.Remarks
        })) : NoCaller();

    [HttpPost("{id:int}/status")]
    public async Task<IActionResult> SetStatus(int id, [FromBody] MasterStatusRequest r) =>
        Caller() is { } c ? Row(await Procs.RowAsync("dbo.usp_Api_Fund_SetStatus", new { c.CompanyId, c.UserId, FundId = id, r.IsActive })) : NoCaller();
}
