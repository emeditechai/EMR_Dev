using System.Net.Http.Json;

namespace EMR.Web.ApiClients;

/// <summary>One bill per booking (SQLScripts/2310): EMR.Api api/billing-submissions.</summary>
public interface IBillingSubmissionApiClient
{
    Task<BillingSubmissionClaim> ClaimAsync(Guid requestKey, string moduleCode, int? userId);
    Task UpdateAsync(Guid requestKey, int moduleRefId, string? billNo, int? patientId, string? itemsSignature, string stage);
    Task ReleaseAsync(Guid requestKey);
}

public class BillingSubmissionClaim
{
    /// <summary>NEW (create the bill), EXISTS (reuse ModuleRefId), BUSY (being saved right now), INVALID.</summary>
    public string Status { get; set; } = "NEW";
    public int? ModuleRefId { get; set; }
    public string? BillNo { get; set; }
    public int? PatientId { get; set; }
    public string? ItemsSignature { get; set; }
    /// <summary>CREATED = the bill exists but its setup did not finish; READY = only the payment is left.</summary>
    public string? Stage { get; set; }
    public bool HasPayment { get; set; }
    public string? TokenNo { get; set; }
}

public class BillingSubmissionApiClient(IHttpClientFactory httpClientFactory) : IBillingSubmissionApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<BillingSubmissionClaim> ClaimAsync(Guid requestKey, string moduleCode, int? userId)
    {
        var r = await Client.PostAsJsonAsync("api/billing-submissions/claim", new { requestKey, moduleCode, userId });
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<BillingSubmissionClaim>() ?? new BillingSubmissionClaim();
    }

    public async Task UpdateAsync(Guid requestKey, int moduleRefId, string? billNo, int? patientId, string? itemsSignature, string stage)
    {
        var r = await Client.PostAsJsonAsync("api/billing-submissions/update", new { requestKey, moduleRefId, billNo, patientId, itemsSignature, stage });
        r.EnsureSuccessStatusCode();
    }

    public async Task ReleaseAsync(Guid requestKey)
    {
        var r = await Client.PostAsJsonAsync("api/billing-submissions/release", new { requestKey });
        r.EnsureSuccessStatusCode();
    }
}
