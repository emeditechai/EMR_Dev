using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using System.Threading.Tasks;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services
{
    public class DoctorScheduleService(IDbConnectionFactory db) : IDoctorScheduleService
    {
        public async Task<IEnumerable<DoctorScheduleListItem>> GetByDoctorAsync(int? doctorId, int? branchId, int? departmentId)
        {
            using var conn = db.CreateConnection();
            return await conn.QueryAsync<DoctorScheduleListItem>(
                "dbo.usp_Api_DoctorSchedule_GetByDoctor",
                new { DoctorId = doctorId, BranchId = branchId, DepartmentId = departmentId },
                commandType: CommandType.StoredProcedure);
        }

        public async Task<DoctorScheduleDetail?> GetByIdAsync(int scheduleId)
        {
            using var conn = db.CreateConnection();
            return await conn.QueryFirstOrDefaultAsync<DoctorScheduleDetail>(
                "dbo.usp_Api_DoctorSchedule_GetById",
                new { ScheduleId = scheduleId },
                commandType: CommandType.StoredProcedure);
        }

        public async Task<int> UpsertAsync(DoctorScheduleUpsertRequest request)
        {
            using var conn = db.CreateConnection();
            return await conn.ExecuteScalarAsync<int>(
                "dbo.usp_Api_DoctorSchedule_Upsert",
                request,
                commandType: CommandType.StoredProcedure);
        }

        public async Task<(bool Success, string? Warning)> DeleteAsync(int scheduleId, int deletedBy)
        {
            using var conn = db.CreateConnection();
            var p = new DynamicParameters();
            p.Add("@ScheduleId", scheduleId);
            p.Add("@DeletedBy", deletedBy);
            
            var result = await conn.QueryFirstOrDefaultAsync(
                "dbo.usp_Api_DoctorSchedule_Delete",
                p,
                commandType: CommandType.StoredProcedure);

            if (result == null) return (false, null);
            return ((int)result.Success == 1, (string?)result.Warning);
        }

        public async Task<AvailableSlotsResult> GetAvailableSlotsAsync(int doctorId, int branchId, DateTime date)
        {
            using var conn = db.CreateConnection();
            using var multi = await conn.QueryMultipleAsync(
                "dbo.usp_Api_DoctorSchedule_GetAvailableSlots",
                new { DoctorId = doctorId, BranchId = branchId, Date = date },
                commandType: CommandType.StoredProcedure);

            var exceptionStatus = await multi.ReadFirstAsync();
            var result = new AvailableSlotsResult
            {
                Date = date,
                DoctorId = doctorId,
                HasException = exceptionStatus.HasException == 1,
                ExceptionReason = exceptionStatus.ExceptionReason
            };

            var slots = await multi.ReadAsync<AvailableSlot>();
            result.Slots = slots.ToList();
            
            // Populate DoctorName for convenience if needed later, though not strictly required by SP
            return result;
        }

        public async Task<IEnumerable<DoctorScheduleExceptionListItem>> GetExceptionsByDoctorAsync(int? doctorId, int? branchId, DateTime? from, DateTime? to, int? departmentId)
        {
            using var conn = db.CreateConnection();
            return await conn.QueryAsync<DoctorScheduleExceptionListItem>(
                "dbo.usp_Api_DoctorScheduleException_GetByDoctor",
                new { DoctorId = doctorId, BranchId = branchId, FromDate = from, ToDate = to, DepartmentId = departmentId },
                commandType: CommandType.StoredProcedure);
        }

        public async Task<int> UpsertExceptionAsync(DoctorScheduleExceptionUpsertRequest request)
        {
            using var conn = db.CreateConnection();
            return await conn.ExecuteScalarAsync<int>(
                "dbo.usp_Api_DoctorScheduleException_Upsert",
                request,
                commandType: CommandType.StoredProcedure);
        }

        public async Task<bool> DeleteExceptionAsync(int exceptionId, int deletedBy)
        {
            using var conn = db.CreateConnection();
            var success = await conn.ExecuteScalarAsync<int>(
                "dbo.usp_Api_DoctorScheduleException_Delete",
                new { ExceptionId = exceptionId, DeletedBy = deletedBy },
                commandType: CommandType.StoredProcedure);
            return success == 1;
        }
    }
}
