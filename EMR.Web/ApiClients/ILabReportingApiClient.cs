using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public interface ILabReportingApiClient
    {
        Task<LabReportingHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null);

        Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId);

        Task<List<LabReportStatusMasterDto>> GetStatusesAsync();

        Task<bool> SaveEntryAsync(SaveLabReportingRequestDto request);
    }
}
