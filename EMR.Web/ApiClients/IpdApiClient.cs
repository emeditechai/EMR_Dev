using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>
/// EMR.Api IPD endpoints (api/ipd/..., SQLScripts/2422-2424). Rows come back as JSON objects with the column names of
/// the stored procedures (PascalCase); the IPD screens read them as they are. A failed call throws with the API's message.
/// The API takes the company, branch and user from the signed-in user's token.
/// </summary>
public class IpdApiClient(IHttpClientFactory factory)
{
    private HttpClient Client => factory.CreateClient("EmrApi");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public const string Base = "api/ipd";

    public async Task<JsonElement> GetAsync(string url)
    {
        using var res = await Client.GetAsync(Base + url);
        return await ReadAsync(res, url);
    }

    public async Task<JsonElement> PostAsync(string url, object body)
    {
        using var res = await Client.PostAsJsonAsync(Base + url, body, Json);
        return await ReadAsync(res, url);
    }

    /// <summary>Result sets of a multi-set endpoint (empty list for a missing set).</summary>
    public async Task<List<JsonElement>> SetsAsync(string url)
    {
        var data = await GetAsync(url);
        return data.ValueKind == JsonValueKind.Array ? data.EnumerateArray().ToList() : new List<JsonElement>();
    }

    private static async Task<JsonElement> ReadAsync(HttpResponseMessage res, string url)
    {
        ApiResponse<JsonElement>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json); } catch (JsonException) { }
        if (!res.IsSuccessStatusCode || body is not { Success: true })
            throw new InvalidOperationException(body?.Message is { Length: > 0 } m ? m : $"IPD API call failed ({(int)res.StatusCode}): {url.Split('?')[0]}");
        return body.Data;
    }

    public static string Q(params (string Name, object? Value)[] args) => PharmacyApiClient.Q(args);
}
