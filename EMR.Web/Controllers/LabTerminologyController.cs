using EMR.Web.ApiClients;
using EMR.Web.ApiClients.Models;
using EMR.Web.Extensions;
using EMR.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Web.Controllers;

/// <summary>
/// Utility > API data (SQLScripts/2316): Standard Laboratory Test Master (LOINC) - Terminology Import, Standard Test
/// Search, Investigation Mapping and Release Changes. Strictly via EMR.Api; kept apart from the operational lab
/// masters (the local Investigation Master is only read).
/// </summary>
[Authorize]
public class LabTerminologyController(ITerminologyApiClient api, IAuditLogService audit) : Controller
{
    private IActionResult Down(string page)
    {
        ViewData["PageName"] = page;
        return View("ApiDown");
    }

    // ── Terminology Import ───────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Releases()
    {
        try { return View(await api.ReleasesAsync()); }
        catch (HttpRequestException) { return Down("Terminology Import"); }
    }

    /// <summary>One chunk of the release file (raw bytes), passed straight to EMR.Api.</summary>
    [HttpPost]
    [RequestSizeLimit(16 * 1024 * 1024)]
    public async Task<IActionResult> UploadChunk([FromQuery] string uploadId, [FromQuery] int index)
    {
        if (string.IsNullOrWhiteSpace(uploadId) || index < 0) return Json(new { success = false, error = "Invalid upload." });
        try
        {
            var (ok, err) = await api.UploadChunkAsync(uploadId, index, Request.Body);
            return Json(new { success = ok, error = err });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    public class StartImportModel
    {
        public string UploadId { get; set; } = "";
        public string FileName { get; set; } = "";
        public string VersionCode { get; set; } = "";
        public DateTime? ReleaseDate { get; set; }
        public string? Notes { get; set; }
    }

    [HttpPost]
    public async Task<IActionResult> StartImport([FromBody] StartImportModel m)
    {
        try
        {
            var (jobId, err) = await api.StartImportAsync(new TermStartImportRequest
            {
                UploadId = m.UploadId, FileName = m.FileName, VersionCode = m.VersionCode, ReleaseDate = m.ReleaseDate, Notes = m.Notes,
                UserId = User.GetUserId()
            });
            if (jobId.HasValue)
                await audit.LogAsync("UTILITY", "Terminology.Import", $"LOINC release {m.VersionCode} import started ({m.FileName}), job {jobId}.");
            return Json(new { success = jobId.HasValue, jobId, error = err });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    [HttpGet]
    public async Task<IActionResult> ImportStatus(int jobId)
    {
        try
        {
            var job = await api.ImportAsync(jobId);
            return job is null ? NotFound() : Json(job);
        }
        catch (HttpRequestException) { return StatusCode(503); }
    }

    [HttpGet]
    public async Task<IActionResult> ImportErrors(int jobId, int page = 1)
    {
        try { return Json(await api.ImportErrorsAsync(jobId, Math.Max(1, page), 50)); }
        catch (HttpRequestException) { return StatusCode(503); }
    }

    public class ReleaseActionModel { public int ReleaseId { get; set; } }

    [HttpPost]
    public async Task<IActionResult> Publish([FromBody] ReleaseActionModel m)
    {
        try
        {
            var (ok, err) = await api.PublishAsync(m.ReleaseId, User.GetUserId());
            if (ok) await audit.LogAsync("UTILITY", "Terminology.Publish", $"LOINC release #{m.ReleaseId} published.");
            return Json(new { success = ok, error = err });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    [HttpPost]
    public async Task<IActionResult> Discard([FromBody] ReleaseActionModel m)
    {
        try
        {
            var (ok, err) = await api.DiscardAsync(m.ReleaseId, User.GetUserId());
            if (ok) await audit.LogAsync("UTILITY", "Terminology.Discard", $"LOINC release import #{m.ReleaseId} discarded.");
            return Json(new { success = ok, error = err });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    // ── Standard Test Search ─────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Search(string? q, string? className, string? status, string? orderObs, bool all = false, bool retired = false, int page = 1, int pageSize = 25)
    {
        if (pageSize is not (10 or 25 or 50 or 100)) pageSize = 25;
        try
        {
            ViewBag.Q = q; ViewBag.ClassName = className; ViewBag.Status = status; ViewBag.OrderObs = orderObs;
            ViewBag.All = all; ViewBag.Retired = retired;
            ViewBag.Classes = await api.ClassesAsync();
            return View(await api.SearchAsync(q, className, !all, retired, status, orderObs, Math.Max(1, page), pageSize));
        }
        catch (HttpRequestException) { return Down("Standard Test Search"); }
    }

    [HttpGet]
    public async Task<IActionResult> Concept(string code)
    {
        try
        {
            var c = await api.ConceptAsync(code);
            return c is null ? NotFound() : Json(c);
        }
        catch (HttpRequestException) { return StatusCode(503); }
    }

    [HttpGet]
    public async Task<IActionResult> OnlineSearch(string q, int page = 1)
    {
        try { return Json(await api.OnlineSearchAsync(q, Math.Max(1, page), 20)); }
        catch (HttpRequestException) { return Json(new TermOnlineResult { Configured = true, Message = "The API is not reachable." }); }
    }

    [HttpPost]
    public async Task<IActionResult> SaveLookup([FromBody] LoincConceptRow concept)
    {
        try
        {
            var (ok, msg) = await api.SaveLookupAsync(concept, User.GetUserId());
            if (ok) await audit.LogAsync("UTILITY", "Terminology.Lookup", $"LOINC {concept.LoincCode} added from the LOINC Search API.");
            return Json(new { success = ok, message = msg, error = ok ? null : msg });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    // ── Investigation Mapping ────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Mapping(string? search, string? state, int? departmentId, int? open, int page = 1, int pageSize = 25)
    {
        if (pageSize is not (10 or 25 or 50 or 100)) pageSize = 25;
        try
        {
            ViewBag.Search = search; ViewBag.State = state; ViewBag.DepartmentId = departmentId; ViewBag.Open = open;
            ViewBag.Stats = (await api.ReleasesAsync()).Stats;
            return View(await api.InvestigationsAsync(User.IsSuperAdmin() ? null : User.GetCompanyId(), search, state, departmentId, Math.Max(1, page), pageSize));
        }
        catch (HttpRequestException) { return Down("Investigation Mapping"); }
    }

    [HttpGet]
    public async Task<IActionResult> MappingDetail(int id)
    {
        try
        {
            var d = await api.MappingsAsync(id);
            return d is null ? NotFound() : Json(d);
        }
        catch (HttpRequestException) { return StatusCode(503); }
    }

    /// <summary>Concept search for the mapping picker (local repository, lab concepts).</summary>
    [HttpGet]
    public async Task<IActionResult> SearchJson(string q, int page = 1)
    {
        try { return Json(await api.SearchAsync(q, null, true, false, null, null, Math.Max(1, page), 15)); }
        catch (HttpRequestException) { return StatusCode(503); }
    }

    public class ProposeModel
    {
        public int InvestigationId { get; set; }
        public string LoincCode { get; set; } = "";
        public string? Method { get; set; }
        public string? Notes { get; set; }
    }

    [HttpPost]
    public async Task<IActionResult> Propose([FromBody] ProposeModel m)
    {
        try
        {
            var (ok, err) = await api.ProposeAsync(m.InvestigationId, new TermProposeRequest
            {
                LoincCode = m.LoincCode, Method = m.Method, Notes = m.Notes, UserId = User.GetUserId(), CompanyId = User.GetCompanyId()
            });
            if (ok) await audit.LogAsync("UTILITY", "Terminology.Propose", $"LOINC {m.LoincCode} proposed for investigation #{m.InvestigationId}.");
            return Json(new { success = ok, error = err });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    public class DecideModel
    {
        public long MappingId { get; set; }
        public string Decision { get; set; } = "";
        public string? Note { get; set; }
    }

    [HttpPost]
    public async Task<IActionResult> Decide([FromBody] DecideModel m)
    {
        try
        {
            var (ok, err) = await api.DecideAsync(m.MappingId, new TermDecideRequest { Decision = m.Decision, Note = m.Note, UserId = User.GetUserId() });
            if (ok) await audit.LogAsync("UTILITY", "Terminology.Decide", $"Mapping #{m.MappingId}: {m.Decision}.");
            return Json(new { success = ok, error = err });
        }
        catch (HttpRequestException) { return Json(new { success = false, error = "The API is not reachable." }); }
    }

    // ── Release Changes ──────────────────────────────────────────────────────────────────────────────────
    [HttpGet]
    public async Task<IActionResult> Changes(int? releaseId, string? type, string? search, int page = 1)
    {
        try
        {
            var releases = (await api.ReleasesAsync()).Releases.Where(r => r.Status is "Validated" or "Published").ToList();
            var rid = releaseId ?? releases.FirstOrDefault()?.ReleaseId;
            ViewBag.Releases = releases; ViewBag.ReleaseId = rid; ViewBag.Type = type; ViewBag.Search = search;
            var data = rid.HasValue ? await api.ChangesAsync(rid.Value, type, search, Math.Max(1, page), 50) : new TermChangesResult();
            return View(data);
        }
        catch (HttpRequestException) { return Down("Release Changes"); }
    }
}
