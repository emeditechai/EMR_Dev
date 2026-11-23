-- ============================================================================================================
-- Migration: 2264_sample_transfer_franchise_scope.sql
-- Sample Transfer (Dispatch / Receive worklists, Transfer history, print worksheet) for a franchise login:
-- only the samples of the bills it created, or that are for its own franchise (as 2258-2261). Every other login:
-- unchanged (@CreatedBy NULL). Each procedure gets an optional @CreatedBy (the login's user id, passed by the web
-- only for a Franchise login); the row queries filter their LabOrder join, the summary counts check the bill too.
-- Patches the live procedures in place (their other logic untouched). Safe to re-run. Run after 2263.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- usp_SampleTransfer_GetEligibleSamples
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_SampleTransfer_GetEligibleSamples'));
IF @def IS NULL THROW 55150, 'usp_SampleTransfer_GetEligibleSamples not found.', 1;
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    DECLARE @p NVARCHAR(400) = N'    @SubCategoryId         INT           = NULL
AS
';
    DECLARE @j NVARCHAR(400) = N'JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid AND lo.IsActive = 1';
    IF CHARINDEX(@p, @def) = 0 OR CHARINDEX(@j, @def) = 0 THROW 55151, 'usp_SampleTransfer_GetEligibleSamples: an anchor was not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@p, @def), LEN(@p), N'    @SubCategoryId         INT           = NULL,
    -- 2264: a franchise login (its user id): only the samples of the bills it created or that are for its franchise; NULL = all
    @CreatedBy INT = NULL
AS
');
    SET @def = STUFF(@def, CHARINDEX(@j, @def), LEN(@j), @j + N' AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = ''F'' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))');
    DECLARE @s NVARCHAR(400) = N'AND (@SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId);';   -- end of the summary counts
    IF CHARINDEX(@s, @def) = 0 THROW 55152, 'usp_SampleTransfer_GetEligibleSamples: summary anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@s, @def), LEN(@s), N'AND (@SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId)' + N'
      AND (@CreatedBy IS NULL OR EXISTS (SELECT 1 FROM dbo.LabOrder fo WHERE fo.LabOrderId = sc.Laborderid
           AND (fo.CreatedBy = @CreatedBy OR (fo.AgentType = ''F'' AND fo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))));');
    -- CREATE ... PROCEDURE -> CREATE OR ALTER PROCEDURE: "PROCEDURE" is looked for after the CREATE (a header
    -- comment may say "Stored Procedure" earlier), and an empty result stops the script instead of doing nothing
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55199, 'Script 2264: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

-- usp_SampleTransfer_GetReceivableSamples
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_SampleTransfer_GetReceivableSamples'));
IF @def IS NULL THROW 55155, 'usp_SampleTransfer_GetReceivableSamples not found.', 1;
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    DECLARE @p NVARCHAR(400) = N'    @SubCategoryId         INT           = NULL
AS
';
    DECLARE @j NVARCHAR(400) = N'JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid AND lo.IsActive = 1';
    IF CHARINDEX(@p, @def) = 0 OR CHARINDEX(@j, @def) = 0 THROW 55156, 'usp_SampleTransfer_GetReceivableSamples: an anchor was not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@p, @def), LEN(@p), N'    @SubCategoryId         INT           = NULL,
    -- 2264: a franchise login (its user id): only the samples of the bills it created or that are for its franchise; NULL = all
    @CreatedBy INT = NULL
AS
');
    SET @def = STUFF(@def, CHARINDEX(@j, @def), LEN(@j), @j + N' AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = ''F'' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))');
    DECLARE @s NVARCHAR(400) = N'AND (@SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId);';   -- end of the summary counts
    IF CHARINDEX(@s, @def) = 0 THROW 55157, 'usp_SampleTransfer_GetReceivableSamples: summary anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@s, @def), LEN(@s), N'AND (@SubCategoryId IS NULL OR sc.TestsubcategoryID = @SubCategoryId OR lim.SubCategory_ID = @SubCategoryId)' + N'
      AND (@CreatedBy IS NULL OR EXISTS (SELECT 1 FROM dbo.LabOrder fo WHERE fo.LabOrderId = sc.Laborderid
           AND (fo.CreatedBy = @CreatedBy OR (fo.AgentType = ''F'' AND fo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))));');
    -- CREATE ... PROCEDURE -> CREATE OR ALTER PROCEDURE: "PROCEDURE" is looked for after the CREATE (a header
    -- comment may say "Stored Procedure" earlier), and an empty result stops the script instead of doing nothing
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55199, 'Script 2264: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

-- usp_SampleTransfer_GetHistory
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_SampleTransfer_GetHistory'));
IF @def IS NULL THROW 55160, 'usp_SampleTransfer_GetHistory not found.', 1;
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    DECLARE @p NVARCHAR(400) = N'    @Search       NVARCHAR(100) = NULL
AS
';
    DECLARE @j NVARCHAR(400) = N'JOIN dbo.LabOrder lo ON lo.LabOrderId = sta.LabOrderId';
    IF CHARINDEX(@p, @def) = 0 OR CHARINDEX(@j, @def) = 0 THROW 55161, 'usp_SampleTransfer_GetHistory: an anchor was not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@p, @def), LEN(@p), N'    @Search       NVARCHAR(100) = NULL,
    -- 2264: a franchise login (its user id): only the samples of the bills it created or that are for its franchise; NULL = all
    @CreatedBy INT = NULL
AS
');
    SET @def = STUFF(@def, CHARINDEX(@j, @def), LEN(@j), @j + N' AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = ''F'' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))');
    -- CREATE ... PROCEDURE -> CREATE OR ALTER PROCEDURE: "PROCEDURE" is looked for after the CREATE (a header
    -- comment may say "Stored Procedure" earlier), and an empty result stops the script instead of doing nothing
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55199, 'Script 2264: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

-- usp_SampleTransfer_GetWorksheetData
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_SampleTransfer_GetWorksheetData'));
IF @def IS NULL THROW 55165, 'usp_SampleTransfer_GetWorksheetData not found.', 1;
IF CHARINDEX(N'@CreatedBy', @def) = 0
BEGIN
    DECLARE @p NVARCHAR(400) = N'    @SampleCollectionIds NVARCHAR(MAX)
)
AS';
    DECLARE @j NVARCHAR(400) = N'JOIN dbo.LabOrder lo ON sc.Laborderid = lo.LabOrderId';
    IF CHARINDEX(@p, @def) = 0 OR CHARINDEX(@j, @def) = 0 THROW 55166, 'usp_SampleTransfer_GetWorksheetData: an anchor was not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@p, @def), LEN(@p), N'    @SampleCollectionIds NVARCHAR(MAX),
    -- 2264: a franchise login (its user id): only the samples of the bills it created or that are for its franchise; NULL = all
    @CreatedBy INT = NULL
)
AS');
    SET @def = STUFF(@def, CHARINDEX(@j, @def), LEN(@j), @j + N' AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy OR (lo.AgentType = ''F'' AND lo.B2BAgentID = (SELECT fu.ReferenceUserID FROM dbo.Users fu WHERE fu.Id = @CreatedBy AND fu.User_Type = ''F'')))');
    -- CREATE ... PROCEDURE -> CREATE OR ALTER PROCEDURE: "PROCEDURE" is looked for after the CREATE (a header
    -- comment may say "Stored Procedure" earlier), and an empty result stops the script instead of doing nothing
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55199, 'Script 2264: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2264 applied: Sample Transfer - a franchise login sees only its own franchise''s samples.';
GO
