using EMR.Api.Models;

namespace EMR.Api.Services;

public interface ILabAntibioticService
{
    Task<IEnumerable<LabAntibioticListItem>> GetListAsync(bool? status, string? search, int? companyId);
    Task<LabAntibioticListItem?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabAntibioticCreateRequest req);
    Task UpdateAsync(LabAntibioticUpdateRequest req);
    Task ToggleStatusAsync(LabAntibioticToggleStatusRequest req);
    Task DeleteAsync(int id, int? userId);
}
