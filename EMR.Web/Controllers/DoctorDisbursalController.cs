using EMR.Web.ApiClients;
using EMR.Web.Data;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace EMR.Web.Controllers;

/// <summary>
/// OPD > Doctor Commission & Disbursals: the doctor payout workbench (SQLScripts/2213).
/// The doctor's share is earned on collection and kept up to date automatically; each day, each doctor's unsettled
/// share goes on one settlement (payout voucher), which is prepared, approved by a different user (maker-checker) and
/// paid. Every action is its own control of OPD.DOCTORDISBURSAL (Settings > Security); rules live in the procedures.
/// </summary>
[Authorize]
public class DoctorDisbursalController(
    IDoctorCommissionApiClient apiClient,
    IDoctorPayoutApiClient payoutApi,
    EMR.Shared.Security.IActionPermissionGuard permissionGuard,
    IAuditLogService auditLogService,
    ApplicationDbContext dbContext) : Controller
{
    private const string Page = "OPD.DOCTORDISBURSAL";
    private static readonly string[] Controls = ["PREPARE", "ADJUSTMENT", "CANCEL", "APPROVE", "PAYOUT", "PROFILE", "DETAILS"];

    private int BranchId => User.GetCurrentBranchId() ?? HttpContext.Session.GetInt32("SelectedBranchId") ?? 1;

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        // which buttons to offer; every action is checked again on the server when used
        var perms = new Dictionary<string, bool>();
        foreach (var c in Controls) perms[c] = await permissionGuard.ShowsAsync(HttpContext, Page, c);
        ViewBag.Perms = perms;
        ViewBag.UserId = User.GetUserId();
        ViewBag.IsSuperAdmin = User.IsSuperAdmin();
        return View();
    }

    /// <summary>One share line (visit) of the old screen, read-only.</summary>
    [HttpGet]
    public async Task<IActionResult> Details(int id)
    {
        var item = await apiClient.GetDisbursalByIdAsync(id);
        if (item is null) return NotFound();
        return View(item);
    }

    // ── data for the page ─────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> BoardData(string? date) =>
        PassThrough(payoutApi.GetAsync("board", new Dictionary<string, string?>
        {
            ["companyId"] = User.GetCompanyId().ToString(), ["branchId"] = BranchId.ToString(),
            ["date"] = (DateTime.TryParse(date, out var d) ? d : DateTime.Today).ToString("yyyy-MM-dd"),
            ["userId"] = User.GetUserId().ToString(), ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
        }));

    [HttpGet]
    public Task<IActionResult> SettlementsData(string? fromDate, string? toDate, string? status, int? doctorId)
    {
        if (!DateTime.TryParse(fromDate, out var f)) f = DateTime.Today.AddDays(-30);
        if (!DateTime.TryParse(toDate, out var t)) t = DateTime.Today;
        if (t < f) (f, t) = (t, f);
        return PassThrough(payoutApi.GetAsync("settlements", new Dictionary<string, string?>
        {
            ["branchId"] = BranchId.ToString(), ["fromDate"] = f.ToString("yyyy-MM-dd"), ["toDate"] = t.ToString("yyyy-MM-dd"),
            ["status"] = status, ["doctorId"] = doctorId?.ToString(),
            ["userId"] = User.GetUserId().ToString(), ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
        }));
    }

    [HttpGet]
    public Task<IActionResult> SettlementData(int id) =>
        PassThrough(payoutApi.GetAsync($"settlements/{id}", SettlementQuery()));

    /// <summary>Who may approve settlements at this branch (Super Admins and users allowed Approve / reject settlement).</summary>
    [HttpGet]
    public Task<IActionResult> ApproversData() =>
        PassThrough(payoutApi.GetAsync("approvers", new Dictionary<string, string?>
        {
            ["companyId"] = User.GetCompanyId().ToString(), ["branchId"] = BranchId.ToString(),
            ["userId"] = User.GetUserId().ToString(), ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
        }));

    [HttpGet]
    public Task<IActionResult> ProfilesData() =>
        PassThrough(payoutApi.GetAsync("profiles", new Dictionary<string, string?>
        {
            ["companyId"] = User.GetCompanyId().ToString(), ["branchId"] = BranchId.ToString(),
            ["userId"] = User.GetUserId().ToString(), ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
        }));

    /// <summary>Printable payout voucher (A4).</summary>
    [HttpGet]
    public async Task<IActionResult> Voucher(int id)
    {
        var result = await payoutApi.GetAsync($"settlements/{id}", SettlementQuery());
        if (!result.IsSuccess) return Content(result.ErrorMessage ?? "Unable to load the voucher.");
        using var doc = System.Text.Json.JsonDocument.Parse(result.Data!);
        if (doc.RootElement.GetProperty("header").GetArrayLength() == 0) return NotFound();
        ViewBag.Json = result.Data;
        ViewBag.Settings = await dbContext.HospitalSettings.FirstOrDefaultAsync(s => s.BranchId == BranchId);
        return View();
    }

    private Dictionary<string, string?> SettlementQuery() => new()
    {
        ["branchId"] = BranchId.ToString(), ["userId"] = User.GetUserId().ToString(), ["isSuperAdmin"] = User.IsSuperAdmin() ? "true" : "false"
    };

    private static async Task<IActionResult> PassThrough(Task<ReportApiResult<string>> call)
    {
        var result = await call;
        if (!result.IsSuccess) return new JsonResult(new { success = false, message = result.ErrorMessage ?? "Unable to load." });
        return new ContentResult { Content = "{\"success\":true,\"data\":" + result.Data + "}", ContentType = "application/json" };
    }

    // ── actions ───────────────────────────────────────────────────────────────
    public sealed class ProfileInput
    {
        public int DoctorId { get; set; }
        public string? DoctorName { get; set; }
        public string? PayeeName { get; set; }
        public string? Pan { get; set; }
        public bool TdsApplicable { get; set; } = true;
        public decimal TdsPercent { get; set; } = 10;
        public string? PreferredMode { get; set; }
        public string? BankName { get; set; }
        public string? AccountNo { get; set; }
        public string? Ifsc { get; set; }
        public string? UpiId { get; set; }
        public string? Remarks { get; set; }
    }

    public sealed class PrepareInput
    {
        public int DoctorId { get; set; }
        public string? DoctorName { get; set; }
        public DateTime? UpTo { get; set; }
        public decimal OtherAdjustment { get; set; }
        public string? OtherAdjustmentReason { get; set; }
        public string? Remarks { get; set; }
    }

    public sealed class ActionInput
    {
        public int SettlementId { get; set; }
        public string? SettlementNo { get; set; }
        public string? Remarks { get; set; }
        public DateTime? PaymentDate { get; set; }
        public string? PaymentMode { get; set; }
        public string? PaymentReference { get; set; }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveProfile([FromBody] ProfileInput input)
    {
        if (input == null || input.DoctorId <= 0) return Json(new { success = false, message = "Choose the doctor." });
        var result = await payoutApi.PostAsync("profiles", new
        {
            CompanyId = User.GetCompanyId(), input.DoctorId, input.PayeeName, input.Pan, input.TdsApplicable, input.TdsPercent, input.PreferredMode,
            input.BankName, input.AccountNo, input.Ifsc, input.UpiId, input.Remarks, UserId = User.GetUserId()
        });
        if (!result.IsSuccess) return Json(new { success = false, message = result.ErrorMessage });
        await AuditAsync("DoctorPayout.ProfileSaved", $"Payout profile of {input.DoctorName} saved (PAN {(string.IsNullOrWhiteSpace(input.Pan) ? "not given" : input.Pan)}, TDS {(input.TdsApplicable ? input.TdsPercent + "%" : "not applicable")}).",
            null, input.DoctorId, new { input.DoctorId, input.Pan, input.TdsApplicable, input.TdsPercent, input.PreferredMode, input.BankName, input.Ifsc, input.UpiId });
        return Json(new { success = true, message = "Payout profile saved." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> PrepareSettlement([FromBody] PrepareInput input)
    {
        if (input == null || input.DoctorId <= 0) return Json(new { success = false, message = "Choose the doctor." });
        if (input.OtherAdjustment != 0 && !await permissionGuard.AllowsAsync(HttpContext, Page, "ADJUSTMENT"))
            return Json(new { success = false, code = "FORBIDDEN", message = "You do not have permission to add a deduction or incentive." });
        var upTo = (input.UpTo ?? DateTime.Today).Date;
        var result = await payoutApi.PostAsync("prepare", new
        {
            CompanyId = User.GetCompanyId(), BranchId, input.DoctorId, UpTo = upTo, input.OtherAdjustment, input.OtherAdjustmentReason, input.Remarks,
            UserId = User.GetUserId(), IsSuperAdmin = User.IsSuperAdmin()
        });
        if (!result.IsSuccess) return Json(new { success = false, message = result.ErrorMessage });
        var id = ReadId(result.Data);
        await AuditAsync("DoctorPayout.Prepared", $"Settlement prepared for {input.DoctorName}, shares up to {upTo:dd MMM yyyy}" +
            (input.OtherAdjustment != 0 ? $", deduction / incentive ₹{input.OtherAdjustment} ({input.OtherAdjustmentReason})" : "") + ".",
            null, id, new { input.DoctorId, UpTo = upTo, input.OtherAdjustment, input.OtherAdjustmentReason, input.Remarks });
        return Json(new { success = true, id, message = "Settlement prepared. It now needs approval by another user." });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> PrepareDay([FromBody] PrepareInput input)
    {
        var upTo = (input?.UpTo ?? DateTime.Today).Date;
        var result = await payoutApi.PostAsync("prepare-day", new
        {
            CompanyId = User.GetCompanyId(), BranchId, UpTo = upTo, UserId = User.GetUserId(), IsSuperAdmin = User.IsSuperAdmin()
        });
        if (!result.IsSuccess) return Json(new { success = false, message = result.ErrorMessage });
        await AuditAsync("DoctorPayout.PreparedDay", $"Day-end settlements prepared for shares up to {upTo:dd MMM yyyy}.", null, null, new { UpTo = upTo });
        return new ContentResult { Content = "{\"success\":true,\"data\":" + result.Data + "}", ContentType = "application/json" };
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> ApproveSettlement([FromBody] ActionInput input) =>
        SettlementActionAsync("APPROVE", input, "DoctorPayout.Approved", "approved", "Settlement approved. It can now be paid.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> RejectSettlement([FromBody] ActionInput input) =>
        SettlementActionAsync("REJECT", input, "DoctorPayout.Rejected", "rejected", "Settlement rejected. Its shares are back to be settled again.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> CancelSettlement([FromBody] ActionInput input) =>
        SettlementActionAsync("CANCEL", input, "DoctorPayout.Cancelled", "cancelled", "Settlement cancelled. Its shares are back to be settled again.");

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> PaySettlement([FromBody] ActionInput input) =>
        SettlementActionAsync("PAY", input, "DoctorPayout.Paid", "paid", "Payment recorded.");

    private async Task<IActionResult> SettlementActionAsync(string action, ActionInput input, string auditAction, string verb, string okMessage)
    {
        if (input == null || input.SettlementId <= 0) return Json(new { success = false, message = "Choose the settlement." });
        var result = await payoutApi.PostAsync("action", new
        {
            BranchId, input.SettlementId, Action = action, input.Remarks, input.PaymentDate, input.PaymentMode, input.PaymentReference,
            UserId = User.GetUserId(), IsSuperAdmin = User.IsSuperAdmin()
        });
        if (!result.IsSuccess) return Json(new { success = false, message = result.ErrorMessage });
        await AuditAsync(auditAction, $"Doctor settlement {input.SettlementNo} {verb}" +
            (action == "PAY" ? $" by {input.PaymentMode}{(string.IsNullOrWhiteSpace(input.PaymentReference) ? "" : " (" + input.PaymentReference + ")")}" : "") +
            (string.IsNullOrWhiteSpace(input.Remarks) ? "." : $": {input.Remarks}"),
            input.SettlementNo, input.SettlementId, new { input.SettlementId, input.Remarks, input.PaymentDate, input.PaymentMode, input.PaymentReference });
        return Json(new { success = true, message = okMessage });
    }

    private static int ReadId(string? json)
    {
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json ?? "{}");
            return doc.RootElement.TryGetProperty("id", out var v) && v.TryGetInt32(out var id) ? id : 0;
        }
        catch { return 0; }
    }

    private async Task AuditAsync(string actionName, string description, string? referenceNo, long? referenceId, object metadata)
    {
        try
        {
            await auditLogService.LogActivityAsync(eventType: "Finance", actionName: actionName, description: description,
                userId: User.GetUserId(), branchId: BranchId, moduleCode: "OPD", referenceNo: referenceNo, referenceId: referenceId, metadata: metadata);
        }
        catch { /* audit only */ }
    }
}
