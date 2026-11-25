using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public interface ILabOrderApiClient
    {
        Task<LabOrderResponseDto> CreateOrderAsync(LabOrderRequestDto request);
        Task<IEnumerable<AvailableInvestigationDto>> GetAvailableInvestigationsAsync(int branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null, string? rateType = "B2C", int? agentId = null);
        Task<IEnumerable<DepartmentDto>> GetDepartmentsAsync();
        Task<IEnumerable<CategoryDto>> GetCategoriesAsync(int? departmentId = null);
        Task<IEnumerable<SubCategoryDto>> GetSubCategoriesAsync(int? categoryId = null);
        Task<LabOrderPagedResult?> GetPagedOrdersAsync(int branchId, string? fromDate, string? toDate, string? search, int page = 1, int pageSize = 10, bool? isB2B = null, string? dateType = null, string? paymentFilter = null, string? agentType = null, int? agentId = null, int? createdBy = null);
        Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId);
        Task<bool> CreateSampleCollectionAsync(int labOrderId, int branchId, int companyId, int? userId = null);
        /// <summary>LAB B2B: the partner's rate list is a government scheme -> Beneficiary ID mandatory (SQLScripts/2535).</summary>
        Task<LabB2BSchemeDto> GetB2BSchemeAsync(int branchId, string agentType, int agentId);
        /// <summary>Records the government scheme and Beneficiary ID on a saved B2B order (SQLScripts/2535).</summary>
        Task SetOrderSchemeAsync(int labOrderId, string? beneficiaryId);
        /// <summary>Order lists: consent needed / on file for the given bills (SQLScripts/2553).</summary>
        Task<List<LabOrderConsentStatusDto>> GetConsentStatusAsync(IEnumerable<int> labOrderIds, int? branchId);
        /// <summary>Stores the path of a consent uploaded after billing; returns an error message or null (SQLScripts/2553).</summary>
        Task<string?> SaveConsentAsync(int labOrderId, string consentFilePath, int? branchId, int? userId);
        /// <summary>FORM F (PC-PNDT) fields of a bill; null when it does not need FORM F (SQLScripts/2554).</summary>
        Task<LabOrderFormFDto?> GetFormFAsync(int labOrderId, int? branchId);
    }
}
