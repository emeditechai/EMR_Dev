-- ====================================================================================================
-- Script: 2246_accounts_menu_pages_permissions.sql
-- Description: Utility > Accounts - the menu, its pages, their controls and the endpoints behind each control
--   (page / control authorization, SQLScripts/2159-2163). Screens of scripts 2244 / 2245.
--     UTILITY.ACCOUNTS.PETTYEXPENSE  VIEW, CREATE, EDIT, APPROVE (approve / reject), CANCEL, PRINT, EXPORT, ATTACH (bill scans)
--     UTILITY.ACCOUNTS.COUNTERS      VIEW, EDIT (add / edit a counter), FLOAT (issue / replenish / return)
--     UTILITY.ACCOUNTS.CLOSING       VIEW, CREATE (close a day)
--     UTILITY.ACCOUNTS.VOUCHERS      VIEW, CREATE, APPROVE (approve / reject), CANCEL, PRINT, ATTACH (bill scans)
--     UTILITY.ACCOUNTS.REPORTS       VIEW, EXPORT
--     UTILITY.ACCOUNTS.LEDGERS       VIEW, EDIT (add / edit ledgers and groups)
--     UTILITY.ACCOUNTS.EXPENSEHEADS  VIEW, EDIT
--     UTILITY.ACCOUNTS.PAYEES        VIEW, EDIT
--     UTILITY.ACCOUNTS.SETTINGS      VIEW, EDIT, LOCK (lock / unlock the books of a branch)
--   No role or user grant is seeded: who may do what is set in Settings > Security > Role Permissions
--   (Super Admin sees everything without a grant).
--   Safe to re-run.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Controller NVARCHAR(100), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', N'Petty Expenses',      N'PettyExpense',    N'Index',    10, N'bi bi-receipt me-2'),
    (N'UTILITY.ACCOUNTS.COUNTERS',     N'Petty Cash Counters', N'PettyCash',       N'Counters', 20, N'bi bi-safe me-2'),
    (N'UTILITY.ACCOUNTS.CLOSING',      N'Petty Cash Closing',  N'PettyCash',       N'Closing',  30, N'bi bi-calendar-check me-2'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     N'Voucher Entry',       N'AccVouchers',     N'Index',    40, N'bi bi-journal-plus me-2'),
    (N'UTILITY.ACCOUNTS.REPORTS',      N'Accounts Reports',    N'AccReports',      N'Index',    50, N'bi bi-bar-chart-line me-2'),
    (N'UTILITY.ACCOUNTS.LEDGERS',      N'Ledgers and Groups',  N'AccLedgers',      N'Index',    60, N'bi bi-diagram-3 me-2'),
    (N'UTILITY.ACCOUNTS.EXPENSEHEADS', N'Expense Heads',       N'AccExpenseHeads', N'Index',    70, N'bi bi-tags me-2'),
    (N'UTILITY.ACCOUNTS.PAYEES',       N'Payees',              N'AccPayees',       N'Index',    75, N'bi bi-person-lines-fill me-2'),
    (N'UTILITY.ACCOUNTS.SETTINGS',     N'Accounts Settings',   N'AccSettings',     N'Index',    80, N'bi bi-gear me-2');

DECLARE @Controls TABLE (PageCode NVARCHAR(150), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'CREATE',  N'Enter petty expense', 20), (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'EDIT',   N'Edit a waiting / rejected expense', 30),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'APPROVE', N'Approve / reject', 40),    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'CANCEL', N'Cancel an expense', 50),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'PRINT',   N'Print voucher', 60),       (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'EXPORT', N'Export to Excel', 70),
    (N'UTILITY.ACCOUNTS.COUNTERS',     'EDIT',    N'Add / edit counter', 20),  (N'UTILITY.ACCOUNTS.COUNTERS',     'FLOAT',  N'Issue / replenish / return float', 30),
    (N'UTILITY.ACCOUNTS.CLOSING',      'CREATE',  N'Close a day', 20),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'CREATE',  N'Enter voucher', 20),       (N'UTILITY.ACCOUNTS.VOUCHERS',     'APPROVE', N'Approve / reject', 30),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'CANCEL',  N'Cancel a voucher', 40),    (N'UTILITY.ACCOUNTS.VOUCHERS',     'PRINT',  N'Print voucher', 50),
    (N'UTILITY.ACCOUNTS.REPORTS',      'EXPORT',  N'Export to Excel', 20),
    (N'UTILITY.ACCOUNTS.LEDGERS',      'EDIT',    N'Add / edit ledgers and groups', 20),
    (N'UTILITY.ACCOUNTS.EXPENSEHEADS', 'EDIT',    N'Add / edit expense heads', 20),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'ATTACH',  N'Add / remove bill attachments', 80),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'ATTACH',  N'Add / remove bill attachments', 60),
    (N'UTILITY.ACCOUNTS.PAYEES',       'EDIT',    N'Add / edit payees', 20),
    (N'UTILITY.ACCOUNTS.SETTINGS',     'EDIT',    N'Change settings', 20),
    (N'UTILITY.ACCOUNTS.SETTINGS',     'LOCK',    N'Lock / unlock the books of a branch', 30);

DECLARE @Endpoints TABLE (PageCode NVARCHAR(150), Method VARCHAR(10), Controller NVARCHAR(100), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Endpoints VALUES
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Index',       'VIEW'),   (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Details', 'VIEW'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'CounterInfo', 'VIEW'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Create',      'CREATE'), (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'Create',  'CREATE'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Edit',        'EDIT'),   (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'Edit',    'EDIT'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'Approve',     'APPROVE'),(N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'Reject',  'APPROVE'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'Cancel',      'CANCEL'), (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Print',   'PRINT'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Export',      'EXPORT'),
    (N'UTILITY.ACCOUNTS.COUNTERS',     'GET',  N'PettyCash',    N'Counters',    'VIEW'),   (N'UTILITY.ACCOUNTS.COUNTERS',     'GET',  N'PettyCash',    N'FloatHistory', 'VIEW'),
    (N'UTILITY.ACCOUNTS.COUNTERS',     'POST', N'PettyCash',    N'SaveCounter', 'EDIT'),   (N'UTILITY.ACCOUNTS.COUNTERS',     'POST', N'PettyCash',    N'Float',   'FLOAT'),
    (N'UTILITY.ACCOUNTS.CLOSING',      'GET',  N'PettyCash',    N'Closing',     'VIEW'),   (N'UTILITY.ACCOUNTS.CLOSING',      'GET',  N'PettyCash',    N'ClosingBalance', 'VIEW'),
    (N'UTILITY.ACCOUNTS.CLOSING',      'POST', N'PettyCash',    N'SaveClosing', 'CREATE'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'GET',  N'AccVouchers',  N'Index',       'VIEW'),   (N'UTILITY.ACCOUNTS.VOUCHERS',     'GET',  N'AccVouchers',  N'Details', 'VIEW'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'GET',  N'AccVouchers',  N'Create',      'CREATE'), (N'UTILITY.ACCOUNTS.VOUCHERS',     'POST', N'AccVouchers',  N'Create',  'CREATE'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'POST', N'AccVouchers',  N'Approve',     'APPROVE'),(N'UTILITY.ACCOUNTS.VOUCHERS',     'POST', N'AccVouchers',  N'Reject',  'APPROVE'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'POST', N'AccVouchers',  N'Cancel',      'CANCEL'), (N'UTILITY.ACCOUNTS.VOUCHERS',     'GET',  N'AccVouchers',  N'Print',   'PRINT'),
    (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'Index',       'VIEW'),   (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'LedgerStatement', 'VIEW'),
    (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'DayBook',     'VIEW'),   (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'TrialBalance', 'VIEW'),
    (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'IncomeExpense', 'VIEW'), (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'ExpenseSummary', 'VIEW'),
    (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'Voucher',     'VIEW'),   (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'Export',  'EXPORT'),
    (N'UTILITY.ACCOUNTS.LEDGERS',      'GET',  N'AccLedgers',   N'Index',       'VIEW'),   (N'UTILITY.ACCOUNTS.LEDGERS',      'POST', N'AccLedgers',   N'SaveLedger', 'EDIT'),
    (N'UTILITY.ACCOUNTS.LEDGERS',      'POST', N'AccLedgers',   N'SaveGroup',   'EDIT'),
    (N'UTILITY.ACCOUNTS.EXPENSEHEADS', 'GET',  N'AccExpenseHeads', N'Index',    'VIEW'),   (N'UTILITY.ACCOUNTS.EXPENSEHEADS', 'POST', N'AccExpenseHeads', N'Save', 'EDIT'),
    (N'UTILITY.ACCOUNTS.SETTINGS',     'GET',  N'AccSettings',  N'Index',       'VIEW'),   (N'UTILITY.ACCOUNTS.SETTINGS',     'POST', N'AccSettings',  N'Save',    'EDIT'),
    (N'UTILITY.ACCOUNTS.SETTINGS',     'POST', N'AccSettings',  N'SaveLock',    'LOCK'),
    (N'UTILITY.ACCOUNTS.PAYEES',       'GET',  N'AccPayees',    N'Index',       'VIEW'),   (N'UTILITY.ACCOUNTS.PAYEES',       'POST', N'AccPayees',    N'Save',    'EDIT'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'GET',  N'PettyExpense', N'Attachment',  'VIEW'),   (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'AddAttachment', 'ATTACH'),
    (N'UTILITY.ACCOUNTS.PETTYEXPENSE', 'POST', N'PettyExpense', N'DeleteAttachment', 'ATTACH'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'GET',  N'AccVouchers',  N'Attachment',  'VIEW'),   (N'UTILITY.ACCOUNTS.VOUCHERS',     'POST', N'AccVouchers',  N'AddAttachment', 'ATTACH'),
    (N'UTILITY.ACCOUNTS.VOUCHERS',     'POST', N'AccVouchers',  N'DeleteAttachment', 'ATTACH'),
    (N'UTILITY.ACCOUNTS.REPORTS',      'GET',  N'AccReports',   N'PostingAudit', 'VIEW');

DECLARE @co INT, @utility INT, @menu INT, @page INT, @ctl INT;
DECLARE @pc NVARCHAR(150), @title NVARCHAR(150), @controller NVARCHAR(100), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100), @code VARCHAR(30), @method VARCHAR(10);

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @utility = NULL;
    SELECT @utility = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'UTILITY' AND CompanyId = @co;
    IF @utility IS NOT NULL
    BEGIN
        SET @menu = NULL;
        EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @utility, @Menu_Type = 'MENU', @Menu_Code = N'UTILITY.ACCOUNTS', @Title = N'Accounts',
             @Icon = N'bi bi-calculator me-2', @Sort_Order = 55, @UserId = NULL, @Menu_ID = @menu OUTPUT;

        DECLARE p1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Controller, Action, Sort, Icon FROM @Pages;
        OPEN p1; FETCH NEXT FROM p1 INTO @pc, @title, @controller, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @pc, @Title = @title, @Controller = @controller, @Action = @action,
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;

            DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE PageCode = @pc;
            OPEN c1; FETCH NEXT FROM c1 INTO @code, @title, @sort;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @title, @Sort_Order = @sort, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM c1 INTO @code, @title, @sort;
            END
            CLOSE c1; DEALLOCATE c1;

            DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Controller, Action, Code FROM @Endpoints WHERE PageCode = @pc;
            OPEN e1; FETCH NEXT FROM e1 INTO @method, @controller, @action, @code;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @code;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @method,
                     @Controller = @controller, @Action = @action, @Source = 'SEED';
                FETCH NEXT FROM e1 INTO @method, @controller, @action, @code;
            END
            CLOSE e1; DEALLOCATE e1;

            FETCH NEXT FROM p1 INTO @pc, @title, @controller, @action, @sort, @icon;
        END
        CLOSE p1; DEALLOCATE p1;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2246 applied: Utility > Accounts menu, pages, controls and endpoints.';
GO
