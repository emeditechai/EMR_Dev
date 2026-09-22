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

        /// <param name="branchId">
        /// Restricts the tests to the samples this branch holds (Report Entry screen). null = the whole bill (printing).
        /// </param>
        Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId, int? branchId = null);

        /// <summary>The per-level pathologist signatures for the report footer.</summary>
        Task<List<LabReportSignoffLevelDto>> GetSignoffPanelAsync(int labOrderId, int? branchId = null);

        /// <summary>Records an approval made on the Report Entry screen (so the printed signature follows that route).</summary>
        Task<int> RecordEntryApprovalAsync(int labOrderId, IEnumerable<long> sampleCollectionIds, int userId, int? branchId);

        Task<List<LabReportStatusMasterDto>> GetStatusesAsync();

        Task<bool> SaveEntryAsync(SaveLabReportingRequestDto request);
        Task<bool> UpdateSampleStatusAsync(UpdateLabSampleStatusRequestDto request);

        Task<List<LabOrderActivityDto>> GetActivityHistoryAsync(int labOrderId);

        Task<LabReportPrintMetaDto?> GetPrintMetaAsync(int labOrderId);
    }
}
