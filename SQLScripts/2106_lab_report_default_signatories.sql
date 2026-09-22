-- ============================================================================
-- Migration: 2106_lab_report_default_signatories.sql
-- Description:
--   Default report signatories, used when HospitalSettings.PathologistApprovalRequired = 0 (no pathologist
--   sign-off workflow). Up to three pathologists are configured per branch at Level 1 / 2 / 3, any one or all.
--
--     dbo.LabReportDefaultSignatory            one row per level per branch (level 1..3, unique)
--     dbo.usp_Api_LabDefaultSignatory_GetList  the configured levels + the pathologists to pick from
--     dbo.usp_Api_LabDefaultSignatory_Save     replaces the whole set for a branch from a JSON payload
--
--   The name and registration number always come from the chosen user (dbo.Users); SignaturePath here is an
--   optional per-level override, so a level can carry a signature even when the user has none on their profile.
--   Read/written only by the Hospital Settings screen for now - no report or approval behaviour is changed.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.LabReportDefaultSignatory', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabReportDefaultSignatory
    (
        SignatoryId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabReportDefaultSignatory PRIMARY KEY,
        CompanyId      INT           NOT NULL CONSTRAINT DF_LabReportDefaultSignatory_Co DEFAULT (1),
        BranchId       INT           NOT NULL,
        LevelNo        TINYINT       NOT NULL,          -- 1, 2 or 3
        UserId         INT           NOT NULL,
        SignaturePath  NVARCHAR(260) NULL,              -- optional per-level override of the user's signature
        IsActive       BIT           NOT NULL CONSTRAINT DF_LabReportDefaultSignatory_Act DEFAULT (1),
        CreatedBy      INT           NULL,
        CreatedDate    DATETIME      NOT NULL CONSTRAINT DF_LabReportDefaultSignatory_Cd DEFAULT (GETDATE()),
        ModifiedBy     INT           NULL,
        ModifiedDate   DATETIME      NULL,
        CONSTRAINT CK_LabReportDefaultSignatory_Level CHECK (LevelNo BETWEEN 1 AND 3)
    );
    CREATE UNIQUE INDEX UQ_LabReportDefaultSignatory_Branch_Level
        ON dbo.LabReportDefaultSignatory (BranchId, LevelNo);
    PRINT 'Created table dbo.LabReportDefaultSignatory';
END
GO

-- ── the configured levels, plus the pathologists that may be picked ─────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabDefaultSignatory_GetList
    @BranchId  INT,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: what is configured for this branch
    SELECT
        s.SignatoryId, s.LevelNo, s.UserId, s.SignaturePath, s.IsActive,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)             AS FullName,
        ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
        u.SignaturePath                                                       AS UserSignaturePath,
        CAST(CASE WHEN ISNULL(u.IsPathologist, 0) = 1 AND ISNULL(u.IsActive, 0) = 1 THEN 1 ELSE 0 END AS BIT) AS IsEligible
    FROM dbo.LabReportDefaultSignatory s
    INNER JOIN dbo.Users u ON u.Id = s.UserId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1
    ORDER BY s.LevelNo;

    -- RS2: the pathologists of this branch that can be chosen
    SELECT
        u.Id                                                                  AS UserId,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username)              AS FullName,
        ISNULL(NULLIF(LTRIM(RTRIM(u.RegistrationNo)), ''), u.CertificationNo) AS RegistrationNo,
        u.SignaturePath,
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(u.SignaturePath, ''))), '') IS NULL THEN 0 ELSE 1 END AS BIT) AS HasSignature
    FROM dbo.Users u
    WHERE ISNULL(u.IsPathologist, 0) = 1
      AND ISNULL(u.IsActive, 0) = 1
      AND (@CompanyId IS NULL OR ISNULL(u.CompanyId, @CompanyId) = @CompanyId)
      AND EXISTS (SELECT 1 FROM dbo.UserBranches ub
                  WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)
    ORDER BY ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username);
END;
GO
PRINT 'Created dbo.usp_Api_LabDefaultSignatory_GetList';
GO

-- ── replace the whole set for a branch ──────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabDefaultSignatory_Save
    @BranchId  INT,
    @CompanyId INT,
    @UserId    INT,
    @ItemsJson NVARCHAR(MAX)     -- [{ "levelNo":1, "userId":5, "signaturePath":"sig_x.png" }, ...]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @BranchId IS NULL OR @BranchId <= 0
    BEGIN RAISERROR('Valid BranchId is required.', 16, 1); RETURN; END

    DECLARE @Items TABLE (LevelNo TINYINT, UserId INT, SignaturePath NVARCHAR(260));

    INSERT @Items (LevelNo, UserId, SignaturePath)
    SELECT j.levelNo, j.userId, NULLIF(LTRIM(RTRIM(j.signaturePath)), '')
    FROM OPENJSON(ISNULL(@ItemsJson, '[]'))
    WITH (levelNo TINYINT '$.levelNo', userId INT '$.userId', signaturePath NVARCHAR(260) '$.signaturePath') j
    WHERE j.userId > 0 AND j.levelNo BETWEEN 1 AND 3;

    IF EXISTS (SELECT LevelNo FROM @Items GROUP BY LevelNo HAVING COUNT(1) > 1)
    BEGIN RAISERROR('Each level can be set only once.', 16, 1); RETURN; END

    IF EXISTS (SELECT UserId FROM @Items GROUP BY UserId HAVING COUNT(1) > 1)
    BEGIN RAISERROR('The same pathologist cannot be used on more than one level.', 16, 1); RETURN; END

    -- every chosen user must be an active pathologist of this branch
    IF EXISTS (
        SELECT 1 FROM @Items i
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.Users u
            WHERE u.Id = i.UserId AND ISNULL(u.IsPathologist, 0) = 1 AND ISNULL(u.IsActive, 0) = 1
              AND EXISTS (SELECT 1 FROM dbo.UserBranches ub
                          WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)))
    BEGIN
        RAISERROR('Every signatory must be an active pathologist assigned to this branch.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME = GETDATE();

    BEGIN TRAN;

    -- a level that is no longer configured is removed
    DELETE s
    FROM dbo.LabReportDefaultSignatory s
    WHERE s.BranchId = @BranchId
      AND NOT EXISTS (SELECT 1 FROM @Items i WHERE i.LevelNo = s.LevelNo);

    MERGE dbo.LabReportDefaultSignatory AS t
    USING (SELECT LevelNo, UserId, SignaturePath FROM @Items) AS src
       ON t.BranchId = @BranchId AND t.LevelNo = src.LevelNo
    WHEN MATCHED THEN
        UPDATE SET t.UserId        = src.UserId,
                   -- an empty path keeps whatever is already stored for that level
                   t.SignaturePath = ISNULL(src.SignaturePath, t.SignaturePath),
                   t.IsActive      = 1,
                   t.ModifiedBy    = @UserId,
                   t.ModifiedDate  = @Now
    WHEN NOT MATCHED THEN
        INSERT (CompanyId, BranchId, LevelNo, UserId, SignaturePath, IsActive, CreatedBy, CreatedDate)
        VALUES (@CompanyId, @BranchId, src.LevelNo, src.UserId, src.SignaturePath, 1, @UserId, @Now);

    COMMIT;

    SELECT COUNT(1) AS SavedCount FROM @Items;
END;
GO
PRINT 'Created dbo.usp_Api_LabDefaultSignatory_Save';
GO
