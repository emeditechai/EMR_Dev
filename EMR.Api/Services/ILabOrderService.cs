using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public interface ILabOrderService
    {
        Task<LabOrderResponse> CreateOrderAsync(LabOrderRequest request, int userId);
        Task<IEnumerable<AvailableInvestigationDto>> GetAvailableInvestigationsAsync(int branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null, string? rateType = "B2C", int? agentId = null);
        Task<IEnumerable<DepartmentDto>> GetDepartmentsAsync();
        Task<IEnumerable<CategoryDto>> GetCategoriesAsync(int? departmentId = null);
        Task<IEnumerable<SubCategoryDto>> GetSubCategoriesAsync(int? categoryId = null);
        /// <param name="dateType">'B' = range on the booking date, 'C' = on the bill (created) date; null = order date as before.</param>
        Task<LabOrderPagedResult> GetPagedOrdersAsync(int branchId, DateTime? fromDate, DateTime? toDate, string? search, int pageNumber, int pageSize, bool? isB2B = null, string? dateType = null, string? paymentFilter = null, string? agentType = null, int? agentId = null);
        Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId);
        Task<int> CreateSampleCollectionAsync(int labOrderId, int branchId, int companyId, int userId);
    }
}
