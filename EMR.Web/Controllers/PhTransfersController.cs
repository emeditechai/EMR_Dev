using System.Text.Json;
using EMR.Web.Services;
using EMR.Web.Services.Notifications;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Inventory > Branch Indent & Transfer (PHARMACY.TRANSFER, SQLScripts/2349):
/// the receiving branch asks (REQUEST) -> the sending branch sends batches (DISPATCH, in transit) -> the receiving branch accepts (RECEIVE, variance).</summary>
public class PhTransfersController(IPharmacyInventoryService inventory, IPharmacyPurchaseService purchase, IPharmacySaleService sales, INotificationService n, IAuditLogService a)
    : PharmacyInventoryControllerBase(inventory, n, a)
{
    [HttpGet]
    public async Task<IActionResult> Index(string dir = "ALL", string? status = null)
    {
        ViewBag.Dir = dir; ViewBag.Status = status;
        return View("~/Views/PharmacyInventory/Transfers.cshtml", await Inventory.TransfersAsync(CompanyId, BranchId, dir, status));
    }

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0)
    {
        var d = id > 0 ? await Inventory.GetTransferAsync(CompanyId, BranchId, id) : new PhInvDoc { Kind = "TRANSFER", ToBranchId = BranchId, Priority = "NORMAL" };
        if (d == null) return NotFound();
        ViewBag.Branches = await Inventory.OtherBranchesAsync(CompanyId, BranchId);
        ViewBag.BranchId = BranchId;
        return View("~/Views/PharmacyInventory/TransferForm.cshtml", d);
    }

    [HttpGet] public async Task<IActionResult> ItemSearch(string? q) => Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await purchase.ItemSearchAsync(CompanyId, BranchId, q.Trim()));
    [HttpGet] public async Task<IActionResult> Batches(int itemId) => Json(await sales.BatchesAsync(CompanyId, BranchId, itemId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json, bool submit = false)
    {
        var d = string.IsNullOrWhiteSpace(json) ? null : JsonSerializer.Deserialize<PhInvDoc>(json, Json);
        if (d == null) return BadRequest();
        var (id, err) = await Inventory.SaveTransferRequestAsync(CompanyId, BranchId, d, submit, UserId);
        if (err != null) { TempData["Error"] = err; return d.Id > 0 ? RedirectToAction(nameof(Form), new { id = d.Id }) : RedirectToAction(nameof(Form)); }
        await LogAsync("TransferRequest", $"Branch indent #{id} {(submit ? "sent" : "saved")}");
        return Back(null, submit ? "Indent sent to the branch." : "Indent saved as draft.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Dispatch(int id, string? json, string? remarks)
    {
        var lines = string.IsNullOrWhiteSpace(json) ? [] : JsonSerializer.Deserialize<List<PhInvLine>>(json, Json) ?? [];
        var err = await Inventory.DispatchAsync(CompanyId, BranchId, id, lines, remarks, UserId);
        if (err == null) await LogAsync("TransferDispatch", $"Transfer #{id} dispatched");
        return Back(err, "Stock sent: it is in transit until the branch receives it.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Receive(int id, Dictionary<int, decimal>? received, Dictionary<int, string>? reasons, string? remarks)
    {
        var err = await Inventory.ReceiveAsync(CompanyId, BranchId, id, received ?? [], reasons ?? [], remarks, UserId);
        if (err == null) await LogAsync("TransferReceive", $"Transfer #{id} received");
        return Back(err, "Transfer received: stock added.", new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id) => Back(await Inventory.CancelTransferAsync(CompanyId, BranchId, id, UserId), "Indent cancelled.", new { id });

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var d = await Inventory.GetTransferAsync(CompanyId, BranchId, id);
        if (d == null) return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(d.FromBranchId);
        return View("~/Views/PharmacyInventory/Print.cshtml", d);
    }
}
