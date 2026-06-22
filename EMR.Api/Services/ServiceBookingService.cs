using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class ServiceBookingService(IDbConnectionFactory db) : IServiceBookingService
{
    // ─── Paged list ───────────────────────────────────────────────────────────
    public async Task<ServiceBookingPagedResult> GetPagedAsync(
        int? branchId, DateTime? fromDate, DateTime? toDate,
        int page, int pageSize, string? search)
    {
        using var con = db.CreateConnection();

        var rows = (await con.QueryAsync<ServiceBookingListItem>(
            "usp_Api_ServiceBooking_GetByBranch",
            new
            {
                BranchId   = branchId,
                FromDate   = fromDate.HasValue ? (DateTime?)fromDate.Value.Date : null,
                ToDate     = toDate.HasValue   ? (DateTime?)toDate.Value.Date   : null,
                PageNumber = page,
                PageSize   = pageSize,
                Search     = search
            },
            commandType: System.Data.CommandType.StoredProcedure)).ToList();

        var first = rows.FirstOrDefault();
        return new ServiceBookingPagedResult
        {
            Items          = rows,
            TotalCount     = first?.TotalCount      ?? 0,
            TotalFeesAll   = first?.TotalFeesAll    ?? 0,
            RegisteredCount= first?.RegisteredCount ?? 0,
            CompletedCount = first?.CompletedCount  ?? 0,
            Page           = page,
            PageSize       = pageSize
        };
    }

    // ─── Detail (header + line items) ─────────────────────────────────────────
    public async Task<ServiceBookingDetail?> GetByIdAsync(int opdServiceId)
    {
        using var con = db.CreateConnection();

        using var multi = await con.QueryMultipleAsync(
            "usp_Api_ServiceBooking_GetById",
            new { OPDServiceId = opdServiceId },
            commandType: System.Data.CommandType.StoredProcedure);

        var header = await multi.ReadSingleOrDefaultAsync<ServiceBookingDetail>();
        if (header is null) return null;

        header.Items = (await multi.ReadAsync<ServiceBookingDetailItem>()).ToList();
        return header;
    }

    // ─── Update Status ────────────────────────────────────────────────────────
    public async Task<bool> UpdateStatusAsync(int opdServiceId, string status, int userId)
    {
        using var con = db.CreateConnection();
        var rowsAffected = await con.ExecuteAsync(
            "usp_Api_ServiceBooking_UpdateStatus",
            new { OPDServiceId = opdServiceId, Status = status, UserId = userId },
            commandType: System.Data.CommandType.StoredProcedure);
        
        return rowsAffected > 0;
    }

    // ─── Doctor Dashboard Queue ───────────────────────────────────────────────
    public async Task<DoctorDashboardQueueResult> GetDoctorDashboardQueueAsync(int branchId, int? doctorId, DateTime? date)
    {
        using var con = db.CreateConnection();

        using var multi = await con.QueryMultipleAsync(
            "usp_Api_DoctorDashboard_GetQueue",
            new
            {
                BranchId = branchId,
                DoctorId = doctorId,
                Date = date.HasValue ? (DateTime?)date.Value.Date : null
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var list = (await multi.ReadAsync<DoctorDashboardQueueItem>()).ToList();
        var stats = await multi.ReadSingleOrDefaultAsync<QueueStats>();

        return new DoctorDashboardQueueResult
        {
            Data = list,
            TotalWaiting = stats?.TotalWaiting ?? 0,
            TotalCompleted = stats?.TotalCompleted ?? 0
        };
    }

    private class QueueStats
    {
        public int TotalWaiting { get; set; }
        public int TotalCompleted { get; set; }
    }
}
