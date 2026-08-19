using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class BuildingService(IDbConnectionFactory db) : IBuildingService
{
    public async Task<IEnumerable<BuildingListItemViewModel>> GetAllAsync(int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                b.BuildingId,
                b.BuildingCode,
                b.BuildingName,
                b.Description,
                b.NumberOfFloors,
                (SELECT COUNT(1) FROM FloorMaster f WHERE f.BuildingId = b.BuildingId) AS TotalFloorsConfigured,
                b.IsActive,
                b.CreatedDate
            FROM BuildingMaster b
            WHERE (@companyId IS NULL OR b.CompanyId = @companyId)
              AND (@branchId IS NULL OR b.BranchId = @branchId OR b.BranchId IS NULL)
            ORDER BY b.BuildingCode";

        return await con.QueryAsync<BuildingListItemViewModel>(sql, new { companyId, branchId });
    }

    public async Task<BuildingMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<BuildingMaster>(
            "SELECT * FROM BuildingMaster WHERE BuildingId = @id", new { id });
    }

    public async Task<BuildingDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var building = await con.QueryFirstOrDefaultAsync<BuildingDetailsViewModel>(
            "SELECT * FROM BuildingMaster WHERE BuildingId = @id", new { id });

        if (building == null) return null;

        var floors = await con.QueryAsync<FloorMaster>(
            "SELECT * FROM FloorMaster WHERE BuildingId = @id ORDER BY FloorCode", new { id });

        building.Floors = floors.AsList();
        return building;
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM BuildingMaster
            WHERE BuildingCode = @code
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR BuildingId <> @excludeId)",
            new { code, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(BuildingMaster building, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO BuildingMaster (
                CompanyId, BranchId, BuildingCode, BuildingName, Description,
                NumberOfFloors, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @BuildingCode, @BuildingName, @Description,
                @NumberOfFloors, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            building.CompanyId,
            building.BranchId,
            building.BuildingCode,
            building.BuildingName,
            building.Description,
            building.NumberOfFloors,
            building.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(BuildingMaster building, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE BuildingMaster SET
                BuildingCode   = @BuildingCode,
                BuildingName   = @BuildingName,
                Description    = @Description,
                NumberOfFloors = @NumberOfFloors,
                IsActive       = @IsActive,
                ModifiedBy     = @userId,
                ModifiedDate   = GETDATE()
            WHERE BuildingId = @BuildingId";

        await con.ExecuteAsync(sql, new
        {
            building.BuildingCode,
            building.BuildingName,
            building.Description,
            building.NumberOfFloors,
            building.IsActive,
            userId,
            building.BuildingId
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetBuildingOptionsAsync(int? companyId = null, int? selectedId = null)
    {
        using var con = db.CreateConnection();
        var buildings = await con.QueryAsync<BuildingMaster>(@"
            SELECT BuildingId, BuildingCode, BuildingName 
            FROM BuildingMaster 
            WHERE IsActive = 1 AND (@companyId IS NULL OR CompanyId = @companyId)
            ORDER BY BuildingName", new { companyId });

        return buildings.Select(b => new SelectListItem
        {
            Value = b.BuildingId.ToString(),
            Text = $"{b.BuildingName} ({b.BuildingCode})",
            Selected = selectedId.HasValue && b.BuildingId == selectedId.Value
        });
    }
}
