using System.Net.Http.Json;
using EMR.Web.ApiClients.Models;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class ConsentMasterApiClient(IHttpClientFactory factory) : IConsentMasterApiClient
{
    private readonly HttpClient _http = factory.CreateClient("EmrApi");

    public async Task<IEnumerable<ConsentMasterListItemViewModel>> GetConsentMastersAsync(
        int? branchId = null,
        string? type = null,
        string? consentType = null,
        string? language = null,
        int? procedureId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        var queryParams = new List<string>();
        if (branchId.HasValue) queryParams.Add($"branchId={branchId.Value}");
        if (!string.IsNullOrWhiteSpace(type)) queryParams.Add($"type={Uri.EscapeDataString(type)}");
        if (!string.IsNullOrWhiteSpace(consentType)) queryParams.Add($"consentType={Uri.EscapeDataString(consentType)}");
        if (!string.IsNullOrWhiteSpace(language)) queryParams.Add($"language={Uri.EscapeDataString(language)}");
        if (procedureId.HasValue) queryParams.Add($"procedureId={procedureId.Value}");
        if (status.HasValue) queryParams.Add($"status={status.Value.ToString().ToLower()}");
        if (!string.IsNullOrWhiteSpace(search)) queryParams.Add($"search={Uri.EscapeDataString(search)}");
        if (companyId.HasValue) queryParams.Add($"companyId={companyId.Value}");

        var url = "api/consent-masters" + (queryParams.Count > 0 ? "?" + string.Join("&", queryParams) : "");
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ConsentMasterListItemViewModel>>>(url);
        return response?.Data ?? [];
    }

    public async Task<ConsentMasterDetailsViewModel?> GetConsentMasterByIdAsync(int id)
    {
        var response = await _http.GetFromJsonAsync<ApiResponse<ConsentMasterDetailsViewModel>>($"api/consent-masters/{id}");
        return response?.Data;
    }

    public async Task<int> CreateConsentMasterAsync(ConsentMasterFormViewModel model, int? userId)
    {
        var payload = new
        {
            model.CompanyId,
            model.Branch_ID,
            model.ConsentType,
            model.Type,
            model.Procedure_ID,
            model.Language,
            model.ConsentTemplateContent,
            model.Version,
            model.ValidityPeriod,
            model.WitnessRequired,
            model.Status,
            UserId = userId
        };

        var response = await _http.PostAsJsonAsync("api/consent-masters", payload);
        response.EnsureSuccessStatusCode();
        var result = await response.Content.ReadFromJsonAsync<ApiResponse<int>>();
        return result?.Data ?? 0;
    }

    public async Task<bool> UpdateConsentMasterAsync(ConsentMasterFormViewModel model, int? userId)
    {
        var payload = new
        {
            Consent_ID = model.Consent_ID,
            model.CompanyId,
            model.Branch_ID,
            model.ConsentType,
            model.Type,
            model.Procedure_ID,
            model.Language,
            model.ConsentTemplateContent,
            model.Version,
            model.ValidityPeriod,
            model.WitnessRequired,
            model.Status,
            UserId = userId
        };

        var response = await _http.PutAsJsonAsync($"api/consent-masters/{model.Consent_ID}", payload);
        return response.IsSuccessStatusCode;
    }

    public async Task<bool> ToggleConsentMasterStatusAsync(int id, int? userId)
    {
        var response = await _http.PostAsync($"api/consent-masters/{id}/toggle-status?userId={userId}", null);
        return response.IsSuccessStatusCode;
    }

    public async Task<bool> DeleteConsentMasterAsync(int id)
    {
        var response = await _http.DeleteAsync($"api/consent-masters/{id}");
        return response.IsSuccessStatusCode;
    }

    public async Task<IEnumerable<ConsentProcedureOptionViewModel>> GetProcedureOptionsAsync(int? branchId = null)
    {
        var url = "api/consent-masters/procedure-options" + (branchId.HasValue ? $"?branchId={branchId.Value}" : "");
        var response = await _http.GetFromJsonAsync<ApiResponse<List<ConsentProcedureOptionViewModel>>>(url);
        return response?.Data ?? [];
    }
}
