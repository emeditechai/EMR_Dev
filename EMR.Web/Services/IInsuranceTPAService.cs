using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public interface IInsuranceTPAService
{
    Task<IEnumerable<InsuranceTPAListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null,
        int? companyId = null);

    Task<InsuranceTPAMaster?> GetByIdAsync(int id);

    Task<bool> NameExistsAsync(string name, int? excludeId = null, int? branchId = null);

    Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? branchId = null);

    Task<string> GeneratePolicyPrefixAsync(string type, string? code = null);
}
