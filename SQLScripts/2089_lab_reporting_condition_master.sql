-- ====================================================================================================
-- Script: 2089_lab_reporting_condition_master.sql
-- Description: "Conditions of Reporting" master (Master > Lab Master). The conditions printed on the
--              last page of the Lab Report PDF are read from this table, per Company and per Branch.
--
-- Scope rules
--   * Every row belongs to a Company (CompanyId).
--   * Branch_ID = NULL  -> company-wide condition (applies to every branch of the company).
--   * Branch_ID = <id>  -> branch-specific condition.
--   * For a report, if the billing branch has ACTIVE branch-specific conditions, those are printed;
--     otherwise the company-wide ACTIVE conditions are printed (usp_..._GetForReport).
--
-- Objects
--   dbo.LabReportingConditionMaster
--   dbo.usp_Api_LabReportingConditionMaster_GetList / GetById / Create / Update / ToggleStatus / Delete
--   dbo.usp_Api_LabReportingConditionMaster_GetForReport
--
-- Seeds the standard 11 conditions (company-wide) for every company that has none, so existing
-- reports keep printing exactly the same conditions page.
-- ====================================================================================================

USE [Dev_EMR];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Table -------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabReportingConditionMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabReportingConditionMaster
    (
        Condition_ID    INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId       INT NOT NULL CONSTRAINT DF_LabReportingConditionMaster_Company DEFAULT 1,
        Branch_ID       INT NULL,
        Condition_Code  NVARCHAR(50) NOT NULL CONSTRAINT DF_LabReportingConditionMaster_Code DEFAULT '',
        Condition_Text  NVARCHAR(1000) NOT NULL,
        Display_Order   INT NOT NULL CONSTRAINT DF_LabReportingConditionMaster_Order DEFAULT 1,
        Status          BIT NOT NULL CONSTRAINT DF_LabReportingConditionMaster_Status DEFAULT 1,
        IsDeleted       BIT NOT NULL CONSTRAINT DF_LabReportingConditionMaster_Deleted DEFAULT 0,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME2 NOT NULL CONSTRAINT DF_LabReportingConditionMaster_Created DEFAULT GETDATE(),
        ModifiedBy      INT NULL,
        ModifiedDate    DATETIME2 NULL,
        CONSTRAINT FK_LabReportingConditionMaster_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID)
    );
    CREATE INDEX IX_LabReportingConditionMaster_Scope
        ON dbo.LabReportingConditionMaster (CompanyId, Branch_ID, Status, IsDeleted) INCLUDE (Display_Order);
    PRINT 'Created table dbo.LabReportingConditionMaster';
END
ELSE
    PRINT 'Table dbo.LabReportingConditionMaster already exists';
GO

-- 2. Seed the standard conditions (company-wide) for every company that has none ------------------------
IF OBJECT_ID('dbo.CompanyMaster') IS NOT NULL
BEGIN
    DECLARE @Seed TABLE (Ord INT, Txt NVARCHAR(1000));
    INSERT INTO @Seed (Ord, Txt) VALUES
    (1,  N'The contents of this report are to be forwarded to the referring doctor only, for the purpose of assisting in diagnosis and management of the patient.'),
    (2,  N'Test results relate only to the specimen submitted for testing.'),
    (3,  N'Unless the collection time is specified, the date printed is the date the sample was received.'),
    (4,  N'Interpretation notes, where given, appear below the test heading. Results should be interpreted together with clinical findings and other investigations.'),
    (5,  N'A requested test may not be performed, or may be reported as "QTY. NOT ADEQUATE", "TEST NOT PERFORMED" or "INCONCLUSIVE", when the specimen is insufficient, unsuitable (haemolysed / clotted / lipaemic) or incorrectly labelled. The reason is stated on the report.'),
    (6,  N'A "PROVISIONAL" report means some results are not yet authenticated. A provisional copy carries a NOT APPROVED mark and is not valid for clinical or legal use until the final report is issued.'),
    (7,  N'Values marked with * are critical values. H and L indicate results above and below the reference range.'),
    (8,  N'A repeat investigation may be possible as per the laboratory''s sample retention policy.'),
    (9,  N'Laboratory results depend on sample quality, assay technology, equipment and method specificity. Isolated laboratory results are not the final diagnosis of disease.'),
    (10, N'Results may be delayed for reasons beyond the laboratory''s control. If a result does not fit the clinical picture, please contact the laboratory for a retest.'),
    (11, N'Reports are meant to assist in diagnosing medical conditions and are not for forensic or medico-legal purposes.');

    INSERT INTO dbo.LabReportingConditionMaster (CompanyId, Branch_ID, Condition_Text, Display_Order, Status, CreatedDate)
    SELECT c.CompanyId, NULL, s.Txt, s.Ord, 1, GETDATE()
    FROM dbo.CompanyMaster c
    CROSS JOIN @Seed s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.LabReportingConditionMaster m WHERE m.CompanyId = c.CompanyId AND m.IsDeleted = 0);

    UPDATE dbo.LabReportingConditionMaster
    SET Condition_Code = 'LCOR' + RIGHT('0000' + CAST(Condition_ID AS NVARCHAR(10)), 4)
    WHERE Condition_Code = '';

    PRINT 'Seeded default Conditions of Reporting for companies that had none';
END
GO

-- 3. GetList --------------------------------------------------------------------------------------------
--    @BranchScope: NULL = all, 0 = company-wide only, >0 = that branch only
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_GetList
    @Status      BIT           = NULL,
    @BranchScope INT           = NULL,
    @Search      NVARCHAR(100) = NULL,
    @CompanyId   INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Condition_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName   AS Branch_Name,
        b.BranchCode   AS Branch_Code,
        c.Condition_Code,
        c.Condition_Text,
        c.Display_Order,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.LabReportingConditionMaster c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.Branch_ID
    WHERE c.IsDeleted = 0
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (@BranchScope IS NULL
           OR (@BranchScope = 0 AND c.Branch_ID IS NULL)
           OR (@BranchScope > 0 AND c.Branch_ID = @BranchScope))
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
           OR c.Condition_Text LIKE '%' + LTRIM(RTRIM(@Search)) + '%'
           OR c.Condition_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%'
           OR b.BranchName     LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY CASE WHEN c.Branch_ID IS NULL THEN 0 ELSE 1 END, b.BranchName, c.Display_Order ASC, c.Condition_ID ASC;
END
GO

-- 4. GetById --------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_GetById
    @Condition_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.Condition_ID, c.CompanyId, c.Branch_ID,
        b.BranchName AS Branch_Name, b.BranchCode AS Branch_Code,
        c.Condition_Code, c.Condition_Text, c.Display_Order, c.Status,
        c.CreatedBy, c.CreatedDate, c.ModifiedBy, c.ModifiedDate
    FROM dbo.LabReportingConditionMaster c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.Branch_ID
    WHERE c.Condition_ID = @Condition_ID AND c.IsDeleted = 0;
END
GO

-- 5. Create ---------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_Create
    @Condition_Text NVARCHAR(1000),
    @Branch_ID      INT = NULL,          -- NULL / 0 = company-wide
    @Display_Order  INT = 1,
    @CompanyId      INT = 1,
    @UserId         INT = NULL,
    @NewId          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Condition_Text IS NULL OR LTRIM(RTRIM(@Condition_Text)) = ''
    BEGIN RAISERROR('Condition text is required.', 16, 1); RETURN; END

    SET @Condition_Text = LTRIM(RTRIM(@Condition_Text));

    IF LEN(@Condition_Text) > 1000
    BEGIN RAISERROR('Condition text cannot exceed 1000 characters.', 16, 1); RETURN; END

    IF @Branch_ID IS NOT NULL AND @Branch_ID <= 0 SET @Branch_ID = NULL;

    IF @Branch_ID IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @Branch_ID AND CompanyId = @CompanyId AND IsActive = 1)
    BEGIN RAISERROR('Selected branch is invalid, inactive, or does not belong to this company.', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM dbo.LabReportingConditionMaster
               WHERE CompanyId = @CompanyId AND ISNULL(Branch_ID, 0) = ISNULL(@Branch_ID, 0)
                 AND LOWER(Condition_Text) = LOWER(@Condition_Text) AND IsDeleted = 0)
    BEGIN RAISERROR('An identical Condition of Reporting already exists for this company / branch.', 16, 1); RETURN; END

    BEGIN TRANSACTION;

    INSERT INTO dbo.LabReportingConditionMaster (CompanyId, Branch_ID, Condition_Text, Display_Order, Status, CreatedBy, CreatedDate)
    VALUES (@CompanyId, @Branch_ID, @Condition_Text, ISNULL(@Display_Order, 1), 1, @UserId, GETDATE());

    SET @NewId = SCOPE_IDENTITY();

    UPDATE dbo.LabReportingConditionMaster
    SET Condition_Code = 'LCOR' + RIGHT('0000' + CAST(@NewId AS NVARCHAR(10)), 4)
    WHERE Condition_ID = @NewId;

    COMMIT TRANSACTION;
END
GO

-- 6. Update ---------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_Update
    @Condition_ID   INT,
    @Condition_Text NVARCHAR(1000),
    @Branch_ID      INT = NULL,
    @Display_Order  INT = 1,
    @Status         BIT = 1,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CompanyId INT;
    SELECT @CompanyId = CompanyId FROM dbo.LabReportingConditionMaster WHERE Condition_ID = @Condition_ID AND IsDeleted = 0;

    IF @CompanyId IS NULL
    BEGIN RAISERROR('Condition of Reporting record not found.', 16, 1); RETURN; END

    IF @Condition_Text IS NULL OR LTRIM(RTRIM(@Condition_Text)) = ''
    BEGIN RAISERROR('Condition text is required.', 16, 1); RETURN; END

    SET @Condition_Text = LTRIM(RTRIM(@Condition_Text));

    IF LEN(@Condition_Text) > 1000
    BEGIN RAISERROR('Condition text cannot exceed 1000 characters.', 16, 1); RETURN; END

    IF @Branch_ID IS NOT NULL AND @Branch_ID <= 0 SET @Branch_ID = NULL;

    IF @Branch_ID IS NOT NULL AND NOT EXISTS
       (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @Branch_ID AND CompanyId = @CompanyId AND IsActive = 1)
    BEGIN RAISERROR('Selected branch is invalid, inactive, or does not belong to this company.', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM dbo.LabReportingConditionMaster
               WHERE CompanyId = @CompanyId AND ISNULL(Branch_ID, 0) = ISNULL(@Branch_ID, 0)
                 AND LOWER(Condition_Text) = LOWER(@Condition_Text)
                 AND Condition_ID <> @Condition_ID AND IsDeleted = 0)
    BEGIN RAISERROR('An identical Condition of Reporting already exists for this company / branch.', 16, 1); RETURN; END

    UPDATE dbo.LabReportingConditionMaster
    SET Condition_Text = @Condition_Text,
        Branch_ID      = @Branch_ID,
        Display_Order  = ISNULL(@Display_Order, 1),
        Status         = @Status,
        ModifiedBy     = @UserId,
        ModifiedDate   = GETDATE()
    WHERE Condition_ID = @Condition_ID;
END
GO

-- 7. ToggleStatus ---------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_ToggleStatus
    @Condition_ID INT,
    @Status       BIT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabReportingConditionMaster WHERE Condition_ID = @Condition_ID AND IsDeleted = 0)
    BEGIN RAISERROR('Condition of Reporting record not found.', 16, 1); RETURN; END

    UPDATE dbo.LabReportingConditionMaster
    SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Condition_ID = @Condition_ID;
END
GO

-- 8. Delete (soft) --------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_Delete
    @Condition_ID INT,
    @UserId       INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.LabReportingConditionMaster WHERE Condition_ID = @Condition_ID AND IsDeleted = 0)
    BEGIN RAISERROR('Condition of Reporting record not found or already deleted.', 16, 1); RETURN; END

    UPDATE dbo.LabReportingConditionMaster
    SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Condition_ID = @Condition_ID;
END
GO

-- 9. GetForReport ---------------------------------------------------------------------------------------
--    RS1: the active conditions to print, in order (branch-specific if the branch has any, else company-wide)
--    RS2: HasConfiguration - whether this company has ever configured conditions (so "all switched off" can
--         be told apart from "never configured", where the report falls back to its built-in text)
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReportingConditionMaster_GetForReport
    @CompanyId INT,
    @BranchId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseBranch BIT = 0;
    IF @BranchId IS NOT NULL AND EXISTS
       (SELECT 1 FROM dbo.LabReportingConditionMaster
        WHERE CompanyId = @CompanyId AND Branch_ID = @BranchId AND Status = 1 AND IsDeleted = 0)
        SET @UseBranch = 1;

    SELECT Condition_Text
    FROM dbo.LabReportingConditionMaster
    WHERE CompanyId = @CompanyId AND Status = 1 AND IsDeleted = 0
      AND ((@UseBranch = 1 AND Branch_ID = @BranchId) OR (@UseBranch = 0 AND Branch_ID IS NULL))
    ORDER BY Display_Order ASC, Condition_ID ASC;

    SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.LabReportingConditionMaster
                                  WHERE CompanyId = @CompanyId AND IsDeleted = 0) THEN 1 ELSE 0 END AS BIT) AS HasConfiguration;
END
GO

PRINT 'Created SQL objects for Lab Reporting Condition Master.';
GO
