using Dapper;
using EMR.Shared.Security;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Pharmacy > Sales (SQLScripts/2348).
/// PHARMACY.POS:       VIEW (screen and look-ups), SAVE (bill), HOLD (hold / discard), DISCOUNT (above the branch limit), CREDIT (credit sale).
/// PHARMACY.SALEBILLS: VIEW (list, bill), PRINT (print / PDF), SEND (WhatsApp / e-mail), CANCEL (same day, before day closing).
/// </summary>
[Authorize]
public class PhSalesController(IPharmacySaleService sales, IPharmacyPurchaseService purchase, IPharmacyBillNotifier notifier,
    IDbConnectionFactory db, IActionPermissionGuard guard, IAuditLogService audit, IServiceScopeFactory scopes, ILogger<PhSalesController> logger) : Controller
{
    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;
    private int CompanyId => User.GetCompanyId();
    private int UserId => User.GetUserId();

    // ── POS ─────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Pos(int? recall)
    {
        var set = await sales.SettingsAsync(BranchId);
        ViewBag.Settings = set;
        ViewBag.Methods = await sales.PaymentMethodsAsync();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        ViewBag.CanDiscount = await guard.AllowsAsync(HttpContext, "PHARMACY.POS", "DISCOUNT");
        ViewBag.CanCredit = await guard.AllowsAsync(HttpContext, "PHARMACY.POS", "CREDIT");
        ViewBag.Recall = recall;
        return View("~/Views/PharmacySales/Pos.cshtml");
    }

    [HttpGet] public async Task<IActionResult> ItemSearch(string? q, int? genericId) =>
        Json((string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) && genericId == null ? [] : await sales.ItemSearchAsync(CompanyId, BranchId, q ?? "", genericId));

    [HttpGet] public async Task<IActionResult> Batches(int itemId) => Json(await sales.BatchesAsync(CompanyId, BranchId, itemId));

    [HttpGet] public async Task<IActionResult> PriceFor(int itemId, int batchId, string? priceType) => Json(await sales.UnitPriceAsync(CompanyId, itemId, batchId, priceType == "STAFF" ? "STAFF" : "WALKIN"));

    [HttpGet]
    public async Task<IActionResult> Customers(string? q)
    {
        using var con = db.CreateConnection();
        return Json(await con.QueryAsync(@"SELECT TOP 15 c.CustomerId id, c.CustomerName name, c.Mobile mobile, c.Email email, c.Address address, c.CustomerType type, c.CreditAllowed credit, c.CreditLimit creditLimit,
                ISNULL((SELECT SUM(s.BalanceDue) FROM dbo.PhSale s WHERE s.CustomerId = c.CustomerId AND s.Status = 'POSTED'), 0) outstanding
            FROM dbo.PhCustomer c WHERE c.CompanyId = @co AND c.IsActive = 1 AND (c.CustomerName LIKE @like OR c.Mobile LIKE @like) ORDER BY c.CustomerName",
            new { co = CompanyId, like = "%" + (q ?? "").Trim() + "%" }));
    }

    [HttpGet]
    public async Task<IActionResult> Patients(string? q)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Json(Array.Empty<object>());
        using var con = db.CreateConnection();
        return Json(await con.QueryAsync(@"SELECT TOP 15 pm.PatientId id, pm.PatientCode uhid, LTRIM(RTRIM(ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) name, pm.PhoneNumber mobile,
                pm.EmailId email, pm.Address address, pm.Gender gender,
                (SELECT TOP 1 ISNULL(d.NamePrefix + ' ', '') + d.FullName FROM dbo.PatientOPDService v JOIN dbo.DoctorMaster d ON d.DoctorId = v.DoctorId WHERE v.PatientId = pm.PatientId ORDER BY v.OPDServiceId DESC) lastDoctor,
                (SELECT TOP 1 v.DoctorId FROM dbo.PatientOPDService v WHERE v.PatientId = pm.PatientId ORDER BY v.OPDServiceId DESC) lastDoctorId
            FROM dbo.PatientMaster pm WHERE pm.CompanyId = @co AND pm.IsActive = 1
              AND (pm.PatientCode LIKE @like OR pm.PhoneNumber LIKE @like OR pm.FirstName LIKE @like OR pm.LastName LIKE @like OR (pm.FirstName + ' ' + pm.LastName) LIKE @like)
            ORDER BY CASE WHEN pm.PatientCode = @q OR pm.PhoneNumber = @q THEN 0 ELSE 1 END, pm.FirstName", new { co = CompanyId, q = q.Trim(), like = "%" + q.Trim() + "%" }));
    }

    [HttpGet]
    public async Task<IActionResult> Doctors(string? q)
    {
        using var con = db.CreateConnection();
        return Json(await con.QueryAsync(@"SELECT TOP 15 DoctorId id, ISNULL(NamePrefix + ' ', '') + FullName name, MedicalLicenseNo regNo FROM dbo.DoctorMaster
            WHERE CompanyId = @co AND IsActive = 1 AND FullName LIKE @like ORDER BY FullName", new { co = CompanyId, like = "%" + (q ?? "").Trim() + "%" }));
    }

    [HttpGet] public async Task<IActionResult> Held() => Json(await sales.ListAsync(CompanyId, BranchId, "HOLD", null, null, null));

    [HttpGet]
    public async Task<IActionResult> Recall(int id)
    {
        var b = await sales.GetAsync(CompanyId, BranchId, id);
        if (b is not { Status: "HOLD" }) return NotFound();
        var items = new List<PhPosItem>();
        foreach (var itemId in b.Lines.Select(l => l.ItemId).Distinct()) items.AddRange(await sales.ItemSearchAsync(CompanyId, BranchId, "", null, itemId));
        return Json(new { bill = b, items });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] PhSaleRequest r)
    {
        var res = await sales.SaveAsync(CompanyId, BranchId, r, UserId,
            await guard.AllowsAsync(HttpContext, "PHARMACY.POS", "DISCOUNT"), await guard.AllowsAsync(HttpContext, "PHARMACY.POS", "CREDIT"));
        if (res.Success)
        {
            await audit.LogAsync("Pharmacy", "Sale", $"Pharmacy bill {res.SaleNo} ₹{res.NetAmount:N2} ({r.CustomerKind} {r.CustomerName})", UserId, BranchId);
            if ((await sales.SettingsAsync(BranchId)).BillNotificationRequired) SendInBackground(res.SaleId);
        }
        return Json(res);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Hold([FromBody] PhSaleRequest r) => Json(await sales.HoldAsync(CompanyId, BranchId, r, UserId));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> DiscardHold(int id) => Json(new { error = await sales.DiscardHoldAsync(CompanyId, BranchId, id) });

    private void SendInBackground(int saleId)
    {
        var (co, br) = (CompanyId, BranchId);
        _ = Task.Run(async () =>
        {
            try { using var scope = scopes.CreateScope(); await scope.ServiceProvider.GetRequiredService<IPharmacyBillNotifier>().SendAsync(co, br, saleId); }
            catch (Exception ex) { logger.LogError(ex, "[PH-BILL] background send failed for sale {Id}", saleId); }
        });
    }

    // ── Sale Bills ──────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Index(string status = "POSTED", string? search = null, DateTime? from = null, DateTime? to = null)
    {
        from ??= DateTime.Today; to ??= DateTime.Today;
        ViewBag.Filter = (status, search, from, to);
        return View("~/Views/PharmacySales/Index.cshtml", await sales.ListAsync(CompanyId, BranchId, status, search, from, to));
    }

    [HttpGet]
    public async Task<IActionResult> Bill(int id)
    {
        var b = await sales.GetAsync(CompanyId, BranchId, id);
        return b == null ? NotFound() : View("~/Views/PharmacySales/Bill.cshtml", b);
    }

    [HttpGet]
    public async Task<IActionResult> Print(int id, string? format)
    {
        var b = await sales.GetAsync(CompanyId, BranchId, id);
        if (b == null || b.Status == "HOLD") return NotFound();
        ViewBag.Header = await purchase.BranchHeaderAsync(BranchId);
        ViewBag.Format = format is "A4" or "A5" or "80MM" ? format : (await sales.SettingsAsync(BranchId)).BillPrintFormat;
        return View("~/Views/PharmacySales/Print.cshtml", b);
    }

    [HttpGet]
    public async Task<IActionResult> Pdf(int id)
    {
        var b = await sales.GetAsync(CompanyId, BranchId, id);
        if (b == null || b.Status == "HOLD") return NotFound();
        return File(notifier.Pdf(b, await purchase.BranchHeaderAsync(BranchId)), "application/pdf", $"Bill_{b.SaleNo?.Replace('/', '-')}.pdf");
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Send(int id)
    {
        var res = await notifier.SendAsync(CompanyId, BranchId, id);
        TempData["Success"] = string.Join(" ", res);
        return RedirectToAction(nameof(Bill), new { id });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int id, string? reason)
    {
        var err = await sales.CancelAsync(CompanyId, BranchId, id, reason?.Trim() ?? "", UserId);
        if (err != null) TempData["Error"] = err;
        else
        {
            TempData["Success"] = "Bill cancelled: stock put back and the money taken is shown as a refund in your day closing.";
            await audit.LogAsync("Pharmacy", "SaleCancel", $"Pharmacy bill #{id} cancelled: {reason}", UserId, BranchId);
        }
        return RedirectToAction(nameof(Bill), new { id });
    }
}
