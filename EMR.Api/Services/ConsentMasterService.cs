using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class ConsentMasterService(IDbConnectionFactory db) : IConsentMasterService
{
    public async Task<IEnumerable<ConsentMasterListItemDto>> GetListAsync(
        int? branchId = null,
        string? type = null,
        string? consentType = null,
        string? language = null,
        int? procedureId = null,
        bool? status = null,
        string? search = null,
        int? companyId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ConsentMasterListItemDto>(
            "dbo.usp_Api_ConsentMaster_GetList",
            new
            {
                BranchId = branchId,
                Type = string.IsNullOrWhiteSpace(type) ? null : type,
                ConsentType = string.IsNullOrWhiteSpace(consentType) ? null : consentType,
                Language = string.IsNullOrWhiteSpace(language) ? null : language,
                ProcedureId = procedureId,
                Status = status,
                Search = string.IsNullOrWhiteSpace(search) ? null : search,
                CompanyId = companyId
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<ConsentMasterDetailDto?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<ConsentMasterDetailDto>(
            "dbo.usp_Api_ConsentMaster_GetById",
            new { Consent_ID = id },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(ConsentMasterSaveRequest request)
    {
        using var con = db.CreateConnection();
        var newId = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_ConsentMaster_Create",
            new
            {
                request.CompanyId,
                request.Branch_ID,
                request.ConsentType,
                request.Type,
                request.Procedure_ID,
                request.Language,
                request.ConsentTemplateContent,
                request.Version,
                request.ValidityPeriod,
                request.WitnessRequired,
                request.Status,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);

        return newId;
    }

    public async Task<bool> UpdateAsync(ConsentMasterSaveRequest request)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_ConsentMaster_Update",
            new
            {
                request.Consent_ID,
                request.CompanyId,
                request.Branch_ID,
                request.ConsentType,
                request.Type,
                request.Procedure_ID,
                request.Language,
                request.ConsentTemplateContent,
                request.Version,
                request.ValidityPeriod,
                request.WitnessRequired,
                request.Status,
                request.UserId
            },
            commandType: CommandType.StoredProcedure);

        return rows > 0;
    }

    public async Task<bool> ToggleStatusAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_ConsentMaster_ToggleStatus",
            new { Consent_ID = id, UserId = userId },
            commandType: CommandType.StoredProcedure);

        return rows > 0;
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteScalarAsync<int>(
            "dbo.usp_Api_ConsentMaster_Delete",
            new { Consent_ID = id },
            commandType: CommandType.StoredProcedure);

        return rows > 0;
    }

    public async Task<IEnumerable<ConsentProcedureOptionDto>> GetProcedureOptionsAsync(int? branchId = null)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<ConsentProcedureOptionDto>(
            "dbo.usp_Api_ConsentMaster_GetProcedureOptions",
            new { BranchId = branchId },
            commandType: CommandType.StoredProcedure);
    }
}
