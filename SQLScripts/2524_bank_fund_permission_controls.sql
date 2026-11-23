-- ============================================================================================================
-- Migration: 2524_bank_fund_permission_controls.sql   (application database; needs 2522 / 2523)
-- Bank Master and Fund Master: every action on the pages is its own permission control, managed per role on the
-- permission screens (Settings > Security) and enforced on the server (endpoint map):
--   MASTER.BANKS           : VIEW (open the list), DETAILS (view an account), ADD, EDIT, STATUS
--   UTILITY.ACCOUNTS.FUNDS : VIEW (open the list), DETAILS (view a fund), HISTORY (its movements), ADD, EDIT, TOPUP, STATUS
-- TOPUP and HISTORY join the control vocabulary (TOPUP is sensitive - it moves money). No role is granted. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
MERGE dbo.PermissionControlVocabulary AS t
USING (VALUES ('TOPUP', N'Top up', N'Add money to a fund or wallet', 135, 1),
              ('HISTORY', N'History', N'See the history of a record (movements, changes)', 136, 0)) s (Code, Title, Descr, Sort, Sens)
ON t.Control_Code = s.Code
WHEN NOT MATCHED THEN INSERT (Control_Code, Title, Description, Sort_Order, Is_Sensitive) VALUES (s.Code, s.Title, s.Descr, s.Sort, s.Sens);
GO
DECLARE @c TABLE (PageCode NVARCHAR(60), Ctl NVARCHAR(60), Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Method VARCHAR(10), Act NVARCHAR(60));
INSERT @c VALUES
 (N'MASTER.BANKS',           N'Banks', 'DETAILS', N'View a bank account',           15, 'GET', N'Get'),
 (N'UTILITY.ACCOUNTS.FUNDS', N'Funds', 'DETAILS', N'View a fund',                   15, 'GET', N'Get'),
 (N'UTILITY.ACCOUNTS.FUNDS', N'Funds', 'HISTORY', N'See a fund''s history (top-ups, movements)', 45, 'GET', N'History');
DECLARE @pc NVARCHAR(60), @cn NVARCHAR(60), @code VARCHAR(30), @ti NVARCHAR(150), @so INT, @m VARCHAR(10), @a NVARCHAR(60), @page INT, @ctl INT;
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT PageCode, Ctl, Code, Title, Sort, Method, Act FROM @c;
OPEN k; FETCH NEXT FROM k INTO @pc, @cn, @code, @ti, @so, @m, @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = @pc;
    IF @page IS NOT NULL
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @ti, @Sort_Order = @so, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @m, @Controller = @cn, @Action = @a, @Source = 'SEED';
        UPDATE dbo.PageEndpointMap SET Control_ID = @ctl WHERE Page_ID = @page AND App = 'WEB' AND Http_Method = @m AND Controller = @cn AND Action = @a;
    END
    FETCH NEXT FROM k INTO @pc, @cn, @code, @ti, @so, @m, @a;
END
CLOSE k; DEALLOCATE k;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2524 applied: Bank / Fund Master permission controls (DETAILS, HISTORY, TOPUP).';
GO
