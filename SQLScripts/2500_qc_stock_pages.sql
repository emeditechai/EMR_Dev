-- ============================================================================================================
-- Migration: 2500_qc_stock_pages.sql   (after 2498, 2499)
-- Description: Quality & Compliance > Stock Management - menu, pages, one control per action and the endpoint map
--   (Settings > Security). No role is granted here: which role gets which page / control is the user's decision.
--   Sub-menu QUALITY.STOCK "Stock Management" (between Masters and Bill of Material).
--   Sensitive controls to grant explicitly: APPROVE (PO, adjustment, count), POST (receipt, return, opening stock),
--   ACCEPT / REJECT / BLOCK (lots), SKIP (pending consumption), SETTINGS, POST_ACCOUNTS.
--   Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Ctrl NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
 (N'QC.STOCK.DASHBOARD', N'Stock Dashboard',          N'QcStockDashboard',      10, N'bi bi-speedometer2 me-2'),
 (N'QC.STOCK.ENQUIRY',   N'Stock Enquiry',            N'QcStockEnquiry',        20, N'bi bi-search me-2'),
 (N'QC.STOCK.OPENING',   N'Opening Stock',            N'QcOpeningStock',        30, N'bi bi-box-arrow-in-down me-2'),
 (N'QC.STOCK.PO',        N'Purchase Orders',          N'QcPurchaseOrders',      40, N'bi bi-file-earmark-text me-2'),
 (N'QC.STOCK.GRN',       N'Goods Receipt (GRN)',      N'QcGoodsReceipts',       50, N'bi bi-truck me-2'),
 (N'QC.STOCK.LOTS',      N'Lot Acceptance',           N'QcLotAcceptance',       60, N'bi bi-patch-check me-2'),
 (N'QC.STOCK.PRET',      N'Purchase Returns',         N'QcPurchaseReturns',     70, N'bi bi-arrow-return-left me-2'),
 (N'QC.STOCK.INDENT',    N'Indents',                  N'QcIndents',             80, N'bi bi-clipboard-plus me-2'),
 (N'QC.STOCK.ISSUE',     N'Issue / Transfer',         N'QcStockIssues',         90, N'bi bi-arrow-left-right me-2'),
 (N'QC.STOCK.ADJUST',    N'Adjustment / Write-off',   N'QcStockAdjustments',   100, N'bi bi-sliders me-2'),
 (N'QC.STOCK.COUNT',     N'Physical Stock Count',     N'QcStockCounts',        110, N'bi bi-list-check me-2'),
 (N'QC.STOCK.PENDING',   N'Pending Consumption',      N'QcPendingConsumption', 120, N'bi bi-hourglass-split me-2'),
 (N'QC.STOCK.REPORTS',   N'Stock Reports',            N'QcStockReports',       130, N'bi bi-bar-chart-line me-2');

-- controls of each page (VIEW is created with the page)
DECLARE @Controls TABLE (Ctrl NVARCHAR(100), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
 (N'QcStockDashboard', 'SETTINGS', N'Change stock settings', 20), (N'QcStockDashboard', 'POST_ACCOUNTS', N'Post consumption to accounts', 30),
 (N'QcStockEnquiry', 'OPEN_VIAL', N'Mark lot opened', 20),
 (N'QcOpeningStock', 'ADD', N'Add / edit draft', 20), (N'QcOpeningStock', 'POST', N'Post opening stock', 30), (N'QcOpeningStock', 'CANCEL', N'Cancel draft', 40),
 (N'QcPurchaseOrders', 'ADD', N'Add / edit draft', 20), (N'QcPurchaseOrders', 'SUBMIT', N'Submit for approval', 30), (N'QcPurchaseOrders', 'APPROVE', N'Approve / reject', 40),
 (N'QcPurchaseOrders', 'CANCEL', N'Cancel', 50), (N'QcPurchaseOrders', 'CLOSE', N'Short-close', 60),
 (N'QcGoodsReceipts', 'ADD', N'Add / edit draft', 20), (N'QcGoodsReceipts', 'POST', N'Post receipt', 30), (N'QcGoodsReceipts', 'CANCEL', N'Cancel draft', 40),
 (N'QcLotAcceptance', 'ACCEPT', N'Accept lot', 20), (N'QcLotAcceptance', 'REJECT', N'Reject lot', 30), (N'QcLotAcceptance', 'BLOCK', N'Block / unblock lot', 40),
 (N'QcPurchaseReturns', 'ADD', N'Add / edit draft', 20), (N'QcPurchaseReturns', 'POST', N'Post return', 30), (N'QcPurchaseReturns', 'CANCEL', N'Cancel draft', 40),
 (N'QcIndents', 'ADD', N'Add / edit draft', 20), (N'QcIndents', 'SUBMIT', N'Submit indent', 30), (N'QcIndents', 'CANCEL', N'Cancel', 40),
 (N'QcIndents', 'REJECT', N'Reject (supplying store)', 50), (N'QcIndents', 'CLOSE', N'Close (supplying store)', 60),
 (N'QcStockIssues', 'ADD', N'Add / edit draft', 20), (N'QcStockIssues', 'DISPATCH', N'Dispatch', 30), (N'QcStockIssues', 'RECEIVE', N'Receive', 40), (N'QcStockIssues', 'CANCEL', N'Cancel draft', 50),
 (N'QcStockAdjustments', 'ADD', N'Add / edit draft', 20), (N'QcStockAdjustments', 'SUBMIT', N'Submit', 30), (N'QcStockAdjustments', 'APPROVE', N'Approve / reject', 40),
 (N'QcStockAdjustments', 'CANCEL', N'Cancel', 50),
 (N'QcStockCounts', 'ADD', N'Start count / enter counts', 20), (N'QcStockCounts', 'SUBMIT', N'Submit', 30), (N'QcStockCounts', 'APPROVE', N'Approve / reject', 40),
 (N'QcStockCounts', 'CANCEL', N'Cancel', 50),
 (N'QcPendingConsumption', 'RETRY', N'Take out of stock again', 20), (N'QcPendingConsumption', 'SKIP', N'Skip (do not take out of stock)', 30),
 (N'QcStockReports', 'EXPORT', N'Export to Excel', 20);

-- controller actions and the control each needs
DECLARE @Ep TABLE (Ctrl NVARCHAR(100), Method VARCHAR(10), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Ep VALUES
 (N'QcStockDashboard','GET',N'Index','VIEW'),(N'QcStockDashboard','GET',N'Data','VIEW'),(N'QcStockDashboard','POST',N'SaveSettings','SETTINGS'),
 (N'QcStockDashboard','POST',N'PostConsumption','POST_ACCOUNTS'),
 (N'QcStockEnquiry','GET',N'Index','VIEW'),(N'QcStockEnquiry','GET',N'List','VIEW'),(N'QcStockEnquiry','GET',N'Ledger','VIEW'),(N'QcStockEnquiry','POST',N'MarkOpened','OPEN_VIAL'),
 (N'QcLotAcceptance','GET',N'Index','VIEW'),(N'QcLotAcceptance','GET',N'List','VIEW'),(N'QcLotAcceptance','POST',N'Accept','ACCEPT'),
 (N'QcLotAcceptance','POST',N'Reject','REJECT'),(N'QcLotAcceptance','POST',N'Block','BLOCK'),(N'QcLotAcceptance','POST',N'Unblock','BLOCK'),
 (N'QcPendingConsumption','GET',N'Index','VIEW'),(N'QcPendingConsumption','GET',N'List','VIEW'),(N'QcPendingConsumption','POST',N'Retry','RETRY'),
 (N'QcPendingConsumption','POST',N'Skip','SKIP'),
 (N'QcStockReports','GET',N'Index','VIEW'),(N'QcStockReports','GET',N'Data','VIEW'),(N'QcStockReports','GET',N'Export','EXPORT'),
 (N'QcStockCounts','POST',N'Create','ADD'),(N'QcStockCounts','POST',N'SaveCounts','ADD'),
 (N'QcPurchaseOrders','GET',N'Reorder','VIEW'),(N'QcPurchaseReturns','GET',N'Receipts','VIEW'),
 (N'QcGoodsReceipts','GET',N'OpenOrders','VIEW'),(N'QcGoodsReceipts','GET',N'Order','VIEW'),
 (N'QcStockIssues','GET',N'Fefo','VIEW'),(N'QcStockIssues','GET',N'OpenIndents','VIEW'),(N'QcStockIssues','GET',N'FromIndent','VIEW');
-- the document screens share these actions
INSERT INTO @Ep
SELECT c.Ctrl, v.Method, v.Action, v.Code
FROM (VALUES (N'QcOpeningStock'), (N'QcPurchaseOrders'), (N'QcGoodsReceipts'), (N'QcPurchaseReturns'), (N'QcIndents'), (N'QcStockIssues'),
             (N'QcStockAdjustments'), (N'QcStockCounts')) c (Ctrl)
CROSS JOIN (VALUES ('GET', N'Index', 'VIEW'), ('GET', N'List', 'VIEW'), ('GET', N'Get', 'VIEW'), ('GET', N'Print', 'VIEW'), ('GET', N'Lots', 'VIEW')) v (Method, Action, Code)
UNION ALL
SELECT x.Ctrl, 'POST', x.Action, x.Code
FROM (VALUES
 (N'QcOpeningStock', N'Save', 'ADD'), (N'QcOpeningStock', N'Post', 'POST'), (N'QcOpeningStock', N'Cancel', 'CANCEL'),
 (N'QcPurchaseOrders', N'Save', 'ADD'), (N'QcPurchaseOrders', N'Submit', 'SUBMIT'), (N'QcPurchaseOrders', N'Approve', 'APPROVE'), (N'QcPurchaseOrders', N'Reject', 'APPROVE'),
 (N'QcPurchaseOrders', N'Cancel', 'CANCEL'), (N'QcPurchaseOrders', N'Close', 'CLOSE'),
 (N'QcGoodsReceipts', N'Save', 'ADD'), (N'QcGoodsReceipts', N'Post', 'POST'), (N'QcGoodsReceipts', N'Cancel', 'CANCEL'),
 (N'QcPurchaseReturns', N'Save', 'ADD'), (N'QcPurchaseReturns', N'Post', 'POST'), (N'QcPurchaseReturns', N'Cancel', 'CANCEL'),
 (N'QcIndents', N'Save', 'ADD'), (N'QcIndents', N'Submit', 'SUBMIT'), (N'QcIndents', N'Cancel', 'CANCEL'), (N'QcIndents', N'Reject', 'REJECT'), (N'QcIndents', N'Close', 'CLOSE'),
 (N'QcStockIssues', N'Save', 'ADD'), (N'QcStockIssues', N'Dispatch', 'DISPATCH'), (N'QcStockIssues', N'Receive', 'RECEIVE'), (N'QcStockIssues', N'Cancel', 'CANCEL'),
 (N'QcStockAdjustments', N'Save', 'ADD'), (N'QcStockAdjustments', N'Submit', 'SUBMIT'), (N'QcStockAdjustments', N'Approve', 'APPROVE'),
 (N'QcStockAdjustments', N'Reject', 'APPROVE'), (N'QcStockAdjustments', N'Cancel', 'CANCEL'),
 (N'QcStockCounts', N'Submit', 'SUBMIT'), (N'QcStockCounts', N'Approve', 'APPROVE'), (N'QcStockCounts', N'Reject', 'APPROVE'), (N'QcStockCounts', N'Cancel', 'CANCEL')
) x (Ctrl, Action, Code);

DECLARE @co INT, @top INT, @menu INT, @page INT, @ctl INT, @code NVARCHAR(100), @title NVARCHAR(150), @ctrl NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @top = NULL;
    SELECT @top = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'QUALITY' AND CompanyId = @co;
    IF @top IS NOT NULL
    BEGIN
        SET @menu = NULL;
        EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @top, @Menu_Type = 'MENU', @Menu_Code = N'QUALITY.STOCK',
             @Title = N'Stock Management', @Icon = N'bi bi-boxes me-2', @Sort_Order = 15, @Menu_ID = @menu OUTPUT;

        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Ctrl, Sort, Icon FROM @Pages;
        OPEN pg; FETCH NEXT FROM pg INTO @code, @title, @ctrl, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title, @Controller = @ctrl, @Action = N'Index',
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
            DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT;
            DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE Ctrl = @ctrl;
            OPEN c1; FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
            END
            CLOSE c1; DEALLOCATE c1;
            DECLARE @em VARCHAR(10), @ea NVARCHAR(100), @ec VARCHAR(30);
            DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Code FROM @Ep WHERE Ctrl = @ctrl;
            OPEN e1; FETCH NEXT FROM e1 INTO @em, @ea, @ec;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @ec;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @em,
                     @Controller = @ctrl, @Action = @ea, @Source = 'SEED';
                FETCH NEXT FROM e1 INTO @em, @ea, @ec;
            END
            CLOSE e1; DEALLOCATE e1;
            FETCH NEXT FROM pg INTO @code, @title, @ctrl, @sort, @icon;
        END
        CLOSE pg; DEALLOCATE pg;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2500 applied: Quality & Compliance > Stock Management menu, pages, controls and endpoints (no role granted).';
GO
