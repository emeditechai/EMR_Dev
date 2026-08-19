namespace EMR.Api.Services;

using EMR.Api.Models;

public interface IReportService
{
    Task<IEnumerable<DailyCollectionRegisterItem>> GetDailyCollectionRegisterAsync(int? companyId, int branchId, DateTime fromDate, DateTime toDate, bool isDetailed);
    Task<IEnumerable<PatientRegisterItem>> GetPatientRegisterAsync(int? companyId, int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly);
}

