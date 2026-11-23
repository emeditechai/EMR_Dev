using System.Net;
using System.Net.Http.Json;

namespace EMR.Web.ApiClients;

/// <summary>Company > Remove data / Delete company (SQLScripts/2337): rows removed (or that would be) from one table.</summary>
public class CompanyPurgeResultRow
{
    public string TableName { get; set; } = "";
    public int Rows { get; set; }
}

public interface ICompanyPurgeApiClient
{
    /// <summary>Preview (rolled back) or remove a company's data: level TRANSACTIONS, ALL or DELETE.</summary>
    Task<(List<CompanyPurgeResultRow> Rows, string? Error)> PurgeAsync(int companyId, string level, bool preview, int? userId, int? branchId = null);
}

public class CompanyPurgeApiClient(IHttpClientFactory httpClientFactory) : ICompanyPurgeApiClient
{
    private sealed class Message { public string? message { get; set; } }

    public async Task<(List<CompanyPurgeResultRow> Rows, string? Error)> PurgeAsync(int companyId, string level, bool preview, int? userId, int? branchId = null)
    {
        var client = httpClientFactory.CreateClient("EmrApi");
        client.Timeout = TimeSpan.FromMinutes(30);
        var res = await client.PostAsJsonAsync("api/company-purge",
            new { CompanyId = companyId, Level = level, Preview = preview, UserId = userId, BranchId = branchId });
        if (res.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Forbidden)
        {
            string? msg = null;
            try { msg = (await res.Content.ReadFromJsonAsync<Message>())?.message; } catch { }
            return ([], msg ?? "The request was refused.");
        }
        res.EnsureSuccessStatusCode();
        return (await res.Content.ReadFromJsonAsync<List<CompanyPurgeResultRow>>() ?? [], null);
    }
}
