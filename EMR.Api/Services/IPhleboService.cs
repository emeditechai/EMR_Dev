using EMR.Api.Models;

namespace EMR.Api.Services;

/// <summary>The signed-in phlebotomist, always read from the token.</summary>
public sealed record PhleboCaller(int UserId, int CompanyId, int BranchId, string DeviceId);

public interface IPhleboService
{
    Task<string> GuardAsync(PhleboCaller caller);
    Task<string> RegisterDeviceAsync(PhleboCaller caller, PhleboDeviceRequest request);
    Task<object?> SessionAsync(PhleboCaller caller);
    Task<object?> PunchAsync(PhleboCaller caller, PhleboPunchRequest request);
    Task<int> SaveLocationAsync(PhleboCaller caller, IReadOnlyList<PhleboLocationPoint> points);
    Task<int> SaveDocumentAsync(PhleboCaller caller, int? visitId, string docType, IFormFile file, string? remarks);
    Task<object> VisitsAsync(PhleboCaller caller, DateTime? date);
    Task<object?> VisitAsync(PhleboCaller caller, int visitId);
    Task<object> RouteAsync(PhleboCaller caller, int visitId, double latitude, double longitude);
    Task<object?> VisitEventAsync(PhleboCaller caller, int visitId, PhleboEventRequest request);
    Task SendOtpAsync(PhleboCaller caller, int visitId);
    Task VerifyAsync(PhleboCaller caller, int visitId, PhleboVerifyRequest request);
    Task<object?> SamplesAsync(PhleboCaller caller, int visitId, PhleboSamplesRequest request);
    Task<object?> PaymentAsync(PhleboCaller caller, int visitId, PhleboPaymentRequest request);
    Task<object> SearchTestsAsync(PhleboCaller caller, int visitId, string search);
    Task<object?> CreateBillChangeAsync(PhleboCaller caller, PhleboBillChangeRequest request);
    Task<object> BillChangesAsync(PhleboCaller caller, int? visitId);
    Task<object?> HandoverAsync(PhleboCaller caller, PhleboHandoverRequest request);
    Task<object?> SummaryAsync(PhleboCaller caller);
    Task<object> CashCollectionAsync(PhleboCaller caller, DateTime? from, DateTime? to);
}
