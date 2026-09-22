using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabDescriptiveTestTemplateService(IDbConnectionFactory db) : ILabDescriptiveTestTemplateService
{
    public async Task<IEnumerable<LabDescriptiveTestTemplateListItem>> GetListAsync(bool? status, string? search, int? testId, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabDescriptiveTestTemplateListItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetList",
            new { Status = status, Search = search, TestId = testId, CompanyId = companyId },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<LabDescriptiveTestTemplateListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabDescriptiveTestTemplateListItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetById",
            new { Template_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<int> CreateAsync(LabDescriptiveTestTemplateCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Test_ID", req.Test_ID);
        p.Add("@Section_Name", req.Section_Name);
        p.Add("@Section_Sequence", req.Section_Sequence);
        p.Add("@Is_Mandatory", req.Is_Mandatory);
        p.Add("@Default_Content_Html", req.Default_Content_Html);
        p.Add("@Placeholder_Tags", req.Placeholder_Tags);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await con.ExecuteAsync("usp_Api_LabDescriptiveTestTemplate_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabDescriptiveTestTemplateUpdateRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabDescriptiveTestTemplate_Update",
            new
            {
                Template_ID = req.Template_ID,
                Test_ID = req.Test_ID,
                Section_Name = req.Section_Name,
                Section_Sequence = req.Section_Sequence,
                Is_Mandatory = req.Is_Mandatory,
                Default_Content_Html = req.Default_Content_Html,
                Placeholder_Tags = req.Placeholder_Tags,
                IsActive = req.IsActive,
                UserId = req.UserId
            },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task ToggleStatusAsync(LabDescriptiveTestTemplateToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(
            "usp_Api_LabDescriptiveTestTemplate_ToggleStatus",
            new
            {
                Template_ID = req.Template_ID,
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
            "usp_Api_LabDescriptiveTestTemplate_Delete",
            new { Template_ID = id },
            commandType: CommandType.StoredProcedure
        );
    }

    public async Task<IEnumerable<RadiologyTestItem>> GetRadiologyTestsAsync(int? companyId, string? search)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<RadiologyTestItem>(
            "usp_Api_LabDescriptiveTestTemplate_GetRadiologyTests",
            new { CompanyId = companyId, Search = search },
            commandType: CommandType.StoredProcedure
        );
    }
}
