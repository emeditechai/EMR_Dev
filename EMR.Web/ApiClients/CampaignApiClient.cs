using System.Text.Json;

namespace EMR.Web.ApiClients;

// Utility > Campaigns (SQLScripts/2299): EMR.Api api/campaigns (stored procedures usp_Campaign_*).

public class CampaignAudienceFilter
{
    /// <summary>ALL, FILTER or PICK (Ids).</summary>
    public string Mode { get; set; } = "ALL";
    public int? BranchId { get; set; }
    public string? Gender { get; set; }
    public int? AgeFrom { get; set; }
    public int? AgeTo { get; set; }
    public DateTime? VisitFrom { get; set; }
    public DateTime? VisitTo { get; set; }
    public DateTime? RegisteredFrom { get; set; }
    public DateTime? RegisteredTo { get; set; }
    public int? RoleId { get; set; }
    public int? SpecialityId { get; set; }
    public string? DoctorKind { get; set; }
    public List<int> Ids { get; set; } = [];
}

public class CampaignPerson
{
    public int RefId { get; set; }
    public string? Name { get; set; }
    public string? Email { get; set; }
    public string? Code { get; set; }
    public bool OptedOut { get; set; }
}

public class CampaignAudienceSummary
{
    public int Total { get; set; }
    public int Reachable { get; set; }
    public int NoEmail { get; set; }
    public int Unsubscribed { get; set; }
    public int SharedEmail { get; set; }
    public List<CampaignPerson> Sample { get; set; } = [];
}

public class CampaignRow
{
    public int CampaignId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public string Channel { get; set; } = "EMAIL";
    public string Status { get; set; } = "";
    public string Subject { get; set; } = "";
    public DateTime CreatedDate { get; set; }
    public DateTime? ScheduledAt { get; set; }
    public DateTime? StartedAt { get; set; }
    public DateTime? CompletedAt { get; set; }
    public int BranchId { get; set; }
    public string? BranchName { get; set; }
    public string? CreatedByName { get; set; }
    public int Total { get; set; }
    public int Sent { get; set; }
    public int Failed { get; set; }
    public int Skipped { get; set; }
    public int Pending { get; set; }
}

public class CampaignDetail : CampaignRow
{
    public string DesignJson { get; set; } = "";
    public string HtmlBody { get; set; } = "";
    public string SelectionMode { get; set; } = "ALL";
    public string? FilterJson { get; set; }
    public int? TemplateId { get; set; }
    public string? HospitalName { get; set; }
    public string? SenderEmail { get; set; }
}

public class CampaignTemplateRow
{
    public int TemplateId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public string Subject { get; set; } = "";
    public bool IsActive { get; set; }
    public DateTime CreatedDate { get; set; }
    public DateTime? ModifiedDate { get; set; }
    public int Used { get; set; }
}

public class CampaignListResult
{
    public List<CampaignRow> Campaigns { get; set; } = [];
    public List<CampaignTemplateRow> Templates { get; set; } = [];
}

public class CampaignBranchOption
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public bool IsHo { get; set; }
    public string? SenderEmail { get; set; }
    public string? HospitalName { get; set; }
}

public class CampaignOption
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
}

public class CampaignOptions
{
    public List<CampaignBranchOption> Branches { get; set; } = [];
    public List<CampaignOption> Roles { get; set; } = [];
    public List<CampaignOption> Specialities { get; set; } = [];
}

public class CampaignSaveRequest
{
    public int CampaignId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int UserId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public int? TemplateId { get; set; }
    public string Subject { get; set; } = "";
    public string DesignJson { get; set; } = "";
    public string HtmlBody { get; set; } = "";
    public CampaignAudienceFilter Filter { get; set; } = new();
    public string? BaseUrl { get; set; }
    public string Action { get; set; } = "draft";
    public DateTime? ScheduledAt { get; set; }
}

public class CampaignSaveResult
{
    public int CampaignId { get; set; }
    public int Queued { get; set; }
    public int Skipped { get; set; }
}

public class CampaignRecipient
{
    public string? Name { get; set; }
    public string? Email { get; set; }
    public string Status { get; set; } = "P";
    public string? Message { get; set; }
    public DateTime? SentAt { get; set; }
    public int Attempts { get; set; }
}

public class CampaignTemplate
{
    public int TemplateId { get; set; }
    public int CompanyId { get; set; }
    public int UserId { get; set; }
    public string Name { get; set; } = "";
    public string AudienceType { get; set; } = "P";
    public string Subject { get; set; } = "";
    public string DesignJson { get; set; } = "";
    public bool IsActive { get; set; } = true;
}

public class CampaignRunning
{
    public int CampaignId { get; set; }
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public string AudienceType { get; set; } = "P";
    public string Subject { get; set; } = "";
    public string HtmlBody { get; set; } = "";
    public string? BaseUrl { get; set; }
    public string HospitalName { get; set; } = "";
}

public class CampaignPending
{
    public long RecipientId { get; set; }
    public string? Email { get; set; }
    public string? FieldsJson { get; set; }
}

public interface ICampaignApiClient
{
    Task<CampaignListResult> ListAsync(int companyId, int branchId, bool allBranches);
    Task<CampaignDetail?> GetAsync(int campaignId, int companyId, int branchId, bool allBranches);
    Task<CampaignOptions> OptionsAsync(int companyId);
    Task<CampaignAudienceSummary> AudienceAsync(int companyId, string audienceType, CampaignAudienceFilter filter);
    Task<List<CampaignPerson>> SearchAsync(int companyId, string audienceType, string? term);
    Task<(CampaignSaveResult? Result, string? Error)> SaveAsync(CampaignSaveRequest request);
    Task<List<CampaignRecipient>> RecipientsAsync(int campaignId, int companyId, string? status, string? search);
    Task<int> ActionAsync(int campaignId, int companyId, int userId, string action);
    Task<CampaignTemplate?> TemplateGetAsync(int templateId, int companyId);
    Task<List<CampaignTemplateRow>> TemplateListAsync(int companyId, string audienceType);
    Task<(int TemplateId, string? Error)> TemplateSaveAsync(CampaignTemplate template);
    Task<int> TemplateDeleteAsync(int templateId, int companyId);
    // the sender
    Task<List<CampaignRunning>> SenderRunningAsync();
    Task<List<CampaignPending>> SenderNextAsync(int campaignId, int batch);
    Task<bool> SenderMarkAsync(long recipientId, bool sent, string? message);
    Task SenderFinishAsync(int campaignId);
    Task OptOutAsync(int companyId, int? campaignId, string email);
}

public class CampaignApiClient(IHttpClientFactory httpClientFactory) : ICampaignApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");
    private const string Base = "api/campaigns";

    private static async Task<string> ErrorOf(HttpResponseMessage response)
    {
        try
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            if (doc.RootElement.TryGetProperty("message", out var m) && m.GetString() is { Length: > 0 } msg) return msg;
        }
        catch (JsonException) { }
        return $"The campaign service answered {(int)response.StatusCode}.";
    }

    private async Task<T> GetJson<T>(string url) where T : new()
    {
        var r = await Client.GetAsync(url);
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<T>() ?? new T();
    }

    public Task<CampaignListResult> ListAsync(int companyId, int branchId, bool allBranches) =>
        GetJson<CampaignListResult>($"{Base}/list?companyId={companyId}&branchId={branchId}&allBranches={allBranches.ToString().ToLowerInvariant()}");

    public async Task<CampaignDetail?> GetAsync(int campaignId, int companyId, int branchId, bool allBranches)
    {
        var r = await Client.GetAsync($"{Base}/{campaignId}?companyId={companyId}&branchId={branchId}&allBranches={allBranches.ToString().ToLowerInvariant()}");
        if (r.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<CampaignDetail>();
    }

    public Task<CampaignOptions> OptionsAsync(int companyId) => GetJson<CampaignOptions>($"{Base}/options?companyId={companyId}");

    public async Task<CampaignAudienceSummary> AudienceAsync(int companyId, string audienceType, CampaignAudienceFilter filter)
    {
        var r = await Client.PostAsJsonAsync($"{Base}/audience", new { companyId, audienceType, filter });
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<CampaignAudienceSummary>() ?? new();
    }

    public Task<List<CampaignPerson>> SearchAsync(int companyId, string audienceType, string? term) =>
        GetJson<List<CampaignPerson>>($"{Base}/audience/search?companyId={companyId}&audienceType={Uri.EscapeDataString(audienceType)}&term={Uri.EscapeDataString(term ?? "")}");

    public async Task<(CampaignSaveResult? Result, string? Error)> SaveAsync(CampaignSaveRequest request)
    {
        var r = await Client.PostAsJsonAsync($"{Base}/save", request);
        return r.IsSuccessStatusCode ? (await r.Content.ReadFromJsonAsync<CampaignSaveResult>(), null) : (null, await ErrorOf(r));
    }

    public Task<List<CampaignRecipient>> RecipientsAsync(int campaignId, int companyId, string? status, string? search) =>
        GetJson<List<CampaignRecipient>>($"{Base}/{campaignId}/recipients?companyId={companyId}&status={Uri.EscapeDataString(status ?? "")}&search={Uri.EscapeDataString(search ?? "")}");

    public async Task<int> ActionAsync(int campaignId, int companyId, int userId, string action)
    {
        var r = await Client.PostAsJsonAsync($"{Base}/action", new { campaignId, companyId, userId, action });
        r.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await r.Content.ReadAsStringAsync());
        return doc.RootElement.GetProperty("affected").GetInt32();
    }

    public async Task<CampaignTemplate?> TemplateGetAsync(int templateId, int companyId)
    {
        var r = await Client.GetAsync($"{Base}/templates/{templateId}?companyId={companyId}");
        if (r.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadFromJsonAsync<CampaignTemplate>();
    }

    public Task<List<CampaignTemplateRow>> TemplateListAsync(int companyId, string audienceType) =>
        GetJson<List<CampaignTemplateRow>>($"{Base}/templates?companyId={companyId}&audienceType={Uri.EscapeDataString(audienceType)}");

    public async Task<(int TemplateId, string? Error)> TemplateSaveAsync(CampaignTemplate template)
    {
        var r = await Client.PostAsJsonAsync($"{Base}/templates", template);
        if (!r.IsSuccessStatusCode) return (0, await ErrorOf(r));
        using var doc = JsonDocument.Parse(await r.Content.ReadAsStringAsync());
        return (doc.RootElement.GetProperty("templateId").GetInt32(), null);
    }

    public async Task<int> TemplateDeleteAsync(int templateId, int companyId)
    {
        var r = await Client.PostAsync($"{Base}/templates/{templateId}/delete?companyId={companyId}", null);
        r.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await r.Content.ReadAsStringAsync());
        return doc.RootElement.GetProperty("affected").GetInt32();
    }

    public Task<List<CampaignRunning>> SenderRunningAsync() => GetJson<List<CampaignRunning>>($"{Base}/sender/running");

    public Task<List<CampaignPending>> SenderNextAsync(int campaignId, int batch) => GetJson<List<CampaignPending>>($"{Base}/sender/{campaignId}/next?batch={batch}");

    public async Task<bool> SenderMarkAsync(long recipientId, bool sent, string? message)
    {
        var r = await Client.PostAsJsonAsync($"{Base}/sender/mark", new { recipientId, status = sent ? "S" : "F", message });
        r.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await r.Content.ReadAsStringAsync());
        return doc.RootElement.GetProperty("stillSending").GetBoolean();
    }

    public async Task SenderFinishAsync(int campaignId) => (await Client.PostAsync($"{Base}/sender/{campaignId}/finish", null)).EnsureSuccessStatusCode();

    public async Task OptOutAsync(int companyId, int? campaignId, string email) =>
        (await Client.PostAsJsonAsync($"{Base}/opt-out", new { companyId, campaignId, email })).EnsureSuccessStatusCode();
}
