using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

public interface ILabDefaultSignatoryApiClient
{
    Task<LabDefaultSignatoryListResult> GetListAsync(int branchId, int? companyId);
    /// <summary>Returns (savedCount, null) or (0, the rule message the API refused with).</summary>
    Task<(int Saved, string? Error)> SaveAsync(LabDefaultSignatorySaveRequest request);
}
