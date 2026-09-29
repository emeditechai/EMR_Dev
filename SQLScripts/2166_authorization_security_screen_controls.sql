-- ============================================================================
-- Migration: 2166_authorization_security_screen_controls.sql
-- Description:
--   Server-Side Authorization - Phase 4: the controls declared by the four
--   Settings > Security screens (their actions carry [RequiresPermission] with
--   these codes, and the endpoint scanner maps them from the code):
--     SETTINGS.SECURITY.MENUPAGES             VIEW, EDIT   (change the tree / mappings)
--     SETTINGS.SECURITY.ROLEPERMISSIONS       VIEW, EDIT   (save role grants)
--     SETTINGS.SECURITY.USERPERMISSIONS       VIEW, EDIT   (save user overrides)
--     SETTINGS.SECURITY.EFFECTIVEPERMISSIONS  VIEW, EXPORT (download for the auditor)
--   Run after 2163 (the seed that creates the pages).
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @x TABLE (Page_Code NVARCHAR(150), Control_Code VARCHAR(30), Title NVARCHAR(150), Sort_Order INT);
INSERT INTO @x VALUES
    ('SETTINGS.SECURITY.MENUPAGES',            'EDIT',   N'Change menus, pages, controls and endpoint mappings', 30),
    ('SETTINGS.SECURITY.ROLEPERMISSIONS',      'EDIT',   N'Save what a role may reach',                           30),
    ('SETTINGS.SECURITY.USERPERMISSIONS',      'EDIT',   N'Save one person''s exceptions',                        30),
    ('SETTINGS.SECURITY.EFFECTIVEPERMISSIONS', 'EXPORT', N'Download effective permissions for the auditor',       110);

INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order)
SELECT p.Page_ID, x.Control_Code, x.Title, x.Sort_Order
FROM @x x INNER JOIN dbo.PageMaster p ON p.Page_Code = x.Page_Code
WHERE NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster c WHERE c.Page_ID = p.Page_ID AND c.Control_Code = x.Control_Code);
PRINT 'Script 2166 applied: Security screen controls ready.';
GO
