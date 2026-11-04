using EMR.Shared.Security;
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
    IActionPermissionGuard guard, IAuditLogService audit, IServiceScopeFactory scopes, ILogger<PhSalesController> logger) : Controller
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
        ViewBag.Stores = await purchase.StoresAsync(CompanyId, BranchId, "SELL");   // selling stores (counters), default first
        return View("~/Views/PharmacySales/Pos.cshtml");
    }

    [HttpGet] public async Task<IActionResult> ItemSearch(string? q, int? genericId, int? storeId) =>
        Json((string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) && genericId == null ? [] : await sales.ItemSearchAsync(CompanyId, BranchId, q ?? "", genericId, null, storeId));

    [HttpGet] public async Task<IActionResult> Batches(int itemId, int? storeId) => Json(await sales.BatchesAsync(CompanyId, BranchId, itemId, storeId));

    [HttpGet] public async Task<IActionResult> PriceFor(int itemId, int batchId, string? priceType) => Json(await sales.UnitPriceAsync(CompanyId, itemId, batchId, priceType == "STAFF" ? "STAFF" : "WALKIN"));

    [HttpGet] public async Task<IActionResult> Customers(string? q) => Json(await sales.CustomersAsync(CompanyId, q));

    [HttpGet]
    public async Task<IActionResult> Patients(string? q)
    {
        if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Json(Array.Empty<object>());
        return Json(await sales.PatientsAsync(CompanyId, q.Trim()));
    }

    [HttpGet] public async Task<IActionResult> Doctors(string? q) => Json(await sales.DoctorsAsync(CompanyId, q));

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

    // ── OPD prescription, clinical checks, loyalty (SQLScripts/2406) ─────────────────────────────────────
    /// <summary>SQLScripts/2412: name / address of a returning walk-in, and patients registered with this mobile.</summary>
    [HttpGet]
    public async Task<IActionResult> WalkinByMobile(string? mobile)
    {
        if (mobile is not { Length: 10 } || !mobile.All(char.IsDigit)) return Json(new { last = (object?)null, patients = Array.Empty<object>() });
        var (last, patients) = await sales.WalkinByMobileAsync(CompanyId, mobile);
        return Json(new { last, patients });
    }

    [HttpGet] public async Task<IActionResult> RxList(int patientId) => Json(patientId > 0 ? await sales.RxListAsync(CompanyId, BranchId, patientId) : []);

    [HttpGet]
    public async Task<IActionResult> RxLines(int consultationId, int? storeId)
    {
        var (head, lines) = await sales.RxLinesAsync(CompanyId, BranchId, consultationId, storeId);
        return head is null ? NotFound() : Json(new { head, lines });
    }

    public sealed record ClinicalCheckBody(int? PatientId, int? CustomerId, List<int>? ItemIds);

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ClinicalCheck([FromBody] ClinicalCheckBody b) =>
        Json(await sales.ClinicalCheckAsync(CompanyId, BranchId, b.PatientId, b.CustomerId, b.ItemIds ?? []));

    [HttpGet]
    public async Task<IActionResult> Loyalty(int? patientId, int? customerId, string? mobile) =>
        Json(await sales.LoyaltyAsync(CompanyId, BranchId, patientId, customerId, mobile is { Length: 10 } m && m.All(char.IsDigit) ? m : null));

    public sealed record LoyaltyOtpBody(int? PatientId, int? CustomerId, string? Mobile);

    /// <summary>SQLScripts/2409: a 6-digit code to the member's registered WhatsApp number before wallet points are used.</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> LoyaltyOtp([FromBody] LoyaltyOtpBody b)
    {
        var w = await sales.LoyaltyAsync(CompanyId, BranchId, b.PatientId, b.CustomerId, b.PatientId is null && b.CustomerId is null ? b.Mobile : null);
        if (w is not { } wallet || !wallet.TryGetProperty("IsMember", out var im) || !im.GetBoolean()) return Json(new { success = false, message = "Pick the loyalty member first." });
        var phone = wallet.TryGetProperty("Phone", out var ph) ? ph.GetString() : null;
        if (string.IsNullOrWhiteSpace(phone)) return Json(new { success = false, message = "The member has no mobile number to send the OTP to." });
        var key = b.PatientId is int p ? $"P{p}" : b.CustomerId is int c ? $"C{c}" : $"M{b.Mobile}";
        var code = System.Security.Cryptography.RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
        var err = await sales.LoyaltyOtpAsync(CompanyId, key, code);
        if (err != null) return Json(new { success = false, message = err });
        var head = await purchase.BranchHeaderAsync(BranchId);
        var res = await HttpContext.RequestServices.GetRequiredService<IWhatsAppService>().SendTextMessageAsync(phone!,
            $"Your OTP to use loyalty points at {head.Name} is *{code}*. It is valid for 10 minutes. Do not share it with anyone else.", BranchId, "PHR");
        var masked = phone!.Length > 4 ? new string('x', phone.Length - 4) + phone[^4..] : phone;
        return Json(res.Success ? new { success = true, message = $"OTP sent to WhatsApp {masked}." } : new { success = false, message = res.ErrorMessage ?? "WhatsApp did not accept the message." });
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Save([FromBody] PhSaleRequest r)
    {
        var res = await sales.SaveAsync(CompanyId, BranchId, r, UserId,
            await guard.AllowsAsync(HttpContext, "PHARMACY.POS", "DISCOUNT"), await guard.AllowsAsync(HttpContext, "PHARMACY.POS", "CREDIT"));
        if (res.Success)
        {
            await audit.LogAsync("Pharmacy", "Sale", $"Pharmacy bill {res.SaleNo} ₹{res.NetAmount:N2} ({r.CustomerKind} {r.CustomerName})", UserId, BranchId);
            var set = await sales.SettingsAsync(BranchId);
            if (set.BillNotificationRequired) SendInBackground(res.SaleId);
            // SQLScripts/2408: the member hears about the loyalty benefit of this bill on WhatsApp
            var walkinMember = r.CustomerKind == "WALKIN" && set.LoyaltyWalkinByMobile && r.Mobile is { Length: 10 };
            if (set.LoyaltyEnabled && set.LoyaltyNotifyWhatsApp && (r.CustomerKind is "PATIENT" or "CUSTOMER" || walkinMember)
                && (res.PointsEarned > 0 || res.PointsRedeemed > 0 || res.LoyaltyDiscount > 0))
                LoyaltyMessageInBackground(res.SaleId, set.LoyaltyType, res.PointsEarned, res.PointsRedeemed, res.LoyaltyDiscount, set.LoyaltyLockInDays);
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

    /// <summary>WhatsApp to the patient / customer: points earned and used with the balance, or the member discount saved.</summary>
    private void LoyaltyMessageInBackground(int saleId, string loyaltyType, decimal earned, decimal redeemed, decimal discount, int lockInDays)
    {
        var (co, br) = (CompanyId, BranchId);
        _ = Task.Run(async () =>
        {
            try
            {
                using var scope = scopes.CreateScope();
                var svc = scope.ServiceProvider.GetRequiredService<IPharmacySaleService>();
                var bill = await svc.GetAsync(co, br, saleId);
                if (bill == null || string.IsNullOrWhiteSpace(bill.Mobile)) return;
                var head = await scope.ServiceProvider.GetRequiredService<IPharmacyPurchaseService>().BranchHeaderAsync(br);
                var name = string.IsNullOrWhiteSpace(bill.CustomerName) ? "" : " " + bill.CustomerName.Trim();
                var sb = new System.Text.StringBuilder($"Hello{name},\n\nThank you for your purchase (bill {bill.SaleNo}, ₹{bill.NetAmount:N2}).\n");
                if (loyaltyType == "DISCOUNT")
                    sb.Append($"⭐ As a loyalty member you saved *₹{discount:N2}* on this bill.\n");
                else
                {
                    var bal = await svc.LoyaltyAsync(co, br, bill.PatientId, bill.CustomerId, bill.PatientId is null && bill.CustomerId is null ? bill.Mobile : null);
                    var points = bal is { } b && b.TryGetProperty("Points", out var p) ? p.GetDecimal() : 0m;
                    var value = bal is { } b2 && b2.TryGetProperty("PointValue", out var v) ? v.GetDecimal() : 1m;
                    if (redeemed > 0) sb.Append($"Points used: *{redeemed:0}*\n");
                    var pending = bal is { } b3 && b3.TryGetProperty("Pending", out var pp) ? pp.GetDecimal() : 0m;
                    if (earned > 0) sb.Append($"⭐ *{earned:0} points* (₹{earned * value:N2}) credited to your wallet" + (lockInDays > 0 ? $" - usable from {DateTime.Today.AddDays(lockInDays):dd-MMM-yyyy}" : "") + ".\n");
                    sb.Append($"Wallet balance: *{points:0} points* (₹{points * value:N2}) to use on your next bill" + (pending > 0 ? $"; {pending:0} more on the way" : "") + ".\n");
                }
                sb.Append($"\n- {head.Name}");
                var res = await scope.ServiceProvider.GetRequiredService<IWhatsAppService>().SendTextMessageAsync(bill.Mobile!, sb.ToString(), br, "PHR", saleId);
                if (!res.Success) logger.LogWarning("[PH-LOYALTY] WhatsApp not sent for sale {Id}: {Err}", saleId, res.ErrorMessage);
            }
            catch (Exception ex) { logger.LogError(ex, "[PH-LOYALTY] WhatsApp failed for sale {Id}", saleId); }
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
