using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public class LabFranchiseBarcodeApiClient(IHttpClientFactory httpClientFactory, ILogger<LabFranchiseBarcodeApiClient> logger) : ILabFranchiseBarcodeApiClient
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

    public async Task<IEnumerable<LabFranchiseBarcodeSeriesModel>> GetSeriesListAsync(int franchiseId)
    {
        var response = await Client.GetAsync($"api/lab-franchise-barcode/series/{franchiseId}");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabFranchiseBarcodeSeriesModel>>() ?? [];
    }

    public async Task<LabFranchiseBarcodeSeriesGeneratedModel> GenerateSeriesAsync(GenerateBarcodeSeriesRequestModel request)
    {
        var response = await Client.PostAsJsonAsync("api/lab-franchise-barcode/series/generate", request);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(await ExtractErrorAsync(response, "Failed to generate the barcode series."));

        return await response.Content.ReadFromJsonAsync<LabFranchiseBarcodeSeriesGeneratedModel>()
            ?? throw new InvalidOperationException("The series was not generated.");
    }

    public async Task CancelSeriesAsync(int seriesId, CancelBarcodeSeriesRequestModel request)
    {
        var response = await Client.PostAsJsonAsync($"api/lab-franchise-barcode/series/{seriesId}/cancel", request);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(await ExtractErrorAsync(response, "Failed to cancel the series."));
    }

    public async Task<IEnumerable<LabFranchiseBarcodePoolModel>> GetSeriesBarcodesAsync(int seriesId)
    {
        var response = await Client.GetAsync($"api/lab-franchise-barcode/series/{seriesId}/barcodes");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<IEnumerable<LabFranchiseBarcodePoolModel>>() ?? [];
    }

    public async Task<ValidateConsumeBarcodeResponseModel> ValidateAndConsumeAsync(ValidateConsumeBarcodeRequestModel request)
    {
        var response = await Client.PostAsJsonAsync("api/lab-franchise-barcode/pool/validate-consume", request);
        if (!response.IsSuccessStatusCode)
        {
            return new ValidateConsumeBarcodeResponseModel
            {
                Success = false,
                Message = await ExtractErrorAsync(response, "Unable to validate the barcode. Please try again."),
                BarcodeNo = request.BarcodeNo
            };
        }

        return await response.Content.ReadFromJsonAsync<ValidateConsumeBarcodeResponseModel>()
            ?? new ValidateConsumeBarcodeResponseModel { Success = false, Message = "Unexpected empty response.", BarcodeNo = request.BarcodeNo };
    }
}
