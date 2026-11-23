using System.Net;
using System.Net.Http.Json;

namespace EMR.Web.ApiClients;

/// <summary>Company > Copy master data (SQLScripts/2328): one row of the preview / copy result.</summary>
public class CompanyCopyResultRow
{
    public string EntityKey { get; set; } = "";
    public string Entity { get; set; } = "";
    public int InSource { get; set; }
    public int Existing { get; set; }
    public int Copied { get; set; }
    public int Skipped { get; set; }
    public bool Auto { get; set; }
}

public interface ICompanyCopyApiClient
{
    /// <summary>Preview (rolled back) or copy the chosen LAB masters from the source company into the target.</summary>
    Task<(List<CompanyCopyResultRow> Rows, string? Error)> CopyLabMastersAsync(int sourceCompanyId, int targetCompanyId,
        IEnumerable<string> entities, bool preview, int? userId);
}

public class CompanyCopyApiClient(IHttpClientFactory httpClientFactory) : ICompanyCopyApiClient
{
    private sealed class Message { public string? message { get; set; } }

    public async Task<(List<CompanyCopyResultRow> Rows, string? Error)> CopyLabMastersAsync(int sourceCompanyId, int targetCompanyId,
        IEnumerable<string> entities, bool preview, int? userId)
    {
        var client = httpClientFactory.CreateClient("EmrApi");
        client.Timeout = TimeSpan.FromMinutes(10);
        var res = await client.PostAsJsonAsync("api/company-copy/lab-masters",
            new { SourceCompanyId = sourceCompanyId, TargetCompanyId = targetCompanyId, Entities = entities.ToList(), Preview = preview, UserId = userId });
        if (res.StatusCode == HttpStatusCode.BadRequest)
        {
            string? msg = null;
            try { msg = (await res.Content.ReadFromJsonAsync<Message>())?.message; } catch { }
            return ([], msg ?? "The copy was refused.");
        }
        res.EnsureSuccessStatusCode();
        return (await res.Content.ReadFromJsonAsync<List<CompanyCopyResultRow>>() ?? [], null);
    }
}
