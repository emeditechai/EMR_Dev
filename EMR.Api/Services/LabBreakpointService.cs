using System.Data;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class LabBreakpointService(IDbConnectionFactory db) : ILabBreakpointService
{
    public async Task<IEnumerable<LabBreakpointListItem>> GetListAsync(bool? status, string? search, int? companyId, int? organism_ID, int? antibiotic_ID)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabBreakpointListItem>(
            "usp_Api_LabBreakpointMaster_GetList",
            new { Status = status, Search = search, CompanyId = companyId, Organism_ID = organism_ID, Antibiotic_ID = antibiotic_ID },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<LabBreakpointListItem?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<LabBreakpointListItem>(
            "usp_Api_LabBreakpointMaster_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(LabBreakpointCreateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@Organism_ID", req.Organism_ID);
        p.Add("@Antibiotic_ID", req.Antibiotic_ID);
        p.Add("@Standard", req.Standard);
        p.Add("@Standard_Version", req.Standard_Version);
        p.Add("@Method", req.Method);
        p.Add("@Specimen_Scope", req.Specimen_Scope);
        p.Add("@S_Breakpoint", req.S_Breakpoint);
        p.Add("@R_Breakpoint", req.R_Breakpoint);
        p.Add("@Remarks", req.Remarks);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_Api_LabBreakpointMaster_Create", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task UpdateAsync(LabBreakpointUpdateRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Breakpoint_ID);
        p.Add("@Organism_Category", req.Organism_Category);
        p.Add("@Organism_ID", req.Organism_ID);
        p.Add("@Antibiotic_ID", req.Antibiotic_ID);
        p.Add("@Standard", req.Standard);
        p.Add("@Standard_Version", req.Standard_Version);
        p.Add("@Method", req.Method);
        p.Add("@Specimen_Scope", req.Specimen_Scope);
        p.Add("@S_Breakpoint", req.S_Breakpoint);
        p.Add("@R_Breakpoint", req.R_Breakpoint);
        p.Add("@Remarks", req.Remarks);
        p.Add("@Status", req.Status);
        p.Add("@UserId", req.UserId);
        await con.ExecuteAsync("usp_Api_LabBreakpointMaster_Update", p, commandType: CommandType.StoredProcedure);
    }

    public async Task ToggleStatusAsync(LabBreakpointToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabBreakpointMaster_ToggleStatus",
            new { Id = req.Breakpoint_ID, req.Status, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_Api_LabBreakpointMaster_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabBreakpointLookupItem>> LookupOrganismsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabBreakpointLookupItem>("usp_Api_LabBreakpointMaster_LookupOrganisms", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<LabBreakpointLookupItem>> LookupAntibioticsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<LabBreakpointLookupItem>("usp_Api_LabBreakpointMaster_LookupAntibiotics", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }
}
