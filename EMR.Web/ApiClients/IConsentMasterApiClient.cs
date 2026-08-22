using EMR.Web.Models.ViewModels;

namespace EMR.Web.ApiClients;

public interface IConsentMasterApiClient
{
    Task<IEnumerable<ConsentMasterListItemViewModel>> GetConsentMastersAsync(
        int? branchId = null,
        string? type = null,
        string? consentType = null,
        string? language = null,
        int? procedureId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<ConsentMasterDetailsViewModel?> GetConsentMasterByIdAsync(int id);
    Task<int> CreateConsentMasterAsync(ConsentMasterFormViewModel model, int? userId);
    Task<bool> UpdateConsentMasterAsync(ConsentMasterFormViewModel model, int? userId);
    Task<bool> ToggleConsentMasterStatusAsync(int id, int? userId);
    Task<bool> DeleteConsentMasterAsync(int id);
    Task<IEnumerable<ConsentProcedureOptionViewModel>> GetProcedureOptionsAsync(int? branchId = null);
}
