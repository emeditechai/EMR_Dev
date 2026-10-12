-- ====================================================================================================
-- Script: 2259_lab_report_dispatch_created_by.sql
-- Lab Report Dispatch for a franchise login: the bills that login created, or that are for its own franchise (as 2258).
-- dbo.usp_LabReportDispatch_GetDashboard gets an optional @CreatedBy (NULL = every bill, as before), applied where
-- the bills are chosen, so the cards and the list both follow it. The web passes it only for a Franchise login.
-- Patches the live procedure in place (its other logic untouched). Safe to re-run. Run after 2258.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_LabReportDispatch_GetDashboard'));
IF @def IS NULL THROW 55110, 'usp_LabReportDispatch_GetDashboard not found.', 1;
DECLARE @oldFilter NVARCHAR(400) = N'AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)';
DECLARE @newFilter NVARCHAR(600) = N'AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = ''F'' AND lo.B2BAgentID = (SELECT u.ReferenceUserID FROM dbo.Users u WHERE u.Id = @CreatedBy AND u.User_Type = ''F'')))';
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    -- fresh: add the parameter and the filter
    DECLARE @param NVARCHAR(200) = N'    @ClientType     VARCHAR(10)   = ''ALL''
AS';
    DECLARE @filter NVARCHAR(300) = N'AND (@ClientType = ''ALL'' OR (@ClientType = ''B2B'' AND lo.IsB2B = 1) OR (@ClientType = ''B2C'' AND ISNULL(lo.IsB2B, 0) = 0))';
    IF CHARINDEX(@param, @def) = 0 THROW 55111, 'usp_LabReportDispatch_GetDashboard: parameter anchor not found; not changed.', 1;
    IF CHARINDEX(@filter, @def) = 0 THROW 55112, 'usp_LabReportDispatch_GetDashboard: filter anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@param, @def), LEN(@param), N'    @ClientType     VARCHAR(10)   = ''ALL'',
    -- 2259: a franchise login''s bills - created by this user, or for the franchise this user belongs to; NULL = every bill
    @CreatedBy      INT           = NULL
AS');
    SET @def = REPLACE(@def, @filter, @filter + N'
      ' + @newFilter);
END
ELSE IF CHARINDEX(@oldFilter, @def) > 0
    -- patched by the first version of this script (created by only): widen to "or for the login's franchise"
    SET @def = REPLACE(@def, @oldFilter, @newFilter);
ELSE
    SET @def = NULL;   -- already up to date
IF @def IS NOT NULL
BEGIN
    -- "PROCEDURE" is looked for after the CREATE (a header comment may say "Stored Procedure" earlier)
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def, PATINDEX(N'%CREATE%PROCEDURE%', @def)) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55198, 'The procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2259 applied: Lab Report Dispatch - a franchise login sees the bills it created or that are for its franchise.';
GO
