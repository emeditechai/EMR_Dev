using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IDoctorService
{
    Task<PagedResult<DoctorListItem>>  GetListAsync(int? companyId, int? branchId, string? searchQuery = null, int pageNumber = 1, int pageSize = 10);
    /// <summary>Doctor Master list with filters, KPI totals and filter options (SQLScripts/2315).</summary>
    Task<DoctorPagedList> GetPagedListAsync(int? companyId, int? branchId, string? search, string? status, string? referral,
        string? speciality, string? department, int? doctorId, int pageNumber, int pageSize);
    Task<DoctorDetail?>                GetByIdAsync(int doctorId, int? branchId = null, int? companyId = null);
    Task<int>                          CreateAsync(DoctorCreateRequest request);
    Task<bool>                         UpdateAsync(DoctorUpdateRequest request);
    
    Task<DoctorListItem?>              GetLinkedDoctorAsync(int userId, string? email, string? displayName);
}

