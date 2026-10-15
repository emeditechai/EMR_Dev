using System.Globalization;
using System.Text.Json;
using Dapper;
using EMR.Web.Data;

namespace EMR.Web.Services;

/// <summary>The masters that can be put under approval (dbo.ApprovalModule, SQLScripts/2277).</summary>
public static class ApprovalModules
{
    public const string Franchise = "LAB.FRANCHISE";
    public const string Corporate = "MASTER.CORPORATE";
    public const string Package   = "LAB.PACKAGE";
}

public record ApprovalMatrixHit(int Matrix_ID, char Scope, int? Branch_ID);

public record ApprovalField(string Field, string Value);

/// <summary>An open (pending or sent back) request on a record.</summary>
public class OpenApprovalRequest
{
    public int Request_ID { get; set; }
    public string Action_Type { get; set; } = "";
    public string Status { get; set; } = "";
    public bool? Requested_Active { get; set; }
    public string? Requested_By_Name { get; set; }
    public DateTime Requested_Date { get; set; }
    public string? Actioned_By_Name { get; set; }
    public DateTime? Actioned_Date { get; set; }
    public string? Remarks { get; set; }
    public bool IsPendingCreate => Action_Type == "CREATE";
}

public class ApprovalSubmission
{
    public required string ModuleCode { get; init; }
    public required ApprovalMatrixHit Matrix { get; init; }
    public int CompanyId { get; init; }
    public int BranchId { get; init; }
    public int EntityId { get; init; }
    public string? EntityName { get; init; }
    public required string ActionType { get; init; }          // CREATE / UPDATE
    public bool? RequestedActive { get; init; }
    public object? OldValues { get; init; }                    // the save request as it is today (UPDATE)
    public required object NewValues { get; init; }            // the save request as submitted
    public int UserId { get; init; }
}

/// <summary>
/// Maker / checker on masters. A module with an active approval matrix holds new records inactive and changes to
/// approved records aside until a manager named in the matrix approves them on the Approval Dashboard.
/// With no matrix, callers save exactly as before.
/// </summary>
public interface IMasterApprovalService
{
    /// <summary>The matrix that applies to a record of this branch: a branch-wise one first, else the company-wise one.</summary>
    Task<ApprovalMatrixHit?> FindMatrixAsync(int companyId, string moduleCode, int branchId);

    /// <summary>Records the request (an earlier open one on the record is replaced) and returns its id.
    /// Returns 0 when an UPDATE changes nothing.</summary>
    Task<int> SubmitAsync(ApprovalSubmission submission);

    /// <summary>The record's newest request, when it is still pending or was sent back.</summary>
    Task<OpenApprovalRequest?> GetOpenAsync(string moduleCode, int entityId);

    /// <summary>Records of a module that have an open request: id -> "P" / "S", with "N" for a new record
    /// (pending its first approval) and "C" for a change.</summary>
    Task<Dictionary<int, string>> GetOpenStatesAsync(int companyId, string moduleCode);

    /// <summary>A display list of a save request, with codes turned into names.</summary>
    Task<List<ApprovalField>> DescribeAsync(string moduleCode, object values);

    /// <summary>Closes the record's open request without acting on it (record deleted, approval switched off).</summary>
    Task CloseAsync(string moduleCode, int entityId, int userId, string reason);
}

public class MasterApprovalService(IDbConnectionFactory db) : IMasterApprovalService
{
    // never shown or compared: who saved it, keys, and form helpers
    private static readonly HashSet<string> Hidden = new(StringComparer.OrdinalIgnoreCase)
    {
        "UserId", "CompanyId", "Franchise_ID", "Corporate_ID", "Profile_ID", "Credit_ID", "Branch_ID",
        "CorporateTypeOptions", "BillingCycleOptions", "Franchise_Code", "Corporate_Code"
    };

    private static readonly Dictionary<string, Dictionary<string, string>> Codes = new()
    {
        ["Franchise_Type"] = new() { ["1"] = "Collection Center", ["2"] = "Franchise Lab", ["3"] = "Pickup Point", ["4"] = "Marketing" },
        ["Credit_Facility_Type"] = new() { ["1"] = "Prepaid (Wallet)", ["2"] = "Postpaid (Credit)" },
        ["Profile_Type"] = new() { ["1"] = "Profile", ["2"] = "Package" }
    };

    private static readonly Dictionary<string, string> Labels = new()
    {
        ["Status@" + ApprovalModules.Franchise] = "Is Suspended",
        ["Status@" + ApprovalModules.Corporate] = "Active",
        ["Status@" + ApprovalModules.Package] = "Active",
        ["IsActive"] = "Active",
        ["Parent_Branch_ID"] = "Parent Branch",
        ["Test_ID"] = "Profile Test",
        ["Details"] = "Tests",
        ["Mobile_No"] = "Mobile No",
        ["Contact_No"] = "Contact No",
        ["Discount_Pct"] = "Discount %",
        ["MRP"] = "MRP",
        ["Interest_On_Overdue_Percent"] = "Interest On Overdue %",
        ["Profile_TAT_Hours"] = "TAT (Hours)",
        ["Profile_NABL_Accredited"] = "NABL Accredited",
        ["IsReportHeaderRequired"] = "Report Header Required",
        ["PreprintedBarcode"] = "Preprinted Barcode",
        ["IsNotificationRequired"] = "Notification Required",
        ["Agreement_Doc_Path"] = "Agreement Document"
    };

    public async Task<ApprovalMatrixHit?> FindMatrixAsync(int companyId, string moduleCode, int branchId)
    {
        using var con = db.CreateConnection();
        var row = await con.QueryFirstOrDefaultAsync<MatrixRow>(
            @"SELECT TOP 1 m.Matrix_ID, m.Scope, m.Branch_ID
                FROM dbo.ApprovalMatrix m
                JOIN dbo.ApprovalModule am ON am.Module_Code = m.Module_Code AND am.IsActive = 1
               WHERE m.CompanyId = @companyId AND m.Module_Code = @moduleCode AND m.IsActive = 1
                 AND (m.Scope = 'C' OR m.Branch_ID = @branchId)
                 AND EXISTS (SELECT 1 FROM dbo.ApprovalMatrixApprover a WHERE a.Matrix_ID = m.Matrix_ID)
               ORDER BY CASE m.Scope WHEN 'B' THEN 0 ELSE 1 END",
            new { companyId, moduleCode, branchId });
        return row is null ? null : new ApprovalMatrixHit(row.Matrix_ID, row.Scope[0], row.Branch_ID);
    }

    private sealed class MatrixRow
    {
        public int Matrix_ID { get; set; }
        public string Scope { get; set; } = "C";
        public int? Branch_ID { get; set; }
    }

    public async Task<int> SubmitAsync(ApprovalSubmission s)
    {
        var newFields = await DescribeAsync(s.ModuleCode, s.NewValues);
        List<ApprovalField>? oldFields = s.OldValues is null ? null : await DescribeAsync(s.ModuleCode, s.OldValues);

        if (s.ActionType == "UPDATE" && oldFields is not null
            && oldFields.Select(f => f.Value).SequenceEqual(newFields.Select(f => f.Value)))
            return 0;

        using var con = db.CreateConnection();
        con.Open();
        using var tx = con.BeginTransaction();

        // a submission still waiting is replaced by this one (a sent-back one stays as it was, for the record)
        await con.ExecuteAsync(
            @"UPDATE dbo.ApprovalRequest SET Status = 'X', Actioned_By = @UserId, Actioned_Date = GETDATE(),
                     Remarks = N'Replaced by a newer submission'
               WHERE Module_Code = @ModuleCode AND Entity_ID = @EntityId AND Status = 'P'",
            new { s.UserId, s.ModuleCode, s.EntityId }, tx);

        var id = await con.ExecuteScalarAsync<int>(
            @"INSERT dbo.ApprovalRequest (CompanyId, Branch_ID, Matrix_ID, Scope, Module_Code, Entity_ID, Entity_Name, Action_Type,
                                          Requested_Active, Old_Values, New_Values, Payload, Status, Requested_By, Requested_Date)
              VALUES (@CompanyId, @BranchId, @MatrixId, @Scope, @ModuleCode, @EntityId, @EntityName, @ActionType,
                      @RequestedActive, @OldValues, @NewValues, @Payload, 'P', @UserId, GETDATE());
              SELECT CAST(SCOPE_IDENTITY() AS INT);",
            new
            {
                s.CompanyId, s.BranchId, MatrixId = s.Matrix.Matrix_ID, Scope = s.Matrix.Scope.ToString(), s.ModuleCode, s.EntityId,
                s.EntityName, s.ActionType, s.RequestedActive,
                OldValues = oldFields is null ? null : JsonSerializer.Serialize(oldFields),
                NewValues = JsonSerializer.Serialize(newFields),
                Payload = s.ActionType == "UPDATE" ? JsonSerializer.Serialize(s.NewValues, s.NewValues.GetType()) : null,
                s.UserId
            }, tx);

        tx.Commit();
        return id;
    }

    public async Task CloseAsync(string moduleCode, int entityId, int userId, string reason)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            @"UPDATE dbo.ApprovalRequest SET Status = 'X', Actioned_By = @userId, Actioned_Date = GETDATE(),
                     Remarks = ISNULL(Remarks + N' | ', N'') + @reason
               WHERE Module_Code = @moduleCode AND Entity_ID = @entityId AND Status IN ('P', 'S')",
            new { moduleCode, entityId, userId, reason });
    }

    public async Task<OpenApprovalRequest?> GetOpenAsync(string moduleCode, int entityId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<OpenApprovalRequest>(
            @"SELECT TOP 1 r.Request_ID, r.Action_Type, r.Status, r.Requested_Active, r.Requested_Date, r.Actioned_Date, r.Remarks,
                     COALESCE(NULLIF(rb.FullName, ''), rb.Username) AS Requested_By_Name,
                     COALESCE(NULLIF(ab.FullName, ''), ab.Username) AS Actioned_By_Name
                FROM dbo.ApprovalRequest r
                LEFT JOIN dbo.Users rb ON rb.Id = r.Requested_By
                LEFT JOIN dbo.Users ab ON ab.Id = r.Actioned_By
               WHERE r.Request_ID = (SELECT MAX(x.Request_ID) FROM dbo.ApprovalRequest x
                                      WHERE x.Module_Code = @moduleCode AND x.Entity_ID = @entityId AND x.Status <> 'X')
                 AND r.Status IN ('P', 'S')",
            new { moduleCode, entityId });
    }

    public async Task<Dictionary<int, string>> GetOpenStatesAsync(int companyId, string moduleCode)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int Entity_ID, string Action_Type, string Status)>(
            @"SELECT r.Entity_ID, r.Action_Type, r.Status
                FROM dbo.ApprovalRequest r
               WHERE r.CompanyId = @companyId AND r.Module_Code = @moduleCode AND r.Status IN ('P', 'S')
                 AND r.Request_ID = (SELECT MAX(x.Request_ID) FROM dbo.ApprovalRequest x
                                      WHERE x.Module_Code = r.Module_Code AND x.Entity_ID = r.Entity_ID AND x.Status <> 'X')",
            new { companyId, moduleCode });
        return rows.ToDictionary(r => r.Entity_ID, r => r.Status + (r.Action_Type == "CREATE" ? "N" : "C"));
    }

    public async Task<List<ApprovalField>> DescribeAsync(string moduleCode, object values)
    {
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(values, values.GetType()));
        var result = new List<ApprovalField>();
        using var con = db.CreateConnection();

        foreach (var prop in doc.RootElement.EnumerateObject())
        {
            if (Hidden.Contains(prop.Name)) continue;
            if (moduleCode == ApprovalModules.Package && prop.Name is "Detail_ID") continue;

            var label = Labels.GetValueOrDefault(prop.Name + "@" + moduleCode) ?? Labels.GetValueOrDefault(prop.Name) ?? prop.Name.Replace('_', ' ');
            string text;

            if (prop.Name == "Details" && prop.Value.ValueKind == JsonValueKind.Array)
            {
                var ids = prop.Value.EnumerateArray()
                    .Select(d => d.TryGetProperty("Test_ID", out var t) && t.TryGetInt32(out var v) ? v : 0)
                    .Where(v => v > 0).ToArray();
                var names = (await con.QueryAsync<(int Test_ID, string Test_Name)>(
                    "SELECT Test_ID, Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID IN @ids", new { ids }))
                    .ToDictionary(x => x.Test_ID, x => x.Test_Name);
                text = ids.Length == 0 ? "—" : string.Join(", ", ids.Select(i => names.GetValueOrDefault(i) ?? $"#{i}"));
            }
            else if (prop.Name == "Parent_Branch_ID" && prop.Value.TryGetInt32(out var branchId))
            {
                text = await con.ExecuteScalarAsync<string?>(
                    "SELECT BranchName FROM dbo.BranchMaster WHERE BranchID = @branchId", new { branchId }) ?? $"#{branchId}";
            }
            else if (prop.Name == "Test_ID" && prop.Value.TryGetInt32(out var testId))
            {
                text = await con.ExecuteScalarAsync<string?>(
                    "SELECT Test_Name FROM dbo.LabInvestigationMaster WHERE Test_ID = @testId", new { testId }) ?? $"#{testId}";
            }
            else
            {
                text = Format(prop.Value);
                if (Codes.TryGetValue(prop.Name, out var map) && map.TryGetValue(text, out var name)) text = name;
            }

            result.Add(new ApprovalField(label, text));
        }
        return result;
    }

    private static string Format(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined => "—",
        JsonValueKind.True => "Yes",
        JsonValueKind.False => "No",
        JsonValueKind.Number => v.TryGetDecimal(out var d) ? d.ToString("0.##", CultureInfo.InvariantCulture) : v.GetRawText(),
        JsonValueKind.String when v.TryGetDateTime(out var dt) => dt.TimeOfDay == TimeSpan.Zero ? dt.ToString("dd-MMM-yyyy") : dt.ToString("dd-MMM-yyyy HH:mm"),
        JsonValueKind.String => string.IsNullOrWhiteSpace(v.GetString()) ? "—" : v.GetString()!,
        _ => v.GetRawText()
    };
}
