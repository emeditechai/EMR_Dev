using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public interface ILabReportingService
    {
        Task<LabReportingHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType,
            string? statusFilter,
            string? search,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null);

        Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId);

        Task<List<LabReportStatusMasterDto>> GetStatusesAsync();

        Task<int> SaveEntryAsync(SaveLabReportingRequestDto request, int userId);
    }
}
