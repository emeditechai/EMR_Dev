using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

using Microsoft.Extensions.Logging;

namespace EMR.Web.ApiClients
{
    public class LabReportingApiClient : ILabReportingApiClient
    {
        private readonly HttpClient httpClient;
        private readonly ILogger<LabReportingApiClient> logger;

        public LabReportingApiClient(IHttpClientFactory factory, ILogger<LabReportingApiClient> logger)
        {
            httpClient = factory.CreateClient("EmrApi");
            this.logger = logger;
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
            int? subCategoryId = null,
            string? allowedDepartmentIds = null,
            string? reportingType = "Numeric")
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
            // null = unrestricted; otherwise only these departments ("" = none)
            if (allowedDepartmentIds != null) query += $"&restrictDepartments=true&allowedDepartmentIds={Uri.EscapeDataString(allowedDepartmentIds)}";
            if (!string.IsNullOrEmpty(reportingType)) query += $"&reportingType={Uri.EscapeDataString(reportingType)}";

            var response = await httpClient.GetAsync($"api/LabReporting/headers{query}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<LabReportingHeaderListResult>()
                   ?? new LabReportingHeaderListResult();
        }

        public async Task<LabReportingOrderDetailDto?> GetDetailAsync(int labOrderId, int? branchId = null, string? reportingType = "Numeric")
        {
            var query = new List<string>();
            if (branchId.HasValue) query.Add($"branchId={branchId.Value}");
            if (!string.IsNullOrWhiteSpace(reportingType)) query.Add($"reportingType={Uri.EscapeDataString(reportingType)}");
            var queryString = query.Count > 0 ? "?" + string.Join("&", query) : string.Empty;

            var url = $"api/LabReporting/detail/{labOrderId}{queryString}";
            var response = await httpClient.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<LabReportingOrderDetailDto>();
        }

        public async Task<List<LabReportSignoffLevelDto>> GetSignoffPanelAsync(int labOrderId, int? branchId = null, int? departmentId = null, string? reportingType = null)
        {
            var q = new List<string>();
            if (branchId.HasValue) q.Add($"branchId={branchId.Value}");
            if (departmentId.HasValue) q.Add($"departmentId={departmentId.Value}");
            if (!string.IsNullOrWhiteSpace(reportingType)) q.Add($"reportingType={Uri.EscapeDataString(reportingType)}");
            var url = $"api/LabReporting/signoff-panel/{labOrderId}" + (q.Count > 0 ? "?" + string.Join("&", q) : "");
            var response = await httpClient.GetAsync(url);
            if (!response.IsSuccessStatusCode) return [];
            return await response.Content.ReadFromJsonAsync<List<LabReportSignoffLevelDto>>() ?? [];
        }

        public async Task<int> RecordEntryApprovalAsync(int labOrderId, IEnumerable<long> sampleCollectionIds, int userId, int? branchId)
        {
            var response = await httpClient.PostAsJsonAsync("api/LabReporting/record-entry-approval",
                new { LabOrderId = labOrderId, SampleCollectionIds = sampleCollectionIds, UserId = userId, BranchId = branchId });
            if (!response.IsSuccessStatusCode) return 0;

            using var doc = System.Text.Json.JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            return doc.RootElement.TryGetProperty("recordedCount", out var c) ? c.GetInt32() : 0;
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
            if (!response.IsSuccessStatusCode)
            {
                var errorBody = await response.Content.ReadAsStringAsync();
                logger.LogError("Error in SaveEntryAsync (status {StatusCode}): {ErrorBody}", response.StatusCode, errorBody);
                return false;
            }

            var res = await response.Content.ReadFromJsonAsync<SaveEntryResponse>();
            return res?.isSuccess ?? false;
        }

        public async Task<bool> UpdateSampleStatusAsync(UpdateLabSampleStatusRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/LabReporting/update-sample-status", request);
            if (!response.IsSuccessStatusCode)
            {
                var errorBody = await response.Content.ReadAsStringAsync();
                logger.LogError("Error in UpdateSampleStatusAsync (status {StatusCode}): {ErrorBody}", response.StatusCode, errorBody);
                return false;
            }

            var res = await response.Content.ReadFromJsonAsync<SaveEntryResponse>();
            return res?.isSuccess ?? false;
        }

        public async Task<List<LabOrderActivityDto>> GetActivityHistoryAsync(int labOrderId)
        {
            var response = await httpClient.GetAsync($"api/LabReporting/activity-history/{labOrderId}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<List<LabOrderActivityDto>>()
                   ?? new List<LabOrderActivityDto>();
        }

        public async Task<LabReportPrintMetaDto?> GetPrintMetaAsync(int labOrderId)
        {
            var response = await httpClient.GetAsync($"api/LabReporting/print-meta/{labOrderId}");
            if (!response.IsSuccessStatusCode) return null;

            return await response.Content.ReadFromJsonAsync<LabReportPrintMetaDto>();
        }

        private class SaveEntryResponse
        {
            public bool isSuccess { get; set; }
            public int count { get; set; }
        }
    }
}
