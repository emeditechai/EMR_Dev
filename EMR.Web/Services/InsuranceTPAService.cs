using System.Data;
using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class InsuranceTPAService(IDbConnectionFactory db) : IInsuranceTPAService
{
    public async Task<IEnumerable<InsuranceTPAListItemViewModel>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? networkCategory = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var conn = db.CreateConnection();
        var parameters = new DynamicParameters();
        parameters.Add("@BranchId", branchId);
        parameters.Add("@Type", string.IsNullOrWhiteSpace(type) ? null : type);
        parameters.Add("@NetworkCategory", string.IsNullOrWhiteSpace(networkCategory) ? null : networkCategory);
        parameters.Add("@Status", status);
        parameters.Add("@Search", string.IsNullOrWhiteSpace(search) ? null : search.Trim());
        parameters.Add("@CompanyId", companyId);

        return await conn.QueryAsync<InsuranceTPAListItemViewModel>(
            "dbo.usp_Api_InsuranceTPA_GetList",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    public async Task<InsuranceTPAMaster?> GetByIdAsync(int id)
    {
        using var conn = db.CreateConnection();
        return await conn.QueryFirstOrDefaultAsync<InsuranceTPAMaster>(
            "dbo.usp_InsuranceTPA_GetById",
            new { InsuranceTPA_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> NameExistsAsync(string name, int? excludeId = null, int? branchId = null)
    {
        using var conn = db.CreateConnection();
        const string sql = @"
            SELECT COUNT(1) FROM dbo.InsuranceTPAMaster 
            WHERE Name = @Name
              AND (@BranchId IS NULL OR Branch_ID = @BranchId)
              AND (@ExcludeId IS NULL OR InsuranceTPA_ID <> @ExcludeId)";
        var count = await conn.ExecuteScalarAsync<int>(sql, new { Name = name.Trim(), BranchId = branchId, ExcludeId = excludeId });
        return count > 0;
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? branchId = null)
    {
        using var conn = db.CreateConnection();
        const string sql = @"
            SELECT COUNT(1) FROM dbo.InsuranceTPAMaster 
            WHERE Code = @Code
              AND (@BranchId IS NULL OR Branch_ID = @BranchId)
              AND (@ExcludeId IS NULL OR InsuranceTPA_ID <> @ExcludeId)";
        var count = await conn.ExecuteScalarAsync<int>(sql, new { Code = code.Trim(), BranchId = branchId, ExcludeId = excludeId });
        return count > 0;
    }

    public async Task<string> GeneratePolicyPrefixAsync(string type, string? code = null)
    {
        using var conn = db.CreateConnection();
        var nextId = await conn.ExecuteScalarAsync<int>("SELECT ISNULL(MAX(InsuranceTPA_ID), 0) + 1 FROM dbo.InsuranceTPAMaster");
        var typeCode = type.Contains("TPA", StringComparison.OrdinalIgnoreCase) ? "TPA" : "INS";
        
        if (!string.IsNullOrWhiteSpace(code))
        {
            var cleanedCode = new string(code.Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();
            if (cleanedCode.Length > 4) cleanedCode = cleanedCode.Substring(0, 4);
            if (!string.IsNullOrWhiteSpace(cleanedCode))
            {
                return $"POL-{cleanedCode}-{nextId:D4}";
            }
        }
        return $"POL-{typeCode}-{nextId:D4}";
    }
}
