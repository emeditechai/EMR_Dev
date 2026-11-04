using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>Pharmacy > Purchase > Purchase Register (PHARMACY.PURCHASEREGISTER, SQLScripts/2345): posted GRNs and debit notes with the GST split.</summary>
[Authorize]
public class PhPurchaseRegisterController(IPharmacyPurchaseService purchase) : Controller
{
    [HttpGet]
    public async Task<IActionResult> Index(DateTime? from, DateTime? to, int? supplierId, string? docType, string? search)
    {
        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
        var f = from ?? new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1);
        var t = to ?? DateTime.Today;
        if (t < f) (f, t) = (t, f);
        docType = docType is "PURCHASE" or "RETURN" ? docType : "ALL";
        var (rows, gst, suppliers) = await purchase.RegisterAsync(User.GetCompanyId(), branchId, f, t, supplierId, docType, search);
        ViewBag.Filter = (f, t, supplierId);
        ViewBag.DocType = docType;
        ViewBag.Search = search;
        ViewBag.SupplierSummary = suppliers;
        ViewBag.BranchName = User.FindFirst("BranchName")?.Value;
        ViewBag.Suppliers = await purchase.SuppliersAsync(User.GetCompanyId());
        ViewBag.Gst = gst;
        return View("~/Views/PharmacyPurchase/Register.cshtml", rows);
    }
}
