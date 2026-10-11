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
    /// <summary>Heads of family only (patients registered with relation Self).</summary>
    Task<List<MembershipPatientSearchItemViewModel>> SearchPatientsAsync(int companyId, string search);
    /// <summary>The other patients registered on the head's mobile number, with their relation.</summary>
    Task<List<MembershipPatientSearchItemViewModel>> GetFamilyAsync(int companyId, int patientId);
    Task<MembershipCardIssueResultViewModel> IssueCardAsync(MembershipCardIssueViewModel model, List<MembershipCardMemberInput> members, int companyId, int branchId, int userId);
    /// <summary>Issues the next card in renewal of <paramref name="cardId"/>: same members, points carried forward. planId 0 keeps the plan.</summary>
    Task<MembershipCardIssueResultViewModel> RenewCardAsync(int cardId, int planId, int? paymentMethodId, string? transactionRef, string? remarks, int companyId, int branchId, int userId);
    Task<List<MembershipCardListItemViewModel>> GetCardsAsync(int companyId, int? branchId, int? planId, string? status, string? search, DateTime? fromDate, DateTime? toDate);
    Task<MembershipCardDetailViewModel?> GetCardAsync(int cardId, int companyId);
    Task AddMemberAsync(int cardId, int companyId, int branchId, int patientId, string? relation, int userId);
    Task SetCardStatusAsync(int cardId, int companyId, int branchId, string status, string? reason, int userId);
    Task MarkPrintedAsync(int cardId, int companyId, int userId);
    Task MarkSentAsync(int cardId, int companyId, string channel);
}
