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
    Task<ReportApiResult<List<DailyCollectionRegisterItem>>> GetDailyCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool isDetailed);
    Task<ReportApiResult<List<PatientRegisterItem>>> GetPatientRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly);
}
