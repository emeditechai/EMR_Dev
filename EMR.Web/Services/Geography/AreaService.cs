using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public class AreaService(IDbConnectionFactory db) : IAreaService
{
    public async Task<IEnumerable<AreaMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<AreaMaster, CityMaster, AreaMaster>(@"
            SELECT a.*, c.CityId, c.CityName FROM AreaMaster a
            INNER JOIN CityMaster c ON a.CityId = c.CityId
            ORDER BY a.AreaName",
            (a, c) => { a.City = c; return a; },
            splitOn: "CityId");
    }

    public async Task<AreaMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var results = await con.QueryAsync<AreaMaster, CityMaster, AreaMaster>(@"
            SELECT a.*, c.CityId, c.CityName FROM AreaMaster a
            INNER JOIN CityMaster c ON a.CityId = c.CityId
            WHERE a.AreaId = @id",
            (a, c) => { a.City = c; return a; },
            new { id }, splitOn: "CityId");
        return results.FirstOrDefault();
    }

    public async Task<IEnumerable<AreaMaster>> GetByCityAsync(int cityId)
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<AreaMaster>(
            "SELECT AreaId, AreaName, AreaCode FROM AreaMaster WHERE CityId = @cityId AND IsActive = 1 ORDER BY AreaName",
            new { cityId });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM AreaMaster WHERE AreaCode = @code AND (@excludeId IS NULL OR AreaId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(AreaMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO AreaMaster (AreaCode, AreaName, CityId, IsActive, CreatedBy, CreatedDate)
            VALUES (@AreaCode, @AreaName, @CityId, @IsActive, @userId, GETUTCDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.AreaCode, m.AreaName, m.CityId, m.IsActive, userId });
    }

    public async Task UpdateAsync(AreaMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE AreaMaster SET
                AreaCode = @AreaCode, AreaName = @AreaName,
                CityId = @CityId, IsActive = @IsActive,
                ModifiedBy = @userId, ModifiedDate = GETUTCDATE()
            WHERE AreaId = @AreaId",
            new { m.AreaCode, m.AreaName, m.CityId, m.IsActive, userId, m.AreaId });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        // AreaMaster is the leaf — nothing depends on it
        await con.ExecuteAsync("DELETE FROM AreaMaster WHERE AreaId = @id", new { id });
        return true;
    }
}
