using EMR.Web.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase > Goods Receipt (PHARMACY.GRN): supplier bill entry with batch, expiry and MRP; posting brings the stock in.</summary>
public class PhGrnsController(IPharmacyPurchaseService purchase, IAuditLogService audit, IWebHostEnvironment env) : PharmacyPurchaseControllerBase(purchase, audit)
{
    protected override string Kind => "grn";
    protected override string PageCode => "PHARMACY.GRN";
    protected override string Title => "Goods Receipt (GRN)";
    protected override string Icon => "bi-box-arrow-in-down";
    protected override string Description => "Enter the supplier's bill line by line with batch, expiry and MRP. Posting adds the stock; a posted GRN is corrected by a purchase return.";

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0, int? poId = null)
    {
        PhDoc? d;
        if (id > 0) d = await Purchase.GetAsync(Kind, CompanyId, BranchId, id);
        else
        {
            d = new PhDoc { InvoiceDate = DateTime.Today };
            if (poId != null && await Purchase.GetAsync("po", CompanyId, BranchId, poId.Value) is { } po)
            {
                d.SupplierId = po.SupplierId; d.SupplierName = po.SupplierName; d.RefId = po.Id; d.RefNo = po.DocNo; d.IsInterState = po.IsInterState;
                d.Lines = await Purchase.PoLinesForGrnAsync(CompanyId, BranchId, po.Id);
            }
        }
        return d == null ? NotFound() : await FormView(d);
    }

    [HttpGet]
    public async Task<IActionResult> OpenPos(int supplierId) => Json(await Purchase.OpenPosAsync(CompanyId, BranchId, supplierId));

    [HttpGet]
    public async Task<IActionResult> PoLines(int poId) => Json(await Purchase.PoLinesForGrnAsync(CompanyId, BranchId, poId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string? json)
    {
        var d = ReadDoc(json);
        if (d == null) return BadRequest();
        var (id, warnings, err) = await Purchase.SaveGrnAsync(CompanyId, BranchId, d, UserId);
        return await AfterSave(d, id, err, "GRN", warnings);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Delete(int id)
    {
        var err = await Purchase.DeleteDraftAsync(Kind, CompanyId, BranchId, id);
        if (err != null) return await Done(id, err, "Delete", "");
        TempData["Success"] = "Draft GRN deleted.";
        return RedirectToAction(nameof(Index));
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Post(int id, bool acceptWarnings = false)
    {
        var (no, err) = await Purchase.PostGrnAsync(CompanyId, BranchId, id, acceptWarnings, UserId);
        return await Done(id, err, "Post", $"GRN {no} posted - stock added.");
    }

    [HttpGet]
    public async Task<IActionResult> RateHistory(int itemId) => Json(await Purchase.RateHistoryAsync(CompanyId, itemId));

    private static readonly Dictionary<string, string> BillTypes = new() { [".pdf"] = "application/pdf", [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg", [".png"] = "image/png", [".webp"] = "image/webp" };

    /// <summary>Scanned supplier bill: saved in wwwroot/uploads/pharmacy/grn like the other uploads; the GRN page opens it through
    /// Attachment (VIEW of the GRN page). Scans saved earlier in App_Data/pharmacy/grn still open.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Attach(int id, IFormFile? file)
    {
        var ext = Path.GetExtension(file?.FileName ?? "").ToLowerInvariant();
        if (file == null || file.Length == 0) return await Done(id, "Choose the scanned bill (PDF or image).", "Attach", "");
        if (!BillTypes.ContainsKey(ext)) return await Done(id, "Bill scan: PDF, JPG, PNG or WEBP only.", "Attach", "");
        if (file.Length > 5 * 1024 * 1024) return await Done(id, "Bill scan: up to 5 MB.", "Attach", "");
        var dir = Path.Combine(env.WebRootPath, "uploads", "pharmacy", "grn");
        Directory.CreateDirectory(dir);
        var name = $"grn{id}_{Guid.NewGuid():N}{ext}";
        await using (var fs = System.IO.File.Create(Path.Combine(dir, name))) await file.CopyToAsync(fs);
        var original = Path.GetFileName(file.FileName);
        return await Done(id, await Purchase.AttachAsync(CompanyId, BranchId, id, "/uploads/pharmacy/grn/" + name, original.Length > 150 ? original[^150..] : original), "Attach", "Supplier bill attached.");
    }

    [HttpGet]
    public async Task<IActionResult> Attachment(int id)
    {
        var d = await Purchase.GetAsync(Kind, CompanyId, BranchId, id);
        if (d?.AttachmentPath == null) return NotFound();
        var file = Path.GetFileName(d.AttachmentPath);
        var path = d.AttachmentPath.StartsWith("/uploads/", StringComparison.Ordinal)
            ? Path.Combine(env.WebRootPath, "uploads", "pharmacy", "grn", file)
            : Path.Combine(env.ContentRootPath, "App_Data", "pharmacy", "grn", file);   // saved before the move to wwwroot/uploads
        if (!System.IO.File.Exists(path)) return NotFound();
        return PhysicalFile(path, BillTypes.GetValueOrDefault(Path.GetExtension(path).ToLowerInvariant(), "application/octet-stream"), enableRangeProcessing: true);
    }
}
