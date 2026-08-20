using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public interface IProcedureTariffService
{
    Task<ProcedureTariffMaster?> GetByIdAsync(int id);
    Task<ProcedureTariffFormViewModel?> GetFormModelByIdAsync(int id);
    Task<int> CreateAsync(ProcedureTariffFormViewModel model, int? userId);
    Task<bool> UpdateAsync(ProcedureTariffFormViewModel model, int? userId);
    Task<bool> ToggleActiveAsync(int id, int? userId);
    Task<bool> DeleteAsync(int id, int? userId);
    Task<bool> HasActiveTariffAsync(int branchId, int tariffCategoryId, int procedureId, int? excludeId = null);
    Task<List<SelectListItem>> GetTariffCategoryOptionsAsync(int? selectedId = null, int? companyId = null, int? branchId = null);
    Task<List<SelectListItem>> GetProcedureOptionsAsync(int? selectedId = null, int? branchId = null);
}
