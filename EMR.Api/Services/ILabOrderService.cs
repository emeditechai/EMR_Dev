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
        Task<LabOrderPagedResult> GetPagedOrdersAsync(int branchId, DateTime? fromDate, DateTime? toDate, string? search, int pageNumber, int pageSize, bool? isB2B = null, string? dateType = null, string? paymentFilter = null, string? agentType = null, int? agentId = null, int? createdBy = null);
        Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId);
        Task<int> CreateSampleCollectionAsync(int labOrderId, int branchId, int companyId, int userId);
        /// <summary>The B2B partner's rate list in force and whether it is a government scheme (SQLScripts/2535).</summary>
        Task<LabB2BSchemeDto> GetB2BSchemeAsync(int branchId, string agentType, int agentId);
        /// <summary>Records the government scheme and Beneficiary ID on a saved B2B order; returns the scheme name or null.</summary>
        Task<string?> SetOrderSchemeAsync(int labOrderId, string? beneficiaryId);
        /// <summary>For the order lists: does each bill need a consent, and is one already on file (SQLScripts/2553).</summary>
        Task<IEnumerable<LabOrderConsentStatusDto>> GetConsentStatusAsync(string labOrderIds, int? branchId);
        /// <summary>Stores the path of a consent uploaded after billing (SQLScripts/2553).</summary>
        Task SaveConsentAsync(int labOrderId, string consentFilePath, int? branchId, int? userId);
        /// <summary>FORM F (PC-PNDT) fields of a bill; null when the bill does not need FORM F (SQLScripts/2554).</summary>
        Task<LabOrderFormFDto?> GetFormFAsync(int labOrderId, int? branchId);
        /// <summary>B2C bookings: can each be rescheduled, and why not (SQLScripts/2561).</summary>
        Task<IEnumerable<LabOrderRescheduleInfoDto>> GetRescheduleInfoAsync(string labOrderIds, int branchId);
        /// <summary>Moves a B2C booking to a new date / time (SQLScripts/2561); a refused rule throws SqlException 56600-56619.</summary>
        Task<LabOrderRescheduleResultDto?> RescheduleAsync(int labOrderId, LabOrderRescheduleRequest request);
        Task<IEnumerable<LabOrderRescheduleHistoryDto>> GetRescheduleHistoryAsync(int labOrderId, int branchId);
        Task SetRescheduleNotifiedAsync(int rescheduleId, LabOrderRescheduleNotifiedRequest request);
    }
}
