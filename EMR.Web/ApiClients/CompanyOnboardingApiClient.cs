using System.Net.Http.Json;

namespace EMR.Web.ApiClients;

/// <summary>Settings > Company Master > New Company wizard (SQLScripts/2306): EMR.Api api/company-onboarding.</summary>
public interface ICompanyOnboardingApiClient
{
    Task<List<CompanyOnboardTemplate>> TemplatesAsync();
    Task<CompanyOnboardCheck> CheckAsync(string? companyCode, string? branchCode, string? username, string? email = null);
    Task<(CompanyOnboardResult? Result, string? Error)> OnboardAsync(CompanyOnboardRequest request);
}

public class CompanyOnboardTemplate
{
    public int CompanyId { get; set; }
    public string CompanyCode { get; set; } = "";
    public string CompanyName { get; set; } = "";
    public int Menus { get; set; }
    public int Pages { get; set; }
    public int Roles { get; set; }
    public int AdminPermissions { get; set; }
}

public class CompanyOnboardCheck
{
    public bool CompanyCodeFree { get; set; }
    public bool BranchCodeFree { get; set; }
    public bool UsernameFree { get; set; }
    public bool EmailFree { get; set; } = true;
}

public class CompanyOnboardResult
{
    public int CompanyId { get; set; }
    public int BranchId { get; set; }
    public int HospitalSettingsId { get; set; }
    public int AdminRoleId { get; set; }
    public int UserId { get; set; }
    public int Menus { get; set; }
    public int Pages { get; set; }
    public int Controls { get; set; }
    public int Endpoints { get; set; }
    public int Roles { get; set; }
    public int Permissions { get; set; }
}

public class CompanyOnboardRequest
{
    public string CompanyCode { get; set; } = "";
    public string CompanyName { get; set; } = "";
    public string? LegalName { get; set; }
    public string? RegistrationNumber { get; set; }
    public string? GSTIN { get; set; }
    public string? PAN { get; set; }
    public string? Email { get; set; }
    public string? Phone { get; set; }
    public string? Website { get; set; }
    public string? Address { get; set; }
    public string? Country { get; set; }
    public string? State { get; set; }
    public string? City { get; set; }
    public string? Pincode { get; set; }
    public string? LogoPath { get; set; }
    public string BranchCode { get; set; } = "";
    public string BranchName { get; set; } = "";
    public string? BranchAddress { get; set; }
    public string? BranchCountry { get; set; }
    public string? BranchState { get; set; }
    public string? BranchCity { get; set; }
    public string? BranchPincode { get; set; }
    public bool BranchIsLab { get; set; } = true;
    public string HospitalName { get; set; } = "";
    public string? HospitalPhone { get; set; }
    public string? HospitalEmail { get; set; }
    public int? OpdRegistrationValidityDays { get; set; }
    public string AdminUsername { get; set; } = "";
    public string AdminFirstName { get; set; } = "";
    public string AdminLastName { get; set; } = "";
    public string? AdminEmail { get; set; }
    public string? AdminPhone { get; set; }
    public string? AdminEmployeeCode { get; set; }
    public string AdminPasswordHash { get; set; } = "";
    public string? AdminSalt { get; set; }
    public bool AdminMustChangePassword { get; set; } = true;
    public int TemplateCompanyId { get; set; }
    public bool CopyAdminPermissions { get; set; } = true;
    public bool CopyOtherRoles { get; set; } = true;
    public int? CreatedBy { get; set; }
}

public class CompanyOnboardingApiClient(IHttpClientFactory httpClientFactory) : ICompanyOnboardingApiClient
{
    private HttpClient Client => httpClientFactory.CreateClient("EmrApi");

    public async Task<List<CompanyOnboardTemplate>> TemplatesAsync() =>
        await Client.GetFromJsonAsync<List<CompanyOnboardTemplate>>("api/company-onboarding/templates") ?? [];

    public async Task<CompanyOnboardCheck> CheckAsync(string? companyCode, string? branchCode, string? username, string? email = null) =>
        await Client.GetFromJsonAsync<CompanyOnboardCheck>(
            $"api/company-onboarding/check?companyCode={Uri.EscapeDataString(companyCode ?? "")}&branchCode={Uri.EscapeDataString(branchCode ?? "")}&username={Uri.EscapeDataString(username ?? "")}&email={Uri.EscapeDataString(email ?? "")}")
        ?? new CompanyOnboardCheck { CompanyCodeFree = true, BranchCodeFree = true, UsernameFree = true, EmailFree = true };

    public async Task<(CompanyOnboardResult? Result, string? Error)> OnboardAsync(CompanyOnboardRequest request)
    {
        var r = await Client.PostAsJsonAsync("api/company-onboarding", request);
        if (r.IsSuccessStatusCode) return (await r.Content.ReadFromJsonAsync<CompanyOnboardResult>(), null);
        try
        {
            var body = await r.Content.ReadFromJsonAsync<System.Text.Json.JsonElement>();
            if (body.TryGetProperty("message", out var m)) return (null, m.GetString());
        }
        catch (System.Text.Json.JsonException) { }
        return (null, "The company could not be created. Nothing was saved.");
    }
}
