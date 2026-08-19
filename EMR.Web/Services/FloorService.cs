using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class FloorService(IDbConnectionFactory db) : IFloorService
{
    public async Task<IEnumerable<FloorMaster>> GetAllAsync(int? buildingId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                f.FloorId,
                f.FloorCode,
                f.FloorName,
                f.BuildingId,
                b.BuildingName,
                b.BuildingCode,
                f.IsActive,
                f.CreatedBy,
                f.CreatedDate,
                f.ModifiedBy,
                f.ModifiedDate
            FROM FloorMaster f
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            WHERE (@buildingId IS NULL OR f.BuildingId = @buildingId)
            ORDER BY b.BuildingCode, f.FloorCode";

        return await con.QueryAsync<FloorMaster>(sql, new { buildingId });
    }

    public async Task<FloorMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                f.FloorId,
                f.FloorCode,
                f.FloorName,
                f.BuildingId,
                b.BuildingName,
                b.BuildingCode,
                f.IsActive,
                f.CreatedBy,
                f.CreatedDate,
                f.ModifiedBy,
                f.ModifiedDate
            FROM FloorMaster f
            LEFT JOIN BuildingMaster b ON f.BuildingId = b.BuildingId
            WHERE f.FloorId = @id";

        return await con.QueryFirstOrDefaultAsync<FloorMaster>(sql, new { id });
    }

    public async Task<bool> CodeExistsAsync(string code, int? buildingId = null, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM FloorMaster
            WHERE FloorCode = @code
              AND (@buildingId IS NULL OR BuildingId = @buildingId)
              AND (@excludeId IS NULL OR FloorId <> @excludeId)",
            new { code, buildingId, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(FloorMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO FloorMaster (FloorCode, FloorName, BuildingId, IsActive, CreatedBy, CreatedDate)
            VALUES (@FloorCode, @FloorName, @BuildingId, @IsActive, @userId, GETDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.FloorCode, m.FloorName, m.BuildingId, m.IsActive, userId });
    }

    public async Task UpdateAsync(FloorMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE FloorMaster SET
                FloorCode     = @FloorCode,
                FloorName     = @FloorName,
                BuildingId    = @BuildingId,
                IsActive      = @IsActive,
                ModifiedBy    = @userId,
                ModifiedDate  = GETDATE()
            WHERE FloorId = @FloorId",
            new { m.FloorCode, m.FloorName, m.BuildingId, m.IsActive, userId, m.FloorId });
    }
}
