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
        Task<LabOrderPagedResult?> GetPagedOrdersAsync(int branchId, string? fromDate, string? toDate, string? search, int page = 1, int pageSize = 10, bool? isB2B = null);
        Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId);
        Task<bool> CreateSampleCollectionAsync(int labOrderId, int branchId, int companyId, int? userId = null);
    }
}
