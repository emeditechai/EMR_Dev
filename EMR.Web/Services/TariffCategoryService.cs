using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class TariffCategoryService(IDbConnectionFactory db) : ITariffCategoryService
{
    public async Task<IEnumerable<TariffCategoryListItemViewModel>> GetAllAsync(
        string? patientCategory = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                TariffCategoryId,
                Code,
                Name,
                PatientCategory,
                Description,
                IsActive,
                CreatedDate
            FROM TariffCategoryMaster
            WHERE (@patientCategory IS NULL OR PatientCategory = @patientCategory)
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@branchId IS NULL OR BranchId = @branchId OR BranchId IS NULL)
            ORDER BY Code, Name";

        return await con.QueryAsync<TariffCategoryListItemViewModel>(sql, new { patientCategory, companyId, branchId });
    }

    public async Task<TariffCategoryMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                TariffCategoryId,
                CompanyId,
                BranchId,
                Code,
                Name,
                PatientCategory,
                Description,
                IsActive,
                CreatedBy,
                CreatedDate,
                ModifiedBy,
                ModifiedDate
            FROM TariffCategoryMaster
            WHERE TariffCategoryId = @id";

        return await con.QueryFirstOrDefaultAsync<TariffCategoryMaster>(sql, new { id });
    }

    public async Task<TariffCategoryDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                TariffCategoryId,
                CompanyId,
                BranchId,
                Code,
                Name,
                PatientCategory,
                Description,
                IsActive,
                CreatedDate,
                ModifiedDate,
                CreatedBy,
                ModifiedBy
            FROM TariffCategoryMaster
            WHERE TariffCategoryId = @id";

        return await con.QueryFirstOrDefaultAsync<TariffCategoryDetailsViewModel>(sql, new { id });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM TariffCategoryMaster
            WHERE Code = @code
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR TariffCategoryId <> @excludeId)",
            new { code, excludeId, companyId });
        return count > 0;
    }

    public async Task<bool> NameExistsAsync(string name, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM TariffCategoryMaster
            WHERE LOWER(Name) = LOWER(@name)
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR TariffCategoryId <> @excludeId)",
            new { name, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(TariffCategoryMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO TariffCategoryMaster (
                CompanyId, BranchId, Code, Name, PatientCategory,
                Description, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @Code, @Name, @PatientCategory,
                @Description, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.Code,
            model.Name,
            model.PatientCategory,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(TariffCategoryMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE TariffCategoryMaster SET
                Code            = @Code,
                Name            = @Name,
                PatientCategory = @PatientCategory,
                Description     = @Description,
                IsActive        = @IsActive,
                ModifiedBy      = @userId,
                ModifiedDate    = GETDATE()
            WHERE TariffCategoryId = @TariffCategoryId";

        await con.ExecuteAsync(sql, new
        {
            model.Code,
            model.Name,
            model.PatientCategory,
            model.Description,
            model.IsActive,
            userId,
            model.TariffCategoryId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync("DELETE FROM TariffCategoryMaster WHERE TariffCategoryId = @id", new { id });
        return rows > 0;
    }

    public IEnumerable<SelectListItem> GetPatientCategoryOptions(string? selectedCategory = null)
    {
        var categories = new[]
        {
            "Cash / Self Pay",
            "Corporate",
            "Insurance / TPA",
            "Government / Public Scheme",
            "Staff / Employee",
            "Senior Citizen",
            "Charity / Subsidized",
            "VIP / Executive"
        };

        return categories.Select(c => new SelectListItem
        {
            Value = c,
            Text = c,
            Selected = string.Equals(c, selectedCategory, StringComparison.OrdinalIgnoreCase)
        });
    }
}
