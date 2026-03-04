using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IServiceBookingApiClient
{
    Task<ServiceBookingPagedResult> GetPagedAsync(
        int? branchId, DateOnly? fromDate, DateOnly? toDate,
        int page, int pageSize, string? search);

    Task<ServiceBookingDetail?> GetByIdAsync(int opdServiceId);
}
