-- ============================================================================================================
-- Migration: 2266_sample_collection_franchise_scope.sql
-- Sample Collection for a franchise login: only the orders it created, or that are for its own franchise (as the
-- other franchise screens, 2258-2264). dbo.usp_SampleCollection_GetHeaderList gets an optional @CreatedBy (the
-- login's user id, passed by the web only for a Franchise login); the list and its counters both follow it.
-- Every other login: unchanged. Patches the live procedure in place. Safe to re-run. Run after 2265.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_SampleCollection_GetHeaderList'));
IF @def IS NULL THROW 55210, 'usp_SampleCollection_GetHeaderList not found.', 1;
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    DECLARE @p NVARCHAR(400) = N'    @Search          NVARCHAR(100) = NULL
AS
';
    DECLARE @j NVARCHAR(400) = N'INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = agg.Laborderid AND lo.IsActive = 1';
    IF CHARINDEX(@p, @def) = 0 OR CHARINDEX(@j, @def) = 0 THROW 55211, 'usp_SampleCollection_GetHeaderList: an anchor was not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@p, @def), LEN(@p), N'    @Search          NVARCHAR(100) = NULL,
    -- 2266: a franchise login (its user id): only the orders it created or that are for its franchise; NULL = all
    @CreatedBy       INT           = NULL
AS
');
    SET @def = STUFF(@def, CHARINDEX(@j, @def), LEN(@j), @j + N' AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = ''F'' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))');
    -- "PROCEDURE" is looked for after the CREATE (a header comment may say "Stored Procedure" earlier)
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55212, 'usp_SampleCollection_GetHeaderList: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2266 applied: Sample Collection - a franchise login sees only its own franchise''s orders.';
GO
