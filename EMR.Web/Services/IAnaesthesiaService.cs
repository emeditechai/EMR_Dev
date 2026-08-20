using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IAnaesthesiaService
{
    // Anaesthesia Types
    Task<AnaesthesiaTypeMaster?> GetTypeByIdAsync(int id);
    Task<AnaesthesiaTypeFormViewModel?> GetTypeFormModelByIdAsync(int id);
    Task<int> CreateTypeAsync(AnaesthesiaTypeFormViewModel model, int? userId);
    Task<bool> UpdateTypeAsync(AnaesthesiaTypeFormViewModel model, int? userId);
    Task<bool> ToggleTypeActiveAsync(int id, int? userId);
    Task<bool> DeleteTypeAsync(int id, int? userId);
    Task<bool> IsTypeCodeExistsAsync(string code, int branchId, int? excludeId = null);

    // Anaesthesia Rates
    Task<AnaesthesiaRateMaster?> GetRateByIdAsync(int id);
    Task<AnaesthesiaRateFormViewModel?> GetRateFormModelByIdAsync(int id);
    Task<int> CreateRateAsync(AnaesthesiaRateFormViewModel model, int? userId);
    Task<bool> UpdateRateAsync(AnaesthesiaRateFormViewModel model, int? userId);
    Task<bool> ToggleRateActiveAsync(int id, int? userId);
    Task<bool> DeleteRateAsync(int id, int? userId);
    Task<bool> HasActiveRateAsync(int branchId, int procedureId, int anaesthesiaTypeId, int? excludeId = null);

    // Dropdown helpers
    Task<List<SelectListItem>> GetProcedureOptionsAsync(int? selectedId = null, int? branchId = null);
    Task<List<SelectListItem>> GetAnaesthesiaTypeOptionsAsync(int? selectedId = null, int? branchId = null);
}
