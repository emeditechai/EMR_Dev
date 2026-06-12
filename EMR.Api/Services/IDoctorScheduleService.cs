using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public interface IDoctorScheduleService
    {
        Task<IEnumerable<DoctorScheduleListItem>> GetByDoctorAsync(int? doctorId, int? branchId, int? departmentId);
        Task<DoctorScheduleDetail?> GetByIdAsync(int scheduleId);
        Task<int> UpsertAsync(DoctorScheduleUpsertRequest request);
        Task<(bool Success, string? Warning)> DeleteAsync(int scheduleId, int deletedBy);
        Task<AvailableSlotsResult> GetAvailableSlotsAsync(int doctorId, int branchId, DateTime date);
        Task<IEnumerable<DoctorScheduleExceptionListItem>> GetExceptionsByDoctorAsync(int? doctorId, int? branchId, DateTime? from, DateTime? to, int? departmentId);
        Task<int> UpsertExceptionAsync(DoctorScheduleExceptionUpsertRequest request);
        Task<bool> DeleteExceptionAsync(int exceptionId, int deletedBy);
    }
}
