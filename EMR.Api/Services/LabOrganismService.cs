using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabOrganismService(IDbConnectionFactory db) : ILabOrganismService
{
    public async Task<IEnumerable<LabOrganismListItem>> GetListAsync(bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabOrganismListItem>(
            "usp_Api_LabOrganismMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabOrganismListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabOrganismListItem>(
            "usp_Api_LabOrganismMaster_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabOrganismCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Organism_Name", req.Organism_Name);
        p.Add("@Gram_Type", req.Gram_Type);
        p.Add("@Organism_Type", req.Organism_Type);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@WHONET_Code", req.WHONET_Code);
        p.Add("@Description", req.Description);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_Api_LabOrganismMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabOrganismUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Organism_ID);
        p.Add("@Organism_Name", req.Organism_Name);
        p.Add("@Gram_Type", req.Gram_Type);
        p.Add("@Organism_Type", req.Organism_Type);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@WHONET_Code", req.WHONET_Code);
        p.Add("@Description", req.Description);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        await con.ExecuteAsync("usp_Api_LabOrganismMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabOrganismToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabOrganismMaster_ToggleStatus",
            new { Id = req.Organism_ID, req.Status, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabOrganismMaster_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }
}
