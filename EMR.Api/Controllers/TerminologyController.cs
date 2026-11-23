using EMR.Api.Models;
using EMR.Api.Services;
using Microsoft.AspNetCore.Mvc;

namespace EMR.Api.Controllers;

/// <summary>
/// Utility > API data: Standard Laboratory Test Master (LOINC), SQLScripts/2316. Import -> Validate -> Map -> Approve ->
/// Publish. Everything is kept in schema Terminology; the local Investigation Master is only read.
/// </summary>
[ApiController]
[Route("api/v1/terminology")]
public class TerminologyController(ITerminologyService svc, TerminologyStorage storage, TerminologyImportQueue queue,
    ILoincTerminologyClient online) : ControllerBase
{
    private IActionResult Rule(Exception ex) =>
        TerminologyService.RuleMessage(ex) is { } m ? BadRequest(ApiResponse<object>.Fail(m)) : throw ex;

    // ── Releases and imports ────────────────────────────────────────────────────────────────────────────
    [HttpGet("releases")]
    public async Task<IActionResult> Releases()
    {
        var r = await svc.ReleasesAsync();
        r.OnlineConfigured = online.IsConfigured;
        return Ok(ApiResponse<TermReleasesResult>.Ok(r));
    }

    /// <summary>One chunk of an upload (raw bytes, in order). Chunks keep each request under the web server limits.</summary>
    [HttpPost("uploads/{uploadId}/chunks/{index:int}")]
    [RequestSizeLimit(16 * 1024 * 1024)]
    public async Task<IActionResult> UploadChunk(string uploadId, int index, CancellationToken ct)
    {
        if (!TerminologyStorage.ValidUploadId(uploadId) || index < 0) return BadRequest(ApiResponse<object>.Fail("Invalid upload."));
        try
        {
            var size = await storage.AppendChunkAsync(uploadId, index, Request.Body, ct);
            return Ok(ApiResponse<long>.Ok(size));
        }
        catch (InvalidOperationException ex) { return BadRequest(ApiResponse<object>.Fail(ex.Message)); }
    }

    [HttpPost("import")]
    public async Task<IActionResult> StartImport([FromBody] TermStartImportRequest req, CancellationToken ct)
    {
        if (req is null || !TerminologyStorage.ValidUploadId(req.UploadId)) return BadRequest(ApiResponse<object>.Fail("Upload the release file first."));
        var ext = Path.GetExtension(req.FileName ?? "").ToLowerInvariant();
        if (ext is not (".csv" or ".zip")) return BadRequest(ApiResponse<object>.Fail("Upload Loinc.csv or the official LOINC release ZIP."));
        if (string.IsNullOrWhiteSpace(req.VersionCode) || req.VersionCode.Trim().Length > 30)
            return BadRequest(ApiResponse<object>.Fail("Enter the LOINC release version (for example 2.78)."));
        string? stored = null;
        try
        {
            var (path, size, hash) = await storage.FinishUploadAsync(req.UploadId, req.FileName!, ct);
            stored = path;
            var (jobId, releaseId) = await svc.CreateImportAsync(req.VersionCode.Trim(), req.ReleaseDate, Path.GetFileName(req.FileName!), hash, size, path, req.Notes, req.UserId);
            stored = null;   // the job owns the file now
            queue.Enqueue(jobId);
            return Ok(ApiResponse<object>.Ok(new { jobId, releaseId, hash, size }));
        }
        catch (InvalidOperationException ex) { return BadRequest(ApiResponse<object>.Fail(ex.Message)); }
        catch (Exception ex) when (TerminologyService.RuleMessage(ex) is not null) { return Rule(ex); }
        finally
        {
            // refused (e.g. version already published): the file is not kept
            if (stored is not null) try { System.IO.File.Delete(stored); } catch { /* ignore */ }
        }
    }

    [HttpGet("imports/{id:int}")]
    public async Task<IActionResult> Import(int id)
    {
        var job = await svc.ImportAsync(id);
        return job is null ? NotFound(ApiResponse<object>.Fail("Import not found.")) : Ok(ApiResponse<TermImportJob>.Ok(job));
    }

    [HttpGet("imports/{id:int}/errors")]
    public async Task<IActionResult> ImportErrors(int id, [FromQuery] int page = 1, [FromQuery] int pageSize = 50) =>
        Ok(ApiResponse<TermPaged<TermImportError>>.Ok(await svc.ImportErrorsAsync(id, Math.Max(1, page), Math.Clamp(pageSize, 1, 200))));

    [HttpPost("releases/{id:int}/publish")]
    public async Task<IActionResult> Publish(int id, [FromBody] TermUserRequest req)
    {
        try { return Ok(ApiResponse<TermImportJob?>.Ok(await svc.PublishAsync(id, req?.UserId))); }
        catch (Exception ex) when (TerminologyService.RuleMessage(ex) is not null) { return Rule(ex); }
    }

    [HttpPost("releases/{id:int}/discard")]
    public async Task<IActionResult> Discard(int id, [FromBody] TermUserRequest req)
    {
        try { await svc.DiscardAsync(id, req?.UserId); return Ok(ApiResponse<object>.Ok(new { })); }
        catch (Exception ex) when (TerminologyService.RuleMessage(ex) is not null) { return Rule(ex); }
    }

    [HttpGet("releases/{id:int}/changes")]
    public async Task<IActionResult> Changes(int id, [FromQuery] string? type, [FromQuery] string? search, [FromQuery] int page = 1, [FromQuery] int pageSize = 50) =>
        Ok(ApiResponse<TermChangesResult>.Ok(await svc.ChangesAsync(id,
            type?.Trim().ToUpperInvariant() is "ADDED" or "MODIFIED" or "STATUS" or "RETIRED" ? type.Trim().ToUpperInvariant() : null,
            search?.Trim(), Math.Max(1, page), Math.Clamp(pageSize, 1, 200))));

    // ── Search ──────────────────────────────────────────────────────────────────────────────────────────
    [HttpGet("loinc/search")]
    public async Task<IActionResult> Search([FromQuery] string? q, [FromQuery] string? className, [FromQuery] bool labOnly = true,
        [FromQuery] bool includeRetired = false, [FromQuery] string? status = null, [FromQuery] string? orderObs = null,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25) =>
        Ok(ApiResponse<TermPaged<LoincConceptRow>>.Ok(await svc.SearchAsync(q?.Trim(), className?.Trim(), labOnly, includeRetired,
            status?.Trim().ToUpperInvariant() is "ACTIVE" or "TRIAL" or "DISCOURAGED" or "DEPRECATED" ? status.Trim().ToUpperInvariant() : null,
            orderObs?.Trim() is "Order" or "Observation" or "Both" ? orderObs.Trim() : null,
            Math.Max(1, page), Math.Clamp(pageSize, 1, 100))));

    [HttpGet("loinc/classes")]
    public async Task<IActionResult> Classes() => Ok(ApiResponse<List<LoincClassRow>>.Ok(await svc.ClassesAsync()));

    [HttpGet("loinc/{code}")]
    public async Task<IActionResult> Concept(string code)
    {
        var c = await svc.ConceptAsync(code.Trim());
        return c is null ? NotFound(ApiResponse<object>.Fail("LOINC code not in the local repository.")) : Ok(ApiResponse<LoincConceptDetail>.Ok(c));
    }

    [HttpGet("loinc/online")]
    public async Task<IActionResult> OnlineSearch([FromQuery] string q, [FromQuery] int page = 1, [FromQuery] int pageSize = 20, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(q)) return BadRequest(ApiResponse<object>.Fail("Type what to search for."));
        var size = Math.Clamp(pageSize, 1, 50);
        var r = await online.SearchAsync(q.Trim(), size, (Math.Max(1, page) - 1) * size, ct);
        if (r.Items.Count > 0)
        {
            var have = await svc.ExistingCodesAsync(r.Items.Select(i => i.LoincCode));
            foreach (var i in r.Items) i.InLocal = have.Contains(i.LoincCode);
        }
        return Ok(ApiResponse<TermOnlineResult>.Ok(r));
    }

    [HttpPost("loinc/lookup")]
    public async Task<IActionResult> SaveLookup([FromBody] TermSaveLookupRequest req)
    {
        if (req?.Concept is null || string.IsNullOrWhiteSpace(req.Concept.LoincCode)) return BadRequest(ApiResponse<object>.Fail("No concept given."));
        if (!TerminologyImportWorker.CheckDigitOk(req.Concept.LoincCode.Trim())) return BadRequest(ApiResponse<object>.Fail("Not a valid LOINC code."));
        try
        {
            req.Concept.LoincCode = req.Concept.LoincCode.Trim();
            var (added, message) = await svc.SaveLookupAsync(req.Concept, req.UserId);
            return Ok(ApiResponse<object>.Ok(new { added, message }));
        }
        catch (Exception ex) when (TerminologyService.RuleMessage(ex) is not null) { return Rule(ex); }
    }

    // ── Investigation mapping ───────────────────────────────────────────────────────────────────────────
    [HttpGet("investigations")]
    public async Task<IActionResult> Investigations([FromQuery] int? companyId, [FromQuery] string? search, [FromQuery] string? state,
        [FromQuery] int? departmentId, [FromQuery] int page = 1, [FromQuery] int pageSize = 25) =>
        Ok(ApiResponse<TermInvestigationsResult>.Ok(await svc.InvestigationsAsync(companyId, search?.Trim(),
            state?.Trim().ToUpperInvariant() is "UNMAPPED" or "PENDING" or "APPROVED" or "REVIEW" ? state.Trim().ToUpperInvariant() : null,
            departmentId is > 0 ? departmentId : null, Math.Max(1, page), Math.Clamp(pageSize, 1, 100))));

    [HttpGet("investigations/{id:int}/mappings")]
    public async Task<IActionResult> Mappings(int id)
    {
        var d = await svc.InvestigationDetailAsync(id);
        return d.Investigation is null ? NotFound(ApiResponse<object>.Fail("Investigation not found.")) : Ok(ApiResponse<TermInvestigationDetail>.Ok(d));
    }

    [HttpPost("investigations/{id:int}/mappings")]
    public async Task<IActionResult> Propose(int id, [FromBody] TermProposeRequest req)
    {
        if (req is null || string.IsNullOrWhiteSpace(req.LoincCode)) return BadRequest(ApiResponse<object>.Fail("Choose a LOINC code."));
        try { return Ok(ApiResponse<long>.Ok(await svc.ProposeAsync(id, req))); }
        catch (Exception ex) when (TerminologyService.RuleMessage(ex) is not null) { return Rule(ex); }
    }

    [HttpPost("mappings/{mappingId:long}/decide")]
    public async Task<IActionResult> Decide(long mappingId, [FromBody] TermDecideRequest req)
    {
        if (req is null || req.Decision?.Trim().ToUpperInvariant() is not ("APPROVE" or "REJECT" or "PREFERRED" or "REVIEWED"))
            return BadRequest(ApiResponse<object>.Fail("Unknown decision."));
        try { await svc.DecideAsync(mappingId, req); return Ok(ApiResponse<object>.Ok(new { })); }
        catch (Exception ex) when (TerminologyService.RuleMessage(ex) is not null) { return Rule(ex); }
    }
}
