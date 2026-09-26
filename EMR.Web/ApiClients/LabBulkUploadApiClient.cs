using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabBulkUploadApiClient(IHttpClientFactory factory) : ILabBulkUploadApiClient
{
    private HttpClient Client
    {
        get
        {
            var client = factory.CreateClient("EmrApi");
            client.Timeout = TimeSpan.FromMinutes(10); // large uploads run one save per row
            return client;
        }
    }

    public async Task<(byte[] Content, string FileName)> DownloadTemplateAsync(string module, bool withData, int companyId, int? branchId, bool isHO)
    {
        var url = $"api/lab-bulk-upload/{Uri.EscapeDataString(module)}/template?withData={withData.ToString().ToLower()}&companyId={companyId}&isHO={isHO.ToString().ToLower()}"
                  + (branchId.HasValue ? $"&branchId={branchId.Value}" : "");
        var res = await Client.GetAsync(url);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Failed to generate the template.");
        }
        var fileName = res.Content.Headers.ContentDisposition?.FileNameStar
                       ?? res.Content.Headers.ContentDisposition?.FileName?.Trim('"')
                       ?? $"{module}.xlsx";
        return (await res.Content.ReadAsByteArrayAsync(), fileName);
    }

    public async Task<LabBulkUploadResultModel> ImportAsync(string module, Stream file, string fileName, bool dryRun, int companyId, int? userId, int? branchId, bool isHO)
    {
        using var form = new MultipartFormDataContent();
        var fileContent = new StreamContent(file);
        fileContent.Headers.ContentType = new("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        form.Add(fileContent, "file", fileName);
        form.Add(new StringContent(dryRun.ToString().ToLower()), "dryRun");
        form.Add(new StringContent(companyId.ToString()), "companyId");
        form.Add(new StringContent(isHO.ToString().ToLower()), "isHO");
        if (userId.HasValue) form.Add(new StringContent(userId.Value.ToString()), "userId");
        if (branchId.HasValue) form.Add(new StringContent(branchId.Value.ToString()), "branchId");

        var res = await Client.PostAsync($"api/lab-bulk-upload/{Uri.EscapeDataString(module)}/import", form);
        if (!res.IsSuccessStatusCode)
        {
            var err = await res.Content.ReadFromJsonAsync<ApiResponse<object>>();
            throw new InvalidOperationException(err?.Message ?? "Bulk upload failed.");
        }
        var body = await res.Content.ReadFromJsonAsync<ApiResponse<LabBulkUploadResultModel>>();
        return body?.Data ?? throw new InvalidOperationException("Empty response from the bulk upload service.");
    }
}
