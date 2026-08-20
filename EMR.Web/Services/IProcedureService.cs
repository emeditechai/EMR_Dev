using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IProcedureService
{
    Task<ProcedureMaster?> GetByIdAsync(int id);
    Task<List<ProcedureTariffMaster>> GetTariffsByProcedureIdAsync(int procedureId);
    Task<ProcedureFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(ProcedureFormViewModel model, int? userId);
    Task<bool> UpdateAsync(ProcedureFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> IsCodeExistsAsync(string code, int branchId, int? excludeId = null);
    Task<List<SelectListItem>> GetDepartmentOptionsAsync(int? selectedId = null);
    Task<List<SelectListItem>> GetSpecialityOptionsAsync(int? selectedId = null);
    List<SelectListItem> GetProcedureCategoryOptions(string? selected = null);
}
