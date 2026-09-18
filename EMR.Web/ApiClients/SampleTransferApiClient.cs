using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients
{
    public class SampleTransferApiClient : ISampleTransferApiClient
    {
        private readonly HttpClient _httpClient;

        public SampleTransferApiClient(IHttpClientFactory factory)
        {
            _httpClient = factory.CreateClient("EmrApi");
        }

        public async Task<SampleTransferHeaderListResult> GetEligibleSamplesAsync(
            int sourceBranchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "CollectionDate",
            string? transferStatusFilter = "Ready",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            string query = $"?sourceBranchId={sourceBranchId}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (!string.IsNullOrEmpty(dateFilterType)) query += $"&dateFilterType={Uri.EscapeDataString(dateFilterType)}";
            if (!string.IsNullOrEmpty(transferStatusFilter)) query += $"&transferStatusFilter={Uri.EscapeDataString(transferStatusFilter)}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={Uri.EscapeDataString(search)}";
            if (departmentId.HasValue && departmentId.Value > 0) query += $"&departmentId={departmentId.Value}";
            if (categoryId.HasValue && categoryId.Value > 0) query += $"&categoryId={categoryId.Value}";
            if (subCategoryId.HasValue && subCategoryId.Value > 0) query += $"&subCategoryId={subCategoryId.Value}";

            var response = await _httpClient.GetAsync($"api/SampleTransfer/eligible{query}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<SampleTransferHeaderListResult>()
                   ?? new SampleTransferHeaderListResult();
        }

        public async Task<ExecuteSampleTransferResponseDto> ExecuteTransferAsync(ExecuteSampleTransferRequestDto request)
        {
            var response = await _httpClient.PostAsJsonAsync("api/SampleTransfer/execute", request);
            if (response.IsSuccessStatusCode)
            {
                return await response.Content.ReadFromJsonAsync<ExecuteSampleTransferResponseDto>()
                       ?? new ExecuteSampleTransferResponseDto { IsSuccess = true };
            }

            try
            {
                var error = await response.Content.ReadFromJsonAsync<ExecuteSampleTransferResponseDto>();
                if (error != null) return error;
            }
            catch
            {
            }

            var rawErr = await response.Content.ReadAsStringAsync();
            return new ExecuteSampleTransferResponseDto
            {
                IsSuccess = false,
                Message = string.IsNullOrWhiteSpace(rawErr) ? "Transfer request failed." : rawErr
            };
        }

        public async Task<List<SampleTransferAuditDto>> GetTransferHistoryAsync(
            int branchId,
            string? mode = "Outgoing",
            DateTime? fromDate = null,
            DateTime? toDate = null,
            string? search = null)
        {
            string query = $"?branchId={branchId}";
            if (!string.IsNullOrEmpty(mode)) query += $"&mode={Uri.EscapeDataString(mode)}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={Uri.EscapeDataString(search)}";

            var response = await _httpClient.GetAsync($"api/SampleTransfer/history{query}");
            if (!response.IsSuccessStatusCode) return new List<SampleTransferAuditDto>();

            return await response.Content.ReadFromJsonAsync<List<SampleTransferAuditDto>>()
                   ?? new List<SampleTransferAuditDto>();
        }

        public async Task<List<TargetBranchOptionDto>> GetTargetBranchesAsync(int currentBranchId)
        {
            var response = await _httpClient.GetAsync($"api/SampleTransfer/target-branches?currentBranchId={currentBranchId}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<List<TargetBranchOptionDto>>()
                   ?? new List<TargetBranchOptionDto>();
        }

        public async Task<List<SampleTransferEligibleItemDto>> GetWorksheetDataAsync(string sampleCollectionIds)
        {
            if (string.IsNullOrWhiteSpace(sampleCollectionIds)) return new List<SampleTransferEligibleItemDto>();
            var response = await _httpClient.GetAsync($"api/SampleTransfer/worksheet-data?sampleCollectionIds={Uri.EscapeDataString(sampleCollectionIds)}");
            response.EnsureSuccessStatusCode();
            return await response.Content.ReadFromJsonAsync<List<SampleTransferEligibleItemDto>>()
                   ?? new List<SampleTransferEligibleItemDto>();
        }

        public async Task<SampleTransferReceivableListResult> GetReceivableSamplesAsync(
            int targetBranchId,
            DateTime? fromDate,
            DateTime? toDate,
            string? dateFilterType = "ReceivedDate",
            string? receiveStatusFilter = "Pending",
            string? search = null,
            int? departmentId = null,
            int? categoryId = null,
            int? subCategoryId = null)
        {
            string query = $"?targetBranchId={targetBranchId}";
            if (fromDate.HasValue) query += $"&fromDate={fromDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (toDate.HasValue) query += $"&toDate={toDate.Value:yyyy-MM-ddTHH:mm:ss}";
            if (!string.IsNullOrEmpty(dateFilterType)) query += $"&dateFilterType={Uri.EscapeDataString(dateFilterType)}";
            if (!string.IsNullOrEmpty(receiveStatusFilter)) query += $"&receiveStatusFilter={Uri.EscapeDataString(receiveStatusFilter)}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={Uri.EscapeDataString(search)}";
            if (departmentId.HasValue && departmentId.Value > 0) query += $"&departmentId={departmentId.Value}";
            if (categoryId.HasValue && categoryId.Value > 0) query += $"&categoryId={categoryId.Value}";
            if (subCategoryId.HasValue && subCategoryId.Value > 0) query += $"&subCategoryId={subCategoryId.Value}";

            var response = await _httpClient.GetAsync($"api/SampleTransfer/receivable{query}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<SampleTransferReceivableListResult>()
                   ?? new SampleTransferReceivableListResult();
        }

        public async Task<ReceiveSampleTransferResponseDto> ExecuteReceiveAsync(ReceiveSampleTransferRequestDto request)
        {
            var response = await _httpClient.PostAsJsonAsync("api/SampleTransfer/receive", request);
            if (response.IsSuccessStatusCode)
            {
                return await response.Content.ReadFromJsonAsync<ReceiveSampleTransferResponseDto>()
                       ?? new ReceiveSampleTransferResponseDto { IsSuccess = true };
            }

            try
            {
                var error = await response.Content.ReadFromJsonAsync<ReceiveSampleTransferResponseDto>();
                if (error != null) return error;
            }
            catch
            {
            }

            var rawErr = await response.Content.ReadAsStringAsync();
            return new ReceiveSampleTransferResponseDto
            {
                IsSuccess = false,
                Message = string.IsNullOrWhiteSpace(rawErr) ? "Receive request failed." : rawErr
            };
        }
    }
}
