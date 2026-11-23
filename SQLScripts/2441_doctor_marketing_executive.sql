-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2441  Doctor Master: Marketing Executive (Master > General > Marketing Executive, SQLScripts/2440)
--   DoctorMaster.MarketingExecutiveId (optional). usp_Api_Doctor_Create / _Update take @MarketingExecutiveId (default NULL,
--   so existing callers are unchanged): it must be an active executive of the company - an executive already on the doctor
--   may stay when deactivated later. usp_Api_Doctor_GetById returns the id and the executive's name / code / type.
--   The Doctor Master screen (EMR.Web) saves the executive with usp_Api_Doctor_SetMarketingExecutive after the doctor, and
--   reads it with usp_Api_Doctor_GetMarketingExecutive (EMR.Api api/marketing-executives/doctor/{id}).
--   Needs 2440. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.DoctorMaster', 'MarketingExecutiveId') IS NULL
BEGIN
    ALTER TABLE dbo.DoctorMaster ADD MarketingExecutiveId INT NULL
        CONSTRAINT FK_DoctorMaster_MarketingExecutive REFERENCES dbo.MarketingExecutive (ExecutiveId);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DoctorMaster_MarketingExecutive')
    CREATE INDEX IX_DoctorMaster_MarketingExecutive ON dbo.DoctorMaster (MarketingExecutiveId) WHERE MarketingExecutiveId IS NOT NULL;
GO

DECLARE @def NVARCHAR(MAX), @check NVARCHAR(MAX);
-- create
SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_Doctor_Create'));
IF @def NOT LIKE '%MarketingExecutiveId%'
BEGIN
    IF @def NOT LIKE '%@UserId INT = NULL%' OR @def NOT LIKE '%JoiningDate, IsActive, CreatedBranchId, CreatedBy, CreatedDate)%'
       OR @def NOT LIKE '%@JoiningDate, @IsActive, @CreatedBranchId, @UserId, GETDATE());%' OR @def NOT LIKE '%    INSERT INTO DoctorMaster%'
        THROW 51410, 'usp_Api_Doctor_Create has changed: add the marketing executive by hand.', 1;
    SET @def = STUFF(@def, CHARINDEX('@UserId INT = NULL', @def), LEN('@UserId INT = NULL'), '@UserId INT = NULL,
    @MarketingExecutiveId INT = NULL   -- SQLScripts/2441');
    SET @check = N'    -- the marketing executive (SQLScripts/2441): an active one of the company
    SET @MarketingExecutiveId = NULLIF(@MarketingExecutiveId, 0);
    IF @MarketingExecutiveId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.MarketingExecutive WHERE ExecutiveId = @MarketingExecutiveId AND IsActive = 1 AND IsDeleted = 0
                                                          AND CompanyId = ISNULL(NULLIF(@CompanyId, 0), (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @CreatedBranchId)))
    BEGIN RAISERROR(''Choose an active marketing executive.'', 16, 1); RETURN; END

';
    SET @def = STUFF(@def, CHARINDEX('    INSERT INTO DoctorMaster', @def), 0, @check);
    SET @def = REPLACE(@def, 'JoiningDate, IsActive, CreatedBranchId, CreatedBy, CreatedDate)', 'JoiningDate, IsActive, CreatedBranchId, CreatedBy, CreatedDate, MarketingExecutiveId)');
    SET @def = REPLACE(@def, '@JoiningDate, @IsActive, @CreatedBranchId, @UserId, GETDATE());', '@JoiningDate, @IsActive, @CreatedBranchId, @UserId, GETDATE(), @MarketingExecutiveId);');
    SET @def = REPLACE(REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE'), 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
-- update
SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_Doctor_Update'));
IF @def NOT LIKE '%MarketingExecutiveId%'
BEGIN
    IF @def NOT LIKE '%@UserId INT = NULL%' OR @def NOT LIKE '%        ModifiedBy = @UserId,%' OR @def NOT LIKE '%    UPDATE DoctorMaster SET%'
        THROW 51411, 'usp_Api_Doctor_Update has changed: add the marketing executive by hand.', 1;
    SET @def = STUFF(@def, CHARINDEX('@UserId INT = NULL', @def), LEN('@UserId INT = NULL'), '@UserId INT = NULL,
    @MarketingExecutiveId INT = NULL   -- SQLScripts/2441');
    SET @check = N'    -- the marketing executive (SQLScripts/2441): an active one of the company; the one already on the doctor may stay
    SET @MarketingExecutiveId = NULLIF(@MarketingExecutiveId, 0);
    IF @MarketingExecutiveId IS NOT NULL
       AND @MarketingExecutiveId <> ISNULL((SELECT MarketingExecutiveId FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId), 0)
       AND NOT EXISTS (SELECT 1 FROM dbo.MarketingExecutive me JOIN dbo.DoctorMaster d ON d.DoctorId = @DoctorId AND d.CompanyId = me.CompanyId
                       WHERE me.ExecutiveId = @MarketingExecutiveId AND me.IsActive = 1 AND me.IsDeleted = 0)
    BEGIN RAISERROR(''Choose an active marketing executive.'', 16, 1); RETURN; END

';
    SET @def = STUFF(@def, CHARINDEX('    UPDATE DoctorMaster SET', @def), 0, @check);
    SET @def = REPLACE(@def, '        ModifiedBy = @UserId,', '        MarketingExecutiveId = @MarketingExecutiveId,
        ModifiedBy = @UserId,');
    SET @def = REPLACE(REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE'), 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
-- get by id
SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_Doctor_GetById'));
IF @def NOT LIKE '%MarketingExecutiveId%'
BEGIN
    IF @def NOT LIKE '%        d.ModifiedDate
    FROM DoctorMaster d%' THROW 51412, 'usp_Api_Doctor_GetById has changed: add the marketing executive by hand.', 1;
    SET @def = REPLACE(@def, '        d.ModifiedDate
    FROM DoctorMaster d', '        d.ModifiedDate,
        d.MarketingExecutiveId, me.ExecutiveName AS MarketingExecutiveName, me.ExecutiveCode AS MarketingExecutiveCode,
        me.ExecutiveType AS MarketingExecutiveType, CAST(ISNULL(me.IsActive, 0) AS BIT) AS MarketingExecutiveActive
    FROM DoctorMaster d
    LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = d.MarketingExecutiveId');
    SET @def = REPLACE(REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE'), 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO
-- ── the Doctor Master screen: read / set a doctor's executive ─────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_GetMarketingExecutive @CompanyId INT, @DoctorId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DoctorId, d.MarketingExecutiveId, me.ExecutiveName AS MarketingExecutiveName, me.ExecutiveCode AS MarketingExecutiveCode,
           me.ExecutiveType AS MarketingExecutiveType, me.PhoneNumber AS MarketingExecutivePhone, CAST(ISNULL(me.IsActive, 0) AS BIT) AS MarketingExecutiveActive
    FROM dbo.DoctorMaster d LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = d.MarketingExecutiveId AND me.IsDeleted = 0
    WHERE d.DoctorId = @DoctorId AND d.CompanyId = @CompanyId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Doctor_SetMarketingExecutive @CompanyId INT, @UserId INT, @DoctorId INT, @ExecutiveId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ExecutiveId = NULLIF(@ExecutiveId, 0);
    DECLARE @current INT, @found BIT = 0;
    SELECT @current = MarketingExecutiveId, @found = 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId;
    IF @found = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, CAST(N'The doctor was not found.' AS NVARCHAR(400)) AS Error; RETURN; END
    -- an active executive of the company; the one already on the doctor may stay when deactivated later
    IF @ExecutiveId IS NOT NULL AND @ExecutiveId <> ISNULL(@current, 0)
       AND NOT EXISTS (SELECT 1 FROM dbo.MarketingExecutive WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsActive = 1 AND IsDeleted = 0)
    BEGIN SELECT CAST(0 AS BIT) AS Success, CAST(N'Choose an active marketing executive.' AS NVARCHAR(400)) AS Error; RETURN; END
    IF ISNULL(@current, 0) <> ISNULL(@ExecutiveId, 0)
        UPDATE dbo.DoctorMaster SET MarketingExecutiveId = @ExecutiveId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE DoctorId = @DoctorId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @DoctorId AS DoctorId, @ExecutiveId AS ExecutiveId;
END;
GO
-- an executive still assigned to doctors is not deleted (deactivate instead): replaces 2440's delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_MarketingExecutive_Delete @CompanyId INT, @UserId INT, @ExecutiveId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT = (SELECT COUNT(*) FROM dbo.DoctorMaster WHERE MarketingExecutiveId = @ExecutiveId AND CompanyId = @CompanyId);
    IF @n > 0
    BEGIN
        SELECT CAST(0 AS BIT) AS Success,
               CAST(CONCAT(N'This marketing executive is assigned to ', @n, N' doctor(s). Change them in Doctor Master first, or deactivate the executive instead.') AS NVARCHAR(400)) AS Error;
        RETURN;
    END
    UPDATE dbo.MarketingExecutive SET IsDeleted = 1, IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE ExecutiveId = @ExecutiveId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, CAST(N'The marketing executive was not found.' AS NVARCHAR(400)) AS Error;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(400)) AS Error, @ExecutiveId AS ExecutiveId;
END;
GO
-- the Doctor Master list shows the executive (name + type) under the doctor, and its search finds the executive's name
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_Doctor_GetPagedList'));
IF @def NOT LIKE '%MarketingExecutiveName%'
BEGIN
    IF @def NOT LIKE '%        d.IsReferralDoctor,
        ISNULL(fees.ConsultingFeeNames%'
       OR @def NOT LIKE '%    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId%'
       OR @def NOT LIKE '%    SELECT DoctorId, FullName, PrimarySpecialityName, DepartmentNames, PhoneNumber, EmailId, IsActive, IsReferralDoctor,
           ConsultingFeeNames, HasOPDDept%'
       OR @def NOT LIKE '%OR x.DepartmentNames LIKE N''%%'' + @Search + N''%%'')%'
        THROW 51413, 'usp_Api_Doctor_GetPagedList has changed: add the marketing executive by hand.', 1;
    SET @def = REPLACE(@def, '        d.IsReferralDoctor,
        ISNULL(fees.ConsultingFeeNames', '        d.IsReferralDoctor,
        me.ExecutiveName AS MarketingExecutiveName, me.ExecutiveType AS MarketingExecutiveType,
        ISNULL(fees.ConsultingFeeNames');
    SET @def = STUFF(@def, CHARINDEX('    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId', @def)
                     + LEN('    INNER JOIN DoctorSpecialityMaster ps ON ps.SpecialityId = d.PrimarySpecialityId'), 0, '
    LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = d.MarketingExecutiveId AND me.IsDeleted = 0');
    SET @def = REPLACE(@def, '    SELECT DoctorId, FullName, PrimarySpecialityName, DepartmentNames, PhoneNumber, EmailId, IsActive, IsReferralDoctor,
           ConsultingFeeNames, HasOPDDept', '    SELECT DoctorId, FullName, PrimarySpecialityName, DepartmentNames, PhoneNumber, EmailId, IsActive, IsReferralDoctor,
           ConsultingFeeNames, HasOPDDept, MarketingExecutiveName, MarketingExecutiveType');
    SET @def = REPLACE(@def, 'OR x.DepartmentNames LIKE N''%'' + @Search + N''%'')', 'OR x.DepartmentNames LIKE N''%'' + @Search + N''%''
           OR ISNULL(x.MarketingExecutiveName, N'''') LIKE N''%'' + @Search + N''%'')');
    SET @def = REPLACE(REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE'), 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO
PRINT '2441 Doctor marketing executive - done.';
GO
