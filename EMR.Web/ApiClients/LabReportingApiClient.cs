using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public class LabReportingApiClient : ILabReportingApiClient
    {
        private readonly HttpClient httpClient;

        public LabReportingApiClient(IHttpClientFactory factory)
        {
            httpClient = factory.CreateClient("EmrApi");
        }

        public async Task<LabReportingHeaderListResult> GetHeaderListAsync(
            int branchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "BookingDate",
            string? statusFilter = "All",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            string query = $"?branchId={branchId}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (!string.IsNullOrEmpty(dateFilterType)) query += $"&dateFilterType={Uri.EscapeDataString(dateFilterType)}";
            if (!string.IsNullOrEmpty(statusFilter)) query += $"&statusFilter={Uri.EscapeDataString(statusFilter)}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={Uri.EscapeDataString(search)}";
            if (departmentId.HasValue && departmentId.Value > 0) query += $"&departmentId={departmentId.Value}";
            if (categoryId.HasValue && categoryId.Value > 0) query += $"&categoryId={categoryId.Value}";
            if (subCategoryId.HasValue && subCategoryId.Value > 0) query += $"&subCategoryId={subCategoryId.Value}";

            var response = await httpClient.GetAsync($"api/LabReporting/headers{query}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<LabReportingHeaderListResult>()
                   ?? new LabReportingHeaderListResult();
        }

        public async Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId)
        {
            var response = await httpClient.GetAsync($"api/LabReporting/detail/{labOrderId}");
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<LabReportingOrderDetailDto>();
        }

        public async Task<List<LabReportStatusMasterDto>> GetStatusesAsync()
        {
            var response = await httpClient.GetAsync("api/LabReporting/statuses");
            if (!response.IsSuccessStatusCode) return new List<LabReportStatusMasterDto>();

            return await response.Content.ReadFromJsonAsync<List<LabReportStatusMasterDto>>()
                   ?? new List<LabReportStatusMasterDto>();
        }

        public async Task<bool> SaveEntryAsync(SaveLabReportingRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/LabReporting/save-entry", request);
            if (!response.IsSuccessStatusCode) return false;

            var res = await response.Content.ReadFromJsonAsync<SaveEntryResponse>();
            return res?.isSuccess ?? false;
        }

        private class SaveEntryResponse
        {
            public bool isSuccess { get; set; }
            public int count { get; set; }
        }
    }
}
