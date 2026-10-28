using System.Text.Json;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase pages (SQLScripts/2344): shared list, item / supplier look-ups and document posting helpers.
/// Every action is mapped to a page control (VIEW, SAVE, APPROVE, POST ...) in PageEndpointMap; the views hide what the user may not do.</summary>
[Authorize]
public abstract class PharmacyPurchaseControllerBase(IPharmacyPurchaseService purchase, IAuditLogService audit) : Controller
{
    protected static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    protected IPharmacyPurchaseService Purchase => purchase;
    protected int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    protected int CompanyId => User.GetCompanyId();
    protected int UserId => User.GetUserId();

    protected abstract string Kind { get; }
    protected abstract string PageCode { get; }
    protected abstract string Title { get; }
    protected abstract string Icon { get; }
    protected abstract string Description { get; }

    [HttpGet]
    public async Task<IActionResult> Index(string? status, string? search, DateTime? from, DateTime? to)
    {
        from ??= DateTime.Today.AddDays(-30); to ??= DateTime.Today;
        ViewBag.Kind = Kind; ViewBag.PageCode = PageCode; ViewBag.Title = Title; ViewBag.Icon = Icon; ViewBag.Description = Description;
        ViewBag.Filter = (status, search, from, to);
        ViewBag.Counts = await purchase.StatusCountsAsync(Kind, CompanyId, BranchId);
        return View("~/Views/PharmacyPurchase/List.cshtml", await purchase.ListAsync(Kind, CompanyId, BranchId, status, search, from, to));
    }

    [HttpGet]
    public async Task<IActionResult> Print(int id)
    {
        var d = await purchase.GetAsync(Kind, CompanyId, BranchId, id);
        if (d == null) return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        ViewBag.Kind = Kind; ViewBag.Title = Title;
        return View("~/Views/PharmacyPurchase/Print.cshtml", d);
    }

    [HttpGet]
    public async Task<IActionResult> ItemSearch(string? q) =>
        Json(string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2 ? [] : await purchase.ItemSearchAsync(CompanyId, BranchId, q.Trim()));

    [HttpGet]
    public async Task<IActionResult> SupplierInfo(int id) => Json(await purchase.SupplierInfoAsync(CompanyId, BranchId, id));

    protected async Task<IActionResult> FormView(PhDoc doc, List<string>? warnings = null)
    {
        var page = new PhDocPage
        {
            Kind = Kind, PageCode = PageCode, Title = Title, Icon = Icon, Description = Description, Doc = doc,
            Suppliers = Kind == "indent" ? [] : await purchase.SuppliersAsync(CompanyId),
            // a draft GRN always shows what needs checking (and the tick box to accept it) when it is opened
            Warnings = warnings ?? (Kind == "grn" && doc.Id > 0 && doc.Status == "DRAFT" ? await purchase.GrnWarningsAsync(CompanyId, BranchId, doc.Id) : []),
            MinShelfLifeDays = Kind == "grn" || doc.IsDirect ? await purchase.MinShelfLifeGrnDaysAsync(BranchId) : 0
        };
        if (doc.SupplierId is int sid and > 0)
        {
            page.Supplier = await purchase.SupplierInfoAsync(CompanyId, BranchId, sid);
            if (Kind == "grn") page.OpenPos = await purchase.OpenPosAsync(CompanyId, BranchId, sid);
        }
        if (Kind == "return") page.Reasons = await purchase.ReasonsAsync(CompanyId, "PURCHASE_RETURN");
        return View("~/Views/PharmacyPurchase/Form.cshtml", page);
    }

    protected PhDoc? ReadDoc(string? json)
    {
        try { return string.IsNullOrWhiteSpace(json) ? null : JsonSerializer.Deserialize<PhDoc>(json, Json); }
        catch (JsonException) { return null; }
    }

    protected async Task<IActionResult> AfterSave(PhDoc doc, int id, string? error, string what, List<string>? warnings = null)
    {
        if (error != null)
        {
            TempData["Error"] = error;
            return await FormView(doc, warnings);
        }
        await audit.LogAsync("Pharmacy" + Kind, "Save", $"{Title} draft #{id} saved", UserId, BranchId);
        TempData["Success"] = $"{what} saved as draft.";
        if (warnings is { Count: > 0 }) TempData["Warning"] = string.Join(" ", warnings);
        return RedirectToAction("Form", new { id });
    }

    protected async Task<IActionResult> Done(int id, string? error, string action, string okMessage)
    {
        if (error != null) TempData["Error"] = error;
        else
        {
            TempData["Success"] = okMessage;
            await audit.LogAsync("Pharmacy" + Kind, action, $"{Title} #{id}: {okMessage}", UserId, BranchId);
        }
        return RedirectToAction("Form", new { id });
    }
}
