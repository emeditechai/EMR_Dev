using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;

namespace EMR.Web.Services;

public class DepartmentService(IDbConnectionFactory db) : IDepartmentService
{
    public async Task<IEnumerable<DepartmentMaster>> GetAllAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DepartmentMaster>(
            "SELECT * FROM DepartmentMaster ORDER BY DeptType, DeptCode");
    }

    public async Task<DepartmentMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        return await con.QueryFirstOrDefaultAsync<DepartmentMaster>(
            "SELECT * FROM DepartmentMaster WHERE DeptId = @id", new { id });
    }

    public async Task<IEnumerable<DepartmentMaster>> GetActiveAsync()
    {
        using var con = db.CreateConnection();
        return await con.QueryAsync<DepartmentMaster>(
            "SELECT DeptId, DeptCode, DeptName, DeptType FROM DepartmentMaster WHERE IsActive = 1 ORDER BY DeptType, DeptName");
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(
            @"SELECT COUNT(1) FROM DepartmentMaster
              WHERE DeptCode = @code
                AND (@excludeId IS NULL OR DeptId <> @excludeId)",
            new { code, excludeId });
        return count > 0;
    }

    public async Task<int> CreateAsync(DepartmentMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        return await con.ExecuteScalarAsync<int>(@"
            INSERT INTO DepartmentMaster (DeptCode, DeptName, DeptType, IsActive, CreatedBy, CreatedDate)
            VALUES (@DeptCode, @DeptName, @DeptType, @IsActive, @userId, GETDATE());
            SELECT SCOPE_IDENTITY();",
            new { m.DeptCode, m.DeptName, m.DeptType, m.IsActive, userId });
    }

    public async Task UpdateAsync(DepartmentMaster m, int? userId)
    {
        using var con = db.CreateConnection();
        await con.ExecuteAsync(@"
            UPDATE DepartmentMaster SET
                DeptCode     = @DeptCode,
                DeptName     = @DeptName,
                DeptType     = @DeptType,
                IsActive     = @IsActive,
                ModifiedBy   = @userId,
                ModifiedDate = GETDATE()
            WHERE DeptId = @DeptId",
            new { m.DeptCode, m.DeptName, m.DeptType, m.IsActive, userId, m.DeptId });
    }
}
