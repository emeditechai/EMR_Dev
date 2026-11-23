using System.Text.Json;
using EMR.Shared.Security;
using EMR.Web.ApiClients;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// IPD > Bed Board (Phase 2, SQLScripts/2431): live beds, transfer / ICU shift, swap, reservation, block / maintenance,
/// housekeeping cleaning and the daily census. Web -> EMR.Api api/ipd -> stored procedures.
/// </summary>
[Authorize]
public class IpdBedsController(IpdApiClient api, IActionPermissionGuard permissionGuard, IAuditLogService auditLogService,
    ILogger<IpdBedsController> logger) : Controller
{
    public const string BoardPage = "IPD.BEDBOARD";

    private IActionResult Fail(string message) => Json(new { success = false, error = message });

    private async Task<IActionResult> Read(Func<Task<object>> call)
    {
        try { return Json(new { success = true, data = await call() }); }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Try again in a moment."); }
    }

    private async Task<IActionResult> Write(Func<Task<JsonElement>> call, string action, string? description = null, int? refId = null)
    {
        try
        {
            var row = await call();
            if (!row.B("Success")) return Fail(row.S("Error") is { Length: > 0 } e ? e : "The request could not be completed.");
            await auditLogService.LogActivityAsync(eventType: "IPD Beds", actionName: action, description: description, userId: User.GetUserId(),
                branchId: User.GetCurrentBranchId(), moduleCode: "IPD", referenceId: refId);
            return Json(new { success = true, data = row });
        }
        catch (InvalidOperationException ex) { return Fail(ex.Message); }
        catch (HttpRequestException ex) { logger.LogWarning(ex, "IPD API unreachable"); return Fail("The EMR API is not reachable. Nothing was saved; try again in a moment."); }
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        if (User.GetCurrentBranchId() is null) return RedirectToAction("SelectBranch", "Account");
        foreach (var c in new[] { "TRANSFER", "SWAP", "RESERVE", "RELEASE", "BLOCK", "HOUSEKEEPING" })
            ViewData["Can" + c] = await permissionGuard.AllowsAsync(HttpContext, BoardPage, c);
        return View();
    }

    [HttpGet]
    public Task<IActionResult> BoardData() => Read(async () =>
    {
        var s = await api.SetsAsync("/beds/board");
        return new { beds = s.ElementAtOrDefault(0), staff = s.ElementAtOrDefault(1), reservations = s.ElementAtOrDefault(2), cleaning = s.ElementAtOrDefault(3) };
    });

    [HttpGet]
    public Task<IActionResult> History(int bedId) => Read(async () =>
    {
        var s = await api.SetsAsync($"/beds/{bedId}/history");
        return new { log = s.ElementAtOrDefault(0), patients = s.ElementAtOrDefault(1) };
    });

    [HttpGet]
    public Task<IActionResult> CensusData(DateTime? fromDate, DateTime? toDate) => Read(async () =>
        await api.GetAsync("/census" + IpdApiClient.Q(("fromDate", fromDate ?? DateTime.Today.AddDays(-6)), ("toDate", toDate ?? DateTime.Today))));

    /// <summary>Beds for the transfer picker (board and IPD Patient screen).</summary>
    [HttpGet]
    public Task<IActionResult> TransferBeds(int admissionId) => Read(async () => await api.GetAsync($"/beds/for-transfer/{admissionId}"));

    public sealed class TransferBody { public int ToBedId { get; set; } public DateTime? TransferAt { get; set; } public string? Reason { get; set; } public bool UpdateDepartment { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Transfer(int admissionId, [FromBody] TransferBody b)
    {
        // allowed from the Bed Board or the IPD Patient screen (each has its own TRANSFER control)
        if (!await permissionGuard.AllowsAnyAsync(HttpContext, [BoardPage, IpdAdmissionController.PatientPage], "TRANSFER"))
            return Fail(PermissionFilter.DeniedMessage);
        var backdate = await permissionGuard.AllowsAsync(HttpContext, BoardPage, "BACKDATE");
        return await Write(() => api.PostAsync($"/admissions/{admissionId}/transfer", new { b.ToBedId, b.TransferAt, b.Reason, b.UpdateDepartment, CanBackdate = backdate }),
            "IPD.Transfer", $"Admission {admissionId} transferred to bed {b.ToBedId}: {b.Reason}", admissionId);
    }

    public sealed class SwapBody { public int AdmissionId { get; set; } public int OtherAdmissionId { get; set; } public string? Reason { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Swap([FromBody] SwapBody b) =>
        Write(() => api.PostAsync($"/admissions/{b.AdmissionId}/swap", new { b.OtherAdmissionId, b.Reason }),
            "IPD.Swap", $"Beds of admissions {b.AdmissionId} and {b.OtherAdmissionId} swapped: {b.Reason}", b.AdmissionId);

    public sealed class StatusBody { public int BedId { get; set; } public string? Status { get; set; } public string? Reason { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> SetStatus([FromBody] StatusBody b) =>
        Write(() => api.PostAsync($"/beds/{b.BedId}/status", new { Status = b.Status ?? "", b.Reason }), "IPD.BedStatus", $"Bed {b.BedId} → {b.Status}: {b.Reason}", b.BedId);

    public sealed class ReserveBody
    {
        public int BedId { get; set; }
        public int? PatientId { get; set; }
        public string? PatientName { get; set; }
        public string? Phone { get; set; }
        public DateTime ExpectedAdmitAt { get; set; }
        public int? HoldHours { get; set; }
        public int? DoctorId { get; set; }
        public string? Remarks { get; set; }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Reserve([FromBody] ReserveBody b) =>
        Write(() => api.PostAsync($"/beds/{b.BedId}/reserve", new { b.PatientId, b.PatientName, b.Phone, b.ExpectedAdmitAt, b.HoldHours, b.DoctorId, EstimateId = (int?)null, b.Remarks }),
            "IPD.Reserve", $"Bed {b.BedId} reserved for {b.PatientName ?? b.PatientId?.ToString()}", b.BedId);

    public sealed class ReleaseBody { public int ReservationId { get; set; } public string? Reason { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> ReleaseReservation([FromBody] ReleaseBody b) =>
        Write(() => api.PostAsync($"/reservations/{b.ReservationId}/release", new { b.Reason }), "IPD.ReleaseReservation", $"Reservation {b.ReservationId} released: {b.Reason}", b.ReservationId);

    public sealed class CleaningBody { public int CleaningTaskId { get; set; } public string? Action { get; set; } public int? StaffUserId { get; set; } public string? Remarks { get; set; } }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Cleaning([FromBody] CleaningBody b) =>
        Write(() => api.PostAsync($"/cleaning/{b.CleaningTaskId}", new { Action = (b.Action ?? "").ToUpperInvariant(), b.StaffUserId, b.Remarks }),
            "IPD.BedCleaning", $"Cleaning job {b.CleaningTaskId}: {b.Action}", b.CleaningTaskId);
}
