using System.Net;
using System.Net.Http.Json;

namespace EMR.Web.ApiClients;

/// <summary>Utility > Print Templates (SQLScripts/2324): EMR.Api api/print-templates.</summary>
public interface IPrintTemplateApiClient
{
    Task<List<PrintTemplateRowDto>> ListAsync(int companyId);
    Task<PrintTemplateDetailDto?> GetAsync(int companyId, int templateId);
    Task<List<PrintTemplateAssignmentDto>> AssignmentsAsync(int companyId);
    Task<PrintTemplateResolvedDto?> ResolveAsync(int branchId, string kind);
    /// <summary>Returns the template id, or an error message.</summary>
    Task<(int? TemplateId, string? Error)> SaveAsync(int companyId, int templateId, string kind, string name, string draftJson, int userId);
    Task<(int? Version, string? Error)> PublishAsync(int companyId, int templateId, int userId);
    Task<string?> RestoreAsync(int companyId, int templateId, int versionNo, int userId);
    Task<string?> DeleteAsync(int companyId, int templateId, int userId);
    Task<string?> AssignAsync(int companyId, int branchId, string kind, int? templateId, int userId);
}

public class PrintTemplateRowDto
{
    public int TemplateId { get; set; }
    public string Kind { get; set; } = "";
    public string Name { get; set; } = "";
    public int Version { get; set; }
    public bool IsPublished { get; set; }
    public bool HasUnpublishedChanges { get; set; }
    public DateTime ModifiedDate { get; set; }
    public string? ModifiedByName { get; set; }
    public DateTime? PublishedDate { get; set; }
    public string? Branches { get; set; }
}

public class PrintTemplateDetailDto
{
    public int TemplateId { get; set; }
    public string Kind { get; set; } = "";
    public string Name { get; set; } = "";
    public string DraftJson { get; set; } = "{}";
    public string? LayoutJson { get; set; }
    public int Version { get; set; }
    public bool IsPublished { get; set; }
    public DateTime ModifiedDate { get; set; }
    public DateTime? PublishedDate { get; set; }
    public List<PrintTemplateVersionDto> Versions { get; set; } = [];
}

public class PrintTemplateVersionDto
{
    public int VersionNo { get; set; }
    public DateTime PublishedDate { get; set; }
    public string? PublishedByName { get; set; }
}

public class PrintTemplateAssignmentDto
{
    public int BranchId { get; set; }
    public string BranchName { get; set; } = "";
    public bool IsHOBranch { get; set; }
    public int? BillTemplateId { get; set; }
    public int? ReportTemplateId { get; set; }
}

public class PrintTemplateResolvedDto
{
    public int TemplateId { get; set; }
    public int Version { get; set; }
    public string LayoutJson { get; set; } = "{}";
}

public class PrintTemplateApiClient(IHttpClientFactory httpClientFactory) : IPrintTemplateApiClient
{
    private const string Base = "api/print-templates";
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    private sealed class Message { public string? message { get; set; } }

    private static async Task<string?> ErrorAsync(HttpResponseMessage res)
    {
        if (res.IsSuccessStatusCode) return null;
        if (res.StatusCode == HttpStatusCode.BadRequest)
            try { return (await res.Content.ReadFromJsonAsync<Message>())?.message ?? "The request was refused."; } catch { }
        res.EnsureSuccessStatusCode();
        return null;
    }

    public async Task<List<PrintTemplateRowDto>> ListAsync(int companyId) =>
        await Client.GetFromJsonAsync<List<PrintTemplateRowDto>>($"{Base}?companyId={companyId}") ?? [];

    public async Task<PrintTemplateDetailDto?> GetAsync(int companyId, int templateId)
    {
        var res = await Client.GetAsync($"{Base}/{templateId}?companyId={companyId}");
        if (res.StatusCode == HttpStatusCode.NotFound) return null;
        res.EnsureSuccessStatusCode();
        return await res.Content.ReadFromJsonAsync<PrintTemplateDetailDto>();
    }

    public async Task<List<PrintTemplateAssignmentDto>> AssignmentsAsync(int companyId) =>
        await Client.GetFromJsonAsync<List<PrintTemplateAssignmentDto>>($"{Base}/assignments?companyId={companyId}") ?? [];

    public async Task<PrintTemplateResolvedDto?> ResolveAsync(int branchId, string kind)
    {
        var res = await Client.GetAsync($"{Base}/resolve?branchId={branchId}&kind={Uri.EscapeDataString(kind)}");
        if (res.StatusCode is HttpStatusCode.NoContent or HttpStatusCode.NotFound) return null;
        res.EnsureSuccessStatusCode();
        return await res.Content.ReadFromJsonAsync<PrintTemplateResolvedDto>();
    }

    private sealed class SaveResult { public int templateId { get; set; } }
    private sealed class PublishResult { public int version { get; set; } }

    public async Task<(int? TemplateId, string? Error)> SaveAsync(int companyId, int templateId, string kind, string name, string draftJson, int userId)
    {
        var res = await Client.PostAsJsonAsync($"{Base}/save", new { companyId, templateId, kind, name, draftJson, userId });
        if (await ErrorAsync(res) is { } err) return (null, err);
        return ((await res.Content.ReadFromJsonAsync<SaveResult>())?.templateId, null);
    }

    public async Task<(int? Version, string? Error)> PublishAsync(int companyId, int templateId, int userId)
    {
        var res = await Client.PostAsJsonAsync($"{Base}/publish", new { companyId, templateId, userId });
        if (await ErrorAsync(res) is { } err) return (null, err);
        return ((await res.Content.ReadFromJsonAsync<PublishResult>())?.version, null);
    }

    public async Task<string?> RestoreAsync(int companyId, int templateId, int versionNo, int userId) =>
        await ErrorAsync(await Client.PostAsJsonAsync($"{Base}/restore", new { companyId, templateId, versionNo, userId }));

    public async Task<string?> DeleteAsync(int companyId, int templateId, int userId) =>
        await ErrorAsync(await Client.PostAsJsonAsync($"{Base}/delete", new { companyId, templateId, userId }));

    public async Task<string?> AssignAsync(int companyId, int branchId, string kind, int? templateId, int userId) =>
        await ErrorAsync(await Client.PostAsJsonAsync($"{Base}/assign", new { companyId, branchId, kind, templateId, userId }));
}
