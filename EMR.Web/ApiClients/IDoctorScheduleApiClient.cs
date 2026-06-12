using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients
{
    public interface IDoctorScheduleApiClient
    {
        Task<List<DoctorScheduleListItem>> GetByDoctorAsync(int? doctorId, int? branchId = null, int? departmentId = null);
        Task<DoctorScheduleDetail?> GetByIdAsync(int scheduleId);
        Task<int?> UpsertAsync(DoctorScheduleUpsertRequest request);
        Task<(bool Success, string? Warning)> DeleteAsync(int scheduleId, int deletedBy);
        Task<AvailableSlotsResult?> GetAvailableSlotsAsync(int doctorId, int branchId, DateTime date);
        Task<List<DoctorScheduleExceptionListItem>> GetExceptionsAsync(int? doctorId, int? branchId = null, DateTime? from = null, DateTime? to = null, int? departmentId = null);
        Task<int?> UpsertExceptionAsync(DoctorScheduleExceptionUpsertRequest request);
        Task<bool> DeleteExceptionAsync(int exceptionId, int deletedBy);
    }
}
