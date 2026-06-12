using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading.Tasks;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients
{
    public class DoctorScheduleApiClient : IDoctorScheduleApiClient
    {
        private readonly HttpClient _http;

        public DoctorScheduleApiClient(IHttpClientFactory factory)
        {
            _http = factory.CreateClient("EmrApi");
        }

        public async Task<List<DoctorScheduleListItem>> GetByDoctorAsync(int doctorId, int? branchId = null)
        {
            var url = branchId.HasValue
                ? $"api/doctorschedules?doctorId={doctorId}&branchId={branchId}"
                : $"api/doctorschedules?doctorId={doctorId}";

            try
            {
                var response = await _http.GetFromJsonAsync<ApiResponse<List<DoctorScheduleListItem>>>(url);
                return response?.Data ?? new List<DoctorScheduleListItem>();
            }
            catch { return new List<DoctorScheduleListItem>(); }
        }

        public async Task<DoctorScheduleDetail?> GetByIdAsync(int scheduleId)
        {
            try
            {
                var response = await _http.GetFromJsonAsync<ApiResponse<DoctorScheduleDetail>>($"api/doctorschedules/{scheduleId}");
                return response?.Data;
            }
            catch { return null; }
        }

        public async Task<int?> UpsertAsync(DoctorScheduleUpsertRequest request)
        {
            try
            {
                HttpResponseMessage httpResponse;
                if (request.ScheduleId == 0)
                {
                    httpResponse = await _http.PostAsJsonAsync("api/doctorschedules", request);
                }
                else
                {
                    httpResponse = await _http.PutAsJsonAsync($"api/doctorschedules/{request.ScheduleId}", request);
                }

                if (!httpResponse.IsSuccessStatusCode) return null;

                var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<int>>();
                return result?.Success == true ? result.Data : null;
            }
            catch { return null; }
        }

        public async Task<(bool Success, string? Warning)> DeleteAsync(int scheduleId, int deletedBy)
        {
            try
            {
                var httpResponse = await _http.DeleteAsync($"api/doctorschedules/{scheduleId}?deletedBy={deletedBy}");
                if (!httpResponse.IsSuccessStatusCode) return (false, null);

                var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<dynamic>>();
                var warning = result?.Data?.GetProperty("warning").GetString(); // Using dynamic or JsonElement parsing if possible
                // Alternatively, string parsing
                return (result?.Success == true, warning);
            }
            catch { return (false, null); }
        }

        public async Task<AvailableSlotsResult?> GetAvailableSlotsAsync(int doctorId, int branchId, DateTime date)
        {
            try
            {
                var url = $"api/doctorschedules/availableslots?doctorId={doctorId}&branchId={branchId}&date={date:yyyy-MM-dd}";
                var response = await _http.GetFromJsonAsync<ApiResponse<AvailableSlotsResult>>(url);
                return response?.Data;
            }
            catch { return null; }
        }

        public async Task<List<DoctorScheduleExceptionListItem>> GetExceptionsAsync(int doctorId, int? branchId = null, DateTime? from = null, DateTime? to = null)
        {
            try
            {
                var url = $"api/doctorschedules/exceptions?doctorId={doctorId}";
                if (branchId.HasValue) url += $"&branchId={branchId}";
                if (from.HasValue) url += $"&from={from:yyyy-MM-dd}";
                if (to.HasValue) url += $"&to={to:yyyy-MM-dd}";

                var response = await _http.GetFromJsonAsync<ApiResponse<List<DoctorScheduleExceptionListItem>>>(url);
                return response?.Data ?? new List<DoctorScheduleExceptionListItem>();
            }
            catch { return new List<DoctorScheduleExceptionListItem>(); }
        }

        public async Task<int?> UpsertExceptionAsync(DoctorScheduleExceptionUpsertRequest request)
        {
            try
            {
                var httpResponse = await _http.PostAsJsonAsync("api/doctorschedules/exceptions", request);
                if (!httpResponse.IsSuccessStatusCode) return null;

                var result = await httpResponse.Content.ReadFromJsonAsync<ApiResponse<int>>();
                return result?.Success == true ? result.Data : null;
            }
            catch { return null; }
        }

        public async Task<bool> DeleteExceptionAsync(int exceptionId, int deletedBy)
        {
            try
            {
                var httpResponse = await _http.DeleteAsync($"api/doctorschedules/exceptions/{exceptionId}?deletedBy={deletedBy}");
                return httpResponse.IsSuccessStatusCode;
            }
            catch { return false; }
        }
    }
}
