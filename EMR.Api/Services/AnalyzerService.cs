using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class AnalyzerService(IDbConnectionFactory db) : IAnalyzerService
{
    public async Task<IEnumerable<AnalyzerListItemDto>> GetListAsync(int? departmentId = null,
        string? interfaceProtocol = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<AnalyzerListItemDto>(
            "dbo.usp_Api_Analyzer_GetList",
            new
            {
                DepartmentId = departmentId,
                InterfaceProtocol = string.IsNullOrWhiteSpace(interfaceProtocol) ? null : interfaceProtocol,
                Status = status,
                Search = string.IsNullOrWhiteSpace(search) ? null : search,
                CompanyId = companyId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<AnalyzerDetailDto?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<AnalyzerDetailDto>(
            "dbo.usp_Api_Analyzer_GetById",
            new { Analyzer_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(AnalyzerSaveRequest request)
    {
        using var con = db.CreateConnection();
        var newId = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_Analyzer_Create",
            new
            {
                request.CompanyId,
                request.Department_ID,
                request.Analyzer_Name,
                request.Interface_Protocol,
                request.Status,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);

        return newId;
    }

    public async Task<bool> UpdateAsync(AnalyzerSaveRequest request)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_Analyzer_Update",
            new
            {
                request.Analyzer_ID,
                request.CompanyId,
                request.Department_ID,
                request.Analyzer_Name,
                request.Interface_Protocol,
                request.Status,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);

        return rows > 0;
    }

    public async Task<bool?> ToggleStatusAsync(int id, int? userId = null)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<bool?>(
            "dbo.usp_Api_Analyzer_ToggleStatus",
            new { Analyzer_ID = id, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_Analyzer_Delete",
            new { Analyzer_ID = id },
            commandType: CommandType.StoredProcedure);

        return rows > 0;
    }
}
