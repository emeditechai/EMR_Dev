using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD Phase 8 - Operation Theatre (SQLScripts/2492, 2494): IPD > OT Schedule and the OT tab of the IPD Patient workspace
/// (booking, pre-op and WHO checklists, OT times, anaesthesia record, surgery note, implants, OT charges, OT record print).
/// Controls: IPD.PATIENT OT_BOOK, OT_CHECKLIST, OT_PROGRESS, OT_ANAESTHESIA, OT_NOTE, OT_NOTE_SIGN, OT_IMPLANT, OT_CHARGE,
/// CHARGE (charged implants), RATE_EDIT (changed OT rate), CHARGE_CANCEL (reverse OT charges); IPD.OTSCHEDULE BOOK, CANCEL.
/// Web -> EMR.Api api/ipd -> procedures. Rights the procedures need ("Can...") are worked out here, never taken from the page.
/// </summary>
[Authorize]
public class IpdOtController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService, IPrintTemplateRuntime printRuntime, ILogger<IpdOtController> logger) : Controller
{
    public const string SchedulePage = "IPD.OTSCHEDULE";
    private const string PatientPage = IpdAdmissionController.PatientPage;

    private IActionResult Fail(string message) => Json(new { success = false, error = message });
    private Task<bool> Can(string page, string control) => permissionGuard.AllowsAsync(HttpContext, page, control);

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string description, int refId)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD OT", actionName: action, description: description + (row.S("BookingNo") is { Length: > 0 } b ? $" ({b})" : ""),
                userId: User.GetUserId(), branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    /// <summary>The page's body as sent, without any "Can..." flag (those are set from the user's rights), plus the extra values.</summary>
    private static Dictionary<string, object?> Body(JsonElement body, params (string Key, object? Value)[] extra)
    {
        var d = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        if (body.ValueKind == JsonValueKind.Object)
            foreach (var p in body.EnumerateObject())
                if (!p.Name.StartsWith("can", StringComparison.OrdinalIgnoreCase)) d[p.Name] = p.Value;
        foreach (var (k, v) in extra) d[k] = v;
        return d;
    }

    // ── IPD > OT Schedule ──────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Schedule()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        foreach (var c in new[] { "BOOK", "CANCEL" }) ViewData["Can" + c] = await Can(SchedulePage, c);
        ViewData["CanPatient"] = await Can(PatientPage, "VIEW");
        return View();
    }

    [HttpGet]
    public Task<IActionResult> ScheduleData(DateTime? date, int? otId, bool includeCancelled = false) => Read(async () =>
    {
        var s = await api.SetsAsync("/ot/schedule" + IpdApiClient.Q(("date", (date ?? DateTime.Today).ToString("yyyy-MM-dd")), ("otId", otId), ("includeCancelled", includeCancelled)));
        return new { ots = s.ElementAtOrDefault(0), bookings = s.ElementAtOrDefault(1) };
    });

    /// <summary>Admitted patients for booking from the schedule (search by name, UHID, IP no. or mobile).</summary>
    [HttpGet]
    public Task<IActionResult> Patients(string? search) => Read(async () =>
        (await api.SetsAsync("/admissions" + IpdApiClient.Q(("status", "ADMITTED"), ("search", search), ("page", 1), ("pageSize", 20)))).ElementAtOrDefault(0));

    [HttpGet]
    public Task<IActionResult> Lookups() => Read(async () =>
    {
        var s = await api.SetsAsync("/ot/lookups");
        return new { ots = s.ElementAtOrDefault(0), procedures = s.ElementAtOrDefault(1), doctors = s.ElementAtOrDefault(2), anaesthesiaTypes = s.ElementAtOrDefault(3),
                     consents = s.ElementAtOrDefault(4), checklist = s.ElementAtOrDefault(5) };
    });

    // ── OT tab ──────────────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public Task<IActionResult> Data(int id) => Read(async () =>
    {
        var s = await api.SetsAsync($"/admissions/{id}/ot");
        return new { bookings = s.ElementAtOrDefault(0), checklists = s.ElementAtOrDefault(1), consents = s.ElementAtOrDefault(2), anaesthesia = s.ElementAtOrDefault(3),
                     notes = s.ElementAtOrDefault(4), implants = s.ElementAtOrDefault(5), charges = s.ElementAtOrDefault(6) };
    });

    /// <summary>Book a new OT or change a scheduled one (IPD Patient > OT_BOOK or OT Schedule > BOOK).</summary>
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Book(int id, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "OT_BOOK") && !await Can(SchedulePage, "BOOK")) return Fail(PermissionFilter.DeniedMessage);
        var edit = b.TryGetProperty("otBookingId", out var x) && x.ValueKind == JsonValueKind.Number;
        return await Write(() => api.PostAsync($"/admissions/{id}/ot", Body(b)), edit ? "IPD.OtEdit" : "IPD.OtBook",
            $"Admission {id}: OT {(edit ? "booking changed" : "booked")}", id);
    }

    public sealed class ReasonBody { public string? Reason { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Cancel(int bookingId, [FromBody] ReasonBody b)
    {
        if (!await Can(PatientPage, "OT_BOOK") && !await Can(SchedulePage, "CANCEL")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ot/{bookingId}/cancel", new { b.Reason }), "IPD.OtCancel", $"OT booking {bookingId} cancelled: {b.Reason}", bookingId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveChecklist(int bookingId, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "OT_CHECKLIST")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ot/{bookingId}/checklist", Body(b)), "IPD.OtChecklist",
            $"OT booking {bookingId}: {b.S("phase")} checklist completed", bookingId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveTimes(int bookingId, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "OT_PROGRESS")) return Fail(PermissionFilter.DeniedMessage);
        var complete = b.B("complete");
        return await Write(() => api.PostAsync($"/ot/{bookingId}/times", Body(b)), complete ? "IPD.OtComplete" : "IPD.OtTimes",
            $"OT booking {bookingId}: {(complete ? "surgery completed" : "OT times recorded")}", bookingId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveAnaesthesia(int bookingId, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "OT_ANAESTHESIA")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ot/{bookingId}/anaesthesia", Body(b)), "IPD.OtAnaesthesia",
            $"OT booking {bookingId}: anaesthesia record {(b.B("sign") ? "signed" : "saved")}", bookingId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveNote(int bookingId, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "OT_NOTE") && !await Can(PatientPage, "OT_NOTE_SIGN")) return Fail(PermissionFilter.DeniedMessage);
        var canSign = await Can(PatientPage, "OT_NOTE_SIGN");
        return await Write(() => api.PostAsync($"/ot/{bookingId}/note", Body(b, ("CanSign", canSign))), "IPD.OtNote",
            $"OT booking {bookingId}: surgery note {(b.B("sign") ? "signed" : "saved")}" + (b.S("amendReason") is { Length: > 0 } r ? $" (amended: {r})" : ""), bookingId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> AddImplant(int bookingId, [FromBody] JsonElement b)
    {
        if (!await Can(PatientPage, "OT_IMPLANT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ot/{bookingId}/implants", Body(b)), "IPD.OtImplant",
            $"OT booking {bookingId}: {b.S("itemType")} item {b.S("itemId")} x {b.S("qty")} issued from pharmacy stock", bookingId);
    }

    /// <summary>OT items with stock: items of the type's pharmacy category in the store, the stores, and whether the category exists.</summary>
    [HttpGet]
    public Task<IActionResult> StockItems(string? itemType, string? q, int? storeId) => Read(async () =>
    {
        var s = await api.SetsAsync("/ot/stock-items" + IpdApiClient.Q(("itemType", itemType), ("q", q), ("storeId", storeId)));
        return new { items = s.ElementAtOrDefault(0), stores = s.ElementAtOrDefault(1), hasCategory = s.ElementAtOrDefault(2) };
    });

    /// <summary>Saleable batches of an item in the store (nearest expiry first).</summary>
    [HttpGet]
    public Task<IActionResult> Batches(int itemId, int? storeId) => Read(async () => await api.GetAsync($"/ph-batches/{itemId}" + IpdApiClient.Q(("storeId", storeId))));

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> RemoveImplant(int implantId, [FromBody] ReasonBody b)
    {
        if (!await Can(PatientPage, "OT_IMPLANT")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ot-implants/{implantId}/remove", new { b.Reason }), "IPD.OtImplantRemove", $"OT item {implantId} removed: {b.Reason}", implantId);
    }

    [HttpGet]
    public Task<IActionResult> ChargePreview(int bookingId) => Read(async () => await api.GetAsync($"/ot/{bookingId}/charge-preview"));

    public sealed class ChargesBody { public List<ChargeLine> Lines { get; set; } = []; }
    public sealed class ChargeLine { public string Code { get; set; } = ""; public decimal Rate { get; set; } }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> PostCharges(int bookingId, [FromBody] ChargesBody b)
    {
        if (!await Can(PatientPage, "OT_CHARGE")) return Fail(PermissionFilter.DeniedMessage);
        if (b.Lines.Count == 0) return Fail("Choose the OT charges to post.");
        var canRate = await Can(PatientPage, "RATE_EDIT");
        var lines = JsonSerializer.Serialize(b.Lines.Select(l => new { code = l.Code, rate = l.Rate }));
        return await Write(() => api.PostAsync($"/ot/{bookingId}/charges", new { Lines = lines, CanEditRate = canRate }), "IPD.OtCharges",
            $"OT booking {bookingId}: OT charges posted", bookingId);
    }

    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> ReverseCharges(int bookingId, [FromBody] ReasonBody b)
    {
        if (!await Can(PatientPage, "CHARGE_CANCEL")) return Fail(PermissionFilter.DeniedMessage);
        return await Write(() => api.PostAsync($"/ot/{bookingId}/charges/reverse", new { b.Reason }), "IPD.OtChargesReverse",
            $"OT booking {bookingId}: OT charges reversed: {b.Reason}", bookingId);
    }

    /// <summary>OT record print: booking, team, times, checklists, consents, anaesthesia record, surgery note, implants, charges.</summary>
    [HttpGet]
    public async Task<IActionResult> PrintRecord(int bookingId)
    {
        try
        {
            var s = await api.SetsAsync($"/ot/{bookingId}/print");
            var header = s.ElementAtOrDefault(0);
            if (header.ValueKind != JsonValueKind.Array || header.GetArrayLength() == 0) return NotFound();
            if (header[0].I("BranchId") is var br && br > 0 && br != (User.GetCurrentBranchId() ?? 0)) return NotFound();
            await IpdPrint.PrepareAsync(this, printRuntime, logger, User.GetCurrentBranchId() ?? 0,
                new PrintDocInfo { DocNo = header[0].S("IpNo"), DocDate = DateTime.Now.ToString("dd-MMM-yyyy HH:mm"), CopyLabel = "Original", PrintedBy = this.PrintedBy() });
            ViewData["Print"] = JsonSerializer.Serialize(new
            {
                header = header[0], bookingId, bookings = s.ElementAtOrDefault(1), checklists = s.ElementAtOrDefault(2), consents = s.ElementAtOrDefault(3),
                anaesthesia = s.ElementAtOrDefault(4), notes = s.ElementAtOrDefault(5), implants = s.ElementAtOrDefault(6), charges = s.ElementAtOrDefault(7),
                printedBy = User.Identity?.Name, printedAt = DateTime.Now
            });
            return View();
        }
        catch (HttpRequestException) { ViewData["PageName"] = "OT Record"; return View("ApiDown"); }
        catch (InvalidOperationException ex) { return Content(ex.Message); }
    }
}
