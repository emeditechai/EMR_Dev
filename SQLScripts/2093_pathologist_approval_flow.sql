-- ====================================================================================================
-- Script: 2093_pathologist_approval_flow.sql
-- Description: "Pathologist Approval Flow" configuration (Settings). Defines how many approvals
--              (1 to 3, sequential) a lab report needs and which pathologists may give each one.
--
--              CONFIGURATION ONLY. No report / approval screen reads these tables yet; the Approval
--              screen will use dbo.usp_LabApprovalFlow_Resolve later.
--
-- Scope rules
--   * Every flow belongs to a Company (CompanyId).
--   * Branch_ID     NULL = company-wide flow            | <id> = that branch only
--   * Department_ID NULL = every department             | <id> = that Lab department only
--   * Category_IDs  NULL = every test category          | "3,7,11" = those test categories only
--     (comma-separated LabTestCategoryMaster.Category_ID, ascending, same style as Users.DepartmentIds).
--     When categories are chosen and no department is, the department is filled in if all the chosen
--     categories share one department (otherwise it stays NULL).
--   * Precedence when resolving a flow for a report (usp_LabApprovalFlow_Resolve):
--       Test Category  ->  Department  ->  Branch default  ->  Company default  ->  none
--     (within the same specificity a branch-specific flow beats a company-wide one).
--   * No two flows may overlap: for the same company + branch, a category may belong to only one flow, and
--     there is only one category-less flow per department (or one for "all departments").
--
-- Objects
--   dbo.LabApprovalFlow / dbo.LabApprovalFlowLevel / dbo.LabApprovalFlowApprover
--   dbo.usp_Api_LabApprovalFlow_GetList / GetById / Create / Update / ToggleStatus / Delete
--   dbo.usp_Api_LabApprovalFlow_GetEligibleApprovers
--   dbo.usp_LabApprovalFlow_Resolve
--
-- Who can be an approver (matched against User Master, on save AND in the picker)
--   * active user flagged Is Pathologist, with a Registration No
--   * branch flow      -> the user works in that branch (UserBranches)
--   * department scope -> the department must be in the user's "Assigned Department(s)" (Users.DepartmentIds).
--                         This is strict: a user with no assigned department is not listed for a department.
--   * category scope   -> EVERY chosen category must be in the user's "Test Categories (sign-off scope)"
--                         (Users.PathologistCategoryIds); an empty sign-off scope means all categories.
--
-- Re-runnable: an earlier version of this table (single Category_ID) is migrated in place.
-- No seed rows: with no flow configured nothing changes anywhere in the application.
-- ====================================================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Tables -------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabApprovalFlow' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabApprovalFlow
    (
        Flow_ID             INT IDENTITY(1,1) PRIMARY KEY,
        Flow_Code           NVARCHAR(50)  NOT NULL CONSTRAINT DF_LabApprovalFlow_Code DEFAULT '',
        CompanyId           INT           NOT NULL CONSTRAINT DF_LabApprovalFlow_Company DEFAULT 1,
        Branch_ID           INT           NULL,
        Department_ID       INT           NULL,
        Category_IDs        NVARCHAR(500) NULL,
        Flow_Name           NVARCHAR(150) NOT NULL,
        Required_Levels     TINYINT       NOT NULL,
        Allow_Same_Approver BIT           NOT NULL CONSTRAINT DF_LabApprovalFlow_SameApprover DEFAULT 0,
        Status              BIT           NOT NULL CONSTRAINT DF_LabApprovalFlow_Status DEFAULT 1,
        IsDeleted           BIT           NOT NULL CONSTRAINT DF_LabApprovalFlow_Deleted DEFAULT 0,
        CreatedBy           INT           NULL,
        CreatedDate         DATETIME2     NOT NULL CONSTRAINT DF_LabApprovalFlow_Created DEFAULT GETDATE(),
        ModifiedBy          INT           NULL,
        ModifiedDate        DATETIME2     NULL,
        CONSTRAINT CK_LabApprovalFlow_Levels CHECK (Required_Levels BETWEEN 1 AND 3),
        CONSTRAINT FK_LabApprovalFlow_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_LabApprovalFlow_Scope
        ON dbo.LabApprovalFlow (CompanyId, Branch_ID, Department_ID, Status, IsDeleted);
    PRINT 'Created table dbo.LabApprovalFlow';
END
ELSE
    PRINT 'Table dbo.LabApprovalFlow already exists';
GO

-- 1b. Migrate the first version (single Category_ID) to the comma-separated Category_IDs ---------------------
IF COL_LENGTH('dbo.LabApprovalFlow', 'Category_ID') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.LabApprovalFlow', 'Category_IDs') IS NULL
        ALTER TABLE dbo.LabApprovalFlow ADD Category_IDs NVARCHAR(500) NULL;

    EXEC('UPDATE dbo.LabApprovalFlow SET Category_IDs = CAST(Category_ID AS NVARCHAR(20)) WHERE Category_ID IS NOT NULL AND Category_IDs IS NULL');

    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_LabApprovalFlow_Category' AND parent_object_id = OBJECT_ID('dbo.LabApprovalFlow'))
        ALTER TABLE dbo.LabApprovalFlow DROP CONSTRAINT FK_LabApprovalFlow_Category;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabApprovalFlow_Scope' AND object_id = OBJECT_ID('dbo.LabApprovalFlow'))
        DROP INDEX IX_LabApprovalFlow_Scope ON dbo.LabApprovalFlow;

    ALTER TABLE dbo.LabApprovalFlow DROP COLUMN Category_ID;

    CREATE INDEX IX_LabApprovalFlow_Scope
        ON dbo.LabApprovalFlow (CompanyId, Branch_ID, Department_ID, Status, IsDeleted);

    PRINT 'Migrated dbo.LabApprovalFlow: Category_ID -> Category_IDs (comma-separated)';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabApprovalFlowLevel' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabApprovalFlowLevel
    (
        Level_ID     INT IDENTITY(1,1) PRIMARY KEY,
        Flow_ID      INT          NOT NULL,
        Level_No     TINYINT      NOT NULL,
        Level_Title  NVARCHAR(100) NOT NULL CONSTRAINT DF_LabApprovalFlowLevel_Title DEFAULT '',
        CONSTRAINT CK_LabApprovalFlowLevel_No CHECK (Level_No BETWEEN 1 AND 3),
        CONSTRAINT FK_LabApprovalFlowLevel_Flow FOREIGN KEY (Flow_ID) REFERENCES dbo.LabApprovalFlow(Flow_ID),
        CONSTRAINT UQ_LabApprovalFlowLevel UNIQUE (Flow_ID, Level_No)
    );
    PRINT 'Created table dbo.LabApprovalFlowLevel';
END
ELSE
    PRINT 'Table dbo.LabApprovalFlowLevel already exists';
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabApprovalFlowApprover' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabApprovalFlowApprover
    (
        Approver_ID INT IDENTITY(1,1) PRIMARY KEY,
        Level_ID    INT NOT NULL,
        UserId      INT NOT NULL,
        CONSTRAINT FK_LabApprovalFlowApprover_Level FOREIGN KEY (Level_ID) REFERENCES dbo.LabApprovalFlowLevel(Level_ID),
        CONSTRAINT FK_LabApprovalFlowApprover_User  FOREIGN KEY (UserId)   REFERENCES dbo.Users(Id),
        CONSTRAINT UQ_LabApprovalFlowApprover UNIQUE (Level_ID, UserId)
    );
    PRINT 'Created table dbo.LabApprovalFlowApprover';
END
ELSE
    PRINT 'Table dbo.LabApprovalFlowApprover already exists';
GO

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

    -- the department (if any) must be an active Lab department of the company
    IF @Department_ID IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM dbo.DepartmentMaster
        WHERE DeptId = @Department_ID AND IsActive = 1 AND CompanyId = @CompanyId AND UPPER(LTRIM(RTRIM(DeptType))) = 'LAB')
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

-- 3. Eligible approvers ------------------------------------------------------------------------------------
--    Applies the same rules as the save-time validation. @IncludeIneligible = 1 also returns the pathologists that do NOT
--    match, with IneligibleReason, so the screen can explain why someone is not offered.
--    @CategoryIds: CSV. The approver must cover EVERY chosen category and department.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_GetEligibleApprovers
    @CompanyId         INT,
    @BranchId          INT           = NULL,
    @DepartmentId      INT           = NULL,
    @CategoryIds       NVARCHAR(500) = NULL,
    @IncludeIneligible BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @BranchId IS NOT NULL AND @BranchId <= 0 SET @BranchId = NULL;
    IF @DepartmentId IS NOT NULL AND @DepartmentId <= 0 SET @DepartmentId = NULL;

    DECLARE @Cats TABLE (CategoryId INT PRIMARY KEY);
    INSERT INTO @Cats
    SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@CategoryIds, ''), ',') s
    WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) > 0;

    -- every department the scope touches: the chosen one plus the departments of the chosen categories
    DECLARE @Depts TABLE (DeptId INT PRIMARY KEY);
    IF @DepartmentId IS NOT NULL INSERT INTO @Depts VALUES (@DepartmentId);
    INSERT INTO @Depts (DeptId)
    SELECT DISTINCT m.Department_ID FROM @Cats c JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
    WHERE m.Department_ID IS NOT NULL AND m.Department_ID NOT IN (SELECT DeptId FROM @Depts);

    SELECT *
    FROM (
        SELECT
            u.Id                                                        AS UserId,
            ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)    AS FullName,
            u.Username,
            u.RegistrationNo,
            u.DepartmentIds,
            u.PathologistCategoryIds,
            ISNULL(dn.Names, '')                                        AS DepartmentNames,
            CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.PathologistCategoryIds, ''))), '') IS NULL
                 THEN 'All categories' ELSE ISNULL(cn.Names, '') END    AS CategoryNames,
            r.Reason                                                    AS IneligibleReason,
            CAST(CASE WHEN r.Reason IS NULL THEN 1 ELSE 0 END AS BIT)   AS IsEligible
        FROM dbo.Users u
        OUTER APPLY (
            SELECT STRING_AGG(d.DeptName, ', ') WITHIN GROUP (ORDER BY d.DeptName) AS Names
            FROM STRING_SPLIT(ISNULL(u.DepartmentIds, ''), ',') s
            JOIN dbo.DepartmentMaster d ON d.DeptId = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
        ) dn
        OUTER APPLY (
            SELECT STRING_AGG(m.Category_Name, ', ') WITHIN GROUP (ORDER BY m.Category_Name) AS Names
            FROM STRING_SPLIT(ISNULL(u.PathologistCategoryIds, ''), ',') s
            JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
        ) cn
        OUTER APPLY (
            SELECT COALESCE(
                CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.RegistrationNo, ''))), '') IS NULL
                     THEN 'No Registration No in User Master' END,
                CASE WHEN @BranchId IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub
                                          WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1)
                     THEN 'No access to the selected branch' END,
                (SELECT TOP 1 'Not assigned to department "' + dm.DeptName + '"'
                 FROM @Depts d JOIN dbo.DepartmentMaster dm ON dm.DeptId = d.DeptId
                 WHERE NOT EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(u.DepartmentIds, ''), ',') s
                                   WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = d.DeptId)
                 ORDER BY dm.DeptName),
                (SELECT TOP 1 'Not assigned to test category "' + m.Category_Name + '"'
                 FROM @Cats c JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = c.CategoryId
                 WHERE NULLIF(LTRIM(RTRIM(ISNULL(u.PathologistCategoryIds, ''))), '') IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(u.PathologistCategoryIds, ',') s
                                   WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = c.CategoryId)
                 ORDER BY m.Category_Name)
            ) AS Reason
        ) r
        WHERE u.CompanyId = @CompanyId
          AND u.IsActive = 1
          AND ISNULL(u.IsPathologist, 0) = 1
    ) x
    WHERE @IncludeIneligible = 1 OR x.IsEligible = 1
    ORDER BY x.IsEligible DESC, x.FullName;
END
GO

-- 4. List ------------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_GetList
    @CompanyId     INT           = NULL,
    @BranchScope   INT           = NULL,     -- NULL = all, 0 = company-wide only, >0 = that branch only
    @DepartmentId  INT           = NULL,
    @CategoryId    INT           = NULL,     -- flows that include this category
    @Status        BIT           = NULL,
    @Search        NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');

    SELECT
        f.Flow_ID, f.Flow_Code, f.CompanyId, f.Branch_ID,
        ISNULL(b.BranchName, '')            AS BranchName,
        f.Department_ID,
        ISNULL(d.DeptName, '')              AS DepartmentName,
        f.Category_IDs,
        ISNULL(cn.Names, '')                AS CategoryNames,
        f.Flow_Name, f.Required_Levels, f.Allow_Same_Approver, f.Status,
        f.CreatedDate, f.ModifiedDate,
        ISNULL((
            SELECT STRING_AGG(CAST('L' + CAST(l.Level_No AS VARCHAR(2)) + ': ' + ISNULL(x.Names, '—') AS NVARCHAR(MAX)), ' | ')
                   WITHIN GROUP (ORDER BY l.Level_No)
            FROM dbo.LabApprovalFlowLevel l
            OUTER APPLY (
                SELECT STRING_AGG(ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username), ', ')
                       WITHIN GROUP (ORDER BY u.FullName) AS Names
                FROM dbo.LabApprovalFlowApprover a
                JOIN dbo.Users u ON u.Id = a.UserId
                WHERE a.Level_ID = l.Level_ID
            ) x
            WHERE l.Flow_ID = f.Flow_ID
        ), '')                              AS LevelsSummary
    FROM dbo.LabApprovalFlow f
    LEFT JOIN dbo.Branchmaster b     ON b.BranchID = f.Branch_ID
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = f.Department_ID
    OUTER APPLY (
        SELECT STRING_AGG(m.Category_Name, ', ') WITHIN GROUP (ORDER BY m.Category_Name) AS Names
        FROM STRING_SPLIT(ISNULL(f.Category_IDs, ''), ',') s
        JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
    ) cn
    WHERE f.IsDeleted = 0
      AND (@CompanyId IS NULL OR f.CompanyId = @CompanyId)
      AND (@BranchScope IS NULL
           OR (@BranchScope = 0 AND f.Branch_ID IS NULL)
           OR (@BranchScope > 0 AND f.Branch_ID = @BranchScope))
      AND (@DepartmentId IS NULL
           OR f.Department_ID = @DepartmentId
           OR EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(f.Category_IDs, ''), ',') s
                      JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
                      WHERE m.Department_ID = @DepartmentId))
      AND (@CategoryId IS NULL
           OR EXISTS (SELECT 1 FROM STRING_SPLIT(ISNULL(f.Category_IDs, ''), ',') s
                      WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = @CategoryId))
      AND (@Status IS NULL OR f.Status = @Status)
      AND (@Search IS NULL
           OR f.Flow_Code LIKE '%' + @Search + '%'
           OR f.Flow_Name LIKE '%' + @Search + '%'
           OR b.BranchName LIKE '%' + @Search + '%'
           OR d.DeptName LIKE '%' + @Search + '%'
           OR cn.Names LIKE '%' + @Search + '%')
    ORDER BY f.Status DESC, ISNULL(f.Branch_ID, 0), ISNULL(d.DeptName, ''), f.Flow_ID;
END
GO

-- 5. Get by id (RS1 header, RS2 levels, RS3 approvers) -----------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_GetById
    @Flow_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        f.Flow_ID, f.Flow_Code, f.CompanyId, f.Branch_ID,
        ISNULL(b.BranchName, '')            AS BranchName,
        f.Department_ID,
        ISNULL(d.DeptName, '')              AS DepartmentName,
        f.Category_IDs,
        ISNULL(cn.Names, '')                AS CategoryNames,
        f.Flow_Name, f.Required_Levels, f.Allow_Same_Approver, f.Status,
        f.CreatedDate, f.ModifiedDate
    FROM dbo.LabApprovalFlow f
    LEFT JOIN dbo.Branchmaster b     ON b.BranchID = f.Branch_ID
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = f.Department_ID
    OUTER APPLY (
        SELECT STRING_AGG(m.Category_Name, ', ') WITHIN GROUP (ORDER BY m.Category_Name) AS Names
        FROM STRING_SPLIT(ISNULL(f.Category_IDs, ''), ',') s
        JOIN dbo.LabTestCategoryMaster m ON m.Category_ID = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
    ) cn
    WHERE f.Flow_ID = @Flow_ID AND f.IsDeleted = 0;

    SELECT l.Level_ID, l.Level_No, l.Level_Title
    FROM dbo.LabApprovalFlowLevel l
    WHERE l.Flow_ID = @Flow_ID
    ORDER BY l.Level_No;

    SELECT
        l.Level_No,
        a.UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)    AS FullName,
        u.RegistrationNo,
        u.IsActive                                                  AS UserIsActive,
        CAST(ISNULL(u.IsPathologist, 0) AS BIT)                     AS UserIsPathologist
    FROM dbo.LabApprovalFlowLevel l
    JOIN dbo.LabApprovalFlowApprover a ON a.Level_ID = l.Level_ID
    JOIN dbo.Users u ON u.Id = a.UserId
    WHERE l.Flow_ID = @Flow_ID
    ORDER BY l.Level_No, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username);
END
GO

-- 6. Create -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_Create
    @Flow_Name           NVARCHAR(150),
    @Required_Levels     INT,
    @Branch_ID           INT = NULL,
    @Department_ID       INT = NULL,
    @Category_IDs        NVARCHAR(500) = NULL,
    @Allow_Same_Approver BIT = 0,
    @LevelsJson          NVARCHAR(MAX),
    @CompanyId           INT = 1,
    @UserId              INT = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #Lv  (Level_No INT, Level_Title NVARCHAR(100));
    CREATE TABLE #Ap  (Level_No INT, UserId INT);
    CREATE TABLE #Cat (CategoryId INT PRIMARY KEY);

    DECLARE @Err NVARCHAR(500);
    EXEC dbo.usp_LabApprovalFlow_ValidateAndParse
        @CompanyId = @CompanyId, @Branch_ID = @Branch_ID, @Department_ID = @Department_ID OUTPUT,
        @Category_IDs = @Category_IDs OUTPUT, @Flow_Name = @Flow_Name, @Required_Levels = @Required_Levels,
        @Allow_Same_Approver = @Allow_Same_Approver, @LevelsJson = @LevelsJson,
        @ExcludeFlowId = NULL, @ErrorMessage = @Err OUTPUT;

    IF @Err IS NOT NULL
    BEGIN RAISERROR('%s', 16, 1, @Err); RETURN; END

    IF @Branch_ID IS NOT NULL AND @Branch_ID <= 0 SET @Branch_ID = NULL;

    BEGIN TRANSACTION;

    -- serialise concurrent saves of the same company, then re-check for an overlapping flow
    IF EXISTS (SELECT 1 FROM dbo.LabApprovalFlow WITH (UPDLOCK, HOLDLOCK)
               WHERE CompanyId = @CompanyId AND IsDeleted = 0
                 AND ISNULL(Branch_ID, 0) = ISNULL(@Branch_ID, 0)
                 AND ((@Category_IDs IS NULL AND Category_IDs IS NULL AND ISNULL(Department_ID, 0) = ISNULL(@Department_ID, 0))
                   OR (@Category_IDs IS NOT NULL AND Category_IDs IS NOT NULL AND EXISTS (
                        SELECT 1 FROM STRING_SPLIT(Category_IDs, ',') s JOIN #Cat c ON c.CategoryId = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)))))
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR('An approval flow already exists for this scope. Edit that flow instead.', 16, 1);
        RETURN;
    END

    INSERT INTO dbo.LabApprovalFlow
        (CompanyId, Branch_ID, Department_ID, Category_IDs, Flow_Name, Required_Levels, Allow_Same_Approver, Status, CreatedBy, CreatedDate)
    VALUES
        (@CompanyId, @Branch_ID, @Department_ID, @Category_IDs, LTRIM(RTRIM(@Flow_Name)), @Required_Levels, ISNULL(@Allow_Same_Approver, 0), 1, @UserId, GETDATE());

    SET @NewId = SCOPE_IDENTITY();

    UPDATE dbo.LabApprovalFlow
    SET Flow_Code = 'LAF' + RIGHT('0000' + CAST(@NewId AS NVARCHAR(10)), 4)
    WHERE Flow_ID = @NewId;

    INSERT INTO dbo.LabApprovalFlowLevel (Flow_ID, Level_No, Level_Title)
    SELECT @NewId, Level_No, CASE WHEN Level_Title = '' THEN 'Level ' + CAST(Level_No AS VARCHAR(2)) ELSE Level_Title END
    FROM #Lv;

    INSERT INTO dbo.LabApprovalFlowApprover (Level_ID, UserId)
    SELECT l.Level_ID, ap.UserId
    FROM #Ap ap
    JOIN dbo.LabApprovalFlowLevel l ON l.Flow_ID = @NewId AND l.Level_No = ap.Level_No;

    COMMIT TRANSACTION;
END
GO

-- 7. Update -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_Update
    @Flow_ID             INT,
    @Flow_Name           NVARCHAR(150),
    @Required_Levels     INT,
    @Branch_ID           INT = NULL,
    @Department_ID       INT = NULL,
    @Category_IDs        NVARCHAR(500) = NULL,
    @Allow_Same_Approver BIT = 0,
    @Status              BIT = 1,
    @LevelsJson          NVARCHAR(MAX),
    @UserId              INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CompanyId INT;
    SELECT @CompanyId = CompanyId FROM dbo.LabApprovalFlow WHERE Flow_ID = @Flow_ID AND IsDeleted = 0;

    IF @CompanyId IS NULL
    BEGIN RAISERROR('Approval flow record not found.', 16, 1); RETURN; END

    CREATE TABLE #Lv  (Level_No INT, Level_Title NVARCHAR(100));
    CREATE TABLE #Ap  (Level_No INT, UserId INT);
    CREATE TABLE #Cat (CategoryId INT PRIMARY KEY);

    DECLARE @Err NVARCHAR(500);
    EXEC dbo.usp_LabApprovalFlow_ValidateAndParse
        @CompanyId = @CompanyId, @Branch_ID = @Branch_ID, @Department_ID = @Department_ID OUTPUT,
        @Category_IDs = @Category_IDs OUTPUT, @Flow_Name = @Flow_Name, @Required_Levels = @Required_Levels,
        @Allow_Same_Approver = @Allow_Same_Approver, @LevelsJson = @LevelsJson,
        @ExcludeFlowId = @Flow_ID, @ErrorMessage = @Err OUTPUT;

    IF @Err IS NOT NULL
    BEGIN RAISERROR('%s', 16, 1, @Err); RETURN; END

    IF @Branch_ID IS NOT NULL AND @Branch_ID <= 0 SET @Branch_ID = NULL;

    BEGIN TRANSACTION;

    IF EXISTS (SELECT 1 FROM dbo.LabApprovalFlow WITH (UPDLOCK, HOLDLOCK)
               WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Flow_ID <> @Flow_ID
                 AND ISNULL(Branch_ID, 0) = ISNULL(@Branch_ID, 0)
                 AND ((@Category_IDs IS NULL AND Category_IDs IS NULL AND ISNULL(Department_ID, 0) = ISNULL(@Department_ID, 0))
                   OR (@Category_IDs IS NOT NULL AND Category_IDs IS NOT NULL AND EXISTS (
                        SELECT 1 FROM STRING_SPLIT(Category_IDs, ',') s JOIN #Cat c ON c.CategoryId = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)))))
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR('An approval flow already exists for this scope. Edit that flow instead.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabApprovalFlow
    SET Branch_ID = @Branch_ID, Department_ID = @Department_ID, Category_IDs = @Category_IDs,
        Flow_Name = LTRIM(RTRIM(@Flow_Name)), Required_Levels = @Required_Levels,
        Allow_Same_Approver = ISNULL(@Allow_Same_Approver, 0), Status = ISNULL(@Status, 1),
        ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Flow_ID = @Flow_ID;

    -- the level structure is replaced as a whole (the tables hold configuration only)
    DELETE a FROM dbo.LabApprovalFlowApprover a
    JOIN dbo.LabApprovalFlowLevel l ON l.Level_ID = a.Level_ID
    WHERE l.Flow_ID = @Flow_ID;

    DELETE FROM dbo.LabApprovalFlowLevel WHERE Flow_ID = @Flow_ID;

    INSERT INTO dbo.LabApprovalFlowLevel (Flow_ID, Level_No, Level_Title)
    SELECT @Flow_ID, Level_No, CASE WHEN Level_Title = '' THEN 'Level ' + CAST(Level_No AS VARCHAR(2)) ELSE Level_Title END
    FROM #Lv;

    INSERT INTO dbo.LabApprovalFlowApprover (Level_ID, UserId)
    SELECT l.Level_ID, ap.UserId
    FROM #Ap ap
    JOIN dbo.LabApprovalFlowLevel l ON l.Flow_ID = @Flow_ID AND l.Level_No = ap.Level_No;

    COMMIT TRANSACTION;
END
GO

-- 8. Toggle status / soft delete ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_ToggleStatus
    @Flow_ID INT,
    @Status  BIT,
    @UserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabApprovalFlow WHERE Flow_ID = @Flow_ID AND IsDeleted = 0)
    BEGIN RAISERROR('Approval flow record not found.', 16, 1); RETURN; END

    UPDATE dbo.LabApprovalFlow
    SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Flow_ID = @Flow_ID AND IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabApprovalFlow_Delete
    @Flow_ID INT,
    @UserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabApprovalFlow WHERE Flow_ID = @Flow_ID AND IsDeleted = 0)
    BEGIN RAISERROR('Approval flow record not found.', 16, 1); RETURN; END

    UPDATE dbo.LabApprovalFlow
    SET IsDeleted = 1, Status = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Flow_ID = @Flow_ID;
END
GO

-- 9. Resolve (read-only; used later by the Approval screen) -------------------------------------------------
--    RS1: the winning flow (0 or 1 row)   RS2: its levels   RS3: its approvers per level
--    @CategoryId is the test category of the report being approved.
CREATE OR ALTER PROCEDURE dbo.usp_LabApprovalFlow_Resolve
    @CompanyId     INT,
    @BranchId      INT = NULL,
    @DepartmentId  INT = NULL,
    @CategoryId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @CategoryId IS NOT NULL AND @CategoryId <= 0 SET @CategoryId = NULL;
    IF @DepartmentId IS NOT NULL AND @DepartmentId <= 0 SET @DepartmentId = NULL;

    IF @CategoryId IS NOT NULL AND @DepartmentId IS NULL
        SELECT @DepartmentId = Department_ID FROM dbo.LabTestCategoryMaster WHERE Category_ID = @CategoryId;

    DECLARE @FlowId INT;

    SELECT TOP 1 @FlowId = f.Flow_ID
    FROM dbo.LabApprovalFlow f
    WHERE f.CompanyId = @CompanyId
      AND f.IsDeleted = 0 AND f.Status = 1
      AND (f.Branch_ID IS NULL OR f.Branch_ID = @BranchId)
      AND (
            -- a flow that lists this category
            (f.Category_IDs IS NOT NULL AND @CategoryId IS NOT NULL
             AND EXISTS (SELECT 1 FROM STRING_SPLIT(f.Category_IDs, ',') s WHERE TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) = @CategoryId))
            -- or a category-less flow for this department / all departments
         OR (f.Category_IDs IS NULL AND (f.Department_ID IS NULL OR f.Department_ID = @DepartmentId))
          )
    ORDER BY
        CASE WHEN f.Category_IDs IS NOT NULL THEN 3 WHEN f.Department_ID IS NOT NULL THEN 2 ELSE 1 END DESC,
        CASE WHEN f.Branch_ID IS NOT NULL THEN 1 ELSE 0 END DESC,
        f.Flow_ID;

    SELECT f.Flow_ID, f.Flow_Code, f.Flow_Name, f.Required_Levels, f.Allow_Same_Approver,
           f.Branch_ID, f.Department_ID, f.Category_IDs
    FROM dbo.LabApprovalFlow f
    WHERE f.Flow_ID = @FlowId;

    SELECT l.Level_ID, l.Level_No, l.Level_Title
    FROM dbo.LabApprovalFlowLevel l
    WHERE l.Flow_ID = @FlowId
    ORDER BY l.Level_No;

    SELECT
        l.Level_No,
        a.UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS FullName,
        u.RegistrationNo
    FROM dbo.LabApprovalFlowLevel l
    JOIN dbo.LabApprovalFlowApprover a ON a.Level_ID = l.Level_ID
    JOIN dbo.Users u ON u.Id = a.UserId AND u.IsActive = 1
    WHERE l.Flow_ID = @FlowId
    ORDER BY l.Level_No, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username);
END
GO

PRINT 'Pathologist Approval Flow objects created.';
GO
