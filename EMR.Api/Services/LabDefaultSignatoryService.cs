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
        using var multi = await db.QueryMultipleAsync(
            "dbo.usp_Api_LabDefaultSignatory_GetList",
            new { BranchId = branchId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);

        return new LabDefaultSignatoryListResult
        {
            Signatories = (await multi.ReadAsync<LabDefaultSignatoryDto>()).ToList(),
            Candidates = (await multi.ReadAsync<LabSignatoryCandidateDto>()).ToList()
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
