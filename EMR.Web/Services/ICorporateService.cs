using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface ICorporateService
{
    Task<IEnumerable<CorporateListItemViewModel>> GetListAsync(int? branchId = null, string? type = null, bool? status = null, string? search = null, int? companyId = null);
    Task<CorporateMaster?> GetByIdAsync(int id);
    Task<bool> NameExistsAsync(string name, int? excludeId = null, int? branchId = null);
}
