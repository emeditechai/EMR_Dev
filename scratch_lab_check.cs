using System;
using System.Data;
using Microsoft.Data.SqlClient;
using Dapper;

class Program
{
    static void Main()
    {
        var connStr = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True";
        using var conn = new SqlConnection(connStr);
        conn.Open();

        Console.WriteLine("--- LabInvestigationMaster Columns ---");
        var cols = conn.Query("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'LabInvestigationMaster'");
        foreach (var c in cols) Console.WriteLine($"{c.COLUMN_NAME} ({c.DATA_TYPE})");

        Console.WriteLine("\n--- LabInvestigationMaster Sample Data ---");
        var tests = conn.Query("SELECT TOP 5 Test_ID, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, MRP FROM LabInvestigationMaster WHERE IsDeleted = 0");
        foreach (var t in tests) Console.WriteLine($"ID:{t.Test_ID}, Code:{t.Test_Code}, Name:{t.Test_Name}, Dept:{t.Department_ID}, Cat:{t.Category_ID}, SubCat:{t.SubCategory_ID}, MRP:{t.MRP}");

        Console.WriteLine("\n--- Departments from usp_GetLabDepartments ---");
        var depts = conn.Query("dbo.usp_GetLabDepartments", commandType: CommandType.StoredProcedure);
        foreach (var d in depts) Console.WriteLine($"DeptId:{d.DepartmentId}, Name:{d.DepartmentName}");

        Console.WriteLine("\n--- Categories from usp_GetLabCategories ---");
        var cats = conn.Query("dbo.usp_GetLabCategories", commandType: CommandType.StoredProcedure);
        foreach (var c in cats) Console.WriteLine($"CatId:{c.CategoryId}, Name:{c.CategoryName}, DeptId:{c.DepartmentId}");

        Console.WriteLine("\n--- SubCategories from usp_GetLabSubCategories ---");
        var subcats = conn.Query("dbo.usp_GetLabSubCategories", commandType: CommandType.StoredProcedure);
        foreach (var s in subcats) Console.WriteLine($"SubCatId:{s.SubCategoryId}, Name:{s.SubCategoryName}, CatId:{s.CategoryId}");
    }
}
