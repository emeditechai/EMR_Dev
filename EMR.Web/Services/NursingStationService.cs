using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class NursingStationService(IDbConnectionFactory db) : INursingStationService
{
    public async Task<IEnumerable<NursingStationListItemViewModel>> GetAllAsync(
        int? wardId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                ns.NursingStationId,
                ns.StationCode,
                ns.StationName,
                ns.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                f.FloorName,
                ns.ResponsibleNurse,
                ns.Description,
                ns.IsActive,
                ns.CreatedDate
            FROM NursingStationMaster ns
            INNER JOIN WardMaster w ON ns.WardId = w.WardId
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            WHERE (@wardId IS NULL OR ns.WardId = @wardId)
              AND (@companyId IS NULL OR ns.CompanyId = @companyId)
              AND (@branchId IS NULL OR ns.BranchId = @branchId OR ns.BranchId IS NULL)
            ORDER BY w.WardCode, ns.StationCode";

        return await con.QueryAsync<NursingStationListItemViewModel>(sql, new { wardId, companyId, branchId });
    }

    public async Task<NursingStationMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                ns.NursingStationId,
                ns.CompanyId,
                ns.BranchId,
                ns.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                f.FloorName,
                ns.StationCode,
                ns.StationName,
                ns.ResponsibleNurse,
                ns.Description,
                ns.IsActive,
                ns.CreatedBy,
                ns.CreatedDate,
                ns.ModifiedBy,
                ns.ModifiedDate
            FROM NursingStationMaster ns
            INNER JOIN WardMaster w ON ns.WardId = w.WardId
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            WHERE ns.NursingStationId = @id";

        return await con.QueryFirstOrDefaultAsync<NursingStationMaster>(sql, new { id });
    }

    public async Task<NursingStationDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                ns.NursingStationId,
                ns.CompanyId,
                ns.BranchId,
                ns.WardId,
                w.WardName,
                w.WardCode,
                w.WardType,
                f.FloorName,
                b.BuildingName,
                ns.StationCode,
                ns.StationName,
                ns.ResponsibleNurse,
                ns.Description,
                ns.IsActive,
                ns.CreatedDate,
                ns.ModifiedDate,
                ns.CreatedBy,
                ns.ModifiedBy
            FROM NursingStationMaster ns
            INNER JOIN WardMaster w ON ns.WardId = w.WardId
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            WHERE ns.NursingStationId = @id";

        return await con.QueryFirstOrDefaultAsync<NursingStationDetailsViewModel>(sql, new { id });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM NursingStationMaster
            WHERE StationCode = @code
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR NursingStationId <> @excludeId)",
            new { code, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(NursingStationMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO NursingStationMaster (
                CompanyId, BranchId, WardId, StationCode, StationName,
                ResponsibleNurse, Description, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @WardId, @StationCode, @StationName,
                @ResponsibleNurse, @Description, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.WardId,
            model.StationCode,
            model.StationName,
            model.ResponsibleNurse,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(NursingStationMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE NursingStationMaster SET
                WardId           = @WardId,
                StationCode      = @StationCode,
                StationName      = @StationName,
                ResponsibleNurse = @ResponsibleNurse,
                Description      = @Description,
                IsActive         = @IsActive,
                ModifiedBy       = @userId,
                ModifiedDate     = GETDATE()
            WHERE NursingStationId = @NursingStationId";

        await con.ExecuteAsync(sql, new
        {
            model.WardId,
            model.StationCode,
            model.StationName,
            model.ResponsibleNurse,
            model.Description,
            model.IsActive,
            userId,
            model.NursingStationId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync(
            "DELETE FROM NursingStationMaster WHERE NursingStationId = @id", new { id });
        return rows > 0;
    }

    public async Task<IEnumerable<SelectListItem>> GetWardOptionsAsync(int? selectedWardId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<WardMaster>(@"
            SELECT w.WardId, w.WardCode, w.WardName, w.WardType, f.FloorName
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            WHERE w.IsActive = 1
            ORDER BY w.WardName");

        return list.Select(w => new SelectListItem
        {
            Value = w.WardId.ToString(),
            Text = $"{w.WardName} ({w.WardCode}) - {w.WardType}",
            Selected = selectedWardId.HasValue && w.WardId == selectedWardId.Value
        });
    }

    public IEnumerable<SelectListItem> GetNurseOptions(string? selectedNurse = null)
    {
        var sampleNurses = new[]
        {
            "Sr. Nurse Priya Sharma (Nursing Supervisor)",
            "Sr. Nurse Anjali Menon (ICU In-Charge)",
            "Nurse Sunita Paul (Ward In-Charge)",
            "Nurse Rajeshwari Nair (Staff Nurse)",
            "Nurse Kavita Deshmukh (Staff Nurse)",
            "Nurse Pooja Sengupta (Staff Nurse)",
            "Duty Nursing Officer (Rotating Shift)"
        };

        return sampleNurses.Select(n => new SelectListItem
        {
            Value = n,
            Text = n,
            Selected = string.Equals(n, selectedNurse, StringComparison.OrdinalIgnoreCase)
        });
    }
}
