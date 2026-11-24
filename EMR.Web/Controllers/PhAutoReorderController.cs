using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Purchase > Auto Reorder (PHARMACY.AUTOREORDER, SQLScripts/2403): sales-based order suggestions
/// (Hospital Settings > MED > Auto Reorder) and one draft purchase order per supplier from the ticked lines.
/// SQLScripts/2538: tab "Auto Indent Rules" - per item the supplier, reorder / Max level and quantity; indents are raised by
/// PharmacyAutoIndentWorker right after stock goes out (Hospital Settings > MED > Auto Indent), or here with "Run now".
/// </summary>
[Authorize]
public class PhAutoReorderController(IPharmacyPurchaseService purchase, IPharmacyMasterService masters, IAuditLogService audit,
    IPharmacyAutoIndentNotifier autoIndentNotifier) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();
    private int UserId => User.GetUserId();

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        ViewBag.Suppliers = await purchase.SuppliersAsync(CompanyId);
        ViewBag.Categories = (await masters.ItemLookupsAsync(CompanyId)).Categories;
        return View("~/Views/PharmacyPurchase/AutoReorder.cshtml");
    }

    [HttpGet]
    public async Task<IActionResult> Data(int? supplierId, int? categoryId, bool showAll = false)
    {
        var (settings, rows) = await purchase.AutoReorderAsync(CompanyId, BranchId, supplierId, categoryId, showAll);
        return Json(new { settings, rows });
    }

    [HttpGet]
    public async Task<IActionResult> SchemeFree(int supplierId, int itemId, decimal qty) =>
        Json(supplierId > 0 && itemId > 0 && qty > 0 ? await purchase.SchemeFreeAsync(CompanyId, BranchId, supplierId, itemId, qty) : new PhSchemeFree());

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> CreatePos([FromForm] string? json)
    {
        List<PhReorderLine>? lines;
        try { lines = System.Text.Json.JsonSerializer.Deserialize<List<PhReorderLine>>(json ?? "[]", new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
        catch (System.Text.Json.JsonException) { return Json(new { success = false, message = "The list could not be read." }); }
        var (created, error) = await purchase.AutoReorderCreatePosAsync(CompanyId, BranchId, lines ?? [], UserId);
        if (error != null) return Json(new { success = false, message = error });
        await audit.LogAsync("PHARMACY", "PHARMACY.AutoReorderPosCreated",
            $"Auto reorder: {created.Count} draft purchase order(s) - " + string.Join(", ", created.Select(c => $"#{c.PoId} {c.SupplierName} ({c.Lines} items, {c.NetAmount:N2})")), UserId);
        // the page opens each PO by an encrypted link (QUERY_STRING_ENCRYPTION_ARCHITECTURE.md)
        return Json(new { success = true, created = created.Select(c => new { c.PoId, c.SupplierName, c.Lines, c.NetAmount, url = Url.ActionEncrypted("Form", "PhPurchaseOrders", new { id = c.PoId }) }) });
    }

    // ── auto indent (SQLScripts/2538) ──────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> RulesData(int? supplierId, int? categoryId, string? filter, string? search)
    {
        var (settings, rows) = await purchase.AutoIndentListAsync(CompanyId, BranchId, supplierId, categoryId, filter ?? "RULES", search);
        return Json(new { settings, rows });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveRules([FromForm] string? json)
    {
        List<PhAutoIndentRuleInput>? rules;
        try { rules = System.Text.Json.JsonSerializer.Deserialize<List<PhAutoIndentRuleInput>>(json ?? "[]", new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
        catch (System.Text.Json.JsonException) { return Json(new { success = false, message = "The rules could not be read." }); }
        var errors = await purchase.AutoIndentSaveRulesAsync(CompanyId, BranchId, rules ?? [], UserId);
        if (errors.Count > 0) return Json(new { success = false, message = string.Join("\n", errors.Take(10)) + (errors.Count > 10 ? $"\n... and {errors.Count - 10} more." : "") });
        var saved = rules!.Count(r => !r.Remove);
        var removed = rules!.Count(r => r.Remove);
        await audit.LogAsync("PHARMACY", "PHARMACY.AutoIndentRulesSaved", $"Auto indent rules: {saved} saved, {removed} removed (branch {BranchId}).", UserId);
        return Json(new { success = true, message = $"{saved} rule(s) saved" + (removed > 0 ? $", {removed} removed" : "") + "." });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> RunNow()
    {
        var res = await purchase.AutoIndentRunAsync(CompanyId, BranchId, UserId, manual: true);
        if (!res.IsError && res.LinesRaised > 0)
        {
            await autoIndentNotifier.NotifyAsync(CompanyId, BranchId, res, UserId);
            await audit.LogAsync("PHARMACY", "PHARMACY.AutoIndentRun", "Auto indent run now: " + res.Message, UserId);
        }
        return Json(new
        {
            success = !res.IsError, message = res.Message,
            indents = res.Indents.Select(i => new { i.IndentNo, i.SupplierName, i.Lines, i.IsNew, url = Url.ActionEncrypted("Form", "PhPurchaseIndents", new { id = i.IndentId }) })
        });
    }

    [HttpGet]
    public async Task<IActionResult> RunLog() => Json(await purchase.AutoIndentLogAsync(CompanyId, BranchId));
}
