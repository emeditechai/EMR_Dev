using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class DoctorSubSpecialityService(IDbConnectionFactory db) : IDoctorSubSpecialityService
{
    public async Task<IEnumerable<DoctorSubSpecialityListItemViewModel>> GetAllAsync(int? specialityId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                sub.SubSpecialityId,
                sub.SpecialityId,
                s.SpecialityName,
                s.SpecialityCode,
                sub.SubSpecialityCode,
                sub.SubSpecialityName,
                sub.Description,
                sub.IsActive,
                sub.CreatedDate
            FROM DoctorSubSpecialityMaster sub
            INNER JOIN DoctorSpecialityMaster s ON sub.SpecialityId = s.SpecialityId
            WHERE (@specialityId IS NULL OR sub.SpecialityId = @specialityId)
              AND (@companyId IS NULL OR sub.CompanyId = @companyId)
              AND (@branchId IS NULL OR sub.BranchId = @branchId OR sub.BranchId IS NULL)
            ORDER BY s.SpecialityName, sub.SubSpecialityName";

        return await con.QueryAsync<DoctorSubSpecialityListItemViewModel>(sql, new { specialityId, companyId, branchId });
    }

    public async Task<DoctorSubSpecialityMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                sub.SubSpecialityId,
                sub.CompanyId,
                sub.BranchId,
                sub.SpecialityId,
                s.SpecialityName,
                s.SpecialityCode,
                sub.SubSpecialityCode,
                sub.SubSpecialityName,
                sub.Description,
                sub.IsActive,
                sub.CreatedBy,
                sub.CreatedDate,
                sub.ModifiedBy,
                sub.ModifiedDate
            FROM DoctorSubSpecialityMaster sub
            INNER JOIN DoctorSpecialityMaster s ON sub.SpecialityId = s.SpecialityId
            WHERE sub.SubSpecialityId = @id";

        return await con.QueryFirstOrDefaultAsync<DoctorSubSpecialityMaster>(sql, new { id });
    }

    public async Task<DoctorSubSpecialityDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                sub.SubSpecialityId,
                sub.SpecialityId,
                s.SpecialityName,
                s.SpecialityCode,
                sub.SubSpecialityCode,
                sub.SubSpecialityName,
                sub.Description,
                sub.IsActive,
                sub.CreatedDate,
                sub.ModifiedDate,
                sub.CreatedBy,
                sub.ModifiedBy
            FROM DoctorSubSpecialityMaster sub
            INNER JOIN DoctorSpecialityMaster s ON sub.SpecialityId = s.SpecialityId
            WHERE sub.SubSpecialityId = @id";

        return await con.QueryFirstOrDefaultAsync<DoctorSubSpecialityDetailsViewModel>(sql, new { id });
    }

    public async Task<IEnumerable<DoctorSubSpecialityMaster>> GetBySpecialityIdAsync(int specialityId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                sub.SubSpecialityId,
                sub.SpecialityId,
                sub.SubSpecialityCode,
                sub.SubSpecialityName,
                sub.Description,
                sub.IsActive,
                sub.CreatedDate
            FROM DoctorSubSpecialityMaster sub
            WHERE sub.SpecialityId = @specialityId AND sub.IsActive = 1
            ORDER BY sub.SubSpecialityName";

        return await con.QueryAsync<DoctorSubSpecialityMaster>(sql, new { specialityId });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM DoctorSubSpecialityMaster
            WHERE SubSpecialityCode = @code
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR SubSpecialityId <> @excludeId)",
            new { code, excludeId, companyId });
        return count > 0;
    }

    public async Task<bool> NameExistsAsync(string name, int specialityId, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM DoctorSubSpecialityMaster
            WHERE SubSpecialityName = @name
              AND SpecialityId = @specialityId
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR SubSpecialityId <> @excludeId)",
            new { name, specialityId, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(DoctorSubSpecialityMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO DoctorSubSpecialityMaster (
                CompanyId, BranchId, SpecialityId, SubSpecialityCode, SubSpecialityName,
                Description, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @SpecialityId, @SubSpecialityCode, @SubSpecialityName,
                @Description, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.SpecialityId,
            model.SubSpecialityCode,
            model.SubSpecialityName,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(DoctorSubSpecialityMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE DoctorSubSpecialityMaster SET
                SpecialityId      = @SpecialityId,
                SubSpecialityCode = @SubSpecialityCode,
                SubSpecialityName = @SubSpecialityName,
                Description       = @Description,
                IsActive          = @IsActive,
                ModifiedBy        = @userId,
                ModifiedDate      = GETDATE()
            WHERE SubSpecialityId = @SubSpecialityId";

        await con.ExecuteAsync(sql, new
        {
            model.SpecialityId,
            model.SubSpecialityCode,
            model.SubSpecialityName,
            model.Description,
            model.IsActive,
            userId,
            model.SubSpecialityId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync(
            "DELETE FROM DoctorSubSpecialityMaster WHERE SubSpecialityId = @id", new { id });
        return rows > 0;
    }

    public async Task<IEnumerable<SelectListItem>> GetSpecialityOptionsAsync(int? selectedId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<DoctorSpecialityMaster>(@"
            SELECT SpecialityId, SpecialityCode, SpecialityName 
            FROM DoctorSpecialityMaster 
            WHERE IsActive = 1 
            ORDER BY SpecialityName");

        return list.Select(s => new SelectListItem
        {
            Value = s.SpecialityId.ToString(),
            Text = $"{s.SpecialityName} ({s.SpecialityCode})",
            Selected = selectedId.HasValue && s.SpecialityId == selectedId.Value
        });
    }
}
