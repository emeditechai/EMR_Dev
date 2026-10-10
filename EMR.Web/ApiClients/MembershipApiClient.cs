using System.Net;
using System.Text.Json;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public class MembershipApiClient : IMembershipApiClient
{
    private readonly HttpClient httpClient;

    public MembershipApiClient(IHttpClientFactory factory)
    {
        httpClient = factory.CreateClient("EmrApi");
    }

    // ── Membership Plan master ───────────────────────────────────────────────

    public async Task<List<MembershipPlanListItemViewModel>> GetPlansAsync(int companyId, bool? status = null, string? search = null)
    {
        var url = $"api/membership/plans?companyId={companyId}";
        if (status.HasValue) url += $"&status={status.Value}";
        if (!string.IsNullOrWhiteSpace(search)) url += $"&search={Uri.EscapeDataString(search)}";
        return await httpClient.GetFromJsonAsync<List<MembershipPlanListItemViewModel>>(url) ?? [];
    }

    public async Task<MembershipPlanFormViewModel?> GetPlanAsync(int planId, int companyId)
    {
        var response = await httpClient.GetAsync($"api/membership/plans/{planId}?companyId={companyId}");
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        await EnsureOkAsync(response);
        return await response.Content.ReadFromJsonAsync<MembershipPlanFormViewModel>();
    }

    public async Task<MembershipBenefitScopesViewModel> GetBenefitScopesAsync(int companyId) =>
        await httpClient.GetFromJsonAsync<MembershipBenefitScopesViewModel>($"api/membership/plans/benefit-scopes?companyId={companyId}") ?? new();

    public async Task<int> SavePlanAsync(MembershipPlanFormViewModel model, int companyId, int userId)
    {
        var payload = new
        {
            model.PlanId,
            CompanyId = companyId,
            model.PlanName,
            model.PlanType,
            model.CardFee,
            model.GstPercent,
            model.ValidityDays,
            model.MaxMembers,
            model.MinAge,
            model.WelcomePoints,
            model.PointsEarnPercent,
            model.PointValue,
            model.MaxRedeemPercent,
            model.PointsExpiryDays,
            model.FreeHomeCollection,
            model.Terms,
            model.IsActive,
            Benefits = model.Benefits.Select(b => new { b.Scope, b.ScopeRefId, b.DiscountFlag, b.DiscountValue, b.IsExcluded, b.FreeQuantity }),
            UserId = userId
        };
        var response = await httpClient.PostAsJsonAsync("api/membership/plans", payload);
        await EnsureOkAsync(response);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.GetProperty("id").GetInt32();
    }

    public async Task<bool> DeletePlanAsync(int planId, int companyId, int userId)
    {
        var response = await httpClient.DeleteAsync($"api/membership/plans/{planId}?companyId={companyId}&userId={userId}");
        await EnsureOkAsync(response);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.GetProperty("removed").GetBoolean();
    }

    // ── Membership Cards ─────────────────────────────────────────────────────

    public async Task<List<MembershipPatientSearchItemViewModel>> SearchPatientsAsync(int companyId, string search) =>
        await httpClient.GetFromJsonAsync<List<MembershipPatientSearchItemViewModel>>(
            $"api/membership/patients?companyId={companyId}&search={Uri.EscapeDataString(search ?? string.Empty)}") ?? [];

    public async Task<MembershipCardIssueResultViewModel> IssueCardAsync(MembershipCardIssueViewModel model, List<MembershipCardMemberInput> members, int companyId, int branchId, int userId)
    {
        var payload = new
        {
            CompanyId = companyId,
            BranchId = branchId,
            model.PlanId,
            model.PrimaryPatientId,
            ValidFrom = model.ValidFrom.Date,
            Members = members,
            model.PaymentMethodId,
            model.TransactionRef,
            model.Remarks,
            UserId = userId
        };
        var response = await httpClient.PostAsJsonAsync("api/membership/cards", payload);
        await EnsureOkAsync(response);
        return await response.Content.ReadFromJsonAsync<MembershipCardIssueResultViewModel>()
               ?? throw new MembershipApiException("The card was issued but the API returned no card number.");
    }

    public async Task<List<MembershipCardListItemViewModel>> GetCardsAsync(int companyId, int? branchId, int? planId, string? status, string? search, DateTime? fromDate, DateTime? toDate)
    {
        var query = new List<string> { $"companyId={companyId}" };
        if (branchId.HasValue) query.Add($"branchId={branchId.Value}");
        if (planId.HasValue) query.Add($"planId={planId.Value}");
        if (!string.IsNullOrWhiteSpace(status)) query.Add($"status={Uri.EscapeDataString(status)}");
        if (!string.IsNullOrWhiteSpace(search)) query.Add($"search={Uri.EscapeDataString(search)}");
        if (fromDate.HasValue) query.Add($"fromDate={fromDate.Value:yyyy-MM-dd}");
        if (toDate.HasValue) query.Add($"toDate={toDate.Value:yyyy-MM-dd}");
        return await httpClient.GetFromJsonAsync<List<MembershipCardListItemViewModel>>("api/membership/cards?" + string.Join("&", query)) ?? [];
    }

    public async Task<MembershipCardDetailViewModel?> GetCardAsync(int cardId, int companyId)
    {
        var response = await httpClient.GetAsync($"api/membership/cards/{cardId}?companyId={companyId}");
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        await EnsureOkAsync(response);
        return await response.Content.ReadFromJsonAsync<MembershipCardDetailViewModel>();
    }

    public async Task AddMemberAsync(int cardId, int companyId, int branchId, int patientId, string? relation, int userId) =>
        await EnsureOkAsync(await httpClient.PostAsJsonAsync($"api/membership/cards/{cardId}/members",
            new { CompanyId = companyId, BranchId = branchId, PatientId = patientId, Relation = relation, UserId = userId }));

    public async Task SetCardStatusAsync(int cardId, int companyId, int branchId, string status, string? reason, int userId) =>
        await EnsureOkAsync(await httpClient.PostAsJsonAsync($"api/membership/cards/{cardId}/status",
            new { CompanyId = companyId, BranchId = branchId, Status = status, Reason = reason, UserId = userId }));

    public async Task MarkPrintedAsync(int cardId, int companyId, int userId) =>
        await EnsureOkAsync(await httpClient.PostAsJsonAsync($"api/membership/cards/{cardId}/printed",
            new { CompanyId = companyId, UserId = userId }));

    public async Task MarkSentAsync(int cardId, int companyId, string channel) =>
        await EnsureOkAsync(await httpClient.PostAsJsonAsync($"api/membership/cards/{cardId}/sent",
            new { CompanyId = companyId, Channel = channel }));

    /// <summary>A 400 carries the business-rule message of the procedure; anything else is a plain failure.</summary>
    private static async Task EnsureOkAsync(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode) return;

        string? message = null;
        try
        {
            var body = await response.Content.ReadFromJsonAsync<JsonElement>();
            if (body.ValueKind == JsonValueKind.Object && body.TryGetProperty("message", out var m)) message = m.GetString();
        }
        catch (JsonException) { }

        if (response.StatusCode == HttpStatusCode.BadRequest && !string.IsNullOrWhiteSpace(message))
            throw new MembershipApiException(message);
        throw new HttpRequestException($"Membership API returned {(int)response.StatusCode}.");
    }
}
