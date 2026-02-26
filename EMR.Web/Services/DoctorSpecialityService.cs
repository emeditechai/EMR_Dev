using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class DoctorSpecialityService(IDbConnectionFactory db) : IDoctorSpecialityService
{
    public async Task<IEnumerable<DoctorSpecialityMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorSpecialityMaster>(
            "SELECT * FROM DoctorSpecialityMaster ORDER BY SpecialityName");
    }

    public async Task<DoctorSpecialityMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DoctorSpecialityMaster>(
            "SELECT * FROM DoctorSpecialityMaster WHERE SpecialityId = @id", new { id });
    }

    public async Task<IEnumerable<DoctorSpecialityMaster>> GetActiveAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DoctorSpecialityMaster>(
            "SELECT SpecialityId, SpecialityName FROM DoctorSpecialityMaster WHERE IsActive = 1 ORDER BY SpecialityName");
    }

    public async Task<bool> NameExistsAsync(string name, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            @"SELECT COUNT(1) FROM DoctorSpecialityMaster
              WHERE SpecialityName = @name
                AND (@excludeId IS NULL OR SpecialityId <> @excludeId)",
            new { name, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(DoctorSpecialityMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO DoctorSpecialityMaster (SpecialityName, IsActive, CreatedBy, CreatedDate)
            VALUES (@SpecialityName, @IsActive, @userId, GETUTCDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.SpecialityName, m.IsActive, userId });
    }

    public async Task UpdateAsync(DoctorSpecialityMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE DoctorSpecialityMaster SET
                SpecialityName = @SpecialityName,
                IsActive       = @IsActive,
                ModifiedBy     = @userId,
                ModifiedDate   = GETUTCDATE()
            WHERE SpecialityId = @SpecialityId",
            new { m.SpecialityName, m.IsActive, userId, m.SpecialityId });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        // Guard: prevent delete if doctors are linked (future-proof)
        var inUse = await con.ExecuteScalarAsync<int>(
            @"SELECT COUNT(1) FROM INFORMATION_SCHEMA.TABLES
              WHERE TABLE_NAME = 'DoctorMaster'");
        if (inUse > 0)
        {
            var linked = await con.ExecuteScalarAsync<int>(
                "SELECT COUNT(1) FROM DoctorMaster WHERE SpecialityId = @id", new { id });
            if (linked > 0) return false;
        }
        await con.ExecuteAsync(
            "DELETE FROM DoctorSpecialityMaster WHERE SpecialityId = @id", new { id });
        return true;
    }
}
