using EMR.Web.ApiClients.Models;
using EMR.Web.Models;

namespace EMR.Web.ApiClients;

public class ReportApiResult<T>
{
    public bool IsSuccess { get; set; }
    public T? Data { get; set; }
    public string? ErrorMessage { get; set; }
    
    public static ReportApiResult<T> SuccessResult(T data) => new() { IsSuccess = true, Data = data };
    public static ReportApiResult<T> FailureResult(string message) => new() { IsSuccess = false, ErrorMessage = message };
}

public interface IReportApiClient
{
    Task<ReportApiResult<List<DailyCollectionRegisterItem>>> GetDailyCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool isDetailed, int? companyId = null);
    Task<ReportApiResult<List<PatientRegisterItem>>> GetPatientRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly, int? companyId = null);
    Task<ReportApiResult<B2CCollectionRegisterResult>> GetLabB2CCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, int? paymentMethodId, int? collectedBy, string? search,
        int userId, bool isAdmin, bool isSuperAdmin);
    Task<ReportApiResult<DiscountRegisterResult>> GetLabDiscountRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, string? billingType,
        int? approvedBy, int? enteredBy, string? search, int userId, bool isAdmin, bool isSuperAdmin);
    /// <summary>Runs a registered LAB report on the API; returns its JSON (summary / groups / rows / options) unchanged.</summary>
    Task<ReportApiResult<string>> RunLabReportRawAsync(string report, IDictionary<string, string?> query);
}

