using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

/// <summary>Raised when the membership API refuses a request; the message is safe to show to the user.</summary>
public class MembershipApiException(string message) : Exception(message);

public interface IMembershipApiClient
{
    // Membership Plan master
    Task<List<MembershipPlanListItemViewModel>> GetPlansAsync(int companyId, bool? status = null, string? search = null);
    Task<MembershipPlanFormViewModel?> GetPlanAsync(int planId, int companyId);
    Task<MembershipBenefitScopesViewModel> GetBenefitScopesAsync(int companyId);
    Task<int> SavePlanAsync(MembershipPlanFormViewModel model, int companyId, int userId);
    /// <summary>True when the plan was removed, false when it was only deactivated (it has issued cards).</summary>
    Task<bool> DeletePlanAsync(int planId, int companyId, int userId);

    // Membership Cards
    Task<List<MembershipPatientSearchItemViewModel>> SearchPatientsAsync(int companyId, string search);
    Task<MembershipCardIssueResultViewModel> IssueCardAsync(MembershipCardIssueViewModel model, List<MembershipCardMemberInput> members, int companyId, int branchId, int userId);
    Task<List<MembershipCardListItemViewModel>> GetCardsAsync(int companyId, int? branchId, int? planId, string? status, string? search, DateTime? fromDate, DateTime? toDate);
    Task<MembershipCardDetailViewModel?> GetCardAsync(int cardId, int companyId);
    Task AddMemberAsync(int cardId, int companyId, int branchId, int patientId, string? relation, int userId);
    Task SetCardStatusAsync(int cardId, int companyId, int branchId, string status, string? reason, int userId);
    Task MarkPrintedAsync(int cardId, int companyId, int userId);
    Task MarkSentAsync(int cardId, int companyId, string channel);
}
