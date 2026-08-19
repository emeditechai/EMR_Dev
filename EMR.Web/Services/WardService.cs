using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class WardService(IDbConnectionFactory db) : IWardService
{
    public async Task<IEnumerable<WardListItemViewModel>> GetAllAsync(
        int? floorId = null, int? departmentId = null, string? wardType = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                w.WardId,
                w.WardCode,
                w.WardName,
                w.FloorId,
                f.FloorName,
                b.BuildingName,
                w.DepartmentId,
                d.DeptName AS DepartmentName,
                w.WardType,
                w.Gender,
                w.Capacity,
                w.IsIsolationWard,
                w.IsActive,
                w.CreatedDate,
                (SELECT COUNT(1) FROM NursingStationMaster ns WHERE ns.WardId = w.WardId) AS TotalNursingStations
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            INNER JOIN DepartmentMaster d ON w.DepartmentId = d.DeptId
            WHERE (@floorId IS NULL OR w.FloorId = @floorId)
              AND (@departmentId IS NULL OR w.DepartmentId = @departmentId)
              AND (@wardType IS NULL OR w.WardType = @wardType)
              AND (@companyId IS NULL OR w.CompanyId = @companyId)
              AND (@branchId IS NULL OR w.BranchId = @branchId OR w.BranchId IS NULL)
            ORDER BY b.BuildingCode, f.FloorCode, w.WardName";

        return await con.QueryAsync<WardListItemViewModel>(sql, new { floorId, departmentId, wardType, companyId, branchId });
    }

    public async Task<WardMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                w.WardId,
                w.CompanyId,
                w.BranchId,
                w.FloorId,
                f.FloorName,
                f.FloorCode,
                b.BuildingName,
                w.DepartmentId,
                d.DeptName AS DepartmentName,
                d.DeptCode AS DepartmentCode,
                w.WardCode,
                w.WardName,
                w.WardType,
                w.Gender,
                w.Capacity,
                w.IsIsolationWard,
                w.Description,
                w.IsActive,
                w.CreatedBy,
                w.CreatedDate,
                w.ModifiedBy,
                w.ModifiedDate
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            INNER JOIN DepartmentMaster d ON w.DepartmentId = d.DeptId
            WHERE w.WardId = @id";

        return await con.QueryFirstOrDefaultAsync<WardMaster>(sql, new { id });
    }

    public async Task<WardDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                w.WardId,
                w.CompanyId,
                w.BranchId,
                w.FloorId,
                f.FloorName,
                f.FloorCode,
                b.BuildingName,
                w.DepartmentId,
                d.DeptName AS DepartmentName,
                d.DeptCode AS DepartmentCode,
                w.WardCode,
                w.WardName,
                w.WardType,
                w.Gender,
                w.Capacity,
                w.IsIsolationWard,
                w.Description,
                w.IsActive,
                w.CreatedDate,
                w.ModifiedDate,
                w.CreatedBy,
                w.ModifiedBy
            FROM WardMaster w
            INNER JOIN FloorMaster f ON w.FloorId = f.FloorId
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            INNER JOIN DepartmentMaster d ON w.DepartmentId = d.DeptId
            WHERE w.WardId = @id";

        var ward = await con.QueryFirstOrDefaultAsync<WardDetailsViewModel>(sql, new { id });
        if (ward != null)
        {
            var stationsSql = @"
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
                WHERE ns.WardId = @id
                ORDER BY ns.StationName";

            ward.NursingStations = (await con.QueryAsync<NursingStationListItemViewModel>(stationsSql, new { id })).AsList();
        }

        return ward;
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM WardMaster
            WHERE WardCode = @code
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR WardId <> @excludeId)",
            new { code, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(WardMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO WardMaster (
                CompanyId, BranchId, FloorId, DepartmentId, WardCode, WardName,
                WardType, Gender, Capacity, IsIsolationWard, Description, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @FloorId, @DepartmentId, @WardCode, @WardName,
                @WardType, @Gender, @Capacity, @IsIsolationWard, @Description, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.FloorId,
            model.DepartmentId,
            model.WardCode,
            model.WardName,
            model.WardType,
            model.Gender,
            model.Capacity,
            model.IsIsolationWard,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(WardMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE WardMaster SET
                FloorId         = @FloorId,
                DepartmentId    = @DepartmentId,
                WardCode        = @WardCode,
                WardName        = @WardName,
                WardType        = @WardType,
                Gender          = @Gender,
                Capacity        = @Capacity,
                IsIsolationWard = @IsIsolationWard,
                Description     = @Description,
                IsActive        = @IsActive,
                ModifiedBy      = @userId,
                ModifiedDate    = GETDATE()
            WHERE WardId = @WardId";

        await con.ExecuteAsync(sql, new
        {
            model.FloorId,
            model.DepartmentId,
            model.WardCode,
            model.WardName,
            model.WardType,
            model.Gender,
            model.Capacity,
            model.IsIsolationWard,
            model.Description,
            model.IsActive,
            userId,
            model.WardId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync(
            "DELETE FROM WardMaster WHERE WardId = @id", new { id });
        return rows > 0;
    }

    public async Task<IEnumerable<SelectListItem>> GetFloorOptionsAsync(int? selectedId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<FloorMaster>(@"
            SELECT f.FloorId, f.FloorCode, f.FloorName, b.BuildingName 
            FROM FloorMaster f
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            WHERE f.IsActive = 1 
            ORDER BY b.BuildingCode, f.FloorCode");

        return list.Select(f => new SelectListItem
        {
            Value = f.FloorId.ToString(),
            Text = string.IsNullOrWhiteSpace(f.BuildingName)
                ? $"{f.FloorName} ({f.FloorCode})"
                : $"{f.FloorName} ({f.FloorCode}) - {f.BuildingName}",
            Selected = selectedId.HasValue && f.FloorId == selectedId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetIpdDepartmentOptionsAsync(int? selectedId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<DepartmentMaster>(@"
            SELECT DeptId, DeptCode, DeptName, DeptType 
            FROM DepartmentMaster 
            WHERE DeptType = 'IPD' AND IsActive = 1 
            ORDER BY DeptName");

        return list.Select(d => new SelectListItem
        {
            Value = d.DeptId.ToString(),
            Text = $"{d.DeptName} ({d.DeptCode})",
            Selected = selectedId.HasValue && d.DeptId == selectedId.Value
        });
    }

    public IEnumerable<SelectListItem> GetWardTypeOptions(string? selectedType = null)
    {
        var types = new[]
        {
            "General Ward",
            "Semi-Private Ward",
            "Private Room",
            "Deluxe Ward",
            "ICU (Intensive Care)",
            "CCU (Coronary Care)",
            "NICU (Neonatal ICU)",
            "PICU (Pediatric ICU)",
            "HDU (High Dependency)",
            "Isolation Ward",
            "Post-Operative Recovery",
            "Day Care Ward",
            "Emergency Observation"
        };

        return types.Select(t => new SelectListItem
        {
            Value = t,
            Text = t,
            Selected = string.Equals(t, selectedType, StringComparison.OrdinalIgnoreCase)
        });
    }

    public IEnumerable<SelectListItem> GetGenderOptions(string? selectedGender = null)
    {
        var genders = new[] { "Unisex / All", "Male", "Female", "Other" };
        return genders.Select(g => new SelectListItem
        {
            Value = g,
            Text = g,
            Selected = string.Equals(g, selectedGender, StringComparison.OrdinalIgnoreCase)
        });
    }
}
