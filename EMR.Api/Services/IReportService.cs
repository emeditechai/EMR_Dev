namespace EMR.Api.Services;

using EMR.Api.Models;

public interface IReportService
{
    Task<IEnumerable<DailyCollectionRegisterItem>> GetDailyCollectionRegisterAsync(int? companyId, int branchId, DateTime fromDate, DateTime toDate, bool isDetailed, string? moduleCode = null);
    Task<IEnumerable<PatientRegisterItem>> GetPatientRegisterAsync(int? companyId, int branchId, DateTime fromDate, DateTime toDate, bool dependentOnly);
    Task<B2CCollectionRegisterResult> GetLabB2CCollectionRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, int? paymentMethodId, int? collectedBy, string? search,
        int userId, bool isAdmin, bool isSuperAdmin);
    Task<DiscountRegisterResult> GetLabDiscountRegisterAsync(int branchId, DateTime fromDate, DateTime toDate, string? billingType,
        int? approvedBy, int? enteredBy, string? search, int userId, bool isAdmin, bool isSuperAdmin);
    /// <summary>Runs one of the registered LAB report procedures (summary / groups / rows / options result sets).</summary>
    Task<LabReportResult> RunLabReportAsync(string storedProcedure, IDictionary<string, object?> parameters);
    /// <summary>Runs a LAB procedure with several named result sets (e.g. LF-18 Owner MIS); each set is keyed by its name, in order.</summary>
    Task<Dictionary<string, List<Dictionary<string, object?>>>> RunLabSectionsAsync(string storedProcedure, IDictionary<string, object?> parameters, IReadOnlyList<string> sections);
    /// <summary>Runs a LAB register action procedure (e.g. LR-13 Mark sent); returns the rows it changed.</summary>
    Task<int> ExecuteLabActionAsync(string storedProcedure, IDictionary<string, object?> parameters);
}

