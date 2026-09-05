using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public class SampleCollectionApiClient : ISampleCollectionApiClient
    {
        private readonly HttpClient httpClient;

        public SampleCollectionApiClient(IHttpClientFactory factory)
        {
            httpClient = factory.CreateClient("EmrApi");
        }

        public async Task<SampleCollectionHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null)
        {
            string query = $"?branchId={branchId}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (!string.IsNullOrEmpty(dateFilterType)) query += $"&dateFilterType={Uri.EscapeDataString(dateFilterType)}";
            if (!string.IsNullOrEmpty(statusFilter)) query += $"&statusFilter={Uri.EscapeDataString(statusFilter)}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={Uri.EscapeDataString(search)}";

            var response = await httpClient.GetAsync($"api/SampleCollection/headers{query}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<SampleCollectionHeaderListResult>()
                   ?? new SampleCollectionHeaderListResult();
        }

        public async Task<SampleCollectionOrderDetailDto?> GetDetailAsync(int labOrderId)
        {
            var response = await httpClient.GetAsync($"api/SampleCollection/detail/{labOrderId}");
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<SampleCollectionOrderDetailDto>();
        }

        public async Task<bool> UpdateStatusAsync(UpdateSampleCollectionStatusRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/SampleCollection/update-status", request);
            if (!response.IsSuccessStatusCode) return false;

            var res = await response.Content.ReadFromJsonAsync<StatusUpdateResponse>();
            return res?.isSuccess ?? false;
        }

        public async Task<int> UpdateProfileStatusAsync(UpdateProfileSampleCollectionStatusRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/SampleCollection/update-profile-status", request);
            if (!response.IsSuccessStatusCode) return 0;

            var res = await response.Content.ReadFromJsonAsync<CollectAllResponse>();
            return res?.count ?? 0;
        }

        public async Task<int> CollectAllAsync(int labOrderId)
        {
            var response = await httpClient.PostAsJsonAsync("api/SampleCollection/collect-all", new CollectAllSamplesRequestDto { LabOrderId = labOrderId });
            if (!response.IsSuccessStatusCode) return 0;

            var res = await response.Content.ReadFromJsonAsync<CollectAllResponse>();
            return res?.count ?? 0;
        }

        public async Task<int> AutoCollectIfNotMandatoryAsync(int labOrderId)
        {
            var response = await httpClient.PostAsJsonAsync("api/SampleCollection/auto-collect-if-not-mandatory", new CollectAllSamplesRequestDto { LabOrderId = labOrderId });
            if (!response.IsSuccessStatusCode) return 0;

            var res = await response.Content.ReadFromJsonAsync<CollectAllResponse>();
            return res?.count ?? 0;
        }

        public async Task<List<SampleCollectionStatusMasterDto>> GetStatusesAsync()
        {
            var response = await httpClient.GetAsync("api/SampleCollection/statuses");
            if (!response.IsSuccessStatusCode) return new List<SampleCollectionStatusMasterDto>();

            return await response.Content.ReadFromJsonAsync<List<SampleCollectionStatusMasterDto>>()
                   ?? new List<SampleCollectionStatusMasterDto>();
        }

        private class StatusUpdateResponse
        {
            public bool isSuccess { get; set; }
        }

        private class CollectAllResponse
        {
            public bool isSuccess { get; set; }
            public int count { get; set; }
        }
    }
}
