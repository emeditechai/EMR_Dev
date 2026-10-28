using System.Text.Json;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Stock Adjustment and Expiry / Damage Write-off (SQLScripts/2349): draft -> submit -> approve / reject (maker-checker).</summary>
public abstract class PharmacyAdjustControllerBase(IPharmacyInventoryService inventory, IPharmacyPurchaseService purchase, INotificationService n, IAuditLogService a)
    : PharmacyInventoryControllerBase(inventory, n, a)
{
    protected abstract string Kind { get; }          // ADJUST | WRITEOFF
    protected abstract string Module { get; }        // Approval Matrix module = page code
    protected abstract string Title { get; }

    [HttpGet]
    public async Task<IActionResult> Index(string? status)
    {
        ViewBag.Kind = Kind; ViewBag.Title = Title; ViewBag.Status = status; ViewBag.Page = Module;
        return View("~/Views/PharmacyInventory/Adjustments.cshtml", await Inventory.AdjustmentsAsync(CompanyId, BranchId, Kind, status));
    }

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0)
    {
        var d = id > 0 ? await Inventory.GetAdjustmentAsync(CompanyId, BranchId, id) : new PhInvDoc { Kind = Kind, DisposalDate = DateTime.Today };
        if (d == null || d.Kind != Kind) return NotFound();
        ViewBag.Reasons = await purchase.ReasonsAsync(CompanyId, "ADJUSTMENT");
        ViewBag.Page = Module; ViewBag.Title = Title; ViewBag.UserId = UserId;
        ViewBag.Approvers = await Inventory.MatrixApproversAsync(CompanyId, Module, BranchId);
        return View("~/Views/PharmacyInventory/AdjustForm.cshtml", d);
    }

    [HttpGet] public async Task<IActionResult> BatchSearch(string? q) =>
        Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await Inventory.BatchSearchAsync(CompanyId, BranchId, q.Trim()));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json)
    {
        var d = string.IsNullOrWhiteSpace(json) ? null : JsonSerializer.Deserialize<PhInvDoc>(json, Json);
        if (d == null) return BadRequest();
        d.Kind = Kind;
        var (id, err) = await Inventory.SaveAdjustmentAsync(CompanyId, BranchId, d, UserId);
        if (err != null) { TempData["Error"] = err; return d.Id > 0 ? RedirectToAction(nameof(Form), new { id = d.Id }) : RedirectToAction(nameof(Form)); }
        return Back(null, "Saved as draft.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Submit(int id)
    {
        var err = await Inventory.AdjustmentActionAsync(CompanyId, BranchId, id, "submit", null, UserId);
        if (err == null)
        {
            await LogAsync(Kind + "Submit", $"{Title} #{id} submitted");
            await NotifyApproversAsync(Module, $"{Title} to approve", $"{User.Identity?.Name} submitted a pharmacy {Title.ToLower()} for approval.", Url.Action(nameof(Form), new { id })!, id);
        }
        return Back(err, "Submitted for approval.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id, string? remarks)
    {
        var err = await ApproverCheckAsync(Module) ?? await Inventory.AdjustmentActionAsync(CompanyId, BranchId, id, "approve", remarks, UserId);
        if (err == null) await LogAsync(Kind + "Approve", $"{Title} #{id} approved: stock and books updated");
        return Back(err, "Approved: stock changed and posted to the books.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Reject(int id, string? remarks)
    {
        var err = await ApproverCheckAsync(Module) ?? await Inventory.AdjustmentActionAsync(CompanyId, BranchId, id, "reject", remarks, UserId);
        if (err == null) await LogAsync(Kind + "Reject", $"{Title} #{id} rejected: {remarks}");
        return Back(err, "Rejected.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, string? remarks) => Back(await Inventory.AdjustmentActionAsync(CompanyId, BranchId, id, "cancel", remarks, UserId), "Cancelled.", new { id });

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var d = await Inventory.GetAdjustmentAsync(CompanyId, BranchId, id);
        if (d == null || d.Kind != Kind) return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        return View("~/Views/PharmacyInventory/Print.cshtml", d);
    }
}

/// <summary>Pharmacy > Inventory > Stock Adjustment (PHARMACY.STOCKADJUST).</summary>
public class PhAdjustmentsController(IPharmacyInventoryService i, IPharmacyPurchaseService p, INotificationService n, IAuditLogService a) : PharmacyAdjustControllerBase(i, p, n, a)
{
    protected override string Kind => "ADJUST";
    protected override string Module => "PHARMACY.STOCKADJUST";
    protected override string Title => "Stock Adjustment";
}

/// <summary>Pharmacy > Inventory > Expiry / Damage Write-off (PHARMACY.WRITEOFF): expiry list, then destroy (destruction record) or return to supplier.</summary>
public class PhWriteOffsController(IPharmacyInventoryService i, IPharmacyPurchaseService p, INotificationService n, IAuditLogService a) : PharmacyAdjustControllerBase(i, p, n, a)
{
    protected override string Kind => "WRITEOFF";
    protected override string Module => "PHARMACY.WRITEOFF";
    protected override string Title => "Expiry / Damage Write-off";

    [HttpGet]
    public async Task<IActionResult> Expiry(int days = 90)
    {
        ViewBag.Days = days;
        var rows = (await Inventory.StockAsync(CompanyId, BranchId, null, null, "instock")).Where(r => r.ExpiryDate <= DateTime.Today.AddDays(days)).OrderBy(r => r.ExpiryDate).ToList();
        return View("~/Views/PharmacyInventory/Expiry.cshtml", rows);
    }
}
