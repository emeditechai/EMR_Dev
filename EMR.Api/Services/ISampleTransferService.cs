using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public interface ISampleTransferService
    {
        Task<SampleTransferHeaderListResult> GetEligibleSamplesAsync(
            int sourceBranchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "CollectionDate",
            string? transferStatusFilter = "Ready",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null);

        Task<ExecuteSampleTransferResponseDto> ExecuteTransferAsync(
            ExecuteSampleTransferRequestDto request,
            int userId);

        Task<List<SampleTransferAuditDto>> GetTransferHistoryAsync(
            int branchId,
            string? mode = "Outgoing",
            DateTime? fromDate = null,
            DateTime? toDate = null,
            string? search = null);

        Task<SampleTransferReceivableListResult> GetReceivableSamplesAsync(
            int targetBranchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "ReceivedDate",
            string? receiveStatusFilter = "Pending",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null);

        Task<ReceiveSampleTransferResponseDto> ReceiveSamplesAsync(
            ReceiveSampleTransferRequestDto request,
            int userId);

        Task<List<TargetBranchOptionDto>> GetTargetBranchesAsync(int currentBranchId);
        
        Task<List<SampleTransferEligibleItemDto>> GetWorksheetDataAsync(string sampleCollectionIds);
    }
}
