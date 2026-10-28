using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Sales > Credit Collection (PHARMACY.CREDITCOLLECTION, SQLScripts/2348): dues of credit customers,
/// received bill by bill with a money receipt (same receipt series as OPD / LAB); VIEW, COLLECT.</summary>
[Authorize]
public class PhCreditCollectionController(IPharmacySaleService sales, IPharmacyPurchaseService purchase, IAuditLogService audit) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    [HttpGet]
    public async Task<IActionResult> Index() => View("~/Views/PharmacySales/Credit.cshtml", await sales.CreditCustomersAsync(CompanyId, BranchId));

    [HttpGet]
    public async Task<IActionResult> Collect(int customerId)
    {
        var (bills, cust) = await sales.OpenBillsAsync(CompanyId, BranchId, customerId);
        if (cust == null) { TempData["Error"] = "Nothing is due from this customer."; return RedirectToAction(nameof(Index)); }
        ViewBag.Customer = cust;
        ViewBag.Methods = await sales.PaymentMethodsAsync();
        return View("~/Views/PharmacySales/Collect.cshtml", bills);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(int customerId, string mode, string? reference, Dictionary<int, decimal>? alloc)
    {
        var (receipt, err) = await sales.CollectAsync(CompanyId, BranchId, customerId, mode ?? "", reference, alloc ?? [], User.GetUserId());
        if (err != null) { TempData["Error"] = err; return RedirectToAction(nameof(Collect), new { customerId }); }
        await audit.LogAsync("Pharmacy", "CreditCollection", $"Pharmacy credit collection {receipt} from customer #{customerId}", User.GetUserId(), BranchId);
        return RedirectToAction(nameof(Receipt), new { receiptNo = receipt });
    }

    [HttpGet]
    public async Task<IActionResult> Receipt(string receiptNo)
    {
        var (rows, name, mobile) = await sales.ReceiptAsync(CompanyId, BranchId, receiptNo ?? "");
        if (rows.Count == 0) return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        ViewBag.Name = name; ViewBag.Mobile = mobile;
        return View("~/Views/PharmacySales/Receipt.cshtml", rows);
    }
}
