using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase > Purchase Indent (PHARMACY.PURCHASEINDENT): draft -> submit -> approve / reject -> ordered by a PO.</summary>
public class PhPurchaseIndentsController(IPharmacyPurchaseService purchase, IAuditLogService audit) : PharmacyPurchaseControllerBase(purchase, audit)
{
    protected override string Kind => "indent";
    protected override string PageCode => "PHARMACY.PURCHASEINDENT";
    protected override string Title => "Purchase Indent";
    protected override string Icon => "bi-clipboard-plus";
    protected override string Description => "Ask for stock to be bought: items below reorder level are suggested. An approved indent becomes a purchase order.";

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0)
    {
        var d = id > 0 ? await Purchase.GetAsync(Kind, CompanyId, BranchId, id) : new PhDoc { Priority = "NORMAL" };
        return d == null ? NotFound() : await FormView(d);
    }

    [HttpGet]
    public async Task<IActionResult> ReorderSuggest() => Json(await Purchase.ReorderSuggestAsync(CompanyId, BranchId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json)
    {
        var d = ReadDoc(json);
        if (d == null) return BadRequest();
        var (id, err) = await Purchase.SaveIndentAsync(CompanyId, BranchId, d, UserId);
        return await AfterSave(d, id, err, "Indent");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Submit(int id) => await Done(id, await Purchase.IndentActionAsync(CompanyId, BranchId, id, "submit", null, UserId), "Submit", "Indent submitted for approval.");

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id, string? remarks) => await Done(id, await Purchase.IndentActionAsync(CompanyId, BranchId, id, "approve", remarks, UserId), "Approve", "Indent approved.");

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Reject(int id, string? remarks) => await Done(id, await Purchase.IndentActionAsync(CompanyId, BranchId, id, "reject", remarks, UserId), "Reject", "Indent rejected.");

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, string? remarks) => await Done(id, await Purchase.IndentActionAsync(CompanyId, BranchId, id, "cancel", remarks, UserId), "Cancel", "Indent cancelled.");
}
