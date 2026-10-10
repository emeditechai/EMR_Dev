using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IDoctorIpCommissionApiClient
{
    Task<IEnumerable<DoctorIpCommissionPendingModel>> GetPendingAsync(int branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId);
    Task<IEnumerable<DoctorIpCommissionCalculateResultModel>> CalculateAsync(DoctorIpCommissionCalculateRequestModel req);
    Task<IEnumerable<DoctorIpCommissionListModel>> GetListAsync(int? branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId);
    Task<DoctorIpCommissionDetailModel?> GetDetailAsync(long id);
}
