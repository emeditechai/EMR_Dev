using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Master > Pharmacy Master > Item / Drug Master (SQLScripts/2343). Company-wise items; rack and stock levels per branch.</summary>
[Authorize]
public class PharmacyItemsController(
    IPharmacyMasterService masters,
    IAuditLogService auditLogService,
    IActionPermissionGuard permissionGuard) : Controller
{
    private const string PageCode = "MASTER.PH_ITEMS";
    private const int PageSize = 50;
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    [HttpGet]
    public async Task<IActionResult> Index(string? search, int? categoryId, string? schedule, int? manufacturerId, bool? active = true, int page = 1)
    {
        await masters.EnsureMastersAsync(CompanyId, BranchId);
        var rows = await masters.ItemsAsync(CompanyId, BranchId, search, categoryId, schedule, manufacturerId, active, page, PageSize);
        ViewBag.Lookups = await masters.ItemLookupsAsync(CompanyId);
        ViewBag.Filter = new PhItemFilter(search, categoryId, schedule, manufacturerId, active, Math.Max(page, 1));
        ViewBag.Total = rows.FirstOrDefault()?.TotalCount ?? 0;
        ViewBag.Counts = await masters.ItemCountsAsync(CompanyId);
        ViewBag.PageSize = PageSize;
        ViewBag.CanEdit = await permissionGuard.AllowsAsync(HttpContext, PageCode, "EDIT");
        return View(rows);
    }

    [HttpGet]
    public async Task<IActionResult> Form(int id = 0, int? copyOf = null)
    {
        await masters.EnsureMastersAsync(CompanyId, BranchId);
        var source = id > 0 ? id : copyOf ?? 0;
        var model = source > 0 ? await masters.ItemAsync(CompanyId, BranchId, source) : new PhItemForm();
        if (model == null) { TempData["Error"] = "Item not found."; return RedirectToAction(nameof(Index)); }
        if (id == 0 && copyOf != null) { model.ItemId = 0; model.ItemCode = null; model.Barcode = null; model.ItemName += " (copy)"; }
        if (model.ItemId == 0 && source == 0) await DefaultsAsync(model);
        return await FormView(model);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(PhItemForm model, string? next)
    {
        var isNew = model.ItemId == 0;
        var (id, error) = await masters.SaveItemAsync(CompanyId, BranchId, model, User.GetUserId());
        if (error != null)
        {
            TempData["Error"] = error;
            return await FormView(model);
        }
        await auditLogService.LogAsync("PharmacyItems", isNew ? "Create" : "Edit", $"Pharmacy item {model.ItemCode} '{model.ItemName}' saved", User.GetUserId(), BranchId);
        TempData["Success"] = $"Item '{model.ItemName}' ({model.ItemCode}) saved.";
        return next switch
        {
            "new" => RedirectToAction(nameof(Form)),
            "copy" => RedirectToAction(nameof(Form), new { copyOf = id }),
            "stay" => RedirectToAction(nameof(Form), new { id }),
            _ => RedirectToAction(nameof(Index))
        };
    }

    /// <summary>Item look-up for later pages (sale, GRN, indent): name, generic, code or barcode.</summary>
    [HttpGet]
    public async Task<IActionResult> Search(string? q)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Json(Array.Empty<object>());
        return Json(await masters.SearchItemsAsync(CompanyId, q.Trim()));
    }

    private async Task DefaultsAsync(PhItemForm m)
    {
        var lk = await masters.ItemLookupsAsync(CompanyId);
        int Pick(List<PhOption> list, string startsWith) => int.TryParse(list.FirstOrDefault(o => o.Text.StartsWith(startsWith, StringComparison.OrdinalIgnoreCase))?.Value, out var v) ? v : 0;
        m.HsnId = lk.Hsn.FirstOrDefault(h => h.Code == "3004").Id;
        m.PurchaseUomId = Pick(lk.Uoms, "Strip");
        m.SaleUomId = Pick(lk.Uoms, "Tablet");
        m.DosageFormId = Pick(lk.DosageForms, "Tablet") is var d and > 0 ? d : null;
        m.ConversionQty = 10;
    }

    private async Task<IActionResult> FormView(PhItemForm model)
    {
        ViewBag.Lookups = await masters.ItemLookupsAsync(CompanyId);
        ViewBag.Substitutes = model.ItemId > 0 ? await masters.SubstitutesAsync(CompanyId, model.ItemId) : new List<PhItemListRow>();
        ViewBag.CanEdit = await permissionGuard.AllowsAsync(HttpContext, PageCode, "EDIT");
        return View("Form", model);
    }
}
