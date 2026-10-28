using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Sales > Sale Return (PHARMACY.SALERETURN, SQLScripts/2348): against the original bill; VIEW, SAVE.</summary>
[Authorize]
public class PhSaleReturnsController(IPharmacySaleService sales, IPharmacyPurchaseService purchase, IAuditLogService audit) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    [HttpGet]
    public async Task<IActionResult> Index(string? search, DateTime? from, DateTime? to)
    {
        from ??= DateTime.Today.AddDays(-30); to ??= DateTime.Today;
        ViewBag.Filter = (search, from, to);
        return View("~/Views/PharmacySales/Returns.cshtml", await sales.ReturnsAsync(CompanyId, BranchId, from.Value, to.Value, search));
    }

    [HttpGet]
    public async Task<IActionResult> Form(string? q, int? saleId)
    {
        PhSaleBill? bill = null;
        if (saleId != null) bill = await sales.GetAsync(CompanyId, BranchId, saleId.Value);
        else if (!string.IsNullOrWhiteSpace(q)) bill = await sales.FindForReturnAsync(CompanyId, BranchId, q);
        if (bill != null && bill.Status != "POSTED") { TempData["Error"] = "That bill is not open for returns (held or cancelled)."; bill = null; }
        else if (!string.IsNullOrWhiteSpace(q) && bill == null) TempData["Error"] = $"No saved bill {q} at this branch.";
        ViewBag.Q = q;
        ViewBag.Settings = await sales.SettingsAsync(BranchId);
        ViewBag.Reasons = await purchase.ReasonsAsync(CompanyId, "SALE_RETURN");
        ViewBag.Methods = await sales.PaymentMethodsAsync();
        return View("~/Views/PharmacySales/ReturnForm.cshtml", bill);
    }

    [HttpGet] public async Task<IActionResult> FindBill(string q) => Json(await sales.FindForReturnAsync(CompanyId, BranchId, q));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(int saleId, Dictionary<int, decimal>? qty, int reasonId, string? refundMode, string? refundRef, string? remarks)
    {
        var (id, no, err) = await sales.SaveReturnAsync(CompanyId, BranchId, saleId, qty ?? [], reasonId, refundMode ?? "", refundRef, remarks, User.GetUserId());
        if (err != null) { TempData["Error"] = err; return RedirectToAction(nameof(Form), new { saleId }); }
        await audit.LogAsync("Pharmacy", "SaleReturn", $"Pharmacy sale return {no} against bill #{saleId}", User.GetUserId(), BranchId);
        TempData["Success"] = $"Return {no} saved: stock taken back.";
        return RedirectToAction(nameof(Print), new { id });
    }

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var (head, bill, lines) = await sales.GetReturnAsync(CompanyId, BranchId, id);
        if (head == null) return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        ViewBag.Bill = bill; ViewBag.Lines = lines;
        return View("~/Views/PharmacySales/ReturnPrint.cshtml", head);
    }
}
