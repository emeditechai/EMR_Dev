using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILoincTerminologyClient
{
    bool IsConfigured { get; }
    Task<TermOnlineResult> SearchAsync(string query, int rows, int offset, CancellationToken ct);
}

/// <summary>
/// Optional online lookup in the official LOINC Search API (https://loinc.regenstrief.org/searchapi/, basic
/// authentication with a free loinc.org account). Credentials stay on the server (appsettings "LoincSearchApi":
/// BaseUrl, Username, Password, TimeoutSeconds). Routine work never depends on it: the local repository is the source
/// for search and mapping; an outage only disables the "Online" tab.
/// </summary>
public class LoincSearchClient(IHttpClientFactory httpFactory, IConfiguration config, ILogger<LoincSearchClient> log) : ILoincTerminologyClient
{
    private string BaseUrl => (config["LoincSearchApi:BaseUrl"] is { Length: > 0 } b ? b : "https://loinc.regenstrief.org/searchapi/").TrimEnd('/') + "/";
    private string? User => config["LoincSearchApi:Username"];
    private string? Pass => config["LoincSearchApi:Password"];

    public bool IsConfigured => !string.IsNullOrWhiteSpace(User) && !string.IsNullOrWhiteSpace(Pass);

    public async Task<TermOnlineResult> SearchAsync(string query, int rows, int offset, CancellationToken ct)
    {
        if (!IsConfigured)
            return new TermOnlineResult { Configured = false, Message = "The LOINC Search API is not configured (LoincSearchApi:Username / Password in the API settings)." };
        try
        {
            var http = httpFactory.CreateClient("LoincSearch");
            http.Timeout = TimeSpan.FromSeconds(int.TryParse(config["LoincSearchApi:TimeoutSeconds"], out var t) && t > 0 ? t : 20);
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"{BaseUrl}loincs?query={Uri.EscapeDataString(query)}&rows={Math.Clamp(rows, 1, 100)}&offset={Math.Max(0, offset)}");
            req.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{User}:{Pass}")));
            req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var res = await http.SendAsync(req, ct);
            if (res.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                return new TermOnlineResult { Configured = true, Message = "The LOINC Search API refused the credentials (check the loinc.org user name / password)." };
            if (!res.IsSuccessStatusCode)
                return new TermOnlineResult { Configured = true, Message = $"The LOINC Search API answered {(int)res.StatusCode}. Use the local repository meanwhile." };

            using var doc = await JsonDocument.ParseAsync(await res.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            var root = doc.RootElement;
            var result = new TermOnlineResult { Configured = true, Success = true };
            if (Prop(root, "ResponseSummary") is { } sum && Prop(sum, "RecordsFound") is { } rf && rf.TryGetInt32(out var found)) result.TotalFound = found;
            if (Prop(root, "Results") is { ValueKind: JsonValueKind.Array } arr)
                foreach (var e in arr.EnumerateArray())
                {
                    string? S(string n) => Prop(e, n) is { } v ? (v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString()) : null;
                    var code = S("LOINC_NUM");
                    if (string.IsNullOrWhiteSpace(code)) continue;
                    result.Items.Add(new LoincConceptRow
                    {
                        LoincCode = code, LongCommonName = S("LONG_COMMON_NAME"), ShortName = S("SHORTNAME"), Component = S("COMPONENT"),
                        Property = S("PROPERTY"), TimeAspect = S("TIME_ASPCT"), SystemName = S("SYSTEM"), ScaleType = S("SCALE_TYP"),
                        MethodName = S("METHOD_TYP"), ClassName = S("CLASS"), ClassType = S("CLASSTYPE"), Status = S("STATUS")?.ToUpperInvariant(),
                        OrderObs = S("ORDER_OBS"), ExampleUcumUnits = S("EXAMPLE_UCUM_UNITS"), ExampleUnits = S("EXAMPLE_UNITS"),
                        VersionLastChanged = S("VersionLastChanged") ?? S("VERSIONLASTCHANGED")
                    });
                }
            if (result.TotalFound == 0) result.TotalFound = result.Items.Count;
            return result;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            log.LogWarning(ex, "LOINC Search API lookup failed");
            return new TermOnlineResult { Configured = true, Message = "The LOINC Search API could not be reached. The local repository keeps working." };
        }
    }

    private static JsonElement? Prop(JsonElement e, string name)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        foreach (var p in e.EnumerateObject())
            if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase)) return p.Value;
        return null;
    }
}
