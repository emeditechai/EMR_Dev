using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public interface ISampleCollectionApiClient
    {
        Task<SampleCollectionHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null);

        Task<SampleCollectionOrderDetailDto?> GetDetailAsync(int labOrderId);

        Task<bool> UpdateStatusAsync(UpdateSampleCollectionStatusRequestDto request);

        Task<int> UpdateProfileStatusAsync(UpdateProfileSampleCollectionStatusRequestDto request);

        Task<int> CollectAllAsync(int labOrderId);

        Task<int> AutoCollectIfNotMandatoryAsync(int labOrderId);

        Task<List<SampleCollectionStatusMasterDto>> GetStatusesAsync();
    }
}
