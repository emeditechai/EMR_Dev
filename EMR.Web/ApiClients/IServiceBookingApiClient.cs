using EMR.Web.ApiClients.Models;

namespace EMR.Web.ApiClients;

public interface IServiceBookingApiClient
{
    Task<ServiceBookingPagedResult> GetPagedAsync(
        int? branchId, DateOnly? fromDate, DateOnly? toDate,
        int page, int pageSize, string? search, string? paymentFilter = null);

    Task<ServiceBookingDetail?> GetByIdAsync(int opdServiceId);
    /// <summary>The doctor prescription pad of a visit (null = not found in the branch).</summary>
    Task<PrescriptionPadInfo?> GetPrescriptionPadAsync(int opdServiceId, int? branchId);
    Task<bool> UpdateStatusAsync(int opdServiceId, string status, int userId);
    Task<DoctorDashboardQueueResult?> GetDoctorQueueAsync(int branchId, int? doctorId, DateOnly? date);
}
