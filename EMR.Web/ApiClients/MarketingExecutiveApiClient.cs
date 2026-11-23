using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>EMR.Api api/marketing-executives (SQLScripts/2440). Rows as the procedures return them; a failed call throws with the API's message.</summary>
public class MarketingExecutiveApiClient(IHttpClientFactory factory)
{
    private HttpClient Client => factory.CreateClient("EmrApi");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private const string Base = "api/marketing-executives";

    public async Task<JsonElement> GetAsync(string url = "")
    {
        using var res = await Client.GetAsync(Base + url);
        return await ReadAsync(res);
    }

    public async Task<JsonElement> PostAsync(string url, object body)
    {
        using var res = await Client.PostAsJsonAsync(Base + url, body, Json);
        return await ReadAsync(res);
    }

    private static async Task<JsonElement> ReadAsync(HttpResponseMessage res)
    {
        ApiResponse<JsonElement>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json); } catch (JsonException) { }
        if (!res.IsSuccessStatusCode || body is not { Success: true })
            throw new InvalidOperationException(body?.Message is { Length: > 0 } m ? m : $"Marketing executive API call failed ({(int)res.StatusCode}).");
        return body.Data;
    }
}
