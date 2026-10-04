using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

/// <summary>
/// Critical value communication (NABL): who was informed of a Critical / Panic result, how, when and by whom
/// (SQLScripts/2202). Also the sign-off check: a result at its final sign-off needs an Informed or Attempted record.
/// </summary>
public interface ILabCriticalCommunicationService
{
    /// <summary>Critical results of a bill with their communication state. Context: SIGNOFF / ENTRY / REGISTER.</summary>
    Task<LabCriticalPendingResult> GetPendingAsync(int branchId, int labOrderId, IEnumerable<long>? sampleIds, string context, int userId, bool isSuperAdmin);

    /// <summary>Saves the records; throws <see cref="InvalidOperationException"/> with the SQL rule message.</summary>
    Task<List<LabCriticalRecordedDto>> RecordAsync(LabCriticalRecordRequest request);

    /// <summary>The message refusing a sign-off, or null when nothing blocks it.</summary>
    Task<string?> GetSignoffBlockAsync(int branchId, int labOrderId, IEnumerable<long> sampleIds, string context, int userId, bool isSuperAdmin);
}

public class LabCriticalCommunicationService(IDbConnectionFactory connectionFactory) : ILabCriticalCommunicationService
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<LabCriticalPendingResult> GetPendingAsync(int branchId, int labOrderId, IEnumerable<long>? sampleIds, string context,
        int userId, bool isSuperAdmin)
    {
        using var db = connectionFactory.CreateConnection();
        using var multi = await db.QueryMultipleAsync("dbo.usp_LabCritical_GetPending",
            new
            {
                BranchId = branchId,
                LabOrderId = labOrderId,
                SampleIds = sampleIds == null ? null : string.Join(",", sampleIds.Distinct()),
                Context = context,
                UserId = userId,
                IsSuperAdmin = isSuperAdmin
            },
            commandType: CommandType.StoredProcedure);

        return new LabCriticalPendingResult
        {
            Results = (await multi.ReadAsync<LabCriticalResultDto>()).ToList(),
            Contacts = await multi.ReadFirstOrDefaultAsync<LabCriticalContactsDto>(),
            History = (await multi.ReadAsync<LabCriticalHistoryDto>()).ToList()
        };
    }

    public async Task<List<LabCriticalRecordedDto>> RecordAsync(LabCriticalRecordRequest request)
    {
        // local date & time as typed on the form (no time-zone shift)
        var items = request.Items.Select(i => new
        {
            i.SampleId, i.Outcome, i.InformedName, i.InformedRole, i.ContactNo, i.Mode,
            InformedOn = i.InformedOn?.ToString("yyyy-MM-ddTHH:mm:ss"),
            i.ReadBack, i.Remarks, i.CorrectsId, i.SendMessage
        });

        using var db = connectionFactory.CreateConnection();
        try
        {
            return (await db.QueryAsync<LabCriticalRecordedDto>("dbo.usp_LabCritical_Record",
                new
                {
                    request.BranchId,
                    request.LabOrderId,
                    Items = JsonSerializer.Serialize(items, Json),
                    request.Source,
                    request.UserId,
                    request.IsSuperAdmin
                },
                commandType: CommandType.StoredProcedure)).ToList();
        }
        catch (SqlException ex) when (ex.Class == 16 && ex.Number is not (50010 or 50011))
        {
            throw new InvalidOperationException(ex.Message);
        }
    }

    public async Task<string?> GetSignoffBlockAsync(int branchId, int labOrderId, IEnumerable<long> sampleIds, string context,
        int userId, bool isSuperAdmin)
    {
        var ids = sampleIds.Distinct().ToList();
        if (ids.Count == 0) return null;
        var pending = await GetPendingAsync(branchId, labOrderId, ids, context, userId, isSuperAdmin);
        var blocking = pending.Results.Where(r => r.BlocksSignoff).ToList();
        if (blocking.Count == 0) return null;
        return "Record who was informed of the critical / panic value first: "
               + string.Join(", ", blocking.Select(r => $"{r.TestName} {r.TestValue} {r.Unit}".Trim()))
               + ". Use \"Informed\", or \"Attempted\" with the reason when the person could not be reached.";
    }
}
