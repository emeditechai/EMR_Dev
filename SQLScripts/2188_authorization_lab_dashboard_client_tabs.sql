-- ============================================================================
-- Migration: 2188_authorization_lab_dashboard_client_tabs.sql
-- Description: LAB > LAB Dashboard - its three client tabs become controls of the page, so Settings > Security >
--   Role Permissions can decide per role which figures a user sees:
--     CLIENT_ALL  "All Clients" tab     (every client together)
--     CLIENT_B2C  "B2C Patients" tab    (walk-in / registered patients)
--     CLIENT_B2B  "B2B Partners" tab    (franchises and corporate partners)
--   They are checked inside LabDashboard/Index (the tab is a parameter of the page, not an endpoint of its own), so
--   no endpoint is mapped to them. The page shows only the tabs the user holds and opens the first of them; a tab
--   asked for in the address that the user does not hold is not served.
--   No role or user grant is seeded: a control without a row follows the page, so every role that opens the
--   LAB Dashboard keeps all three tabs until a tab is denied (or only some allowed) in Role Permissions.
--   Every user's Permission_Version is bumped so the new controls are picked up at once.
--   Run after 2187.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @Controls TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
    ('CLIENT_ALL', N'All Clients tab',  11),
    ('CLIENT_B2C', N'B2C Patients tab', 12),
    ('CLIENT_B2B', N'B2B Partners tab', 13);

DECLARE @page INT, @ctl INT, @c VARCHAR(30), @t NVARCHAR(150), @s INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'LAB.LABDASHBOARD';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE ctl CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls;
    OPEN ctl; FETCH NEXT FROM ctl INTO @c, @t, @s;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @c, @Title = @t, @Sort_Order = @s, @Control_ID = @ctl OUTPUT;
        FETCH NEXT FROM ctl INTO @c, @t, @s;
    END
    CLOSE ctl; DEALLOCATE ctl;
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
