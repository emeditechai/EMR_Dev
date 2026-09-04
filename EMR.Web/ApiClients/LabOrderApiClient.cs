using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.Models.DTOs;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients
{
    public class LabOrderApiClient : ILabOrderApiClient
    {
        private readonly HttpClient httpClient;

        public LabOrderApiClient(IHttpClientFactory factory)
        {
            httpClient = factory.CreateClient("EmrApi");
        }

        public async Task<LabOrderResponseDto> CreateOrderAsync(LabOrderRequestDto request)
        {
            var response = await httpClient.PostAsJsonAsync("api/LabOrders", request);
            response.EnsureSuccessStatusCode();

            var result = await response.Content.ReadFromJsonAsync<ApiResponse<LabOrderResponseDto>>();
            return result?.Data;
        }

        public async Task<IEnumerable<AvailableInvestigationDto>> GetAvailableInvestigationsAsync(int branchId, int? departmentId, int? categoryId, int? subCategoryId, string? gender = null, int? ageInYears = null)
        {
            string query = $"?branchId={branchId}";
            if (departmentId.HasValue) query += $"&departmentId={departmentId.Value}";
            if (categoryId.HasValue) query += $"&categoryId={categoryId.Value}";
            if (subCategoryId.HasValue) query += $"&subCategoryId={subCategoryId.Value}";
            if (!string.IsNullOrEmpty(gender)) query += $"&gender={Uri.EscapeDataString(gender)}";
            if (ageInYears.HasValue) query += $"&ageInYears={ageInYears.Value}";

            var response = await httpClient.GetAsync($"api/LabOrders/available-investigations{query}");
            response.EnsureSuccessStatusCode();

            return await response.Content.ReadFromJsonAsync<IEnumerable<AvailableInvestigationDto>>();
        }

        public async Task<IEnumerable<DepartmentDto>> GetDepartmentsAsync()
        {
            var response = await httpClient.GetAsync("api/LabOrders/departments");
            response.EnsureSuccessStatusCode();
            return await response.Content.ReadFromJsonAsync<IEnumerable<DepartmentDto>>();
        }

        public async Task<IEnumerable<CategoryDto>> GetCategoriesAsync(int? departmentId = null)
        {
            var query = departmentId.HasValue ? $"?departmentId={departmentId}" : "";
            var response = await httpClient.GetAsync($"api/LabOrders/categories{query}");
            response.EnsureSuccessStatusCode();
            return await response.Content.ReadFromJsonAsync<IEnumerable<CategoryDto>>();
        }

        public async Task<IEnumerable<SubCategoryDto>> GetSubCategoriesAsync(int? categoryId = null)
        {
            var query = categoryId.HasValue ? $"?categoryId={categoryId}" : "";
            var response = await httpClient.GetAsync($"api/LabOrders/sub-categories{query}");
            response.EnsureSuccessStatusCode();
            return await response.Content.ReadFromJsonAsync<IEnumerable<SubCategoryDto>>();
        }

        public async Task<LabOrderPagedResult?> GetPagedOrdersAsync(int branchId, string? fromDate, string? toDate, string? search, int page = 1, int pageSize = 10)
        {
            string query = $"?branchId={branchId}&pageNumber={page}&pageSize={pageSize}";
            if (!string.IsNullOrEmpty(fromDate)) query += $"&fromDate={fromDate}";
            if (!string.IsNullOrEmpty(toDate)) query += $"&toDate={toDate}";
            if (!string.IsNullOrEmpty(search)) query += $"&search={System.Uri.EscapeDataString(search)}";

            var response = await httpClient.GetAsync($"api/LabOrders/paged{query}");
            response.EnsureSuccessStatusCode();
            return await response.Content.ReadFromJsonAsync<LabOrderPagedResult>();
        }

        public async Task<LabOrderDetailDto?> GetOrderDetailAsync(int labOrderId)
        {
            var response = await httpClient.GetAsync($"api/LabOrders/{labOrderId}");
            if (!response.IsSuccessStatusCode) return null;
            return await response.Content.ReadFromJsonAsync<LabOrderDetailDto>();
        }

        public async Task<bool> CreateSampleCollectionAsync(int labOrderId, int branchId, int companyId)
        {
            try
            {
                var response = await httpClient.PostAsync($"api/LabOrders/{labOrderId}/sample-collection?branchId={branchId}&companyId={companyId}", null);
                return response.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }
    }
}
