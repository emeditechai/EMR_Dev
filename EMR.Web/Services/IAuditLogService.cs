namespace EMR.Web.Services;

public interface IAuditLogService
{
    Task LogAsync(string eventType, string actionName, string? description = null, int? userId = null, int? branchId = null);
}
