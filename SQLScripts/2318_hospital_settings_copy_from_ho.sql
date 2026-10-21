-- ============================================================================================================
-- Migration: 2318_hospital_settings_copy_from_ho.sql
-- Settings > Hospital Settings: "Copy from Head Office" on a branch that is not the head office. Every setting of the
-- head office's Hospital Settings (same company, Branchmaster.IsHOBranch = 1) is copied onto the branch - hospital
-- details, logo, NABH, contacts and every OPD / IPD / LAB / MED parameter. The column list is read from the table, so
-- settings added later are copied too. Not copied: the row's own keys (Id, BranchID, CompanyId), its created / modified
-- stamps, IsActive, and DayClosingStartDate (when the branch's own cash day closing began). A branch without settings
-- gets a new row. The branch's previous values are returned (JSON) for the audit log. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_HospitalSettings_CopyFromHO
    @TargetBranchId INT,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @company INT, @isHo BIT;
    SELECT @company = CompanyId, @isHo = ISNULL(IsHOBranch, 0) FROM dbo.Branchmaster WHERE BranchID = @TargetBranchId;
    IF @company IS NULL THROW 51101, 'Branch not found.', 1;
    IF @isHo = 1 THROW 51102, 'This is the head office - its settings are the source, there is nothing to copy.', 1;

    DECLARE @hoBranch INT = (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE CompanyId = @company AND IsHOBranch = 1 ORDER BY BranchID);
    IF @hoBranch IS NULL THROW 51103, 'No head office branch is set for this company.', 1;
    DECLARE @src INT = (SELECT TOP 1 Id FROM dbo.HospitalSettings WHERE BranchID = @hoBranch ORDER BY IsActive DESC, Id DESC);
    IF @src IS NULL THROW 51104, 'The head office has no Hospital Settings yet - set them up there first.', 1;

    -- every column except the row's own keys / stamps / state and the branch's day-closing start
    DECLARE @cols NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(QUOTENAME(c.name) AS NVARCHAR(MAX)), ', ')
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.HospitalSettings') AND c.is_identity = 0 AND c.is_computed = 0
          AND c.name NOT IN (N'Id', N'BranchID', N'BranchId', N'CompanyId', N'CreatedDate', N'CreatedBy', N'LastModifiedDate',
                             N'LastModifiedBy', N'IsActive', N'DayClosingStartDate'));
    DECLARE @set NVARCHAR(MAX) = (
        SELECT STRING_AGG(CAST(N't.' + QUOTENAME(c.name) + N' = s.' + QUOTENAME(c.name) AS NVARCHAR(MAX)), N', ')
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.HospitalSettings') AND c.is_identity = 0 AND c.is_computed = 0
          AND c.name NOT IN (N'Id', N'BranchID', N'BranchId', N'CompanyId', N'CreatedDate', N'CreatedBy', N'LastModifiedDate',
                             N'LastModifiedBy', N'IsActive', N'DayClosingStartDate'));

    DECLARE @target INT = (SELECT TOP 1 Id FROM dbo.HospitalSettings WHERE BranchID = @TargetBranchId ORDER BY IsActive DESC, Id DESC);
    DECLARE @before NVARCHAR(MAX) = (SELECT * FROM dbo.HospitalSettings WHERE Id = @target FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
    DECLARE @sql NVARCHAR(MAX), @copied INT;

    BEGIN TRANSACTION;
    IF @target IS NULL
    BEGIN
        SET @sql = N'INSERT INTO dbo.HospitalSettings (BranchID, CompanyId, IsActive, CreatedDate, CreatedBy, ' + @cols + N')
                     SELECT @TargetBranchId, @company, 1, GETDATE(), @UserId, ' + @cols + N' FROM dbo.HospitalSettings WHERE Id = @src;
                     SET @copied = SCOPE_IDENTITY();';
        EXEC sp_executesql @sql, N'@TargetBranchId INT, @company INT, @UserId INT, @src INT, @copied INT OUTPUT',
             @TargetBranchId, @company, @UserId, @src, @copied OUTPUT;
        SET @target = @copied;
    END
    ELSE
    BEGIN
        SET @sql = N'UPDATE t SET ' + @set + N', t.LastModifiedDate = GETDATE(), t.LastModifiedBy = @UserId
                     FROM dbo.HospitalSettings t CROSS JOIN dbo.HospitalSettings s
                     WHERE t.Id = @target AND s.Id = @src;';
        EXEC sp_executesql @sql, N'@target INT, @src INT, @UserId INT', @target, @src, @UserId;
    END
    COMMIT TRANSACTION;

    SELECT @target AS SettingsId, @hoBranch AS SourceBranchId,
           (SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @hoBranch) AS SourceBranchName,
           (SELECT COUNT(*) FROM STRING_SPLIT(@cols, ',')) AS ColumnsCopied,
           @before AS PreviousValuesJson;
END
GO

-- endpoints: Web HospitalSettings/CopyFromHeadOffice and EMR.Api HospitalSettingsCopy/Copy, under the page's EDIT control
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.HOSPITALSETTINGS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = (SELECT TOP 1 Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'EDIT');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'HospitalSettings', @Action = N'CopyFromHeadOffice', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'API', @Http_Method = 'POST', @Controller = N'HospitalSettingsCopy', @Action = N'Copy', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2318 applied: Hospital Settings - Copy from Head Office.';
GO
