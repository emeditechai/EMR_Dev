using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class FloorService(IDbConnectionFactory db) : IFloorService
{
    public async Task<IEnumerable<FloorMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<FloorMaster>(
            "SELECT * FROM FloorMaster ORDER BY FloorCode");
    }

    public async Task<FloorMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<FloorMaster>(
            "SELECT * FROM FloorMaster WHERE FloorId = @id", new { id });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            @"SELECT COUNT(1) FROM FloorMaster
              WHERE FloorCode = @code
                AND (@excludeId IS NULL OR FloorId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(FloorMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO FloorMaster (FloorCode, FloorName, IsActive, CreatedBy, CreatedDate)
            VALUES (@FloorCode, @FloorName, @IsActive, @userId, GETDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.FloorCode, m.FloorName, m.IsActive, userId });
    }

    public async Task UpdateAsync(FloorMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE FloorMaster SET
                FloorCode     = @FloorCode,
                FloorName     = @FloorName,
                IsActive      = @IsActive,
                ModifiedBy    = @userId,
                ModifiedDate  = GETDATE()
            WHERE FloorId = @FloorId",
            new { m.FloorCode, m.FloorName, m.IsActive, userId, m.FloorId });
    }
}
