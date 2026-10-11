using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabMiscChargeApiClient
{
    Task<IEnumerable<LabMiscChargeModel>> GetListAsync(bool? status = null, string? chargeType = null, string? search = null, int? companyId = null);
    Task<LabMiscChargeModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabMiscChargeSaveRequestModel request);
    Task UpdateAsync(LabMiscChargeSaveRequestModel request);
    Task ToggleStatusAsync(LabMiscChargeToggleStatusRequestModel request);
    Task DeleteAsync(int id, int? userId = null);
}
