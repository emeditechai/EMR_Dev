-- ============================================================================
-- Migration: 2164_authorization_decision_log.sql
-- Description:
--   Server-Side Authorization - Phase 2/3 support.
--
--   AuthorizationDecisionLog  every request the decision point refused - or, in
--                             audit mode, WOULD have refused - with the page, the
--                             control and the scope that decided it. In audit mode
--                             this log drives the mapping work: each row is either a
--                             missing page mapping (UNMAPPED) or a missing grant (DENIED).
--   PageEndpointMap.Is_Public endpoints marked [PublicEndpoint]/[AllowAnonymous] need no
--                             page; they are excluded from the unmapped count.
--
--   usp_Auth_PageEndpointMap_RegisterDiscoveredBulk  the endpoint scanner's single call:
--                             every action it finds, as JSON, in one round trip.
--   usp_Auth_DecisionLog_InsertBulk                   batched writes from the app.
--   usp_Auth_DecisionLog_Summary                      what audit mode has seen, grouped.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Is_Public')
    ALTER TABLE dbo.PageEndpointMap ADD Is_Public BIT NOT NULL CONSTRAINT DF_PageEndpointMap_Is_Public DEFAULT 0;
GO

IF OBJECT_ID(N'dbo.AuthorizationDecisionLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AuthorizationDecisionLog
    (
        Log_ID           BIGINT IDENTITY(1,1) PRIMARY KEY,
        Logged_On        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
        App              VARCHAR(10) NOT NULL,        -- WEB | API
        Mode             VARCHAR(10) NOT NULL,        -- AUDIT (not blocked) | ENFORCE (blocked)
        Outcome          VARCHAR(10) NOT NULL,        -- DENIED | UNMAPPED | INACTIVE
        User_ID          INT NULL,
        Branch_ID        INT NULL,
        Role_ID          INT NULL,
        Http_Method      VARCHAR(10) NOT NULL,
        Controller       NVARCHAR(150) NOT NULL,
        Action           NVARCHAR(150) NOT NULL,
        Path             NVARCHAR(400) NULL,
        Page_Code        NVARCHAR(150) NULL,
        Control_Code     VARCHAR(30) NULL,
        Decided_At_Scope INT NULL,
        Decided_By       VARCHAR(10) NULL
    );
    CREATE INDEX IX_AuthorizationDecisionLog_On ON dbo.AuthorizationDecisionLog(Logged_On DESC);
    CREATE INDEX IX_AuthorizationDecisionLog_Endpoint ON dbo.AuthorizationDecisionLog(Controller, Action, Outcome);
    PRINT 'Created dbo.AuthorizationDecisionLog';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageEndpointMap_RegisterDiscoveredBulk
    @App       VARCHAR(10),
    @Json      NVARCHAR(MAX)   -- [{"m":"GET","c":"LabReporting","a":"Index","r":"LabReporting/Index","p":0}, ...]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ScanStart DATETIME2 = SYSDATETIME();

    SELECT DISTINCT
        CAST(j.m AS VARCHAR(10))    AS Http_Method,
        CAST(j.c AS NVARCHAR(150))  AS Controller,
        CAST(j.a AS NVARCHAR(150))  AS Action,
        CAST(j.r AS NVARCHAR(300))  AS Route,
        CAST(ISNULL(j.p, 0) AS BIT) AS Is_Public
    INTO #Found
    FROM OPENJSON(@Json) WITH (m VARCHAR(10), c NVARCHAR(150), a NVARCHAR(150), r NVARCHAR(300), p BIT) j;

    BEGIN TRANSACTION;

    -- Seen again: refresh, un-orphan, keep every mapping as it is.
    UPDATE e SET e.Last_Seen_On = @ScanStart, e.Is_Orphaned = 0, e.Is_Public = f.Is_Public,
                 e.Route = ISNULL(e.Route, f.Route)
    FROM dbo.PageEndpointMap e
    INNER JOIN #Found f ON f.Http_Method = e.Http_Method AND f.Controller = e.Controller AND f.Action = e.Action
    WHERE e.App = @App;

    -- New: recorded unmapped.
    INSERT INTO dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, Source, Discovered_On, Last_Seen_On, Is_Public)
    SELECT NULL, NULL, @App, f.Http_Method, f.Controller, f.Action, f.Route, 'SCAN', @ScanStart, @ScanStart, f.Is_Public
    FROM #Found f
    WHERE NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap e
                      WHERE e.App = @App AND e.Http_Method = f.Http_Method AND e.Controller = f.Controller AND e.Action = f.Action);

    -- Gone from the code: flagged, never deleted, so grants survive if it comes back.
    UPDATE dbo.PageEndpointMap SET Is_Orphaned = 1
    WHERE App = @App AND IsActive = 1 AND (Last_Seen_On IS NULL OR Last_Seen_On < @ScanStart);

    COMMIT TRANSACTION;

    SELECT
        (SELECT COUNT(*) FROM #Found) AS Found,
        (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @App AND IsActive = 1 AND Is_Orphaned = 0 AND Is_Public = 0 AND Page_ID IS NULL) AS Unmapped,
        (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @App AND IsActive = 1 AND Is_Orphaned = 1) AS Orphaned,
        (SELECT COUNT(*) FROM dbo.PageEndpointMap WHERE App = @App AND IsActive = 1 AND Is_Public = 1 AND Is_Orphaned = 0) AS PublicEndpoints;

    DROP TABLE #Found;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetUnmappedEndpoints
    @App VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Endpoint_ID, App, Http_Method, Controller, Action, Route, Discovered_On, Last_Seen_On
    FROM dbo.PageEndpointMap
    WHERE IsActive = 1 AND Page_ID IS NULL AND Is_Orphaned = 0 AND Is_Public = 0 AND (@App IS NULL OR App = @App)
    ORDER BY App, Controller, Action, Http_Method;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_DecisionLog_InsertBulk
    @Json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.AuthorizationDecisionLog
        (Logged_On, App, Mode, Outcome, User_ID, Branch_ID, Role_ID, Http_Method, Controller, Action, Path,
         Page_Code, Control_Code, Decided_At_Scope, Decided_By)
    SELECT j.LoggedOn, j.App, j.Mode, j.Outcome, j.UserId, j.BranchId, j.RoleId, j.HttpMethod, j.Controller, j.Action,
           LEFT(j.Path, 400), j.PageCode, j.ControlCode, j.DecidedAtScope, j.DecidedBy
    FROM OPENJSON(@Json) WITH (
        LoggedOn DATETIME2(0), App VARCHAR(10), Mode VARCHAR(10), Outcome VARCHAR(10), UserId INT, BranchId INT, RoleId INT,
        HttpMethod VARCHAR(10), Controller NVARCHAR(150), Action NVARCHAR(150), Path NVARCHAR(4000),
        PageCode NVARCHAR(150), ControlCode VARCHAR(30), DecidedAtScope INT, DecidedBy VARCHAR(10)) j;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Auth_DecisionLog_Summary
    @FromDate DATETIME2 = NULL,
    @App      VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -7, SYSDATETIME());
    SELECT l.App, l.Outcome, l.Http_Method, l.Controller, l.Action, l.Page_Code, l.Control_Code,
           COUNT(*) AS Hits, COUNT(DISTINCT l.User_ID) AS Users, MAX(l.Logged_On) AS LastSeen
    FROM dbo.AuthorizationDecisionLog l
    WHERE l.Logged_On >= @FromDate AND (@App IS NULL OR l.App = @App)
    GROUP BY l.App, l.Outcome, l.Http_Method, l.Controller, l.Action, l.Page_Code, l.Control_Code
    ORDER BY Hits DESC;
END;
GO

PRINT 'Script 2164 applied: authorization decision log + bulk endpoint discovery ready.';
GO
