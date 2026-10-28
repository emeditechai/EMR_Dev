using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase > Purchase Return (PHARMACY.PURCHASERETURN): batch-wise return to the supplier (debit note); posting takes the stock out.</summary>
public class PhPurchaseReturnsController(IPharmacyPurchaseService purchase, IAuditLogService audit) : PharmacyPurchaseControllerBase(purchase, audit)
{
    protected override string Kind => "return";
    protected override string PageCode => "PHARMACY.PURCHASERETURN";
    protected override string Title => "Purchase Return";
    protected override string Icon => "bi-box-arrow-up";
    protected override string Description => "Send expired, damaged or wrongly supplied stock back to the supplier, batch by batch, at the purchase rate. Posting reduces stock and raises a debit note.";

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0)
    {
        var d = id > 0 ? await Purchase.GetAsync(Kind, CompanyId, BranchId, id) : new PhDoc();
        return d == null ? NotFound() : await FormView(d);
    }

    [HttpGet]
    public async Task<IActionResult> BatchSearch(string? q, int? supplierId) =>
        Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await Purchase.BatchSearchAsync(CompanyId, BranchId, q.Trim(), supplierId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json)
    {
        var d = ReadDoc(json);
        if (d == null) return BadRequest();
        var (id, err) = await Purchase.SaveReturnAsync(CompanyId, BranchId, d, UserId);
        return await AfterSave(d, id, err, "Purchase return");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var err = await Purchase.DeleteDraftAsync(Kind, CompanyId, BranchId, id);
        if (err != null) return await Done(id, err, "Delete", "");
        TempData["Success"] = "Draft return deleted.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Post(int id)
    {
        var (no, err) = await Purchase.PostReturnAsync(CompanyId, BranchId, id, UserId);
        return await Done(id, err, "Post", $"Purchase return {no} posted - stock reduced.");
    }
}
