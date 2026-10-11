-- ====================================================================================================
-- Script: 2247_accounts_reports_under_reports_menu.sql
-- Description: The Accounts reports move from Utility > Accounts to Reports > Accounts. Masters and transactions
--   (petty expenses, counters, closing, vouchers, ledgers, expense heads, payees, settings) stay under Utility > Accounts.
--   For a database where script 2246 ran before this change: the page UTILITY.ACCOUNTS.REPORTS is renamed to
--   REPORTS.ACCOUNTS and re-parented to a new menu Reports > Accounts. The page row is kept (same Page_ID), so its
--   controls, endpoints and every role / user grant already given stay as they are.
--   A database that gets the current 2246 is already in this state: nothing to do here.
--   Safe to re-run.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @co INT, @reports INT, @menu INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @reports = NULL; SET @menu = NULL;
    SELECT @reports = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS' AND CompanyId = @co;
    IF @reports IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @reports, @Menu_Type = 'MENU', @Menu_Code = N'REPORTS.ACCOUNTS_MENU', @Title = N'Accounts',
             @Icon = N'bi bi-calculator me-2', @Sort_Order = 40, @UserId = NULL, @Menu_ID = @menu OUTPUT;

        IF NOT EXISTS (SELECT 1 FROM dbo.PageMaster WHERE Page_Code = N'REPORTS.ACCOUNTS' AND CompanyId = @co)
            UPDATE dbo.PageMaster SET Page_Code = N'REPORTS.ACCOUNTS' WHERE Page_Code = N'UTILITY.ACCOUNTS.REPORTS' AND CompanyId = @co;
        UPDATE dbo.PageMaster SET Menu_ID = @menu, Sort_Order = 10 WHERE Page_Code = N'REPORTS.ACCOUNTS' AND CompanyId = @co AND ISNULL(Menu_ID, 0) <> @menu;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2247 applied: Accounts reports moved to Reports > Accounts.';
GO
