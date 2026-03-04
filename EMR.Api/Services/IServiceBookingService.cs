using EMR.Api.Models;

namespace EMR.Api.Services;

public interface IServiceBookingService
{
    Task<ServiceBookingPagedResult> GetPagedAsync(
        int? branchId, DateTime? fromDate, DateTime? toDate,
        int page, int pageSize, string? search);

    Task<ServiceBookingDetail?> GetByIdAsync(int opdServiceId);
}
