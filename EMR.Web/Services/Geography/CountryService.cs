using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services.Geography;

public class CountryService(IDbConnectionFactory db) : ICountryService
{
    public async Task<IEnumerable<CountryMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<CountryMaster>(
            "SELECT * FROM CountryMaster ORDER BY CountryName");
    }

    public async Task<CountryMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<CountryMaster>(
            "SELECT * FROM CountryMaster WHERE CountryId = @id", new { id });
    }

    public async Task<IEnumerable<CountryMaster>> GetActiveAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<CountryMaster>(
            "SELECT CountryId, CountryName, CountryCode, Currency FROM CountryMaster WHERE IsActive = 1 ORDER BY CountryName");
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM CountryMaster WHERE CountryCode = @code AND (@excludeId IS NULL OR CountryId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(CountryMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO CountryMaster (CountryCode, CountryName, Currency, IsActive, CreatedBy, CreatedDate)
            VALUES (@CountryCode, @CountryName, @Currency, @IsActive, @userId, GETUTCDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.CountryCode, m.CountryName, m.Currency, m.IsActive, userId });
    }

    public async Task UpdateAsync(CountryMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE CountryMaster SET
                CountryCode = @CountryCode,
                CountryName = @CountryName,
                Currency = @Currency,
                IsActive = @IsActive,
                ModifiedBy = @userId,
                ModifiedDate = GETUTCDATE()
            WHERE CountryId = @CountryId",
            new { m.CountryCode, m.CountryName, m.Currency, m.IsActive, userId, m.CountryId });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var inUse = await con.ExecuteScalarAsync<int>(
            "SELECT COUNT(1) FROM StateMaster WHERE CountryId = @id", new { id });
        if (inUse > 0) return false;
        await con.ExecuteAsync("DELETE FROM CountryMaster WHERE CountryId = @id", new { id });
        return true;
    }
}
