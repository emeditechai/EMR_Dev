using EMR.Web.Models.DTOs;

namespace EMR.Web.ApiClients;

/// <summary>Critical value communication record (EMR.Api api/lab-critical, SQLScripts/2202).</summary>
public interface ILabCriticalApiClient
{
    /// <summary>Critical results of a bill with their communication state, contacts and history, as raw JSON.</summary>
    Task<(string? Json, string? Error)> GetPendingRawAsync(int branchId, int labOrderId, IEnumerable<long>? sampleIds, string context,
        int userId, bool isSuperAdmin);

    Task<(List<LabCriticalRecordedDto>? Rows, string? Error)> RecordAsync(LabCriticalRecordRequestDto request);

    /// <summary>The message refusing the sign-off, or null when nothing blocks it (an unverifiable check also refuses).</summary>
    Task<string?> GetSignoffBlockAsync(int branchId, int labOrderId, IEnumerable<long> sampleIds, string context, int userId, bool isSuperAdmin);
}
