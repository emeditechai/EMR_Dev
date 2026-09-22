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
            int? subCategoryId = null,
            string? allowedDepartmentIds = null);

        /// <param name="branchId">
        /// Show only the samples this branch holds (never-transferred booked here, or transferred here and received).
        /// null = every sample of the bill, which is what the printed report and the dispatch dashboard need.
        /// </param>
        Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId, int? branchId = null);

        /// <summary>The per-level pathologist signatures printed at the foot of the report.</summary>
        Task<List<LabReportSignoffLevelDto>> GetSignoffPanelAsync(int labOrderId, int? branchId = null);

        /// <summary>Records an approval made on the Lab Reporting Entry screen, so the print knows how it was approved.</summary>
        Task<int> RecordEntryApprovalAsync(int labOrderId, IEnumerable<long> sampleCollectionIds, int userId, int? branchId);

        Task<List<LabReportStatusMasterDto>> GetStatusesAsync();

        Task<int> SaveEntryAsync(SaveLabReportingRequestDto request, int userId);
        Task<int> UpdateSampleStatusAsync(UpdateLabSampleStatusRequestDto request, int userId);

        Task<List<LabOrderActivityDto>> GetActivityHistoryAsync(int labOrderId);

        Task<LabReportPrintMetaDto> GetPrintMetaAsync(int labOrderId);
    }
}
