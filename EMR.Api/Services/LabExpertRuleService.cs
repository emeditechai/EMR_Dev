using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabExpertRuleService(IDbConnectionFactory db) : ILabExpertRuleService
{
    public async Task<IEnumerable<LabExpertRuleListItem>> GetListAsync(bool? status, string? search, int? companyId, int? organism_ID, int? antibiotic_ID)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabExpertRuleListItem>(
            "usp_Api_LabExpertRuleMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId, Organism_ID = organism_ID, Antibiotic_ID = antibiotic_ID },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabExpertRuleListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabExpertRuleListItem>(
            "usp_Api_LabExpertRuleMaster_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabExpertRuleCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Rule_Type", req.Rule_Type);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@Organism_ID", req.Organism_ID);
        p.Add("@Antibiotic_ID", req.Antibiotic_ID);
        p.Add("@Trigger_Result", req.Trigger_Result);
        p.Add("@Rule_Action", req.Rule_Action);
        p.Add("@Alert_Message", req.Alert_Message);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_Api_LabExpertRuleMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabExpertRuleUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Rule_ID);
        p.Add("@Rule_Type", req.Rule_Type);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@Organism_ID", req.Organism_ID);
        p.Add("@Antibiotic_ID", req.Antibiotic_ID);
        p.Add("@Trigger_Result", req.Trigger_Result);
        p.Add("@Rule_Action", req.Rule_Action);
        p.Add("@Alert_Message", req.Alert_Message);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        await con.ExecuteAsync("usp_Api_LabExpertRuleMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabExpertRuleToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabExpertRuleMaster_ToggleStatus",
            new { Id = req.Rule_ID, req.Status, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabExpertRuleMaster_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabExpertRuleLookupItem>> LookupOrganismsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabExpertRuleLookupItem>("usp_Api_LabExpertRuleMaster_LookupOrganisms", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabExpertRuleLookupItem>> LookupAntibioticsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabExpertRuleLookupItem>("usp_Api_LabExpertRuleMaster_LookupAntibiotics", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }
}
