using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>
/// EMR.Api pharmacy endpoints (api/pharmacy/...). Shared by the pharmacy services of EMR.Web, which keep their
/// interfaces so the pharmacy controllers and views do not change. A failed call throws with the API's message.
/// </summary>
public class PharmacyApiClient(IHttpClientFactory factory)
{
    private HttpClient Client => factory.CreateClient("EmrApi");

    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<T> GetAsync<T>(string url)
    {
        using var res = await Client.GetAsync(url);
        return await ReadAsync<T>(res, url);
    }

    public async Task<T> PostAsync<T>(string url, object body)
    {
        using var res = await Client.PostAsJsonAsync(url, body, Json);
        return await ReadAsync<T>(res, url);
    }

    public async Task PostAsync(string url, object body)
    {
        using var res = await Client.PostAsJsonAsync(url, body, Json);
        await ReadAsync<JsonElement>(res, url);
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage res, string url)
    {
        ApiResponse<T>? body = null;
        try { body = await res.Content.ReadFromJsonAsync<ApiResponse<T>>(Json); } catch (JsonException) { }
        if (!res.IsSuccessStatusCode || body is not { Success: true })
            throw new InvalidOperationException(body?.Message is { Length: > 0 } m ? m : $"Pharmacy API call failed ({(int)res.StatusCode}): {url.Split('?')[0]}");
        return body.Data!;
    }

    /// <summary>A file (multipart) with form fields - the bill reader.</summary>
    public async Task<T> PostFileAsync<T>(string url, IFormFile file, params (string Name, string Value)[] fields)
    {
        using var content = new MultipartFormDataContent();
        foreach (var (n, v) in fields) content.Add(new StringContent(v), n);
        await using var stream = file.OpenReadStream();
        var part = new StreamContent(stream);
        part.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(string.IsNullOrEmpty(file.ContentType) ? "application/octet-stream" : file.ContentType);
        content.Add(part, "file", file.FileName);
        using var res = await Client.PostAsync(url, content);
        return await ReadAsync<T>(res, url);
    }

    public static string Q(params (string Name, object? Value)[] args) =>
        "?" + string.Join("&", args.Where(a => a.Value is not null && !(a.Value is string s && s.Length == 0))
            .Select(a => a.Name + "=" + Uri.EscapeDataString(a.Value switch
            {
                bool b => b ? "true" : "false",
                DateTime d => d.ToString("yyyy-MM-dd"),
                IFormattable fm => fm.ToString(null, System.Globalization.CultureInfo.InvariantCulture),
                _ => a.Value!.ToString()!
            })));

    /// <summary>A JSON value as the plain .NET value the views expect (bool, number, text, null).</summary>
    public static object? Plain(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined => null,
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number => v.TryGetInt32(out var i) ? (object)i : v.TryGetInt64(out var l) ? l : v.GetDecimal(),
        JsonValueKind.String => v.TryGetDateTime(out var d) && v.GetString()!.Length >= 19 ? (object)d : v.GetString(),
        _ => v.ToString()
    };
}
