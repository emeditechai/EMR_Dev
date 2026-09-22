-- ============================================================================
-- Migration: 2092_pathologist_test_category_assignment.sql
-- Description:
--   "Is Pathologist" configuration on the User master can now assign the Lab Test
--   Categories a pathologist signs off, restricted to the departments granted to that
--   user under "Department Access".
--
--     1. dbo.Users.PathologistCategoryIds  - CSV of LabTestCategoryMaster.Category_ID,
--        the same storage style the row already uses for DepartmentIds.
--     2. dbo.usp_Api_LabTestCategories_GetByDepartments - the categories of a CSV of
--        department ids (active, not deleted), used to populate the dropdown and to
--        validate the posted selection on the server.
--
--   Nothing existing is dropped or rewritten; the column is added only when missing.
-- ============================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Users.PathologistCategoryIds ─────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.Users') AND name = 'PathologistCategoryIds')
BEGIN
    ALTER TABLE dbo.Users ADD PathologistCategoryIds NVARCHAR(500) NULL;
    PRINT 'Added column dbo.Users.PathologistCategoryIds';
END
ELSE
    PRINT 'Column dbo.Users.PathologistCategoryIds already exists';
GO

-- ── 2. Categories of the given departments ──────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabTestCategories_GetByDepartments
    @DepartmentIds NVARCHAR(500) = NULL,   -- CSV; NULL / empty = every active category
    @CompanyId     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ids TABLE (DeptId INT PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@DepartmentIds)), '') IS NOT NULL
        INSERT INTO @Ids (DeptId)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
        FROM STRING_SPLIT(@DepartmentIds, ',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    SELECT
        c.Category_ID                       AS CategoryId,
        c.Category_Name                     AS CategoryName,
        c.Category_Code                     AS CategoryCode,
        c.Department_ID                     AS DepartmentId,
        ISNULL(d.DeptName, '')              AS DepartmentName,
        ISNULL(c.Display_Order, 9999)       AS DisplayOrder
    FROM dbo.LabTestCategoryMaster c
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = c.Department_ID
    WHERE ISNULL(c.IsDeleted, 0) = 0
      AND ISNULL(c.Status, 1) = 1
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (NOT EXISTS (SELECT 1 FROM @Ids) OR c.Department_ID IN (SELECT DeptId FROM @Ids))
    ORDER BY ISNULL(d.DeptName, ''), ISNULL(c.Display_Order, 9999), c.Category_Name;
END;
GO

PRINT 'Created procedure dbo.usp_Api_LabTestCategories_GetByDepartments';
GO
