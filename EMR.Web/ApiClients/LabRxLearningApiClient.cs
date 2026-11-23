using System.Net.Http.Json;
using System.Text.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Services.PrescriptionAssist;
using Microsoft.Extensions.Caching.Memory;

namespace EMR.Web.ApiClients;

/// <summary>
/// EMR.Api api/lab/rx-learning (SQLScripts/2439): what AI Prescription Assist has learnt from users (per company), cached
/// for two minutes, and recording new feedback. Learning never stops a reading: failures give an empty list.
/// </summary>
public class LabRxLearningApiClient(IHttpClientFactory factory, IMemoryCache cache, ILogger<LabRxLearningApiClient> logger)
{
    private HttpClient Client => factory.CreateClient("EmrApi");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static string Key(int companyId) => "rx-learned:" + companyId;

    public async Task<IReadOnlyList<LearnedPhrase>> GetAsync(int companyId)
    {
        if (cache.TryGetValue(Key(companyId), out IReadOnlyList<LearnedPhrase>? hit) && hit is not null) return hit;
        try
        {
            var body = await Client.GetFromJsonAsync<ApiResponse<List<LearnedPhrase>>>("api/lab/rx-learning", Json);
            IReadOnlyList<LearnedPhrase> list = body is { Success: true, Data: not null } ? body.Data : [];
            cache.Set(Key(companyId), list, new MemoryCacheEntryOptions { AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(2), Size = 1 });
            return list;
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or NotSupportedException)
        {
            logger.LogWarning(ex, "Prescription assist: learnt phrases not loaded");
            return [];
        }
    }

    public async Task<bool> LearnAsync(int companyId, IEnumerable<object> items)
    {
        try
        {
            using var res = await Client.PostAsJsonAsync("api/lab/rx-learning", new { Items = JsonSerializer.Serialize(items) }, Json);
            cache.Remove(Key(companyId));
            return res.IsSuccessStatusCode;
        }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "Prescription assist: feedback not recorded");
            return false;
        }
    }
}
