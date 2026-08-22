using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ICorporateHospitalRateService
{
    Task<IEnumerable<CorporateHospitalRateListItemDto>> GetListAsync(
        int? corporateId = null,
        int? branchId = null,
        string? rateServiceType = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<CorporateHospitalRateDetailDto?> GetByIdAsync(int id);

    Task<int> CreateAsync(CorporateHospitalRateSaveRequest request);

    Task<bool> UpdateAsync(int id, CorporateHospitalRateSaveRequest request);

    Task<bool> ToggleStatusAsync(int id, int? userId = null);

    Task<bool> DeleteAsync(int id, int? userId = null);

    Task<IEnumerable<MasterServiceItemDto>> GetMasterItemsAsync(string? rateServiceType = null, int? branchId = null, int? companyId = null);
}
