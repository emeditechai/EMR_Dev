namespace EMR.Web.Services;

public interface IAuditLogService
{
    Task LogAsync(string eventType, string actionName, string? description = null, int? userId = null, int? branchId = null);

    Task LogActivityAsync(
        string eventType,
        string actionName,
        string? description = null,
        int? userId = null,
        int? branchId = null,
        string? moduleCode = null,
        string? referenceNo = null,
        long? referenceId = null,
        string? patientCode = null,
        object? metadata = null);
}
