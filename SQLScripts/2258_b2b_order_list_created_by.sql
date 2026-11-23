-- ====================================================================================================
-- Script: 2258_b2b_order_list_created_by.sql
-- B2B Registration & Order List for a franchise login: the bills that login created, or that are for its own franchise
-- (e.g. booked by the lab for it) - the franchise is Users.ReferenceUserID of a User_Type 'F' login.
-- dbo.usp_LabOrder_GetPagedList gets an optional @CreatedBy (NULL = everyone's bills, as before) applied to the
-- stats, the count and the rows. The web passes it only for a Franchise login; every other caller is unchanged.
-- Patches the live procedure in place (its other logic untouched). Safe to re-run. Run after 2257.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_LabOrder_GetPagedList'));
IF @def IS NULL THROW 55100, 'usp_LabOrder_GetPagedList not found.', 1;
DECLARE @oldFilter NVARCHAR(400) = N'AND (@CreatedBy IS NULL OR o.CreatedBy = @CreatedBy)';
DECLARE @newFilter NVARCHAR(600) = N'AND (@CreatedBy IS NULL OR o.CreatedBy = @CreatedBy OR (o.AgentType = ''F'' AND o.B2BAgentID = (SELECT u.ReferenceUserID FROM dbo.Users u WHERE u.Id = @CreatedBy AND u.User_Type = ''F'')))';
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    -- fresh: add the parameter and the filter
    DECLARE @param NVARCHAR(200) = N'    @AgentId INT = NULL
AS';
    DECLARE @filter NVARCHAR(300) = N'AND (@AgentId IS NULL OR o.B2BAgentID = @AgentId)';
    IF CHARINDEX(@param, @def) = 0 THROW 55101, 'usp_LabOrder_GetPagedList: parameter anchor not found; not changed.', 1;
    IF CHARINDEX(@filter, @def) = 0 THROW 55102, 'usp_LabOrder_GetPagedList: filter anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@param, @def), LEN(@param), N'    @AgentId INT = NULL,
    -- 2258: a franchise login''s bills - created by this user, or for the franchise this user belongs to; NULL = everyone''s
    @CreatedBy INT = NULL
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

PRINT 'Script 2258 applied: B2B order list - a franchise login sees the bills it created or that are for its franchise.';
GO
