-- ============================================================================
-- Migration: 2136_alter_lab_report_default_signatories.sql (v2)
-- Description:
--   Department-wise pathologist signatories with up to 3 slots per department.
--   Handles three possible table states:
--     A) Original table (has LevelNo column - never migrated)
--     B) Partial migration (has DepartmentId but no SlotNo)
--     C) Already fully migrated (has DepartmentId + SlotNo)
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── CASE A: Original table has LevelNo ─────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.LabReportDefaultSignatory') AND name = 'LevelNo')
BEGIN
    -- Drop old check constraint if exists
    IF EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_LabReportDefaultSignatory_Level'
                 AND parent_object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
        ALTER TABLE dbo.LabReportDefaultSignatory DROP CONSTRAINT CK_LabReportDefaultSignatory_Level;

    -- Drop old unique index if exists
    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_LabReportDefaultSignatory_Branch_Level'
                 AND object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
        DROP INDEX UQ_LabReportDefaultSignatory_Branch_Level ON dbo.LabReportDefaultSignatory;

    -- Rename LevelNo -> SlotNo (re-use the 1/2/3 meaning as slot within a department)
    EXEC sp_rename 'dbo.LabReportDefaultSignatory.LevelNo', 'SlotNo', 'COLUMN';

    -- Add DepartmentId column (nullable initially; rows with NULL will be cleared below)
    ALTER TABLE dbo.LabReportDefaultSignatory ADD DepartmentId INT NULL;

    PRINT 'Case A: Renamed LevelNo->SlotNo, added DepartmentId (nullable).';
END
GO

-- ── CASE B: Has DepartmentId but no SlotNo (partial migration) ──────────────
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.LabReportDefaultSignatory') AND name = 'DepartmentId')
   AND NOT EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('dbo.LabReportDefaultSignatory') AND name = 'SlotNo')
BEGIN
    -- Drop old unique constraint if exists
    IF EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_LabReportDefaultSignatory_Branch_Dept'
                 AND object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
        ALTER TABLE dbo.LabReportDefaultSignatory DROP CONSTRAINT UQ_LabReportDefaultSignatory_Branch_Dept;

    -- Add SlotNo with default 1 (existing rows become slot 1)
    ALTER TABLE dbo.LabReportDefaultSignatory ADD SlotNo TINYINT NOT NULL DEFAULT 1;

    PRINT 'Case B: Added SlotNo column (existing rows defaulted to slot 1).';
END
GO

-- ── Clean up NULL DepartmentId rows (from Case A) ──────────────────────────
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.LabReportDefaultSignatory') AND name = 'DepartmentId')
BEGIN
    DELETE FROM dbo.LabReportDefaultSignatory WHERE DepartmentId IS NULL OR DepartmentId = 0;
    ALTER TABLE dbo.LabReportDefaultSignatory ALTER COLUMN DepartmentId INT NOT NULL;
    PRINT 'DepartmentId set to NOT NULL; orphan rows removed.';
END
GO

-- ── Add SlotNo check constraint (1..3) ─────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_LabReportDefaultSignatory_Slot'
                 AND parent_object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
BEGIN
    ALTER TABLE dbo.LabReportDefaultSignatory
        ADD CONSTRAINT CK_LabReportDefaultSignatory_Slot CHECK (SlotNo BETWEEN 1 AND 3);
    PRINT 'Added SlotNo check constraint.';
END
GO

-- ── Drop any stale unique indexes and recreate ──────────────────────────────
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'UQ_LabReportDefaultSignatory_Branch_Level'
             AND object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
    DROP INDEX UQ_LabReportDefaultSignatory_Branch_Level ON dbo.LabReportDefaultSignatory;
GO
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'UQ_LabReportDefaultSignatory_Branch_Dept'
             AND object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
    ALTER TABLE dbo.LabReportDefaultSignatory DROP CONSTRAINT UQ_LabReportDefaultSignatory_Branch_Dept;
GO
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'UQ_LabReportDefaultSignatory_Branch_Dept_Slot'
             AND object_id = OBJECT_ID('dbo.LabReportDefaultSignatory'))
    DROP INDEX UQ_LabReportDefaultSignatory_Branch_Dept_Slot ON dbo.LabReportDefaultSignatory;
GO

CREATE UNIQUE INDEX UQ_LabReportDefaultSignatory_Branch_Dept_Slot
    ON dbo.LabReportDefaultSignatory (BranchId, DepartmentId, SlotNo);
PRINT 'Created unique index on (BranchId, DepartmentId, SlotNo).';
GO

-- ── GetList SP ──────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabDefaultSignatory_GetList
    @BranchId  INT,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: configured signatories for this branch (ordered by dept then slot)
    SELECT
        s.SignatoryId, s.DepartmentId, s.SlotNo, s.UserId, s.SignaturePath, s.IsActive,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
        ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
        u.SignaturePath                                                        AS UserSignaturePath,
        CAST(CASE WHEN ISNULL(u.IsPathologist, 0) = 1
                   AND ISNULL(u.IsActive, 0) = 1 THEN 1 ELSE 0 END AS BIT)   AS IsEligible
    FROM dbo.LabReportDefaultSignatory s
    INNER JOIN dbo.Users u ON u.Id = s.UserId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1
    ORDER BY s.DepartmentId, s.SlotNo;

    -- RS2: active pathologists of this branch that can be chosen
    SELECT
        u.Id                                                                  AS UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
        ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
        u.SignaturePath,
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.SignaturePath,''))), '')
                       IS NULL THEN 0 ELSE 1 END AS BIT)                     AS HasSignature
    FROM dbo.Users u
    WHERE ISNULL(u.IsPathologist, 0) = 1
      AND ISNULL(u.IsActive, 0) = 1
      AND (@CompanyId IS NULL OR ISNULL(u.CompanyId, @CompanyId) = @CompanyId)
      AND EXISTS (SELECT 1 FROM dbo.UserBranches ub
                  WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId
                    AND ISNULL(ub.IsActive, 1) = 1)
    ORDER BY ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username);

    -- RS3: LAB departments (Type = LAB)
    SELECT DeptId AS DepartmentId, DeptName AS DepartmentName
    FROM   dbo.DepartmentMaster
    WHERE  DeptType = 'LAB' AND IsActive = 1
    ORDER  BY DeptName;
END;
GO
PRINT 'Created/updated dbo.usp_Api_LabDefaultSignatory_GetList';
GO

-- ── Save SP ─────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabDefaultSignatory_Save
    @BranchId  INT,
    @CompanyId INT,
    @UserId    INT,
    @ItemsJson NVARCHAR(MAX)
    -- [{"departmentId":1,"slotNo":1,"userId":5,"signaturePath":"sig_x.png"}, ...]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @BranchId IS NULL OR @BranchId <= 0
    BEGIN RAISERROR('Valid BranchId is required.', 16, 1); RETURN; END

    DECLARE @Items TABLE (DepartmentId INT, SlotNo TINYINT, UserId INT, SignaturePath NVARCHAR(260));

    INSERT @Items (DepartmentId, SlotNo, UserId, SignaturePath)
    SELECT j.departmentId,
           j.slotNo,
           j.userId,
           NULLIF(LTRIM(RTRIM(j.signaturePath)), '')
    FROM OPENJSON(ISNULL(@ItemsJson, '[]'))
    WITH (
        departmentId  INT           '$.departmentId',
        slotNo        TINYINT       '$.slotNo',
        userId        INT           '$.userId',
        signaturePath NVARCHAR(260) '$.signaturePath'
    ) j
    WHERE j.userId > 0 AND j.departmentId > 0 AND j.slotNo BETWEEN 1 AND 3;

    -- Each (dept, slot) must appear at most once
    IF EXISTS (SELECT DepartmentId, SlotNo FROM @Items
               GROUP BY DepartmentId, SlotNo HAVING COUNT(1) > 1)
    BEGIN RAISERROR('Duplicate slot within a department.', 16, 1); RETURN; END

    -- Every user must be an active pathologist of this branch
    IF EXISTS (
        SELECT 1 FROM @Items i
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.Users u
            WHERE u.Id = i.UserId
              AND ISNULL(u.IsPathologist, 0) = 1
              AND ISNULL(u.IsActive, 0) = 1
              AND EXISTS (SELECT 1 FROM dbo.UserBranches ub
                          WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId
                            AND ISNULL(ub.IsActive, 1) = 1)))
    BEGIN
        RAISERROR('Every signatory must be an active pathologist assigned to this branch.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME = GETDATE();

    BEGIN TRAN;

    -- Remove (dept, slot) combinations no longer submitted
    DELETE s
    FROM dbo.LabReportDefaultSignatory s
    WHERE s.BranchId = @BranchId
      AND NOT EXISTS (SELECT 1 FROM @Items i
                      WHERE i.DepartmentId = s.DepartmentId AND i.SlotNo = s.SlotNo);

    MERGE dbo.LabReportDefaultSignatory AS t
    USING (SELECT DepartmentId, SlotNo, UserId, SignaturePath FROM @Items) AS src
       ON t.BranchId    = @BranchId
      AND t.DepartmentId = src.DepartmentId
      AND t.SlotNo       = src.SlotNo
    WHEN MATCHED THEN
        UPDATE SET
            t.UserId       = src.UserId,
            t.SignaturePath = ISNULL(src.SignaturePath, t.SignaturePath),
            t.IsActive     = 1,
            t.ModifiedBy   = @UserId,
            t.ModifiedDate = @Now
    WHEN NOT MATCHED THEN
        INSERT (CompanyId, BranchId, DepartmentId, SlotNo, UserId, SignaturePath, IsActive, CreatedBy, CreatedDate)
        VALUES (@CompanyId, @BranchId, src.DepartmentId, src.SlotNo, src.UserId, src.SignaturePath, 1, @UserId, @Now);

    COMMIT;

    SELECT COUNT(1) AS SavedCount FROM @Items;
END;
GO
PRINT 'Created/updated dbo.usp_Api_LabDefaultSignatory_Save';
GO
