-- ============================================================================
-- Migration: 2186_global_masters.sql
-- Description: Department, Clinical Unit and Lab Unit Masters are global: every company and branch sees and uses
--   the same rows (like Country / State / District / Area, which never had a company). CompanyId / BranchId stay on
--   the tables only as the creator's company / branch; nothing filters on them any more.
--   * ClinicalUnitMaster - Unit Code unique across the whole application (was per company); no duplicate exists.
--   * usp_Api_ClinicalUnit_GetList - no company / branch filter (@CompanyId / @BranchId kept, ignored, so old
--     callers keep working).
--   * usp_Api_LabUnitMaster_GetList - no company filter (@CompanyId kept, ignored). Name uniqueness and the
--     UNT code were already global.
--   * usp_LabApprovalFlow_ValidateAndParse - the live definition; a flow's department no longer has to belong to the
--     flow's company. Nothing else changed.
--   Departments (usp_Api_Department_GetList, usp_GetLabDepartments) and the geography
--   masters were already global.
--   Run after 2185.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Clinical Unit Code unique application-wide -------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ClinicalUnitMaster') AND name = 'UQ_ClinicalUnitMaster_Code')
   AND EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
               JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
               WHERE i.object_id = OBJECT_ID('dbo.ClinicalUnitMaster') AND i.name = 'UQ_ClinicalUnitMaster_Code' AND c.name = 'CompanyId')
BEGIN
    IF EXISTS (SELECT UnitCode FROM dbo.ClinicalUnitMaster GROUP BY UnitCode HAVING COUNT(*) > 1)
        THROW 50186, 'Clinical Unit Codes repeat across companies: rename the duplicates before running this script.', 1;

    IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID('dbo.ClinicalUnitMaster') AND name = 'UQ_ClinicalUnitMaster_Code')
        ALTER TABLE dbo.ClinicalUnitMaster DROP CONSTRAINT UQ_ClinicalUnitMaster_Code;
    ELSE
        DROP INDEX UQ_ClinicalUnitMaster_Code ON dbo.ClinicalUnitMaster;

    ALTER TABLE dbo.ClinicalUnitMaster ADD CONSTRAINT UQ_ClinicalUnitMaster_Code UNIQUE (UnitCode);
END
GO

-- 2. Clinical Unit Master list ------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_ClinicalUnit_GetList
    @DepartmentId INT = NULL,
    @SpecialityId INT = NULL,
    @CompanyId INT = NULL,      -- not used: the master is global (kept for existing callers)
    @BranchId INT = NULL        -- not used: the master is global (kept for existing callers)
AS
BEGIN
    SET NOCOUNT ON;
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
    WHERE (@DepartmentId IS NULL OR u.DepartmentId = @DepartmentId)
      AND (@SpecialityId IS NULL OR u.SpecialityId = @SpecialityId)
    ORDER BY dept.DeptName, s.SpecialityName, u.UnitName;
END;
GO

-- 3. Lab Unit Master list -----------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabUnitMaster_GetList
    @Status          BIT = NULL,
    @Search          NVARCHAR(100) = NULL,
    @CompanyId       INT = NULL     -- not used: the master is global (kept for existing callers)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        u.Unit_ID,
        u.CompanyId,
        u.Unit_Name,
        u.Unit_Code,
        u.Unit_Symbol,
        u.Conversion_Factor,
        u.Display_Order,
        u.Status,
        u.CreatedBy,
        u.CreatedDate,
        u.ModifiedBy,
        u.ModifiedDate
    FROM dbo.LabUnitMaster u
    WHERE u.IsDeleted = 0
      AND (@Status IS NULL OR u.Status = @Status)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR 
           u.Unit_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR 
           u.Unit_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           u.Unit_Symbol LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY u.Display_Order ASC, u.Unit_Name ASC;
END
GO

-- 4. Pathologist Approval Flow validation (department check no longer tied to the company) ------------------
-- 2. Shared validation ------------------------------------------------------------------------------------
-- Parses @LevelsJson into #Lv (level titles) and #Ap (approvers per level), and @Category_IDs into #Cat, all created by
-- the caller, and validates the whole flow. Kept as a procedure so Create and Update apply exactly the same rules.
--   @LevelsJson: [ { "levelNo": 1, "title": "Primary Pathologist", "approverIds": [5, 19] }, ... ]
--   @Category_IDs (in): "3,7,11" or NULL      (out): the normalised list (distinct, ascending) or NULL
CREATE OR ALTER PROCEDURE dbo.usp_LabApprovalFlow_ValidateAndParse
    @CompanyId           INT,
    @Branch_ID           INT           = NULL,
    @Department_ID       INT           = NULL OUTPUT,
    @Category_IDs        NVARCHAR(500) = NULL OUTPUT,
    @Flow_Name           NVARCHAR(150),
    @Required_Levels     INT,
    @Allow_Same_Approver BIT,
    @LevelsJson          NVARCHAR(MAX),
    @ExcludeFlowId       INT           = NULL,
    @ErrorMessage        NVARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ErrorMessage = NULL;

    -- header --------------------------------------------------------------------------------------------
    IF @Flow_Name IS NULL OR LTRIM(RTRIM(@Flow_Name)) = ''
    BEGIN SET @ErrorMessage = 'Flow name is required.'; RETURN; END

    IF LEN(LTRIM(RTRIM(@Flow_Name))) > 150
    BEGIN SET @ErrorMessage = 'Flow name cannot exceed 150 characters.'; RETURN; END

    IF @Required_Levels IS NULL OR @Required_Levels NOT BETWEEN 1 AND 3
    BEGIN SET @ErrorMessage = 'Number of approval levels must be 1, 2 or 3.'; RETURN; END

    IF @Branch_ID IS NOT NULL AND @Branch_ID <= 0 SET @Branch_ID = NULL;
    IF @Department_ID IS NOT NULL AND @Department_ID <= 0 SET @Department_ID = NULL;

    IF @Branch_ID IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @Branch_ID AND CompanyId = @CompanyId AND IsActive = 1)
    BEGIN SET @ErrorMessage = 'Selected branch is invalid, inactive, or does not belong to this company.'; RETURN; END

    -- the department (if any) must be an active Lab department (Department Master is global, script 2186)
    IF @Department_ID IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM dbo.DepartmentMaster
        WHERE DeptId = @Department_ID AND IsActive = 1 AND UPPER(LTRIM(RTRIM(DeptType))) = 'LAB')
    BEGIN SET @ErrorMessage = 'Selected department is invalid, inactive, or is not a Lab department.'; RETURN; END

    -- test categories -------------------------------------------------------------------------------------
    INSERT INTO #Cat (CategoryId)
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@Category_IDs, ''), ',') s
    WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) > 0;

    DECLARE @Bad NVARCHAR(200) = NULL;

    IF EXISTS (SELECT 1 FROM #Cat)
    BEGIN
        SELECT TOP 1 @Bad = CAST(c.CategoryId AS NVARCHAR(20))
        FROM #Cat c
        WHERE NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster m
                          WHERE m.Category_ID = c.CategoryId AND m.IsDeleted = 0 AND m.Status = 1 AND m.CompanyId = @CompanyId);
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = 'Test category #' + @Bad + ' is invalid or inactive.'; RETURN; END

        -- every chosen category must belong to the chosen department
        IF @Department_ID IS NOT NULL
        BEGIN
            SELECT TOP 1 @Bad = m.Category_Name
            FROM #Cat c JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
            WHERE ISNULL(m.Department_ID, 0) <> @Department_ID;
            IF @Bad IS NOT NULL
            BEGIN SET @ErrorMessage = 'Test category "' + @Bad + '" does not belong to the selected department.'; RETURN; END
        END

        -- categories must sit in Lab departments
        SELECT TOP 1 @Bad = m.Category_Name
        FROM #Cat c JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
        WHERE NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster d
                          WHERE d.DeptId = m.Department_ID AND d.IsActive = 1 AND UPPER(LTRIM(RTRIM(d.DeptType))) = 'LAB');
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = 'Test category "' + @Bad + '" is not in an active Lab department.'; RETURN; END

        -- no department chosen: adopt the categories' department when they all share one
        IF @Department_ID IS NULL
        BEGIN
            DECLARE @DeptCount INT, @OnlyDept INT;
            SELECT @DeptCount = COUNT(DISTINCT m.Department_ID), @OnlyDept = MIN(m.Department_ID)
            FROM #Cat c JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId;
            IF @DeptCount = 1 SET @Department_ID = @OnlyDept;
        END

        SELECT @Category_IDs = STRING_AGG(CAST(CategoryId AS VARCHAR(10)), ',') WITHIN GROUP (ORDER BY CategoryId) FROM #Cat;
    END
    ELSE
        SET @Category_IDs = NULL;

    -- scope: no overlap with another flow of the same company + branch ----------------------------------------
    IF EXISTS (SELECT 1 FROM #Cat)
    BEGIN
        SELECT TOP 1 @Bad = m.Category_Name
        FROM dbo.LabApprovalFlow f
        CROSS APPLY STRING_SPLIT(f.Category_IDs, ',') s
        JOIN #Cat c ON c.CategoryId = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
        JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
        WHERE f.CompanyId = @CompanyId AND f.IsDeleted = 0
          AND f.Category_IDs IS NOT NULL
          AND ISNULL(f.Branch_ID, 0) = ISNULL(@Branch_ID, 0)
          AND (@ExcludeFlowId IS NULL OR f.Flow_ID <> @ExcludeFlowId);
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = 'An approval flow already covers the test category "' + @Bad + '" for this branch. Edit that flow instead.'; RETURN; END
    END
    ELSE IF EXISTS (SELECT 1 FROM dbo.LabApprovalFlow f
                    WHERE f.CompanyId = @CompanyId AND f.IsDeleted = 0
                      AND f.Category_IDs IS NULL
                      AND ISNULL(f.Branch_ID, 0) = ISNULL(@Branch_ID, 0)
                      AND ISNULL(f.Department_ID, 0) = ISNULL(@Department_ID, 0)
                      AND (@ExcludeFlowId IS NULL OR f.Flow_ID <> @ExcludeFlowId))
    BEGIN SET @ErrorMessage = 'An approval flow already exists for this branch / department. Edit that flow instead.'; RETURN; END

    -- levels & approvers ----------------------------------------------------------------------------------
    IF @LevelsJson IS NULL OR LTRIM(RTRIM(@LevelsJson)) = '' OR ISJSON(@LevelsJson) = 0
    BEGIN SET @ErrorMessage = 'Approval levels are required.'; RETURN; END

    INSERT INTO #Lv (Level_No, Level_Title)
    SELECT j.levelNo, LTRIM(RTRIM(ISNULL(j.title, '')))
    FROM OPENJSON(@LevelsJson) WITH (levelNo INT '$.levelNo', title NVARCHAR(100) '$.title') j;

    INSERT INTO #Ap (Level_No, UserId)
    SELECT DISTINCT j.levelNo, TRY_CAST(a.value AS INT)
    FROM OPENJSON(@LevelsJson)
         WITH (levelNo INT '$.levelNo', approverIds NVARCHAR(MAX) '$.approverIds' AS JSON) j
    CROSS APPLY OPENJSON(j.approverIds) a
    WHERE TRY_CAST(a.value AS INT) IS NOT NULL;

    IF (SELECT COUNT(*) FROM #Lv) <> @Required_Levels
       OR (SELECT COUNT(DISTINCT Level_No) FROM #Lv) <> @Required_Levels
       OR EXISTS (SELECT 1 FROM #Lv WHERE Level_No NOT BETWEEN 1 AND @Required_Levels)
    BEGIN SET @ErrorMessage = 'Approval levels must be numbered 1 to ' + CAST(@Required_Levels AS VARCHAR(2)) + ' with no gaps.'; RETURN; END

    IF EXISTS (SELECT 1 FROM #Lv WHERE LEN(Level_Title) > 100)
    BEGIN SET @ErrorMessage = 'Level title cannot exceed 100 characters.'; RETURN; END

    DECLARE @LevelNo INT = 1;
    WHILE @LevelNo <= @Required_Levels
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM #Ap WHERE Level_No = @LevelNo)
        BEGIN SET @ErrorMessage = 'Level ' + CAST(@LevelNo AS VARCHAR(2)) + ' needs at least one approver.'; RETURN; END
        SET @LevelNo += 1;
    END

    -- every approver must be a valid pathologist
    SET @Bad = NULL;
    SELECT TOP 1 @Bad = 'User #' + CAST(ap.UserId AS VARCHAR(10))
    FROM #Ap ap
    LEFT JOIN dbo.Users u ON u.Id = ap.UserId AND u.CompanyId = @CompanyId
    WHERE u.Id IS NULL;
    IF @Bad IS NOT NULL
    BEGIN SET @ErrorMessage = @Bad + ' does not exist in this company.'; RETURN; END

    SELECT TOP 1 @Bad = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
    FROM #Ap ap JOIN dbo.Users u ON u.Id = ap.UserId
    WHERE u.IsActive = 0 OR ISNULL(u.IsPathologist, 0) = 0;
    IF @Bad IS NOT NULL
    BEGIN SET @ErrorMessage = @Bad + ' is not an active Pathologist and cannot be an approver.'; RETURN; END

    SELECT TOP 1 @Bad = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
    FROM #Ap ap JOIN dbo.Users u ON u.Id = ap.UserId
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(u.RegistrationNo, ''))), '') IS NULL;
    IF @Bad IS NOT NULL
    BEGIN SET @ErrorMessage = @Bad + ' has no Registration No. Add it in User Master before assigning as an approver.'; RETURN; END

    -- a branch-specific flow can only use pathologists who work in that branch
    IF @Branch_ID IS NOT NULL
    BEGIN
        SELECT TOP 1 @Bad = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
        FROM #Ap ap JOIN dbo.Users u ON u.Id = ap.UserId
        WHERE NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub
                          WHERE ub.UserId = ap.UserId AND ub.BranchID = @Branch_ID AND ub.IsActive = 1);
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = @Bad + ' does not have access to the selected branch.'; RETURN; END
    END

    -- a pathologist's Department Access / Test Category assignment (User Master) must cover the flow's whole scope.
    -- An empty assignment means unrestricted.
    DECLARE @Depts TABLE (DeptId INT PRIMARY KEY);
    IF @Department_ID IS NOT NULL INSERT INTO @Depts VALUES (@Department_ID);
    INSERT INTO @Depts (DeptId)
    SELECT DISTINCT m.Department_ID FROM #Cat c JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
    WHERE m.Department_ID IS NOT NULL AND m.Department_ID NOT IN (SELECT DeptId FROM @Depts);

    IF EXISTS (SELECT 1 FROM @Depts)
    BEGIN
        -- strict: the department must be one of the user's Assigned Department(s); no assignment = not eligible
        SET @Bad = NULL;
        SELECT TOP 1 @Bad = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) + ' is not assigned to department "' + dm.DeptName + '" in User Master.'
        FROM #Ap ap
        JOIN dbo.Users u ON u.Id = ap.UserId
        CROSS JOIN @Depts d
        JOIN dbo.DepartmentMaster dm ON dm.DeptId = d.DeptId
        WHERE NOT EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(u.DepartmentIds, ''), ',') s
                          WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = d.DeptId);
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = @Bad; RETURN; END
    END

    IF EXISTS (SELECT 1 FROM #Cat)
    BEGIN
        SELECT TOP 1 @Bad = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) + ' is not assigned to test category "' + m.Category_Name + '".'
        FROM #Ap ap
        JOIN dbo.Users u ON u.Id = ap.UserId
        CROSS JOIN #Cat c
        JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
        WHERE NULLIF(LTRIM(RTRIM(ISNULL(u.PathologistCategoryIds, ''))), '') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(u.PathologistCategoryIds, ',') s
                          WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = c.CategoryId);
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = @Bad; RETURN; END
    END

    -- the same person on two levels defeats the purpose of multiple sign-offs
    IF ISNULL(@Allow_Same_Approver, 0) = 0
    BEGIN
        SET @Bad = NULL;
        SELECT TOP 1 @Bad = ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)
        FROM #Ap ap JOIN dbo.Users u ON u.Id = ap.UserId
        GROUP BY ap.UserId, u.FullName, u.Username
        HAVING COUNT(DISTINCT ap.Level_No) > 1;
        IF @Bad IS NOT NULL
        BEGIN SET @ErrorMessage = @Bad + ' is listed on more than one level. Enable "Allow the same approver on more than one level" or remove the duplicate.'; RETURN; END
    END
END
GO
