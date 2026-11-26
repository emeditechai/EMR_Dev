using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>EMR.Api api/doctor-signatures (SQLScripts/2559): the stored name of a doctor's signature image (Doctor Master).</summary>
public class DoctorSignatureApiClient(IHttpClientFactory factory)
{
    private HttpClient Client => factory.CreateClient("EmrApi");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>The doctor's stored signature file name, or null (none, or not a doctor of this company).</summary>
    public async Task<string?> GetAsync(int doctorId)
    {
        using var res = await Client.GetAsync($"api/doctor-signatures/{doctorId}");
        var body = await Read(res);
        return body.ValueKind == JsonValueKind.Object && body.TryGetProperty("SignaturePath", out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
    }

    /// <summary>Stores (or clears, with null) the name; returns (ok, error, previous name).</summary>
    public async Task<(bool Ok, string? Error, string? Previous)> SetAsync(int doctorId, string? signaturePath)
    {
        using var res = await Client.PostAsJsonAsync($"api/doctor-signatures/{doctorId}", new { signaturePath }, Json);
        var row = await Read(res);
        string? S(string n) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        var ok = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("Success", out var s) && s.ValueKind == JsonValueKind.True;
        return (ok, S("Error"), S("PreviousPath"));
    }

    private static async Task<JsonElement> Read(HttpResponseMessage res)
    {
        ApiResponse<JsonElement>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<JsonElement>>(Json); } catch (JsonException) { }
        if (!res.IsSuccessStatusCode || body is not { Success: true })
            throw new InvalidOperationException(body?.Message is { Length: > 0 } m ? m : $"Doctor signature API call failed ({(int)res.StatusCode}).");
        return body.Data;
    }
}
