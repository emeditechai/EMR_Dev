using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class DoctorIpCommissionService(IDbConnectionFactory db) : IDoctorIpCommissionService
{
    public async Task<IEnumerable<DoctorIpCommissionPendingItem>> GetPendingAsync(int branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpCommissionPendingItem>("usp_DoctorIpCommission_GetPending",
            new { BranchId = branchId, DoctorId = doctorId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorIpCommissionCalculateResult>> CalculateAsync(DoctorIpCommissionCalculateRequest req)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpCommissionCalculateResult>("usp_DoctorIpCommission_Calculate",
            new { req.BranchId, req.DoctorId, req.FromDate, req.ToDate, req.CompanyId, req.UserId, req.Source },
            commandType: CommandType.StoredProcedure, commandTimeout: 120);
    }

    public async Task<IEnumerable<DoctorIpCommissionListItem>> GetListAsync(int? branchId, int? doctorId, DateTime? fromDate, DateTime? toDate, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpCommissionListItem>("usp_DoctorIpCommission_GetList",
            new { BranchId = branchId, DoctorId = doctorId, FromDate = fromDate, ToDate = toDate, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorIpCommissionDetail?> GetDetailAsync(long commissionHdrId)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("usp_DoctorIpCommission_GetDetail",
            new { CommissionHdrId = commissionHdrId }, commandType: CommandType.StoredProcedure);
        var header = await multi.ReadFirstOrDefaultAsync<DoctorIpCommissionHeader>();
        if (header == null) return null;
        var details = (await multi.ReadAsync<DoctorIpCommissionDetailItem>()).ToList();
        return new DoctorIpCommissionDetail { Header = header, Details = details };
    }

    public async Task<IEnumerable<DoctorIpCommissionDueSchedule>> GetDueSchedulesAsync(DateTime today, int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpCommissionDueSchedule>("usp_DoctorIpCommission_GetDueSchedules",
            new { Today = today.Date, BranchId = branchId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorIpCommissionDueBranch>> GetDueBranchesAsync(DateTime now)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpCommissionDueBranch>("usp_DoctorIpCommission_GetDueBranches",
            new { Now = now }, commandType: CommandType.StoredProcedure);
    }

    public async Task<long?> StartRunAsync(int branchId, DateTime runDate)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<long?>("usp_DoctorIpCommission_StartRun",
            new { BranchId = branchId, RunDate = runDate.Date }, commandType: CommandType.StoredProcedure);
    }

    public async Task FinishRunAsync(long runId, int schedulesDue, int itemsComputed, decimal totalCommission, int failedCount, string? message)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_DoctorIpCommission_FinishRun",
            new { RunId = runId, SchedulesDue = schedulesDue, ItemsComputed = itemsComputed, TotalCommission = totalCommission, FailedCount = failedCount, Message = message },
            commandType: CommandType.StoredProcedure);
    }
}
