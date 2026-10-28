using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory > Batch Correction (PHARMACY.BATCHCORRECTION, SQLScripts/2349): a wrong MRP / expiry / batch no. entered
/// at GRN, corrected with maker-checker approval; old and new values are kept.</summary>
public class PhBatchCorrectionsController(IPharmacyInventoryService inventory, INotificationService n, IAuditLogService a) : PharmacyInventoryControllerBase(inventory, n, a)
{
    private const string Module = "PHARMACY.BATCHCORRECTION";

    [HttpGet]
    public async Task<IActionResult> Index(string? status)
    {
        ViewBag.Status = status; ViewBag.UserId = UserId;
        return View("~/Views/PharmacyInventory/Corrections.cshtml", await Inventory.CorrectionsAsync(CompanyId, BranchId, status));
    }

    [HttpGet] public async Task<IActionResult> BatchSearch(string? q) =>
        Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await Inventory.BatchSearchAsync(CompanyId, BranchId, q.Trim()));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(int batchId, string? newBatchNo, string? newExpiry, decimal newMrp, string? reason)
    {
        if (!DateTime.TryParse(newExpiry + (newExpiry?.Length == 7 ? "-01" : ""), out var exp)) { TempData["Error"] = "Enter the correct expiry."; return RedirectToAction(nameof(Index)); }
        var (id, err) = await Inventory.SaveCorrectionAsync(CompanyId, BranchId, batchId, newBatchNo ?? "", exp, newMrp, reason ?? "", UserId);
        if (err == null)
        {
            await LogAsync("BatchCorrectionAsk", $"Batch correction #{id} asked for batch {batchId}: {reason}");
            await NotifyApproversAsync(Module, "Batch correction to approve", $"{User.Identity?.Name} asked to correct a pharmacy batch.", Url.Action(nameof(Index))!, id);
        }
        return Back(err, "Correction sent for approval.", new { }, nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Approve(int id, string? remarks)
    {
        var err = await ApproverCheckAsync(Module) ?? await Inventory.CorrectionActionAsync(CompanyId, BranchId, id, "approve", remarks, UserId);
        if (err == null) await LogAsync("BatchCorrectionApprove", $"Batch correction #{id} approved");
        return Back(err, "Correction approved: the batch is changed.", new { }, nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Reject(int id, string? remarks) =>
        Back(await ApproverCheckAsync(Module) ?? await Inventory.CorrectionActionAsync(CompanyId, BranchId, id, "reject", remarks, UserId), "Correction rejected.", new { }, nameof(Index));
}
