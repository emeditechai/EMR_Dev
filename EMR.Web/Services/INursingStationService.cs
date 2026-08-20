using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface INursingStationService
{
    Task<IEnumerable<NursingStationListItemViewModel>> GetAllAsync(int? wardId = null, int? companyId = null, int? branchId = null);
    Task<NursingStationMaster?> GetByIdAsync(int id);
    Task<NursingStationDetailsViewModel?> GetDetailsByIdAsync(int id);
    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null);
    Task<int> CreateAsync(NursingStationMaster model, int? userId);
    Task UpdateAsync(NursingStationMaster model, int? userId);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? selectedWardId = null);
    Task<IEnumerable<SelectListItem>> GetNurseOptionsAsync(int? companyId = null, int? branchId = null, string? selectedNurse = null);
}
