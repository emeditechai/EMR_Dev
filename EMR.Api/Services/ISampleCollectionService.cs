using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public interface ISampleCollectionService
    {
        Task<SampleCollectionHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType,
            string? statusFilter,
            string? search);

        Task<SampleCollectionOrderDetailDto?> GetDetailAsync(int labOrderId);

        Task<bool> UpdateStatusAsync(UpdateSampleCollectionStatusRequestDto request, int userId);

        Task<int> UpdateProfileStatusAsync(UpdateProfileSampleCollectionStatusRequestDto request, int userId);

        Task<int> CollectAllAsync(int labOrderId, int userId);

        Task<int> AutoCollectIfNotMandatoryAsync(int labOrderId, int userId);

        Task<List<SampleCollectionStatusMasterDto>> GetStatusesAsync();
    }
}
