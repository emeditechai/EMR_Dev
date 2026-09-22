-- ============================================================================
-- Migration: 2109_branch_single_head_office.sql
-- Description:
--   A company can have only ONE Head Office branch.
--   The Branch Master screen checks this before saving; this filtered unique index makes it a hard guarantee in
--   the database too, so no other path (script, API, concurrent save) can ever create a second HO for a company.
--
--   Safe to run: it first reports any company that already has more than one HO and stops without changing
--   anything, so existing data is never altered silently.
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF EXISTS (SELECT CompanyId FROM dbo.Branchmaster WHERE IsHOBranch = 1 GROUP BY CompanyId HAVING COUNT(1) > 1)
BEGIN
    SELECT CompanyId, COUNT(1) AS HeadOffices
    FROM dbo.Branchmaster WHERE IsHOBranch = 1
    GROUP BY CompanyId HAVING COUNT(1) > 1;
    RAISERROR('Some companies already have more than one Head Office branch. Fix them before applying the index.', 16, 1);
    RETURN;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_Branchmaster_OneHeadOfficePerCompany' AND object_id = OBJECT_ID('dbo.Branchmaster'))
BEGIN
    CREATE UNIQUE INDEX UQ_Branchmaster_OneHeadOfficePerCompany
        ON dbo.Branchmaster (CompanyId)
        WHERE IsHOBranch = 1;
    PRINT 'Created UQ_Branchmaster_OneHeadOfficePerCompany';
END
ELSE
    PRINT 'UQ_Branchmaster_OneHeadOfficePerCompany already exists';
GO
