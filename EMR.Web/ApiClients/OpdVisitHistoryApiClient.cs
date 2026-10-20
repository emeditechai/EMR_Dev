using System.Net.Http.Json;
using System.Text.Json;

namespace EMR.Web.ApiClients;

/// <summary>OPD Dashboard > visit Audit History (SQLScripts/2304): EMR.Api api/opd-visits.</summary>
public interface IOpdVisitHistoryApiClient
{
    Task<List<OpdVisitActivityDto>> ActivityAsync(int opdServiceId);
    /// <summary>The workflow as EMR.Api returns it (success, cancelled, steps, rework).</summary>
    Task<JsonElement> WorkflowAsync(int opdServiceId);
}

public class OpdVisitActivityDto
{
    public DateTime EventDate { get; set; }
    public string Source { get; set; } = "";
    public string? EventType { get; set; }
    public string ActionName { get; set; } = "";
    public string? Description { get; set; }
    public string? UserName { get; set; }
    public string? BranchName { get; set; }
    public string? IpAddress { get; set; }
    public string? MetadataJson { get; set; }
}

public class OpdVisitHistoryApiClient(IHttpClientFactory httpClientFactory) : IOpdVisitHistoryApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<List<OpdVisitActivityDto>> ActivityAsync(int opdServiceId)
    {
        var r = await Client.GetAsync($"api/opd-visits/{opdServiceId}/activity");
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<List<OpdVisitActivityDto>>() ?? [];
    }

    public async Task<JsonElement> WorkflowAsync(int opdServiceId)
    {
        var r = await Client.GetAsync($"api/opd-visits/{opdServiceId}/workflow");
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<JsonElement>();
    }
}
