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
}
