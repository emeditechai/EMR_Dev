-- ============================================================================
-- Migration: 2220_doctor_ip_packages.sql
-- Description: Doctor IP - commission on packages as well as tests and profiles.
--   * Doctor_IP_Dtl.Item_Type marks each row: 'Test', 'Profile' or 'Package'.
--     Test / Profile rows: Test_ID = LabInvestigationMaster.Test_ID.
--     Package rows:        Test_ID = LabInvestigationProfileHeader.Profile_ID (Profile_Type = 2).
--     Package ids overlap with test ids, so a row is identified by Item_Type + Test_ID.
--   * usp_DoctorIp_GetItems / GetById / Save handle packages.
--   Run after 2176 (Doctor IP master).
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Item_Type column -----------------------------------------------------------
IF COL_LENGTH('dbo.Doctor_IP_Dtl', 'Item_Type') IS NULL
    ALTER TABLE dbo.Doctor_IP_Dtl ADD Item_Type VARCHAR(10) NOT NULL
        CONSTRAINT DF_Doctor_IP_Dtl_Item_Type DEFAULT 'Test'
        CONSTRAINT CK_Doctor_IP_Dtl_Item_Type CHECK (Item_Type IN ('Test', 'Profile', 'Package'));
GO

UPDATE x SET Item_Type = 'Profile'
FROM dbo.Doctor_IP_Dtl x
JOIN dbo.LabInvestigationMaster m ON m.Test_ID = x.Test_ID
WHERE x.Item_Type = 'Test' AND m.Is_Profile_Test = 1;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Doctor_IP_Dtl_Test' AND object_id = OBJECT_ID('dbo.Doctor_IP_Dtl'))
    DROP INDEX UX_Doctor_IP_Dtl_Test ON dbo.Doctor_IP_Dtl;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Doctor_IP_Dtl_Item' AND object_id = OBJECT_ID('dbo.Doctor_IP_Dtl'))
    CREATE UNIQUE INDEX UX_Doctor_IP_Dtl_Item ON dbo.Doctor_IP_Dtl (Doctor_IP_Hdr_ID, Item_Type, Test_ID);
GO

-- 2. Lookups ----------------------------------------------------------------------
-- Tests, profiles and packages that can carry a commission. Packages have no department / category.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetItems
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT x.Test_ID, x.Test_Code, x.Test_Name, x.Item_Type, x.Department_ID, x.Department_Name,
           x.Category_ID, x.Category_Name, x.Sub_Category_ID, x.Sub_Category_Name, x.MRP
    FROM (
        SELECT m.Test_ID, m.Test_Code, m.Test_Name,
               CASE WHEN m.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS Item_Type,
               ISNULL(m.Department_ID, c.Department_ID) AS Department_ID, dep.DeptName AS Department_Name,
               m.Category_ID, c.Category_Name,
               m.SubCategory_ID AS Sub_Category_ID, sc.SubCategory_Name AS Sub_Category_Name,
               m.MRP
        FROM dbo.LabInvestigationMaster m
        LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = m.Category_ID
        LEFT JOIN dbo.LabTestSubCategoryMaster sc ON sc.SubCategory_ID = m.SubCategory_ID
        LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = ISNULL(m.Department_ID, c.Department_ID)
        WHERE m.IsDeleted = 0 AND m.Status = 1 AND m.Is_Billable = 1
          AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
        UNION ALL
        SELECT CAST(ph.Profile_ID AS BIGINT), ph.Profile_Code, ph.Profile_Name, 'Package',
               NULL, NULL, NULL, NULL, NULL, NULL, ph.MRP
        FROM dbo.LabInvestigationProfileHeader ph
        WHERE ph.IsDeleted = 0 AND ph.Status = 1 AND ph.Profile_Type = 2
          AND (@CompanyId IS NULL OR ph.CompanyId = @CompanyId)
    ) x
    ORDER BY CASE WHEN x.Item_Type = 'Package' THEN 1 ELSE 0 END, x.Department_Name, x.Category_Name, x.Test_Name;
END
GO

-- 3. CRUD ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.Doctor_IP_Hdr_ID, h.CompanyId, h.Doctor_ID,
           ISNULL(d.NamePrefix + ' ', '') + d.FullName AS Doctor_Name,
           h.Speciality_ID, s.SpecialityName AS Speciality_Name,
           h.Branch_ID, b.BranchName AS Branch_Name,
           h.Effective_From, h.Effective_To, h.Frequency_Of_Disbursal, h.IsActive,
           h.Created_By, h.CreatedDate, h.Updated_By, h.UpdatedDate
    FROM dbo.Doctor_IP_Hdr h
    JOIN dbo.DoctorMaster d ON d.DoctorId = h.Doctor_ID
    LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = h.Speciality_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = h.Branch_ID
    WHERE h.Doctor_IP_Hdr_ID = @Id AND h.IsDeleted = 0;

    SELECT x.Doctor_IP_Dtl_ID, x.Doctor_IP_Hdr_ID, x.Test_ID,
           ISNULL(m.Test_Code, ph.Profile_Code) AS Test_Code,
           ISNULL(m.Test_Name, ph.Profile_Name) AS Test_Name,
           x.Item_Type,
           x.Department_ID, dep.DeptName AS Department_Name,
           x.Category_ID, c.Category_Name,
           x.Sub_Category_ID, sc.SubCategory_Name AS Sub_Category_Name,
           ISNULL(ISNULL(m.MRP, ph.MRP), 0) AS MRP, x.Commission_Rate
    FROM dbo.Doctor_IP_Dtl x
    LEFT JOIN dbo.LabInvestigationMaster m ON x.Item_Type <> 'Package' AND m.Test_ID = x.Test_ID
    LEFT JOIN dbo.LabInvestigationProfileHeader ph ON x.Item_Type = 'Package' AND ph.Profile_ID = x.Test_ID
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = x.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = x.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster sc ON sc.SubCategory_ID = x.Sub_Category_ID
    WHERE x.Doctor_IP_Hdr_ID = @Id
    ORDER BY CASE WHEN x.Item_Type = 'Package' THEN 1 ELSE 0 END, dep.DeptName, c.Category_Name, ISNULL(m.Test_Name, ph.Profile_Name);
END
GO

-- Header + details in one transaction.
-- @DetailsJson: [{"Item_Type":"Test","Test_ID":1,"Commission_Rate":20.00}, ...]; Item_Type "Package" means
-- Test_ID is a package id. Test / Profile and department / category come from the test master, not the client.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIp_Save
    @Id            INT = 0,
    @CompanyId     INT = 1,
    @Doctor_ID     INT,
    @Speciality_ID INT = NULL,
    @Branch_ID     INT,
    @Effective_From DATE,
    @Effective_To   DATE,
    @Frequency_Of_Disbursal VARCHAR(20) = 'Monthly',
    @IsActive      BIT = 1,
    @DetailsJson   NVARCHAR(MAX),
    @UserId        INT = NULL,
    @NewId         INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @NewId = NULLIF(@Id, 0);

    IF @Effective_To < @Effective_From
    BEGIN RAISERROR('Effective To must be on or after Effective From.', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @Doctor_ID AND IsReferralDoctor = 1 AND IsActive = 1)
    BEGIN RAISERROR('Select an active referral doctor.', 16, 1); RETURN; END

    IF @NewId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Hdr WHERE Doctor_IP_Hdr_ID = @NewId AND IsDeleted = 0)
    BEGIN RAISERROR('Doctor IP record not found.', 16, 1); RETURN; END

    IF @IsActive = 1 AND EXISTS (
        SELECT 1 FROM dbo.Doctor_IP_Hdr
        WHERE Doctor_ID = @Doctor_ID AND Branch_ID = @Branch_ID AND IsDeleted = 0 AND IsActive = 1
          AND Doctor_IP_Hdr_ID <> ISNULL(@NewId, 0)
          AND Effective_From <= @Effective_To AND Effective_To >= @Effective_From)
    BEGIN RAISERROR('This doctor already has an active Doctor IP for this branch in an overlapping period.', 16, 1); RETURN; END

    IF @DetailsJson IS NULL OR ISJSON(@DetailsJson) = 0
    BEGIN RAISERROR('Add at least one test, profile or package with a commission %%.', 16, 1); RETURN; END

    DECLARE @D TABLE (IsPackage BIT NOT NULL, Test_ID BIGINT NOT NULL, Commission_Rate DECIMAL(18,2), PRIMARY KEY (IsPackage, Test_ID));
    INSERT INTO @D (IsPackage, Test_ID, Commission_Rate)
    SELECT j.IsPackage, j.Test_ID, MAX(j.Commission_Rate)
    FROM (SELECT CAST(CASE WHEN Item_Type = 'Package' THEN 1 ELSE 0 END AS BIT) AS IsPackage, Test_ID, Commission_Rate
          FROM OPENJSON(@DetailsJson)
               WITH (Item_Type VARCHAR(10) '$.Item_Type', Test_ID BIGINT '$.Test_ID', Commission_Rate DECIMAL(18,2) '$.Commission_Rate')) j
    WHERE j.Test_ID IS NOT NULL
    GROUP BY j.IsPackage, j.Test_ID;

    IF NOT EXISTS (SELECT 1 FROM @D)
    BEGIN RAISERROR('Add at least one test, profile or package with a commission %%.', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM @D WHERE Commission_Rate IS NULL OR Commission_Rate < 0 OR Commission_Rate > 100)
    BEGIN RAISERROR('Commission %% must be between 0 and 100 for every row.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @NewId IS NULL
        BEGIN
            INSERT INTO dbo.Doctor_IP_Hdr (CompanyId, Doctor_ID, Speciality_ID, Branch_ID, Effective_From, Effective_To, Frequency_Of_Disbursal, IsActive, Created_By)
            VALUES (@CompanyId, @Doctor_ID, @Speciality_ID, @Branch_ID, @Effective_From, @Effective_To, ISNULL(@Frequency_Of_Disbursal, 'Monthly'), ISNULL(@IsActive, 1), @UserId);
            SET @NewId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.Doctor_IP_Hdr
               SET Doctor_ID = @Doctor_ID, Speciality_ID = @Speciality_ID, Branch_ID = @Branch_ID,
                   Effective_From = @Effective_From, Effective_To = @Effective_To,
                   Frequency_Of_Disbursal = ISNULL(@Frequency_Of_Disbursal, 'Monthly'), IsActive = ISNULL(@IsActive, 1),
                   Updated_By = @UserId, UpdatedDate = GETDATE()
             WHERE Doctor_IP_Hdr_ID = @NewId;
            DELETE FROM dbo.Doctor_IP_Dtl WHERE Doctor_IP_Hdr_ID = @NewId;
        END

        INSERT INTO dbo.Doctor_IP_Dtl (Doctor_IP_Hdr_ID, Item_Type, Department_ID, Category_ID, Sub_Category_ID, Test_ID, Commission_Rate)
        SELECT @NewId, CASE WHEN m.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END,
               ISNULL(m.Department_ID, c.Department_ID), m.Category_ID, m.SubCategory_ID, d.Test_ID, d.Commission_Rate
        FROM @D d
        JOIN dbo.LabInvestigationMaster m ON m.Test_ID = d.Test_ID AND m.IsDeleted = 0
        LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = m.Category_ID
        WHERE d.IsPackage = 0;

        INSERT INTO dbo.Doctor_IP_Dtl (Doctor_IP_Hdr_ID, Item_Type, Test_ID, Commission_Rate)
        SELECT @NewId, 'Package', d.Test_ID, d.Commission_Rate
        FROM @D d
        JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = d.Test_ID AND ph.IsDeleted = 0 AND ph.Profile_Type = 2
        WHERE d.IsPackage = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO
