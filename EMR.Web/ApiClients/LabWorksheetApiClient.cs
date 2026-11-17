using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>EMR.Api api/lab-worksheet (SQLScripts/2477). A failed call throws with the API's message.</summary>
public class LabWorksheetApiClient(IHttpClientFactory factory)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<List<JsonElement>> ListAsync(int branchId, string dateType, DateTime date, string channel, string values)
    {
        using var res = await factory.CreateClient("EmrApi").GetAsync("api/lab-worksheet" + IpdApiClient.Q(("branchId", branchId), ("dateType", dateType),
            ("date", date.ToString("yyyy-MM-dd")), ("channel", channel), ("values", values)));
        ApiResponse<JsonElement>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json); } catch (JsonException) { }
        if (!res.IsSuccessStatusCode || body is not { Success: true })
            throw new InvalidOperationException(body?.Message is { Length: > 0 } m ? m : $"Work sheet API call failed ({(int)res.StatusCode}).");
        return body.Data.ValueKind == JsonValueKind.Array ? body.Data.EnumerateArray().ToList() : [];
    }
}
