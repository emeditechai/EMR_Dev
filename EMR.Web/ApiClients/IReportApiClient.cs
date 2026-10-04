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
    Task<ReportApiResult<List<DailyCollectionRegisterItem>>> GetDailyCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool isDetailed, int? companyId = null, string? moduleCode = null);
    Task<ReportApiResult<List<PatientRegisterItem>>> GetPatientRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly, int? companyId = null);
    Task<ReportApiResult<B2CCollectionRegisterResult>> GetLabB2CCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, int? paymentMethodId, int? collectedBy, string? search,
        int userId, bool isAdmin, bool isSuperAdmin);
    Task<ReportApiResult<DiscountRegisterResult>> GetLabDiscountRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, string? billingType,
        int? approvedBy, int? enteredBy, string? search, int userId, bool isAdmin, bool isSuperAdmin);
    /// <summary>Runs a registered LAB report on the API; returns its JSON (summary / groups / rows / options) unchanged.</summary>
    Task<ReportApiResult<string>> RunLabReportRawAsync(string report, IDictionary<string, string?> query);
    Task<ReportApiResult<string>> RunOpdReportRawAsync(string report, IDictionary<string, string?> query);
    /// <summary>LF-18 Owner MIS: the API's named result sets as raw JSON.</summary>
    Task<ReportApiResult<string>> GetLabOwnerMisRawAsync(IDictionary<string, string?> query);
    /// <summary>LR-13: "sent" (to the outside lab) or "received" (its result); the API validates and records it.</summary>
    Task<ReportApiResult<int>> LabOutsourceActionAsync(string action, LabOutsourceActionModel request);
}

/// <summary>LR-13 Mark sent / Mark result received for one billed outsourced test.</summary>
public sealed class LabOutsourceActionModel
{
    public int BranchId { get; set; }
    public int LabOrderId { get; set; }
    public string SampleIds { get; set; } = string.Empty;
    public string? OutsideLab { get; set; }
    public string? ExternalRefNo { get; set; }
    public DateTime? ActionOn { get; set; }
    public string? Remarks { get; set; }
    public int UserId { get; set; }
    public bool IsSuperAdmin { get; set; }
}
