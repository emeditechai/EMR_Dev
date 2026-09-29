using System.Data;
using System.Text.Json;
using Dapper;
using EMR.Api.Data;
using EMR.Api.Models;

namespace EMR.Api.Services;

public class DoctorIpService(IDbConnectionFactory db) : IDoctorIpService
{
    public async Task<IEnumerable<DoctorIpListItem>> GetListAsync(int? companyId, int? branchId, bool? status, string? search)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpListItem>("usp_DoctorIp_GetList",
            new { CompanyId = companyId, BranchId = branchId, Status = status, Search = search },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorIpDetail?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        using var multi = await con.QueryMultipleAsync("usp_DoctorIp_GetById", new { Id = id }, commandType: CommandType.StoredProcedure);
        var header = await multi.ReadFirstOrDefaultAsync<DoctorIpHeader>();
        if (header == null) return null;
        var details = (await multi.ReadAsync<DoctorIpDetailItem>()).ToList();
        return new DoctorIpDetail { Header = header, Details = details };
    }

    public async Task<int> SaveAsync(DoctorIpSaveRequest req)
    {
        using var con = db.CreateConnection();
        var p = new DynamicParameters();
        p.Add("@Id", req.Doctor_IP_Hdr_ID);
        p.Add("@CompanyId", req.CompanyId);
        p.Add("@Doctor_ID", req.Doctor_ID);
        p.Add("@Speciality_ID", req.Speciality_ID);
        p.Add("@Branch_ID", req.Branch_ID);
        p.Add("@Effective_From", req.Effective_From.Date, DbType.Date);
        p.Add("@Effective_To", req.Effective_To.Date, DbType.Date);
        p.Add("@IsActive", req.IsActive);
        p.Add("@DetailsJson", JsonSerializer.Serialize(req.Details));
        p.Add("@UserId", req.UserId);
        p.Add("@NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);
        await con.ExecuteAsync("usp_DoctorIp_Save", p, commandType: CommandType.StoredProcedure);
        return p.Get<int>("@NewId");
    }

    public async Task ToggleStatusAsync(DoctorIpToggleStatusRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_DoctorIp_ToggleStatus",
            new { Id = req.Doctor_IP_Hdr_ID, req.IsActive, req.UserId }, commandType: CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(int id, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_DoctorIp_Delete", new { Id = id, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorIpSpeciality>> GetSpecialitiesAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpSpeciality>("usp_DoctorIp_GetSpecialities", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorIpLookupItem>> GetDoctorsAsync(int specialityId, int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpLookupItem>("usp_DoctorIp_GetDoctors",
            new { SpecialityId = specialityId, CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<DoctorIpItem>> GetItemsAsync(int? companyId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorIpItem>("usp_DoctorIp_GetItems", new { CompanyId = companyId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorIpAccessStatus> GetAccessStatusAsync(int companyId, int userId)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstAsync<DoctorIpAccessStatus>("usp_DoctorIp_AccessStatus",
            new { CompanyId = companyId, UserId = userId }, commandType: CommandType.StoredProcedure);
    }

    public async Task<DoctorIpVerifyCodeResult> VerifyAccessCodeAsync(DoctorIpVerifyCodeRequest req)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstAsync<DoctorIpVerifyCodeResult>("usp_DoctorIp_VerifyAccessCode",
            new { req.CompanyId, req.UserId, req.Code, req.IpAddress }, commandType: CommandType.StoredProcedure);
    }

    public async Task SetAccessCodeAsync(DoctorIpSetCodeRequest req)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync("usp_DoctorIp_SetAccessCode",
            new { req.CompanyId, req.NewCode, req.CurrentCode, req.UserId }, commandType: CommandType.StoredProcedure);
    }
}
