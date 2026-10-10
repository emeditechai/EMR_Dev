using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IMembershipService
{
    // Membership Plan master
    Task<IEnumerable<MembershipPlanListItem>> GetPlansAsync(int companyId, bool? status, string? search);
    Task<MembershipPlanDetail?> GetPlanAsync(int planId, int companyId);
    Task<MembershipBenefitScopes> GetBenefitScopesAsync(int companyId);
    Task<int> SavePlanAsync(MembershipPlanSaveRequest request);
    /// <summary>True when the plan was removed, false when it was only deactivated (it has issued cards).</summary>
    Task<bool> DeletePlanAsync(int planId, int companyId, int userId);

    // Membership Cards
    Task<IEnumerable<MembershipPatientSearchItem>> SearchPatientsAsync(int companyId, string search);
    Task<MembershipCardIssueResult> IssueCardAsync(MembershipCardIssueRequest request);
    Task<IEnumerable<MembershipCardListItem>> GetCardsAsync(int companyId, int? branchId, int? planId, string? status, string? search, DateTime? fromDate, DateTime? toDate);
    Task<MembershipCardDetail?> GetCardAsync(int cardId, int companyId);
    Task AddMemberAsync(int cardId, MembershipCardAddMemberRequest request);
    Task SetCardStatusAsync(int cardId, MembershipCardStatusRequest request);
    Task MarkPrintedAsync(int cardId, int companyId, int userId);
    Task MarkSentAsync(int cardId, int companyId, string channel);
}
