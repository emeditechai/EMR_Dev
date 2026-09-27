using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabAntibioticService(IDbConnectionFactory db) : ILabAntibioticService
{
    public async Task<IEnumerable<LabAntibioticListItem>> GetListAsync(bool? status, string? search, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabAntibioticListItem>(
            "usp_Api_LabAntibioticMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabAntibioticListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabAntibioticListItem>(
            "usp_Api_LabAntibioticMaster_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabAntibioticCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Antibiotic_Name", req.Antibiotic_Name);
        p.Add("@Abbreviation", req.Abbreviation);
        p.Add("@Antibiotic_Class", req.Antibiotic_Class);
        p.Add("@Route", req.Route);
        p.Add("@WHONET_Code", req.WHONET_Code);
        p.Add("@Description", req.Description);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_Api_LabAntibioticMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabAntibioticUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Antibiotic_ID);
        p.Add("@Antibiotic_Name", req.Antibiotic_Name);
        p.Add("@Abbreviation", req.Abbreviation);
        p.Add("@Antibiotic_Class", req.Antibiotic_Class);
        p.Add("@Route", req.Route);
        p.Add("@WHONET_Code", req.WHONET_Code);
        p.Add("@Description", req.Description);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        await con.ExecuteAsync("usp_Api_LabAntibioticMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabAntibioticToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabAntibioticMaster_ToggleStatus",
            new { Id = req.Antibiotic_ID, req.Status, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabAntibioticMaster_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }
}
