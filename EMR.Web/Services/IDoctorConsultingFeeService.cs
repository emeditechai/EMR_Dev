using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IDoctorConsultingFeeService
{
    /// <summary>All consulting-type services available for a branch.</summary>
    Task<IEnumerable<ConsultingServiceOptionDto>> GetConsultingServicesAsync(int branchId);

    /// <summary>All fee mappings currently assigned to a doctor (branch-scoped).</summary>
    Task<IEnumerable<ConsultingFeeItemDto>> GetByDoctorAsync(int doctorId, int branchId);

    /// <summary>Map a consulting service to a doctor. Ignores duplicate (ON CONFLICT).</summary>
    Task AddAsync(int doctorId, int serviceId, int branchId, int? userId);

    /// <summary>Remove a specific mapping.</summary>
    Task RemoveAsync(int mappingId, int doctorId, int branchId);
}
