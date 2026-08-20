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

    public async Task<IEnumerable<SelectListItem>> GetNurseOptionsAsync(int? companyId = null, int? branchId = null, string? selectedNurse = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                u.Id,
                u.Username,
                COALESCE(u.FullName, u.FirstName + ' ' + u.LastName, u.Username) AS FullName,
                (SELECT TOP 1 ub.EmployeeCode FROM UserBranches ub WHERE ub.UserId = u.Id AND ub.IsActive = 1) AS EmployeeCode
            FROM Users u
            WHERE u.IsNursingStaff = 1
              AND u.IsActive = 1
              AND (@companyId IS NULL OR u.CompanyId = @companyId)
              AND (@branchId IS NULL OR EXISTS (SELECT 1 FROM UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchId = @branchId AND ub.IsActive = 1))
            ORDER BY FullName";

        var users = (await con.QueryAsync(sql, new { companyId, branchId })).ToList();

        var items = new List<SelectListItem>();

        foreach (var u in users)
        {
            string fullName = (string)u.FullName;
            string? empCode = (string?)u.EmployeeCode;
            string? username = (string?)u.Username;
            string display = !string.IsNullOrWhiteSpace(empCode)
                ? $"{fullName} ({empCode})"
                : (!string.IsNullOrWhiteSpace(username) ? $"{fullName} ({username})" : fullName);

            items.Add(new SelectListItem
            {
                Value = fullName,
                Text = display,
                Selected = string.Equals(fullName, selectedNurse, StringComparison.OrdinalIgnoreCase)
            });
        }

        // If a previously selected nurse exists but is not in the current list, preserve it as an option
        if (!string.IsNullOrWhiteSpace(selectedNurse) && !items.Any(x => string.Equals(x.Value, selectedNurse, StringComparison.OrdinalIgnoreCase)))
        {
            items.Insert(0, new SelectListItem
            {
                Value = selectedNurse,
                Text = $"{selectedNurse} (Current In-Charge)",
                Selected = true
            });
        }

        return items;
    }
}

