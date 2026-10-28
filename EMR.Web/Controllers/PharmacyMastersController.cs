using EMR.Shared.Security;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Master > Pharmacy Master (SQLScripts/2343): the simple pharmacy masters, one list + dialog page each
/// (described in PharmacyMasterDefs). The Item Master is PharmacyItemsController.</summary>
[Authorize]
public class PharmacyMastersController(
    IPharmacyMasterService masters,
    IAuditLogService auditLogService,
    IActionPermissionGuard permissionGuard) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();

    [HttpGet] public Task<IActionResult> Generics() => List("generics");
    [HttpGet] public Task<IActionResult> Manufacturers() => List("manufacturers");
    [HttpGet] public Task<IActionResult> Suppliers() => List("suppliers");
    [HttpGet] public Task<IActionResult> Categories() => List("categories");
    [HttpGet] public Task<IActionResult> DosageForms() => List("dosageforms");
    [HttpGet] public Task<IActionResult> Units() => List("units");
    [HttpGet] public Task<IActionResult> Hsn() => List("hsn");
    [HttpGet] public Task<IActionResult> Schedules() => List("schedules");
    [HttpGet] public Task<IActionResult> PriceRules() => List("pricerules");
    [HttpGet] public Task<IActionResult> Discounts() => List("discounts");
    [HttpGet] public Task<IActionResult> Customers() => List("customers");
    [HttpGet] public Task<IActionResult> Reasons() => List("reasons");
    [HttpGet] public Task<IActionResult> NumberSeries() => List("numberseries");

    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveGeneric() => Save("generics", nameof(Generics));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveManufacturer() => Save("manufacturers", nameof(Manufacturers));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveSupplier() => Save("suppliers", nameof(Suppliers));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveCategory() => Save("categories", nameof(Categories));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveDosageForm() => Save("dosageforms", nameof(DosageForms));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveUnit() => Save("units", nameof(Units));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveHsn() => Save("hsn", nameof(Hsn));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SavePriceRule() => Save("pricerules", nameof(PriceRules));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveDiscount() => Save("discounts", nameof(Discounts));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveCustomer() => Save("customers", nameof(Customers));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveReason() => Save("reasons", nameof(Reasons));
    [HttpPost, ValidateAntiForgeryToken] public Task<IActionResult> SaveNumberSeries() => Save("numberseries", nameof(NumberSeries));

    private async Task<IActionResult> List(string key)
    {
        var def = PharmacyMasterDefs.Get(key);
        await masters.EnsureMastersAsync(CompanyId, BranchId);
        ViewBag.Def = def;
        ViewBag.Rows = await masters.ListAsync(def, CompanyId, BranchId);
        ViewBag.Lookups = await masters.LookupsAsync(def, CompanyId);
        ViewBag.CanEdit = !def.ReadOnly && await permissionGuard.AllowsAsync(HttpContext, def.PageCode, "EDIT");
        ViewBag.BranchCode = await masters.BranchCodeAsync(BranchId);
        return View("Master");
    }

    private async Task<IActionResult> Save(string key, string back)
    {
        var def = PharmacyMasterDefs.Get(key);
        var error = await masters.SaveAsync(def, CompanyId, BranchId, Request.Form, User.GetUserId());
        if (error != null)
        {
            TempData["Error"] = error;
            TempData["PhRetry"] = System.Text.Json.JsonSerializer.Serialize(Request.Form.ToDictionary(k => k.Key, v => v.Value.FirstOrDefault(x => x != "false") ?? v.Value.FirstOrDefault()));
        }
        else
        {
            TempData["Success"] = $"{def.Title} saved.";
            await auditLogService.LogAsync("PharmacyMasters", "Save" + def.Title, $"{def.Title} saved: {Request.Form[def.Fields.First(f => f.Kind != "readonly").Name]}", User.GetUserId(), BranchId);
        }
        return RedirectToAction(back);
    }
}
