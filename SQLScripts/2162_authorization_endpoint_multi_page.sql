-- ============================================================================
-- Migration: 2162_authorization_endpoint_multi_page.sql
-- Description:
--   Server-Side Authorization - Phase 1. Some screens are reachable from two menu
--   placements (Bill Cancellation under OPD and under LAB, Unit Master under
--   General and under Lab Master). Each placement is its own page, so it can be
--   granted and shown on its own, but they share the same controller action.
--
--   PageEndpointMap therefore allows one row per (endpoint, page). A request is
--   allowed when the user may use at least one page mapped to that endpoint;
--   an endpoint with no mapped page is refused (deny by default). For the ~all
--   endpoints that belong to a single page, nothing changes.
--
--   A discovered endpoint is recorded once, unmapped (Page_ID NULL); mapping it
--   converts that row, and a further placement adds a row.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PageEndpointMap') AND name = 'Page_Key')
    ALTER TABLE dbo.PageEndpointMap ADD Page_Key AS (ISNULL(Page_ID, 0)) PERSISTED;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PageEndpointMap_Endpoint' AND object_id = OBJECT_ID('dbo.PageEndpointMap'))
    DROP INDEX UX_PageEndpointMap_Endpoint ON dbo.PageEndpointMap;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PageEndpointMap_EndpointPage' AND object_id = OBJECT_ID('dbo.PageEndpointMap'))
    CREATE UNIQUE INDEX UX_PageEndpointMap_EndpointPage ON dbo.PageEndpointMap(App, Http_Method, Controller, Action, Page_Key);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PageEndpointMap_Endpoint' AND object_id = OBJECT_ID('dbo.PageEndpointMap'))
    CREATE INDEX IX_PageEndpointMap_Endpoint ON dbo.PageEndpointMap(App, Http_Method, Controller, Action);
GO

-- ── Map an endpoint to a page (+ control). Converts the unmapped row if there is one. ──
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageEndpointMap_Upsert
    @Page_ID     INT,
    @Control_ID  INT = NULL,
    @App         VARCHAR(10),
    @Http_Method VARCHAR(10),
    @Controller  NVARCHAR(150),
    @Action      NVARCHAR(150),
    @Route       NVARCHAR(300) = NULL,
    @Source      VARCHAR(10) = 'MANUAL'
AS
BEGIN
    SET NOCOUNT ON;

    IF @Page_ID IS NULL
    BEGIN
        RAISERROR('Choose the page this endpoint belongs to.', 16, 1);
        RETURN;
    END
    IF @Control_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID AND Page_ID = @Page_ID)
    BEGIN
        RAISERROR('The control does not belong to the chosen page.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.PageEndpointMap
               WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action AND Page_ID = @Page_ID)
        UPDATE dbo.PageEndpointMap
           SET Control_ID = @Control_ID, Route = ISNULL(@Route, Route), IsActive = 1, Is_Orphaned = 0
         WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action AND Page_ID = @Page_ID;
    ELSE IF EXISTS (SELECT 1 FROM dbo.PageEndpointMap
                    WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action AND Page_ID IS NULL)
        UPDATE dbo.PageEndpointMap
           SET Page_ID = @Page_ID, Control_ID = @Control_ID, Route = ISNULL(@Route, Route), IsActive = 1, Is_Orphaned = 0
         WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action AND Page_ID IS NULL;
    ELSE
        INSERT INTO dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, Source, Discovered_On, Last_Seen_On)
        VALUES (@Page_ID, @Control_ID, @App, @Http_Method, @Controller, @Action, @Route, @Source, GETDATE(), GETDATE());
END;
GO

-- ── Discovery: record an endpoint once; never touches an existing mapping ──
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageEndpointMap_RegisterDiscovered
    @App         VARCHAR(10),
    @Http_Method VARCHAR(10),
    @Controller  NVARCHAR(150),
    @Action      NVARCHAR(150),
    @Route       NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.PageEndpointMap WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action)
        UPDATE dbo.PageEndpointMap
           SET Last_Seen_On = GETDATE(), Is_Orphaned = 0, Route = ISNULL(Route, @Route)
         WHERE App = @App AND Http_Method = @Http_Method AND Controller = @Controller AND Action = @Action;
    ELSE
        INSERT INTO dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, Source, Discovered_On, Last_Seen_On)
        VALUES (NULL, NULL, @App, @Http_Method, @Controller, @Action, @Route, 'SCAN', GETDATE(), GETDATE());
END;
GO

-- ── Endpoints no longer present in the code: flagged, never deleted ──
CREATE OR ALTER PROCEDURE dbo.usp_Auth_PageEndpointMap_MarkOrphans
    @App        VARCHAR(10),
    @ScanStart  DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PageEndpointMap
       SET Is_Orphaned = 1
     WHERE App = @App AND IsActive = 1 AND (Last_Seen_On IS NULL OR Last_Seen_On < @ScanStart);
    SELECT @@ROWCOUNT AS OrphanedCount;
END;
GO

-- ── The inventory gate: endpoints nobody has mapped yet ──
CREATE OR ALTER PROCEDURE dbo.usp_Auth_GetUnmappedEndpoints
    @App VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Endpoint_ID, App, Http_Method, Controller, Action, Route, Discovered_On, Last_Seen_On, Is_Orphaned
    FROM dbo.PageEndpointMap
    WHERE IsActive = 1 AND Page_ID IS NULL AND Is_Orphaned = 0 AND (@App IS NULL OR App = @App)
    ORDER BY App, Controller, Action, Http_Method;
END;
GO

PRINT 'Script 2162 applied: endpoints may belong to more than one page placement.';
GO
