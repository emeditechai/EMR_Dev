using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabFormulaParameterService(IDbConnectionFactory db) : ILabFormulaParameterService
{
    public async Task<IEnumerable<LabFormulaParameterListItem>> GetListAsync(bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabFormulaParameterListItem>(
            "usp_Api_LabFormulaParameterMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabFormulaParameterListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabFormulaParameterListItem>(
            "usp_Api_LabFormulaParameterMaster_GetById",
            new { Parameter_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabFormulaParameterCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Formula_Expression", req.Formula_Expression);
        p.Add("@Rounding_Precision", req.Rounding_Precision);
        p.Add("@Validity_Condition", req.Validity_Condition);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabFormulaParameterMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabFormulaParameterUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabFormulaParameterMaster_Update",
            new
            {
                Parameter_ID = req.Parameter_ID,
                Test_ID = req.Test_ID,
                Formula_Expression = req.Formula_Expression,
                Rounding_Precision = req.Rounding_Precision,
                Validity_Condition = req.Validity_Condition,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabFormulaParameterToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabFormulaParameterMaster_ToggleStatus",
            new
            {
                Parameter_ID = req.Parameter_ID,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabFormulaParameterMaster_Delete",
            new { Parameter_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<NumericTestItem>> GetNumericTestsAsync(int? companyId, string? search)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<NumericTestItem>(
            "usp_Api_LabFormulaParameterMaster_GetNumericTests",
            new { CompanyId = companyId, Search = search },
            commandType: CommandType.StoredProcedure
        );
    }
}
