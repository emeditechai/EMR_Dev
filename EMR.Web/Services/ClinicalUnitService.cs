using Dapper;
using EMR.Web.Data;
using EMR.Web.Models.Entities;
using EMR.Web.Models.ViewModels;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EMR.Web.Services;

public class ClinicalUnitService(IDbConnectionFactory db) : IClinicalUnitService
{
    public async Task<IEnumerable<ClinicalUnitListItemViewModel>> GetAllAsync(
        int? departmentId = null, int? specialityId = null, int? companyId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                u.UnitId,
                u.UnitCode,
                u.UnitName,
                u.DepartmentId,
                dept.DeptName AS DepartmentName,
                dept.DeptCode AS DepartmentCode,
                u.SpecialityId,
                s.SpecialityName,
                s.SpecialityCode,
                u.ConsultantInChargeDoctorId,
                ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultantName,
                u.Description,
                u.IsActive,
                u.CreatedDate
            FROM ClinicalUnitMaster u
            INNER JOIN DepartmentMaster dept ON u.DepartmentId = dept.DeptId
            INNER JOIN DoctorSpecialityMaster s ON u.SpecialityId = s.SpecialityId
            LEFT JOIN DoctorMaster d ON u.ConsultantInChargeDoctorId = d.DoctorId
            WHERE (@departmentId IS NULL OR u.DepartmentId = @departmentId)
              AND (@specialityId IS NULL OR u.SpecialityId = @specialityId)
              AND (@companyId IS NULL OR u.CompanyId = @companyId)
              AND (@branchId IS NULL OR u.BranchId = @branchId OR u.BranchId IS NULL)
            ORDER BY dept.DeptName, s.SpecialityName, u.UnitName";

        return await con.QueryAsync<ClinicalUnitListItemViewModel>(sql, new { departmentId, specialityId, companyId, branchId });
    }

    public async Task<ClinicalUnitMaster?> GetByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                u.UnitId,
                u.CompanyId,
                u.BranchId,
                u.DepartmentId,
                dept.DeptName AS DepartmentName,
                dept.DeptCode AS DepartmentCode,
                u.SpecialityId,
                s.SpecialityName,
                s.SpecialityCode,
                u.UnitCode,
                u.UnitName,
                u.ConsultantInChargeDoctorId,
                ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultantName,
                u.Description,
                u.IsActive,
                u.CreatedBy,
                u.CreatedDate,
                u.ModifiedBy,
                u.ModifiedDate
            FROM ClinicalUnitMaster u
            INNER JOIN DepartmentMaster dept ON u.DepartmentId = dept.DeptId
            INNER JOIN DoctorSpecialityMaster s ON u.SpecialityId = s.SpecialityId
            LEFT JOIN DoctorMaster d ON u.ConsultantInChargeDoctorId = d.DoctorId
            WHERE u.UnitId = @id";

        return await con.QueryFirstOrDefaultAsync<ClinicalUnitMaster>(sql, new { id });
    }

    public async Task<ClinicalUnitDetailsViewModel?> GetDetailsByIdAsync(int id)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                u.UnitId,
                u.CompanyId,
                u.BranchId,
                u.DepartmentId,
                dept.DeptName AS DepartmentName,
                dept.DeptCode AS DepartmentCode,
                dept.DeptType AS DepartmentType,
                u.SpecialityId,
                s.SpecialityName,
                s.SpecialityCode,
                u.UnitCode,
                u.UnitName,
                u.ConsultantInChargeDoctorId,
                ISNULL(d.NamePrefix + ' ', '') + d.FullName AS ConsultantName,
                d.PhoneNumber AS ConsultantPhoneNumber,
                d.EmailId AS ConsultantEmail,
                u.Description,
                u.IsActive,
                u.CreatedDate,
                u.ModifiedDate,
                u.CreatedBy,
                u.ModifiedBy
            FROM ClinicalUnitMaster u
            INNER JOIN DepartmentMaster dept ON u.DepartmentId = dept.DeptId
            INNER JOIN DoctorSpecialityMaster s ON u.SpecialityId = s.SpecialityId
            LEFT JOIN DoctorMaster d ON u.ConsultantInChargeDoctorId = d.DoctorId
            WHERE u.UnitId = @id";

        return await con.QueryFirstOrDefaultAsync<ClinicalUnitDetailsViewModel>(sql, new { id });
    }

    public async Task<bool> CodeExistsAsync(string code, int? excludeId = null, int? companyId = null)
    {
        using var con = db.CreateConnection();
        var count = await con.ExecuteScalarAsync<int>(@"
            SELECT COUNT(1) FROM ClinicalUnitMaster
            WHERE UnitCode = @code
              AND (@companyId IS NULL OR CompanyId = @companyId)
              AND (@excludeId IS NULL OR UnitId <> @excludeId)",
            new { code, excludeId, companyId });
        return count > 0;
    }

    public async Task<int> CreateAsync(ClinicalUnitMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            INSERT INTO ClinicalUnitMaster (
                CompanyId, BranchId, DepartmentId, SpecialityId, UnitCode, UnitName,
                ConsultantInChargeDoctorId, Description, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @CompanyId, @BranchId, @DepartmentId, @SpecialityId, @UnitCode, @UnitName,
                @ConsultantInChargeDoctorId, @Description, @IsActive, @userId, GETDATE()
            );
            SELECT SCOPE_IDENTITY();";

        return await con.ExecuteScalarAsync<int>(sql, new
        {
            model.CompanyId,
            model.BranchId,
            model.DepartmentId,
            model.SpecialityId,
            model.UnitCode,
            model.UnitName,
            model.ConsultantInChargeDoctorId,
            model.Description,
            model.IsActive,
            userId
        });
    }

    public async Task UpdateAsync(ClinicalUnitMaster model, int? userId)
    {
        using var con = db.CreateConnection();
        var sql = @"
            UPDATE ClinicalUnitMaster SET
                DepartmentId               = @DepartmentId,
                SpecialityId               = @SpecialityId,
                UnitCode                   = @UnitCode,
                UnitName                   = @UnitName,
                ConsultantInChargeDoctorId = @ConsultantInChargeDoctorId,
                Description                = @Description,
                IsActive                   = @IsActive,
                ModifiedBy                 = @userId,
                ModifiedDate               = GETDATE()
            WHERE UnitId = @UnitId";

        await con.ExecuteAsync(sql, new
        {
            model.DepartmentId,
            model.SpecialityId,
            model.UnitCode,
            model.UnitName,
            model.ConsultantInChargeDoctorId,
            model.Description,
            model.IsActive,
            userId,
            model.UnitId
        });
    }

    public async Task<bool> DeleteAsync(int id)
    {
        using var con = db.CreateConnection();
        var rows = await con.ExecuteAsync(
            "DELETE FROM ClinicalUnitMaster WHERE UnitId = @id", new { id });
        return rows > 0;
    }

    public async Task<IEnumerable<DoctorOptionDto>> GetDoctorsBySpecialityAsync(int? specialityId = null, int? branchId = null)
    {
        using var con = db.CreateConnection();
        var sql = @"
            SELECT 
                d.DoctorId,
                ISNULL(d.NamePrefix + ' ', '') + d.FullName AS FullName,
                d.PrimarySpecialityId,
                s.SpecialityName
            FROM DoctorMaster d
            INNER JOIN DoctorSpecialityMaster s ON d.PrimarySpecialityId = s.SpecialityId
            WHERE d.IsActive = 1
              AND (@specialityId IS NULL OR d.PrimarySpecialityId = @specialityId OR d.SecondarySpecialityId = @specialityId)
              AND (@branchId IS NULL OR d.CreatedBranchId = @branchId OR EXISTS (
                  SELECT 1 FROM DoctorBranchMap dbm WHERE dbm.DoctorId = d.DoctorId AND dbm.BranchId = @branchId AND dbm.IsActive = 1
              ))
            ORDER BY d.FullName";

        return await con.QueryAsync<DoctorOptionDto>(sql, new { specialityId, branchId });
    }

    public async Task<IEnumerable<SelectListItem>> GetDepartmentOptionsAsync(int? selectedId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<DepartmentMaster>(@"
            SELECT DeptId, DeptCode, DeptName, DeptType 
            FROM DepartmentMaster 
            WHERE IsActive = 1 
            ORDER BY DeptType, DeptName");

        return list.Select(d => new SelectListItem
        {
            Value = d.DeptId.ToString(),
            Text = $"{d.DeptName} ({d.DeptCode} - {d.DeptType})",
            Selected = selectedId.HasValue && d.DeptId == selectedId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetSpecialityOptionsAsync(int? selectedId = null)
    {
        using var con = db.CreateConnection();
        var list = await con.QueryAsync<DoctorSpecialityMaster>(@"
            SELECT SpecialityId, SpecialityCode, SpecialityName 
            FROM DoctorSpecialityMaster 
            WHERE IsActive = 1 
            ORDER BY SpecialityName");

        return list.Select(s => new SelectListItem
        {
            Value = s.SpecialityId.ToString(),
            Text = $"{s.SpecialityName} ({s.SpecialityCode})",
            Selected = selectedId.HasValue && s.SpecialityId == selectedId.Value
        });
    }

    public async Task<IEnumerable<SelectListItem>> GetDoctorOptionsAsync(int? specialityId = null, int? selectedDoctorId = null, int? branchId = null)
    {
        var doctors = await GetDoctorsBySpecialityAsync(specialityId, branchId);
        return doctors.Select(doc => new SelectListItem
        {
            Value = doc.DoctorId.ToString(),
            Text = $"{doc.FullName} ({doc.SpecialityName})",
            Selected = selectedDoctorId.HasValue && doc.DoctorId == selectedDoctorId.Value
        });
    }
}
