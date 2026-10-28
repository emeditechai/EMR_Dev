using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase > Supplier Payments (PHARMACY.SUPPLIERPAYMENT): supplier outstanding and ageing, payments set off bill by bill.</summary>
public class PhSupplierPaymentsController(IPharmacyPurchaseService purchase, IAuditLogService audit) : PharmacyPurchaseControllerBase(purchase, audit)
{
    protected override string Kind => "payment";
    protected override string PageCode => "PHARMACY.SUPPLIERPAYMENT";
    protected override string Title => "Supplier Payments";
    protected override string Icon => "bi-cash-coin";
    protected override string Description => "Payments made to suppliers, set off against their posted GRN bills. See Outstanding for what is due and overdue.";

    [HttpGet]
    public async Task<IActionResult> Outstanding()
    {
        ViewBag.PageCode = PageCode;
        return View("~/Views/PharmacyPurchase/Outstanding.cshtml", await Purchase.SupplierBalancesAsync(CompanyId, BranchId));
    }

    [HttpGet]
    public async Task<IActionResult> Pay(int supplierId)
    {
        var s = await Purchase.SupplierInfoAsync(CompanyId, BranchId, supplierId);
        if (s == null) return NotFound();
        ViewBag.PageCode = PageCode;
        ViewBag.Supplier = s;
        ViewBag.Returns = (await Purchase.SupplierBalancesAsync(CompanyId, BranchId)).FirstOrDefault(b => b.SupplierId == supplierId)?.Returns ?? 0;
        return View("~/Views/PharmacyPurchase/Pay.cshtml", await Purchase.PayablesAsync(CompanyId, BranchId, supplierId));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(int supplierId, DateTime paymentDate, string mode, string? reference, string? remarks, Dictionary<int, decimal>? alloc)
    {
        var (id, err) = await Purchase.SavePaymentAsync(CompanyId, BranchId, supplierId, paymentDate, mode, reference, remarks, alloc ?? [], UserId);
        if (err != null) { TempData["Error"] = err; return RedirectToAction(nameof(Pay), new { supplierId }); }
        TempData["Success"] = "Payment recorded.";
        return RedirectToAction(nameof(Print), new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id)
    {
        var err = await Purchase.CancelPaymentAsync(CompanyId, BranchId, id, UserId);
        TempData[err == null ? "Success" : "Error"] = err ?? "Payment cancelled; the bills are open again.";
        return RedirectToAction(nameof(Index));
    }
}
