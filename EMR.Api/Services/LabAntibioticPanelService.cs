using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabAntibioticPanelService(IDbConnectionFactory db) : ILabAntibioticPanelService
{
    public async Task<IEnumerable<LabAntibioticPanelListItem>> GetListAsync(bool? status, string? search, int? companyId, int? sample_Type_ID)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabAntibioticPanelListItem>(
            "usp_Api_LabAntibioticPanelMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId, Sample_Type_ID = sample_Type_ID },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabAntibioticPanelListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabAntibioticPanelListItem>(
            "usp_Api_LabAntibioticPanelMaster_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabAntibioticPanelCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Panel_Name", req.Panel_Name);
        p.Add("@Gram_Type", req.Gram_Type);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@Sample_Type_ID", req.Sample_Type_ID);
        p.Add("@Description", req.Description);
        p.Add("@Antibiotic_IDs", JsonSerializer.Serialize(req.Antibiotic_IDs.Select((id, i) => new { id, tier = i < req.Antibiotic_Tiers.Count ? req.Antibiotic_Tiers[i] : 1 })));
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_Api_LabAntibioticPanelMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabAntibioticPanelUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Panel_ID);
        p.Add("@Panel_Name", req.Panel_Name);
        p.Add("@Gram_Type", req.Gram_Type);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@Sample_Type_ID", req.Sample_Type_ID);
        p.Add("@Description", req.Description);
        p.Add("@Antibiotic_IDs", JsonSerializer.Serialize(req.Antibiotic_IDs.Select((id, i) => new { id, tier = i < req.Antibiotic_Tiers.Count ? req.Antibiotic_Tiers[i] : 1 })));
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        await con.ExecuteAsync("usp_Api_LabAntibioticPanelMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabAntibioticPanelToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabAntibioticPanelMaster_ToggleStatus",
            new { Id = req.Panel_ID, req.Status, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabAntibioticPanelMaster_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabAntibioticPanelLookupItem>> LookupAntibioticsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabAntibioticPanelLookupItem>("usp_Api_LabAntibioticPanelMaster_LookupAntibiotics", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabAntibioticPanelLookupItem>> LookupSampleTypesAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabAntibioticPanelLookupItem>("usp_Api_LabAntibioticPanelMaster_LookupSampleTypes", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }
}
