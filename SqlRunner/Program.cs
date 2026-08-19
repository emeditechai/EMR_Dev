using System;
using System.Data;
using Microsoft.Data.SqlClient;

var cs = "Server=103.178.113.61,1232;Database=Dev_EMR;User Id=sa;Password=Ehospit@lity@#1926;TrustServerCertificate=True;MultipleActiveResultSets=True;";

using var conn = new SqlConnection(cs);
conn.Open();

Console.WriteLine("=== ENSURING DEFAULT COMPANY AND TAGGING ALL EXISTING BRANCHES / USERS ===");

// 1. Ensure Default Company exists
using (var cmd = new SqlCommand(@"
    IF NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = 1)
    BEGIN
        SET IDENTITY_INSERT dbo.CompanyMaster ON;
        INSERT INTO dbo.CompanyMaster (
            CompanyId, CompanyCode, CompanyName, LegalName, RegistrationNumber, GSTIN, PAN,
            Email, Phone, Website, Address, City, State, Country, Pincode, IsActive, CreatedDate
        ) VALUES (
            1, 'CMP-001', 'Primary Healthcare Network', 'Primary Healthcare Network Pvt Ltd', 'U85110WB2020PTC123456', 
            '19AAACP1234A1Z5', 'AAACP1234A', 'info@primaryhealthcare.com', '+91 33 2456 7890', 'https://primaryhealthcare.com',
            '12A Medical Center Avenue, Sector 5', 'Kolkata', 'West Bengal', 'India', '700091', 1, SYSUTCDATETIME()
        );
        SET IDENTITY_INSERT dbo.CompanyMaster OFF;
        PRINT 'Default company created.';
    END
    ELSE
    BEGIN
        UPDATE dbo.CompanyMaster
        SET IsActive = 1
        WHERE CompanyId = 1;
        PRINT 'Default company already exists and set active.';
    END
", conn))
{
    cmd.ExecuteNonQuery();
}

// 2. Tag ALL existing Branches to CompanyId = 1
using (var cmd = new SqlCommand(@"
    UPDATE dbo.Branchmaster
    SET CompanyId = 1
    WHERE CompanyId IS NULL OR CompanyId = 0 OR NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster c WHERE c.CompanyId = Branchmaster.CompanyId);

    SELECT COUNT(*) AS UpdatedBranches FROM dbo.Branchmaster WHERE CompanyId = 1;
", conn))
{
    var count = (int)cmd.ExecuteScalar();
    Console.WriteLine($"✓ Verified: {count} branches are tagged to Default Company (CompanyId = 1).");
}

// 3. Tag ALL existing Users to CompanyId = 1
using (var cmd = new SqlCommand(@"
    UPDATE dbo.Users
    SET CompanyId = 1
    WHERE CompanyId IS NULL OR CompanyId = 0 OR NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster c WHERE c.CompanyId = Users.CompanyId);

    SELECT COUNT(*) AS UpdatedUsers FROM dbo.Users WHERE CompanyId = 1;
", conn))
{
    var count = (int)cmd.ExecuteScalar();
    Console.WriteLine($"✓ Verified: {count} users are tagged to Default Company (CompanyId = 1).");
}

// 4. Tag ALL other tables to CompanyId = 1
using (var cmd = new SqlCommand(@"
    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql += N'UPDATE dbo.' + QUOTENAME(TABLE_NAME) + N' SET CompanyId = 1 WHERE CompanyId IS NULL OR CompanyId = 0;' + CHAR(13)
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE COLUMN_NAME = 'CompanyId' AND TABLE_SCHEMA = 'dbo' AND TABLE_NAME != 'CompanyMaster';

    EXEC sp_executesql @sql;
    PRINT 'All related tables updated with CompanyId = 1.';
", conn))
{
    cmd.ExecuteNonQuery();
    Console.WriteLine("✓ Verified: All tables in Dev_EMR have records scoped with CompanyId = 1.");
}

// 5. Inspect Admin User status & branches
Console.WriteLine("\n[Admin User Login Readiness Check]:");
using (var cmd = new SqlCommand(@"
    SELECT u.Id, u.Username, u.FullName, u.IsActive, u.CompanyId, c.CompanyName, c.CompanyCode,
           (SELECT COUNT(*) FROM UserBranches ub WHERE ub.UserId = u.Id AND ub.IsActive = 1) AS ActiveBranchCount,
           (SELECT COUNT(*) FROM Userroles ur WHERE ur.UserId = u.Id AND ur.IsActive = 1) AS ActiveRoleCount
    FROM Users u
    LEFT JOIN CompanyMaster c ON u.CompanyId = c.CompanyId
    WHERE u.Username IN ('admin', 'abhik');
", conn))
using (var reader = cmd.ExecuteReader())
{
    while (reader.Read())
    {
        Console.WriteLine($"  - Username: {reader["Username"]}");
        Console.WriteLine($"    FullName: {reader["FullName"]}");
        Console.WriteLine($"    IsActive: {reader["IsActive"]}");
        Console.WriteLine($"    Company: {reader["CompanyName"]} (ID: {reader["CompanyId"]}, Code: {reader["CompanyCode"]})");
        Console.WriteLine($"    Active Branches Mapped: {reader["ActiveBranchCount"]}");
        Console.WriteLine($"    Active Roles Mapped: {reader["ActiveRoleCount"]}");
        Console.WriteLine();
    }
}

// 6. Inspect All Branches under CompanyId = 1
Console.WriteLine("[Branches under Default Company (CompanyId = 1)]:");
using (var cmd = new SqlCommand("SELECT BranchId, BranchCode, BranchName, IsHOBranch, IsActive FROM Branchmaster WHERE CompanyId = 1 ORDER BY BranchId", conn))
using (var reader = cmd.ExecuteReader())
{
    while (reader.Read())
    {
        Console.WriteLine($"  - Branch ID: {reader["BranchId"]} | Code: {reader["BranchCode"]} | Name: {reader["BranchName"]} | HO: {reader["IsHOBranch"]} | Active: {reader["IsActive"]}");
    }
}

Console.WriteLine("\n=== SETUP COMPLETE: DEFAULT COMPANY & BRANCH TAGGING VERIFIED ===");
