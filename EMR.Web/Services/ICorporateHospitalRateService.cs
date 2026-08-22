using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface ICorporateHospitalRateService
{
    Task<IEnumerable<CorporateHospitalRateListItemViewModel>> GetListAsync(
        int? corporateId = null,
        int? branchId = null,
        string? rateServiceType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<CorporateHospitalRateListItemViewModel?> GetByIdAsync(int id);

    Task<IEnumerable<MasterServiceItemViewModel>> GetMasterItemsAsync(string? rateServiceType = null, int? branchId = null, int? companyId = null);
}
