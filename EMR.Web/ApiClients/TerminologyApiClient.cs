using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Web;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>Utility > API data: Standard Laboratory Test Master (LOINC), SQLScripts/2316 - EMR.Api api/v1/terminology.</summary>
public interface ITerminologyApiClient
{
    Task<TermReleasesResult> ReleasesAsync();
    Task<(bool Ok, string? Error)> UploadChunkAsync(string uploadId, int index, Stream chunk);
    Task<(int? JobId, string? Error)> StartImportAsync(TermStartImportRequest req);
    Task<TermImportJob?> ImportAsync(int jobId);
    Task<TermPaged<TermImportError>> ImportErrorsAsync(int jobId, int page, int pageSize);
    Task<(bool Ok, string? Error)> PublishAsync(int releaseId, int? userId);
    Task<(bool Ok, string? Error)> DiscardAsync(int releaseId, int? userId);
    Task<TermChangesResult> ChangesAsync(int releaseId, string? type, string? search, int page, int pageSize);
    Task<TermPaged<LoincConceptRow>> SearchAsync(string? q, string? className, bool labOnly, bool includeRetired, string? status, string? orderObs, int page, int pageSize);
    Task<List<LoincClassRow>> ClassesAsync();
    Task<LoincConceptDetail?> ConceptAsync(string code);
    Task<TermOnlineResult> OnlineSearchAsync(string q, int page, int pageSize);
    Task<(bool Ok, string? Message)> SaveLookupAsync(LoincConceptRow concept, int? userId);
    Task<TermInvestigationsResult> InvestigationsAsync(int? companyId, string? search, string? state, int? departmentId, int page, int pageSize);
    Task<TermInvestigationDetail?> MappingsAsync(int investigationId);
    Task<(bool Ok, string? Error)> ProposeAsync(int investigationId, TermProposeRequest req);
    Task<(bool Ok, string? Error)> DecideAsync(long mappingId, TermDecideRequest req);
}

public class TerminologyApiClient(IHttpClientFactory factory) : ITerminologyApiClient
{
    private HttpClient Http
    {
        get
        {
            var c = factory.CreateClient("EmrApi");
            c.Timeout = TimeSpan.FromMinutes(15);   // publishing a full release takes a while
            return c;
        }
    }
    private const string Base = "api/v1/terminology/";

    private static async Task<(T? Data, string? Error)> ReadAsync<T>(HttpResponseMessage r) where T : notnull
    {
        try
        {
            var body = await r.Content.ReadFromJsonAsync<ApiResponse<T>>();
            if (r.IsSuccessStatusCode && body is { Success: true }) return (body.Data, null);
            return (default, body?.Message is { Length: > 0 } m ? m : $"The server answered {(int)r.StatusCode}.");
        }
        catch (System.Text.Json.JsonException) { return (default, $"The server answered {(int)r.StatusCode}."); }
    }

    private async Task<T> GetAsync<T>(string url) where T : class, new()
    {
        var r = await Http.GetFromJsonAsync<ApiResponse<T>>(Base + url);
        return r?.Data ?? new T();
    }

    public Task<TermReleasesResult> ReleasesAsync() => GetAsync<TermReleasesResult>("releases");

    public async Task<(bool Ok, string? Error)> UploadChunkAsync(string uploadId, int index, Stream chunk)
    {
        using var content = new StreamContent(chunk);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        var r = await Http.PostAsync($"{Base}uploads/{uploadId}/chunks/{index}", content);
        var (_, err) = await ReadAsync<System.Text.Json.JsonElement>(r);
        return (err is null, err);
    }

    public async Task<(int? JobId, string? Error)> StartImportAsync(TermStartImportRequest req)
    {
        var r = await Http.PostAsJsonAsync(Base + "import", req);
        var (data, err) = await ReadAsync<System.Text.Json.JsonElement>(r);
        if (err is not null) return (null, err);
        return (data.TryGetProperty("jobId", out var j) ? j.GetInt32() : null, null);
    }

    public async Task<TermImportJob?> ImportAsync(int jobId)
    {
        var r = await Http.GetAsync($"{Base}imports/{jobId}");
        return r.IsSuccessStatusCode ? (await r.Content.ReadFromJsonAsync<ApiResponse<TermImportJob>>())?.Data : null;
    }

    public Task<TermPaged<TermImportError>> ImportErrorsAsync(int jobId, int page, int pageSize) =>
        GetAsync<TermPaged<TermImportError>>($"imports/{jobId}/errors?page={page}&pageSize={pageSize}");

    public async Task<(bool Ok, string? Error)> PublishAsync(int releaseId, int? userId)
    {
        var (_, err) = await ReadAsync<object>(await Http.PostAsJsonAsync($"{Base}releases/{releaseId}/publish", new { userId }));
        return (err is null, err);
    }

    public async Task<(bool Ok, string? Error)> DiscardAsync(int releaseId, int? userId)
    {
        var (_, err) = await ReadAsync<object>(await Http.PostAsJsonAsync($"{Base}releases/{releaseId}/discard", new { userId }));
        return (err is null, err);
    }

    public Task<TermChangesResult> ChangesAsync(int releaseId, string? type, string? search, int page, int pageSize)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        if (!string.IsNullOrWhiteSpace(type)) qs["type"] = type;
        if (!string.IsNullOrWhiteSpace(search)) qs["search"] = search;
        qs["page"] = page.ToString(); qs["pageSize"] = pageSize.ToString();
        return GetAsync<TermChangesResult>($"releases/{releaseId}/changes?{qs}");
    }

    public Task<TermPaged<LoincConceptRow>> SearchAsync(string? q, string? className, bool labOnly, bool includeRetired, string? status, string? orderObs, int page, int pageSize)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        if (!string.IsNullOrWhiteSpace(q)) qs["q"] = q;
        if (!string.IsNullOrWhiteSpace(className)) qs["className"] = className;
        if (!string.IsNullOrWhiteSpace(status)) qs["status"] = status;
        if (!string.IsNullOrWhiteSpace(orderObs)) qs["orderObs"] = orderObs;
        qs["labOnly"] = labOnly.ToString(); qs["includeRetired"] = includeRetired.ToString();
        qs["page"] = page.ToString(); qs["pageSize"] = pageSize.ToString();
        return GetAsync<TermPaged<LoincConceptRow>>($"loinc/search?{qs}");
    }

    public async Task<List<LoincClassRow>> ClassesAsync() =>
        (await Http.GetFromJsonAsync<ApiResponse<List<LoincClassRow>>>(Base + "loinc/classes"))?.Data ?? [];

    public async Task<LoincConceptDetail?> ConceptAsync(string code)
    {
        var r = await Http.GetAsync($"{Base}loinc/{Uri.EscapeDataString(code)}");
        return r.IsSuccessStatusCode ? (await r.Content.ReadFromJsonAsync<ApiResponse<LoincConceptDetail>>())?.Data : null;
    }

    public Task<TermOnlineResult> OnlineSearchAsync(string q, int page, int pageSize) =>
        GetAsync<TermOnlineResult>($"loinc/online?q={Uri.EscapeDataString(q)}&page={page}&pageSize={pageSize}");

    public async Task<(bool Ok, string? Message)> SaveLookupAsync(LoincConceptRow concept, int? userId)
    {
        var (data, err) = await ReadAsync<System.Text.Json.JsonElement>(await Http.PostAsJsonAsync(Base + "loinc/lookup", new { concept, userId }));
        if (err is not null) return (false, err);
        return (true, data.TryGetProperty("message", out var m) ? m.GetString() : null);
    }

    public Task<TermInvestigationsResult> InvestigationsAsync(int? companyId, string? search, string? state, int? departmentId, int page, int pageSize)
    {
        var qs = HttpUtility.ParseQueryString(string.Empty);
        if (companyId.HasValue) qs["companyId"] = companyId.Value.ToString();
        if (!string.IsNullOrWhiteSpace(search)) qs["search"] = search;
        if (!string.IsNullOrWhiteSpace(state)) qs["state"] = state;
        if (departmentId is > 0) qs["departmentId"] = departmentId.Value.ToString();
        qs["page"] = page.ToString(); qs["pageSize"] = pageSize.ToString();
        return GetAsync<TermInvestigationsResult>($"investigations?{qs}");
    }

    public async Task<TermInvestigationDetail?> MappingsAsync(int investigationId)
    {
        var r = await Http.GetAsync($"{Base}investigations/{investigationId}/mappings");
        return r.IsSuccessStatusCode ? (await r.Content.ReadFromJsonAsync<ApiResponse<TermInvestigationDetail>>())?.Data : null;
    }

    public async Task<(bool Ok, string? Error)> ProposeAsync(int investigationId, TermProposeRequest req)
    {
        var (_, err) = await ReadAsync<System.Text.Json.JsonElement>(await Http.PostAsJsonAsync($"{Base}investigations/{investigationId}/mappings", req));
        return (err is null, err);
    }

    public async Task<(bool Ok, string? Error)> DecideAsync(long mappingId, TermDecideRequest req)
    {
        var (_, err) = await ReadAsync<object>(await Http.PostAsJsonAsync($"{Base}mappings/{mappingId}/decide", req));
        return (err is null, err);
    }
}
