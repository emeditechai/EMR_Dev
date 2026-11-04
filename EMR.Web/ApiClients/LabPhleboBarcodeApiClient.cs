using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

/// <summary>Master &gt; Lab Master &gt; Phlebotomist Barcode Assignment (api/lab-phlebo-barcode, SQLScripts/2401).</summary>
public interface ILabPhleboBarcodeApiClient
{
    Task<IEnumerable<LabPhleboBarcodePhlebotomistModel>> GetPhlebotomistsAsync(int companyId, int branchId);
    Task<IEnumerable<LabPhleboBarcodeSeriesModel>> GetSeriesListAsync(int branchId, int phlebotomistId);
    Task<LabPhleboBarcodeGeneratedModel> GenerateSeriesAsync(LabPhleboBarcodeGenerateRequest request);
    Task CancelSeriesAsync(int seriesId, LabPhleboBarcodeCancelRequest request);
    Task<IEnumerable<LabPhleboBarcodeModel>> GetSeriesBarcodesAsync(int branchId, int seriesId);
}

public class LabPhleboBarcodeApiClient(IHttpClientFactory httpClientFactory) : ILabPhleboBarcodeApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    private static async Task<string> ExtractErrorAsync(HttpResponseMessage response, string fallback)
    {
        try
        {
            var err = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
            return err?.TryGetValue("message", out var m) == true ? m?.ToString() ?? fallback : fallback;
        }
        catch
        {
            return fallback;
        }
    }

    public async Task<IEnumerable<LabPhleboBarcodePhlebotomistModel>> GetPhlebotomistsAsync(int companyId, int branchId)
    {
        var response = await Client.GetAsync($"api/lab-phlebo-barcode/phlebotomists?companyId={companyId}&branchId={branchId}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabPhleboBarcodePhlebotomistModel>>() ?? [];
    }

    public async Task<IEnumerable<LabPhleboBarcodeSeriesModel>> GetSeriesListAsync(int branchId, int phlebotomistId)
    {
        var response = await Client.GetAsync($"api/lab-phlebo-barcode/series?branchId={branchId}&phlebotomistId={phlebotomistId}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabPhleboBarcodeSeriesModel>>() ?? [];
    }

    public async Task<LabPhleboBarcodeGeneratedModel> GenerateSeriesAsync(LabPhleboBarcodeGenerateRequest request)
    {
        var response = await Client.PostAsJsonAsync("api/lab-phlebo-barcode/series/generate", request);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(await ExtractErrorAsync(response, "Failed to generate the barcode series."));
        return await response.Content.ReadFromJsonAsync<LabPhleboBarcodeGeneratedModel>()
            ?? throw new InvalidOperationException("The series was not generated.");
    }

    public async Task CancelSeriesAsync(int seriesId, LabPhleboBarcodeCancelRequest request)
    {
        var response = await Client.PostAsJsonAsync($"api/lab-phlebo-barcode/series/{seriesId}/cancel", request);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(await ExtractErrorAsync(response, "Failed to cancel the series."));
    }

    public async Task<IEnumerable<LabPhleboBarcodeModel>> GetSeriesBarcodesAsync(int branchId, int seriesId)
    {
        var response = await Client.GetAsync($"api/lab-phlebo-barcode/series/{seriesId}/barcodes?branchId={branchId}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabPhleboBarcodeModel>>() ?? [];
    }
}
