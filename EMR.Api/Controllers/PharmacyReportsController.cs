using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Reports > Pharmacy (SQLScripts/2361). Each report is one stored procedure answering three result sets:
/// tiles, the requested page of rows (pageSize 0 = all rows, for export) and totals with TotalRows.
/// Only the reports listed here can be run.
/// </summary>
[ApiController]
[Route("api/pharmacy/reports")]
[Produces("application/json")]
public class PharmacyReportsController(IPharmacyProcService ph) : ControllerBase
{
    private static readonly Dictionary<string, string> Procs = new(StringComparer.OrdinalIgnoreCase)
    {
        ["sales-register"] = "dbo.usp_PhRpt_SalesRegister",
        ["sales-summary"] = "dbo.usp_PhRpt_SalesSummary",
        ["item-sales"] = "dbo.usp_PhRpt_ItemSales",
        ["collections"] = "dbo.usp_PhRpt_Collections",
        ["user-sales"] = "dbo.usp_PhRpt_UserSales",
        ["sale-returns"] = "dbo.usp_PhRpt_SaleReturns",
        ["cancellations"] = "dbo.usp_PhRpt_Cancellations",
        ["discounts"] = "dbo.usp_PhRpt_Discounts",
        ["doctor-sales"] = "dbo.usp_PhRpt_DoctorSales",
        ["customer-history"] = "dbo.usp_PhRpt_CustomerHistory",
        ["credit-ageing"] = "dbo.usp_PhRpt_CreditAgeing",
        ["hourly-pattern"] = "dbo.usp_PhRpt_HourlyPattern",
        // purchase (SQLScripts/2362)
        ["purchase-register"] = "dbo.usp_PhRpt_PurchaseRegister",
        ["item-purchases"] = "dbo.usp_PhRpt_ItemPurchases",
        ["supplier-purchases"] = "dbo.usp_PhRpt_SupplierPurchases",
        ["purchase-returns"] = "dbo.usp_PhRpt_PurchaseReturns",
        ["pending-pos"] = "dbo.usp_PhRpt_PendingPos",
        ["supplier-ageing"] = "dbo.usp_PhRpt_SupplierAgeing",
        ["supplier-payments"] = "dbo.usp_PhRpt_SupplierPayments",
        ["rate-variation"] = "dbo.usp_PhRpt_RateVariation",
        ["indent-turnaround"] = "dbo.usp_PhRpt_IndentTurnaround",
        // stock & inventory (SQLScripts/2363)
        ["current-stock"] = "dbo.usp_PhRpt_CurrentStock",
        ["stock-summary"] = "dbo.usp_PhRpt_StockSummary",
        ["item-ledger"] = "dbo.usp_PhRpt_ItemLedger",
        ["stock-statement"] = "dbo.usp_PhRpt_StockStatement",
        ["reorder"] = "dbo.usp_PhRpt_Reorder",
        ["non-moving"] = "dbo.usp_PhRpt_NonMoving",
        ["abc-analysis"] = "dbo.usp_PhRpt_AbcAnalysis",
        ["fsn-analysis"] = "dbo.usp_PhRpt_FsnAnalysis",
        ["transfers"] = "dbo.usp_PhRpt_Transfers",
        ["adjustments"] = "dbo.usp_PhRpt_Adjustments",
        ["count-variance"] = "dbo.usp_PhRpt_CountVariance",
        ["batch-corrections"] = "dbo.usp_PhRpt_BatchCorrections",
        ["stock-turnover"] = "dbo.usp_PhRpt_StockTurnover",
        ["store-issues"] = "dbo.usp_PhRpt_StoreIssues",   // SQLScripts/2365
        // expiry & quality (SQLScripts/2369)
        ["near-expiry"] = "dbo.usp_PhRpt_NearExpiry",
        ["expired-stock"] = "dbo.usp_PhRpt_ExpiredStock",
        ["expiry-loss"] = "dbo.usp_PhRpt_ExpiryLoss",
        ["short-expiry-receipts"] = "dbo.usp_PhRpt_ShortExpiryReceipts",
        // GST & tax (SQLScripts/2370)
        ["gstr1-summary"] = "dbo.usp_PhRpt_Gstr1Summary",
        ["hsn-summary"] = "dbo.usp_PhRpt_HsnSummary",
        ["credit-notes"] = "dbo.usp_PhRpt_CreditNotes",
        ["purchase-itc"] = "dbo.usp_PhRpt_PurchaseItc",
        ["gstr3b"] = "dbo.usp_PhRpt_Gstr3b",
        ["gst-rate-summary"] = "dbo.usp_PhRpt_GstRateSummary",
        // finance & accounts (SQLScripts/2371)
        ["cashier-closing"] = "dbo.usp_PhRpt_CashierClosing",
        ["gross-profit"] = "dbo.usp_PhRpt_GrossProfit",
        ["trading-account"] = "dbo.usp_PhRpt_TradingAccount",
        ["stock-vs-books"] = "dbo.usp_PhRpt_StockVsBooks",
        ["party-ledger"] = "dbo.usp_PhRpt_PartyLedger",
        // statutory & compliance (SQLScripts/2372)
        ["ndps-register"] = "dbo.usp_PhRpt_NdpsRegister",
        ["rx-sales-register"] = "dbo.usp_PhRpt_RxSalesRegister",
    };

    [HttpGet("lookups")]
    public async Task<IActionResult> Lookups([FromQuery] int companyId, [FromQuery] int? branchId) =>
        Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(
            await ph.SetsAsync("dbo.usp_PhRpt_Lookups", new { CompanyId = companyId, BranchId = branchId }, 10)));

    [HttpGet("{key}")]
    public async Task<IActionResult> Run(string key, [FromQuery] int companyId, [FromQuery] int? branchId, [FromQuery] DateTime from, [FromQuery] DateTime to,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 50, [FromQuery] int? userId = null, [FromQuery] string? mode = null, [FromQuery] string? kind = null,
        [FromQuery] int? categoryId = null, [FromQuery] int? manufacturerId = null, [FromQuery] string? schedule = null, [FromQuery] string? search = null,
        [FromQuery] string? option = null, [FromQuery] int? supplierId = null, [FromQuery] int? storeId = null, [FromQuery] int? ledgerId = null)
    {
        if (!Procs.TryGetValue(key, out var proc)) return NotFound(ApiResponse<object>.Fail("Unknown report."));
        if (to < from) return BadRequest(ApiResponse<object>.Fail("The 'to' date is before the 'from' date."));
        var args = new Dapper.DynamicParameters(new
        {
            CompanyId = companyId, BranchId = branchId, From = from.Date, To = to.Date, Page = Math.Max(1, page), PageSize = Math.Clamp(pageSize, 0, 500),
            UserId = userId, Mode = mode, Kind = kind, CategoryId = categoryId, ManufacturerId = manufacturerId, Schedule = schedule, Search = search, Option = option, SupplierId = supplierId
        });
        if (storeId is > 0) args.Add("StoreId", storeId);
        if (ledgerId is > 0) args.Add("LedgerId", ledgerId);   // party ledger (SQLScripts/2371)   // only the reports with a store filter take it (SQLScripts/2365)
        var sets = await ph.SetsAsync(proc, args, 3);
        return Ok(ApiResponse<List<List<IDictionary<string, object?>>>>.Ok(sets));
    }
}
