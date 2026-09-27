using Dapper;
using EMR.Api.Data;

namespace EMR.Api.Services.BulkUpload;

public class RefDepartment { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; }
public class RefCategory { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public int DepartmentId { get; set; } public string DepartmentName { get; set; } = ""; }
public class RefSubCategory { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public int CategoryId { get; set; } public string CategoryName { get; set; } = ""; public string DepartmentName { get; set; } = ""; }
public class RefMethod { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public int DepartmentId { get; set; } public string DepartmentName { get; set; } = ""; }
public class RefSampleType { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public string? Container { get; set; } }
public class RefUnit { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public string? Symbol { get; set; } }
public class RefBranch { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public bool IsHO { get; set; } }
public class RefFranchise { public int Id { get; set; } public string Code { get; set; } = ""; public string Name { get; set; } = ""; public int ParentBranchId { get; set; } public string? ParentBranchName { get; set; } }

/// <summary>Active dependent masters used for dropdowns and for resolving uploaded values.</summary>
public class LabBulkLookups(IDbConnectionFactory db)
{
    private async Task<List<T>> QueryAsync<T>(string sql, int companyId)
    {
        using var con = db.CreateConnection();
        return (await con.QueryAsync<T>(sql, new { CompanyId = companyId })).ToList();
    }

    public async Task<BulkLookup<RefDepartment>> DepartmentsAsync(int companyId) => new(
        await QueryAsync<RefDepartment>("""
            SELECT DeptId AS Id, DeptCode AS Code, DeptName AS Name
            FROM dbo.DepartmentMaster
            WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%')
              AND (CompanyId = @CompanyId OR CompanyId IS NULL)
            ORDER BY DeptName
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    public async Task<BulkLookup<RefCategory>> CategoriesAsync(int companyId) => new(
        await QueryAsync<RefCategory>("""
            SELECT c.Category_ID AS Id, c.Category_Code AS Code, c.Category_Name AS Name,
                   c.Department_ID AS DepartmentId, ISNULL(d.DeptName, '') AS DepartmentName
            FROM dbo.LabTestCategoryMaster c
            LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = c.Department_ID
            WHERE c.IsDeleted = 0 AND c.Status = 1 AND c.CompanyId = @CompanyId
            ORDER BY d.DeptName, c.Display_Order, c.Category_Name
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    public async Task<BulkLookup<RefSubCategory>> SubCategoriesAsync(int companyId) => new(
        await QueryAsync<RefSubCategory>("""
            SELECT s.SubCategory_ID AS Id, s.SubCategory_Code AS Code, s.SubCategory_Name AS Name,
                   s.Category_ID AS CategoryId, ISNULL(c.Category_Name, '') AS CategoryName, ISNULL(d.DeptName, '') AS DepartmentName
            FROM dbo.LabTestSubCategoryMaster s
            LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = s.Category_ID
            LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = c.Department_ID
            WHERE s.IsDeleted = 0 AND s.Status = 1 AND s.CompanyId = @CompanyId
            ORDER BY c.Category_Name, s.Display_Order, s.SubCategory_Name
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    public async Task<BulkLookup<RefMethod>> MethodsAsync(int companyId) => new(
        await QueryAsync<RefMethod>("""
            SELECT m.Method_ID AS Id, m.Method_Code AS Code, m.Method_Name AS Name,
                   m.Department_ID AS DepartmentId, ISNULL(d.DeptName, '') AS DepartmentName
            FROM dbo.LabTestMethodMaster m
            LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = m.Department_ID
            WHERE m.IsDeleted = 0 AND m.Status = 1 AND m.CompanyId = @CompanyId
            ORDER BY d.DeptName, m.Display_Order, m.Method_Name
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    public async Task<BulkLookup<RefSampleType>> SampleTypesAsync(int companyId) => new(
        await QueryAsync<RefSampleType>("""
            SELECT Sample_Type_ID AS Id, Sample_Code AS Code, Sample_Name AS Name, Container_Type AS Container
            FROM dbo.LabSampleTypeMaster
            WHERE ISNULL(IsDeleted, 0) = 0 AND Status = 1 AND CompanyId = @CompanyId
            ORDER BY Display_Order, Sample_Name
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    public async Task<BulkLookup<RefUnit>> UnitsAsync(int companyId) => new(
        await QueryAsync<RefUnit>("""
            SELECT Unit_ID AS Id, Unit_Code AS Code, Unit_Name AS Name, Unit_Symbol AS Symbol
            FROM dbo.LabUnitMaster
            WHERE ISNULL(IsDeleted, 0) = 0 AND Status = 1 AND CompanyId = @CompanyId
            ORDER BY Display_Order, Unit_Name
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    public async Task<BulkLookup<RefBranch>> BranchesAsync(int companyId) => new(
        await QueryAsync<RefBranch>("""
            SELECT BranchID AS Id, ISNULL(BranchCode, '') AS Code, BranchName AS Name, ISNULL(IsHOBranch, 0) AS IsHO
            FROM dbo.BranchMaster
            WHERE IsActive = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL)
            ORDER BY BranchName
            """, companyId), x => x.Id, x => x.Code, x => x.Name);

    /// <summary>Every rate-list item, including inactive / non-billable ones (they may already sit on a rate card).</summary>
    public Task<List<Models.LabItemModel>> AllRateItemsAsync(int companyId) => QueryAsync<Models.LabItemModel>("""
        SELECT CASE WHEN m.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS Item_Type, m.Test_ID AS Item_ID,
               m.Test_Code AS Item_Code, m.Test_Name AS Item_Name, m.MRP AS Default_Rate, m.Is_Profile_Test
        FROM dbo.LabInvestigationMaster m
        WHERE m.IsDeleted = 0 AND m.CompanyId = @CompanyId
        UNION ALL
        SELECT 'Package', h.Profile_ID, h.Profile_Code, h.Profile_Name, h.MRP, CAST(0 AS BIT)
        FROM dbo.LabInvestigationProfileHeader h
        WHERE h.IsDeleted = 0 AND h.Test_ID IS NULL AND h.Profile_Type = 2 AND h.CompanyId = @CompanyId
        """, companyId);

    /// <summary>Package effective dates by Profile_ID (the profile GetById / GetList procedures do not return them).</summary>
    public async Task<Dictionary<int, (DateTime? Start, DateTime? End)>> ProfileDatesAsync(int companyId)
    {
        using var con = db.CreateConnection();
        var rows = await con.QueryAsync<(int Id, DateTime? Start, DateTime? End)>(
            @"SELECT Profile_ID, Effective_Start_Date, Effective_End_Date
              FROM dbo.LabInvestigationProfileHeader
              WHERE IsDeleted = 0 AND CompanyId = @CompanyId",
            new { CompanyId = companyId });
        return rows.ToDictionary(r => r.Id, r => (r.Start, r.End));
    }

    public async Task<BulkLookup<RefFranchise>> FranchisesAsync(int companyId) => new(
        await QueryAsync<RefFranchise>("""
            SELECT f.Franchise_ID AS Id, f.Franchise_Code AS Code, f.Franchise_Name AS Name,
                   f.Parent_Branch_ID AS ParentBranchId, b.BranchName AS ParentBranchName
            FROM dbo.LabFranchiseMaster f
            LEFT JOIN dbo.BranchMaster b ON b.BranchID = f.Parent_Branch_ID
            WHERE f.IsDeleted = 0 AND f.IsActive = 1 AND f.CompanyId = @CompanyId
            ORDER BY f.Franchise_Name
            """, companyId), x => x.Id, x => x.Code, x => x.Name);
}
