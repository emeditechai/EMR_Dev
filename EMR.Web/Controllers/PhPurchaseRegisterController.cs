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
    public async Task<IActionResult> Index(DateTime? from, DateTime? to, int? supplierId)
    {
        var branchId = User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
        var f = from ?? new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1);
        var t = to ?? DateTime.Today;
        var (rows, gst) = await purchase.RegisterAsync(User.GetCompanyId(), branchId, f, t, supplierId);
        ViewBag.Filter = (f, t, supplierId);
        ViewBag.Suppliers = await purchase.SuppliersAsync(User.GetCompanyId());
        ViewBag.Gst = gst;
        return View("~/Views/PharmacyPurchase/Register.cshtml", rows);
    }
}
