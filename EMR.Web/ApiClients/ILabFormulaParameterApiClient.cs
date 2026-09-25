using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface ILabFormulaParameterApiClient
{
    Task<IEnumerable<LabFormulaParameterModel>> GetListAsync(bool? status = null, string? search = null, int? companyId = null);
    Task<LabFormulaParameterModel?> GetByIdAsync(int id);
    Task<int> CreateAsync(LabFormulaParameterCreateRequestModel req);
    Task<bool> UpdateAsync(LabFormulaParameterUpdateRequestModel req);
    Task<bool> ToggleStatusAsync(LabFormulaParameterToggleStatusRequestModel req);
    Task<bool> DeleteAsync(int id);
    Task<IEnumerable<NumericTestItemModel>> GetNumericTestsAsync(int? companyId = null, string? search = null);

    /// <summary>Formulas whose target test is on this lab order (Report Entry screen).</summary>
    Task<IEnumerable<LabFormulaForOrderModel>> GetForOrderAsync(int labOrderId, int? companyId = null);

    /// <summary>Server-side calculation of every configured parameter of the order.</summary>
    Task<IEnumerable<LabFormulaEvaluationResultModel>> EvaluateAsync(LabFormulaEvaluateRequestModel req);
}
