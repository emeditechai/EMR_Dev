using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

public record PhSaleSaveRequest(int CompanyId, int BranchId, int UserId, bool Hold, bool CanDiscount, bool CanCredit, int? HoldId, string CustomerKind,
    int? PatientId, int? CustomerId, string? CustomerName, string? Mobile, string? Email, string? Address, int? DoctorId, string? DoctorName, string? DoctorRegNo,
    string? RxNo, DateTime? RxDate, decimal BillDiscPercent, string? Remarks, string? HoldLabel, string Lines, string Payments, int? StoreId = null,
    int? ConsultationId = null, string? RxLines = null, string? Alerts = null, decimal RedeemPoints = 0, string? CreditRefNo = null, string? RedeemOtp = null);

public record PhLoyaltyOtpRequest(int CompanyId, string MemberKey, string Code);
public record PhLoyaltyAdjustRequest(int CompanyId, int BranchId, int UserId, int? PatientId, int? CustomerId, string? Mobile, decimal Points, string Reason);

/// <summary>Clinical check of a bill (SQLScripts/2406): ItemIds = JSON array of item ids.</summary>
public record PhClinicalCheckRequest(int CompanyId, int BranchId, int? PatientId, int? CustomerId, string ItemIds);

public record PhSaleRefRequest(int CompanyId, int BranchId, int UserId, int SaleId, string? Reason);

public record PhSaleReturnSaveRequest(int CompanyId, int BranchId, int UserId, int SaleId, int ReasonId, string RefundMode, string? RefundRef, string? Remarks, string Lines);

public record PhSaleCollectRequest(int CompanyId, int BranchId, int UserId, int CustomerId, string Method, string? Reference, string Alloc);

/// <summary>Pharmacy > Sales (SQLScripts/2359): counter sale, hold, return, cancellation, credit collection, receipts, Schedule register.</summary>
[ApiController]
[Route("api/pharmacy/sales")]
[Produces("application/json")]
public class PharmacySalesController(IPharmacyProcService ph) : ControllerBase
{
    private IActionResult Rows(List<IDictionary<string, object?>> rows) => Ok(ApiResponse<List<IDictionary<string, object?>>>.Ok(rows));
    private IActionResult Row(IDictionary<string, object?>? row) => Ok(ApiResponse<IDictionary<string, object?>?>.Ok(row));
    private IActionResult Sets(List<List<IDictionary<string, object?>>> sets) => Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(sets));

    // ── settings and look-ups ──────────────────────────────────────────────────────────────────────────
    [HttpGet("settings/{branchId:int}")]
    public async Task<IActionResult> Settings(int branchId) => Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_Settings", new { BranchId = branchId }));

    [HttpGet("item-search")]
    public async Task<IActionResult> ItemSearch([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? q, [FromQuery] int? genericId, [FromQuery] int? itemId,
        [FromQuery] int? storeId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_ItemSearch", new { CompanyId = companyId, BranchId = branchId, Q = q, GenericId = genericId, ItemId = itemId, StoreId = storeId }));

    [HttpGet("batches")]
    public async Task<IActionResult> Batches([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int itemId, [FromQuery] int? storeId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_Batches", new { CompanyId = companyId, BranchId = branchId, ItemId = itemId, StoreId = storeId }));

    [HttpGet("unit-price")]
    public async Task<IActionResult> UnitPrice([FromQuery] int companyId, [FromQuery] int itemId, [FromQuery] int batchId, [FromQuery] string priceType)
    {
        var row = await ph.RowAsync("dbo.usp_Api_PhSale_UnitPrice", new { CompanyId = companyId, ItemId = itemId, BatchId = batchId, PriceType = priceType });
        return row == null ? NotFound(ApiResponse<object>.Fail("The batch is not of this item.")) : Row(row);
    }

    [HttpGet("payment-methods")]
    public async Task<IActionResult> PaymentMethods() => Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_PaymentMethods", new { }));

    [HttpGet("customers")]
    public async Task<IActionResult> Customers([FromQuery] int companyId, [FromQuery] string? q) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_Customers", new { CompanyId = companyId, Q = q }));

    [HttpGet("patients")]
    public async Task<IActionResult> Patients([FromQuery] int companyId, [FromQuery] string q) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_Patients", new { CompanyId = companyId, Q = q ?? "" }));

    [HttpGet("doctors")]
    public async Task<IActionResult> Doctors([FromQuery] int companyId, [FromQuery] string? q) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_Doctors", new { CompanyId = companyId, Q = q }));

    // ── bills ──────────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("save")]
    public async Task<IActionResult> Save([FromBody] PhSaleSaveRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhSale_Save", new
        {
            r.CompanyId, r.BranchId, r.UserId, r.Hold, r.CanDiscount, r.CanCredit, r.HoldId, r.CustomerKind, r.PatientId, r.CustomerId, r.CustomerName, r.Mobile,
            r.Email, r.Address, r.DoctorId, r.DoctorName, r.DoctorRegNo, r.RxNo, RxDate = r.RxDate?.Date, r.BillDiscPercent, r.Remarks, r.HoldLabel, r.Lines, r.Payments, r.StoreId,
            r.ConsultationId, r.RxLines, r.Alerts, r.RedeemPoints, r.CreditRefNo, r.RedeemOtp
        }));

    // ── SQLScripts/2406: OPD prescription, clinical checks, loyalty ─────────────────────────────────────
    // SQLScripts/2412: walk-in found by mobile (last walk-in bill + registered patients with this phone)
    [HttpGet("walkin-by-mobile")]
    public async Task<IActionResult> WalkinByMobile([FromQuery] int companyId, [FromQuery] string mobile) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhSale_WalkinByMobile", new { CompanyId = companyId, Mobile = mobile }, 2));

    [HttpGet("rx-list")]
    public async Task<IActionResult> RxList([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int patientId, [FromQuery] int days = 30) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_RxList", new { CompanyId = companyId, BranchId = branchId, PatientId = patientId, Days = days }));

    [HttpGet("rx-lines")]
    public async Task<IActionResult> RxLines([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int consultationId, [FromQuery] int? storeId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhSale_RxLines", new { CompanyId = companyId, BranchId = branchId, ConsultationId = consultationId, StoreId = storeId }, 2));

    [HttpPost("clinical-check")]
    public async Task<IActionResult> ClinicalCheck([FromBody] PhClinicalCheckRequest r) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_ClinicalCheck", new { r.CompanyId, r.BranchId, r.PatientId, r.CustomerId, r.ItemIds }));

    [HttpGet("loyalty")]
    public async Task<IActionResult> Loyalty([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int? patientId, [FromQuery] int? customerId, [FromQuery] string? mobile) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhSale_LoyaltyBalance", new { CompanyId = companyId, BranchId = branchId, PatientId = patientId, CustomerId = customerId, Mobile = mobile }));

    // ── loyalty wallet (SQLScripts/2409) ─────────────────────────────────────────────────────────────────
    [HttpPost("loyalty/otp")]
    public async Task<IActionResult> LoyaltyOtp([FromBody] PhLoyaltyOtpRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhLoyalty_OtpCreate", new { r.CompanyId, r.MemberKey, r.Code }));

    [HttpGet("loyalty/members")]
    public async Task<IActionResult> LoyaltyMembers([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string? q) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhLoyalty_Members", new { CompanyId = companyId, BranchId = branchId, Q = q }, 2));

    [HttpGet("loyalty/statement")]
    public async Task<IActionResult> LoyaltyStatement([FromQuery] int companyId, [FromQuery] int? patientId, [FromQuery] int? customerId, [FromQuery] string? mobile) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhLoyalty_Statement", new { CompanyId = companyId, PatientId = patientId, CustomerId = customerId, Mobile = mobile }, 2));

    [HttpPost("loyalty/adjust")]
    public async Task<IActionResult> LoyaltyAdjust([FromBody] PhLoyaltyAdjustRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhLoyalty_Adjust", new { r.CompanyId, r.BranchId, r.UserId, r.PatientId, r.CustomerId, r.Mobile, r.Points, r.Reason }));

    [HttpPost("discard-hold")]
    public async Task<IActionResult> DiscardHold([FromBody] PhSaleRefRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhSale_DiscardHold", new { r.CompanyId, r.BranchId, r.SaleId }));

    [HttpGet("list")]
    public async Task<IActionResult> List([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string status, [FromQuery] string? search,
        [FromQuery] DateTime? from, [FromQuery] DateTime? to) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_List", new { CompanyId = companyId, BranchId = branchId, Status = status, Search = search, From = from?.Date, To = to?.Date }));

    [HttpGet("bill/{saleId:int}")]
    public async Task<IActionResult> Bill(int saleId, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhSale_Get", new { CompanyId = companyId, BranchId = branchId, SaleId = saleId }, 4));

    [HttpGet("find-for-return")]
    public async Task<IActionResult> FindForReturn([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string q) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_FindForReturn", new { CompanyId = companyId, BranchId = branchId, Q = q ?? "" }));

    [HttpPost("cancel")]
    public async Task<IActionResult> Cancel([FromBody] PhSaleRefRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhSale_Cancel", new { r.CompanyId, r.BranchId, r.UserId, r.SaleId, r.Reason }));

    // ── sale return ────────────────────────────────────────────────────────────────────────────────────
    [HttpPost("return/save")]
    public async Task<IActionResult> SaveReturn([FromBody] PhSaleReturnSaveRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhSale_SaveReturn", new { r.CompanyId, r.BranchId, r.UserId, r.SaleId, r.ReasonId, r.RefundMode, r.RefundRef, r.Remarks, r.Lines }));

    [HttpGet("returns")]
    public async Task<IActionResult> Returns([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] DateTime from, [FromQuery] DateTime to, [FromQuery] string? search) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_Returns", new { CompanyId = companyId, BranchId = branchId, From = from.Date, To = to.Date, Search = search }));

    [HttpGet("return/{returnId:int}")]
    public async Task<IActionResult> Return(int returnId, [FromQuery] int companyId, [FromQuery] int branchId) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhSale_GetReturn", new { CompanyId = companyId, BranchId = branchId, ReturnId = returnId }, 3));

    // ── credit collection ──────────────────────────────────────────────────────────────────────────────
    [HttpGet("credit-customers")]
    public async Task<IActionResult> CreditCustomers([FromQuery] int companyId, [FromQuery] int branchId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_CreditCustomers", new { CompanyId = companyId, BranchId = branchId }));

    [HttpGet("open-bills")]
    public async Task<IActionResult> OpenBills([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] int customerId) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_OpenBills", new { CompanyId = companyId, BranchId = branchId, CustomerId = customerId }));

    [HttpPost("collect")]
    public async Task<IActionResult> Collect([FromBody] PhSaleCollectRequest r) =>
        Row(await ph.RowAsync("dbo.usp_Api_PhSale_Collect", new { r.CompanyId, r.BranchId, r.UserId, r.CustomerId, r.Method, r.Reference, r.Alloc }));

    [HttpGet("receipt")]
    public async Task<IActionResult> Receipt([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] string receiptNo) =>
        Sets(await ph.SetsAsync("dbo.usp_Api_PhSale_Receipt", new { CompanyId = companyId, BranchId = branchId, ReceiptNo = receiptNo }, 2));

    [HttpGet("schedule-register")]
    public async Task<IActionResult> ScheduleRegister([FromQuery] int companyId, [FromQuery] int branchId, [FromQuery] DateTime from, [FromQuery] DateTime to, [FromQuery] string? schedule) =>
        Rows(await ph.RowsAsync("dbo.usp_Api_PhSale_ScheduleRegister", new { CompanyId = companyId, BranchId = branchId, From = from.Date, To = to.Date, Schedule = schedule }));
}
