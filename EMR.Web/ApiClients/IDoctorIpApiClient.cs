using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IDoctorIpApiClient
{
    Task<IEnumerable<DoctorIpListModel>> GetListAsync(int? companyId, int? branchId, bool? status = null, string? search = null);
    Task<DoctorIpDetailModel?> GetByIdAsync(int id);
    Task<int> SaveAsync(DoctorIpSaveRequestModel req);
    Task ToggleStatusAsync(DoctorIpToggleStatusRequestModel req);
    Task DeleteAsync(int id, int? userId);

    Task<IEnumerable<DoctorIpSpecialityModel>> GetSpecialitiesAsync(int? companyId);
    Task<IEnumerable<DoctorIpLookupModel>> GetDoctorsAsync(int specialityId, int? companyId);
    Task<IEnumerable<DoctorIpItemModel>> GetItemsAsync(int? companyId);

    Task<DoctorIpAccessStatusModel> GetAccessStatusAsync(int companyId, int userId);
    Task<DoctorIpVerifyCodeResultModel> VerifyAccessCodeAsync(DoctorIpVerifyCodeRequestModel req);
    Task SetAccessCodeAsync(DoctorIpSetCodeRequestModel req);
}
