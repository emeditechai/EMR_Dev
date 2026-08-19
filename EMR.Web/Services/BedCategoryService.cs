using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;

namespace EMR.Web.Services;

public class BedCategoryService(IDbConnectionFactory db) : IBedCategoryService
{
    public async Task<IEnumerable<BedCategoryListItemViewModel>> GetAllAsync(int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                BedCategoryId,
                CategoryCode,
                CategoryName,
                Description,
                IsActive,
                CreatedDate
            FROM BedCategoryMaster
            WHERE (@companyId IS NULL OR CompanyId = @companyId)
              AND (@branchId IS NULL OR BranchId = @branchId OR BranchId IS NULL)
            ORDER BY CategoryName";

        return await con.QueryAsync<BedCategoryListItemViewModel>(sql, new { companyId, branchId });
    }

    public async Task<BedCategoryMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                BedCategoryId,
                CompanyId,
                BranchId,
                CategoryCode,
                CategoryName,
                Description,
                IsActive,
                CreatedBy,
                CreatedDate,
                ModifiedBy,
                ModifiedDate
            FROM BedCategoryMaster
            WHERE BedCategoryId = @id";

        return await con.QueryFirstOrDefaultAsync<BedCategoryMaster>(sql, new { id });
    }

    public async Task<BedCategoryDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                BedCategoryId,
                CompanyId,
                BranchId,
                CategoryCode,
                CategoryName,
                Description,
                IsActive,
                CreatedDate,
                ModifiedDate,
                CreatedBy,
                ModifiedBy
            FROM BedCategoryMaster
            WHERE BedCategoryId = @id";

        return await con.QueryFirstOrDefaultAsync<BedCategoryDetailsViewModel>(sql, new { id });
    }

    public async Task<bool> NameExistsAsync(string name, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM BedCategoryMaster
            WHERE LOWER(CategoryName) = LOWER(@name)
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR BedCategoryId <> @excludeId)",
            new { name, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(BedCategoryMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO BedCategoryMaster (
                CompanyId, BranchId, CategoryCode, CategoryName,
                Description, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @CategoryCode, @CategoryName,
                @Description, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.CategoryCode,
            model.CategoryName,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(BedCategoryMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE BedCategoryMaster SET
                CategoryCode = @CategoryCode,
                CategoryName = @CategoryName,
                Description  = @Description,
                IsActive     = @IsActive,
                ModifiedBy   = @userId,
                ModifiedDate = GETDATE()
            WHERE BedCategoryId = @BedCategoryId";

        await con.ExecuteAsync(sql, new
        {
            model.CategoryCode,
            model.CategoryName,
            model.Description,
            model.IsActive,
            userId,
            model.BedCategoryId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync("DELETE FROM BedCategoryMaster WHERE BedCategoryId = @id", new { id });
        return rows > 0;
    }
}
