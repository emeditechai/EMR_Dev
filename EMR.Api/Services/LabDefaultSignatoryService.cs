using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;
using Microsoft.Data.SqlClient;

namespace EMR.Api.Services;

public interface ILabDefaultSignatoryService
{
    Task<LabDefaultSignatoryListResult> GetListAsync(int branchId, int? companyId);
    /// <summary>Replaces the branch's set; throws <see cref="InvalidOperationException"/> with the SQL rule message.</summary>
    Task<int> SaveAsync(LabDefaultSignatorySaveRequest request);
}

public class LabDefaultSignatoryService(IDbConnectionFactory connectionFactory) : ILabDefaultSignatoryService
{
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public async Task<LabDefaultSignatoryListResult> GetListAsync(int branchId, int? companyId)
    {
        using var db = connectionFactory.CreateConnection();

        // Run signatory list SP (2 or 3 result sets depending on DB migration state)
        var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_LabDefaultSignatory_GetList",
            new { BranchId = branchId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);

        List<LabDefaultSignatoryDto> signatories;
        List<LabSignatoryCandidateDto> candidates;
        List<LabDepartmentDto> departments;

        using (multi)
        {
            signatories = (await multi.ReadAsync<LabDefaultSignatoryDto>()).ToList();
            candidates  = (await multi.ReadAsync<LabSignatoryCandidateDto>()).ToList();
            try
            {
                departments = multi.IsConsumed ? [] : (await multi.ReadAsync<LabDepartmentDto>()).ToList();
            }
            catch
            {
                departments = [];
            }
        }

        // If we didn't get departments from SP, fetch them directly (pre-migration fallback)
        if (departments.Count == 0)
        {
            departments = (await db.QueryAsync<LabDepartmentDto>(
                "SELECT DeptId AS DepartmentId, DeptName AS DepartmentName FROM dbo.DepartmentMaster WHERE DeptType = 'LAB' AND IsActive = 1 ORDER BY DeptName"))
                .ToList();
        }

        return new LabDefaultSignatoryListResult
        {
            Signatories = signatories,
            Candidates  = candidates,
            Departments = departments
        };
    }

    public async Task<int> SaveAsync(LabDefaultSignatorySaveRequest request)
    {
        using var db = connectionFactory.CreateConnection();
        try
        {
            return await db.ExecuteScalarAsync<int>(
                "dbo.usp_Api_LabDefaultSignatory_Save",
                new
                {
                    request.BranchId,
                    request.CompanyId,
                    request.UserId,
                    ItemsJson = JsonSerializer.Serialize(request.Items, JsonOpts)
                },
                commandType: CommandType.StoredProcedure);
        }
        catch (SqlException ex) when (ex.Class == 16)
        {
            throw new InvalidOperationException(ex.Message);
        }
    }
}
