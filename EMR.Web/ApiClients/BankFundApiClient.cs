using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>EMR.Api api/banks and api/funds (SQLScripts/2522). Rows as the procedures return them; a failed call throws with the API's message.</summary>
public class BankFundApiClient(IHttpClientFactory factory)
{
    private HttpClient Client => factory.CreateClient("EmrApi");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<JsonElement> GetAsync(string url)
    {
        using var res = await Client.GetAsync(url);
        return await ReadAsync(res);
    }

    public async Task<JsonElement> PostAsync(string url, object body)
    {
        using var res = await Client.PostAsJsonAsync(url, body, Json);
        return await ReadAsync(res);
    }

    private static async Task<JsonElement> ReadAsync(HttpResponseMessage res)
    {
        ApiResponse<JsonElement>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json); } catch (JsonException) { }
        if (!res.IsSuccessStatusCode || body is not { Success: true })
            throw new InvalidOperationException(body?.Message is { Length: > 0 } m ? m : $"The request failed ({(int)res.StatusCode}).");
        return body.Data;
    }
}
