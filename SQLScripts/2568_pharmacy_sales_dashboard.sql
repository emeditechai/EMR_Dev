-- ============================================================================================================
-- Migration: 2568_pharmacy_sales_dashboard.sql
-- Pharmacy > Sales > Sales Dashboard: the pharmacy's sales of a period split into three channels
--   POS     counter bills to walk-in buyers                        PhSale.CustomerKind NOT IN ('PATIENT', 'CUSTOMER')
--   DIRECT  bills against a registered patient / credit customer   PhSale.CustomerKind IN ('PATIENT', 'CUSTOMER')
--           (includes bills made from an OPD prescription)
--   IPD     medicines / consumables issued to admitted patients    IpdPhIssue Kind ISSUE (SQLScripts/2437, 2475)
-- Definitions as Reports > Pharmacy (2361, 2548): posted bills / issues by document date; a return reduces the period
-- of the document it came from (net = amount - returned, GST included); cost = cost of what was kept. Cancelled bills
-- appear in the list only. IPD issues go to the IP bill, so they carry no counter payment and no due.
--
-- usp_Api_PhSalesDash_Get answers six result sets:
--   1 one row per channel (always POS, DIRECT, IPD): documents, gross, returned, net, cost, paid, due, discount, buyers,
--     and net / documents of the same length of time just before (for the trend arrow)
--   2 net sales per day and channel, every day of the period
--   3 money received in the period by payment mode (POS / Direct receipts by receipt date)
--   4 top 10 items by net value, split by channel
--   5 the requested page of documents (filter by channel / search; pageSize 0 = all)
--   6 TotalRows and totals of the filtered documents
-- Page PHARMACY.SALESDASHBOARD (PhSalesDashboard/Index) under Pharmacy > Sales. Needs 2348-2366, 2437. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSalesDash_Get
    @CompanyId INT, @BranchId INT, @From DATE = NULL, @To DATE = NULL,
    @Channel VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @From IS NULL SET @From = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1);
    IF @To IS NULL SET @To = CAST(GETDATE() AS DATE);
    IF @To < @From BEGIN DECLARE @sw DATE = @From; SET @From = @To; SET @To = @sw; END
    IF DATEDIFF(DAY, @From, @To) > 365 SET @From = DATEADD(DAY, -365, @To);      -- one year at most
    SET @Channel = NULLIF(UPPER(LTRIM(RTRIM(@Channel))), '');
    IF @Channel NOT IN ('POS', 'DIRECT', 'IPD') SET @Channel = NULL;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 0 OR @PageSize > 500 SET @PageSize = 25;

    DECLARE @start DATETIME = @From, @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    DECLARE @days INT = DATEDIFF(DAY, @From, @To) + 1;
    DECLARE @pStart DATETIME = DATEADD(DAY, -@days, @start);                     -- the same length of time just before
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';

    -- ── every document of the period and the one before: pharmacy bills (POS / Direct) and IPD issues ──
    CREATE TABLE #L (Channel VARCHAR(10) NOT NULL, Cur BIT NOT NULL, DocId INT NOT NULL, RefId INT NULL, DocNo NVARCHAR(40) NULL, DocAt DATETIME NOT NULL,
                     Party NVARCHAR(200) NULL, PartyRef NVARCHAR(60) NULL, Mobile NVARCHAR(20) NULL, Doctor NVARCHAR(150) NULL, Items INT NOT NULL,
                     Amount DECIMAL(18,2) NOT NULL, Returned DECIMAL(18,2) NOT NULL, Cost DECIMAL(18,2) NOT NULL, Paid DECIMAL(18,2) NOT NULL,
                     Due DECIMAL(18,2) NOT NULL, Discount DECIMAL(18,2) NOT NULL, Buyer NVARCHAR(40) NULL, Status VARCHAR(12) NOT NULL, CreatedBy INT NULL);

    INSERT #L
    SELECT CASE WHEN s.CustomerKind IN ('PATIENT', 'CUSTOMER') THEN 'DIRECT' ELSE 'POS' END, CASE WHEN s.SaleDate >= @start THEN 1 ELSE 0 END,
           s.SaleId, s.PatientId, s.SaleNo, s.SaleDate,
           COALESCE(NULLIF(s.CustomerName, ''), NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))), ''), N'Walk-in'),
           CASE s.CustomerKind WHEN 'PATIENT' THEN p.PatientCode WHEN 'CUSTOMER' THEN N'Credit customer' END,
           s.Mobile, s.DoctorName,
           (SELECT COUNT(*) FROM dbo.PhSaleDtl x WHERE x.SaleId = s.SaleId),
           s.NetAmount, ISNULL(r.Amount, 0), s.CostAmount - ISNULL(r.Cost, 0), s.PaidAmount, s.BalanceDue, s.DiscountAmount,
           CASE s.CustomerKind WHEN 'PATIENT' THEN 'P' + CAST(s.PatientId AS VARCHAR(12)) WHEN 'CUSTOMER' THEN 'C' + CAST(s.CustomerId AS VARCHAR(12))
                ELSE 'M' + NULLIF(s.Mobile, '') END,
           s.Status, s.CreatedBy
      FROM dbo.PhSale s
      LEFT JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
      OUTER APPLY (SELECT SUM(x.NetAmount) AS Amount, SUM(x.CostAmount) AS Cost FROM dbo.PhSaleReturn x WHERE x.SaleId = s.SaleId AND x.Status = 'POSTED') r
     WHERE s.CompanyId = @CompanyId AND s.BranchId = @BranchId AND s.Status IN ('POSTED', 'CANCELLED') AND s.SaleDate >= @pStart AND s.SaleDate < @end;

    INSERT #L
    SELECT 'IPD', CASE WHEN x.IssueAt >= @start THEN 1 ELSE 0 END, x.IssueId, x.AdmissionId, x.IssueNo, x.IssueAt,
           NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))), ''),
           a.IpNo, p.PhoneNumber, dm.FullName, ln.Items,
           x.Total, ISNULL(ln.Returned, 0), ISNULL(ln.KeptCost, 0), 0, 0, 0,
           'P' + CAST(a.PatientId AS VARCHAR(12)),
           CASE WHEN ISNULL(ln.Returned, 0) >= x.Total AND x.Total > 0 THEN 'RETURNED' WHEN ISNULL(ln.Returned, 0) > 0 THEN 'PART_RETURN' ELSE 'ISSUED' END,
           x.CreatedBy
      FROM dbo.IpdPhIssue x
      JOIN dbo.IpdAdmission a ON a.AdmissionId = x.AdmissionId
      LEFT JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
      LEFT JOIN dbo.DoctorMaster dm ON dm.DoctorId = x.DoctorId
      OUTER APPLY (SELECT COUNT(*) AS Items,
                          SUM(CAST(ROUND(l.ReturnedQty * l.UnitPrice, 2) AS DECIMAL(18,2))) AS Returned,
                          SUM(CAST(ROUND((l.Qty - l.ReturnedQty) * l.UnitCost, 2) AS DECIMAL(18,2))) AS KeptCost
                     FROM dbo.IpdPhIssueLine l WHERE l.IssueId = x.IssueId) ln
     WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND x.Kind = 'ISSUE' AND x.IssueAt >= @pStart AND x.IssueAt < @end;

    -- 1 one row per channel (always three rows, in this order); cancelled bills count nowhere
    SELECT c.Channel, c.Label,
           COUNT(CASE WHEN l.Cur = 1 THEN 1 END)                                                          AS Bills,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Amount END), 0)                                          AS Gross,
           COUNT(CASE WHEN l.Cur = 1 AND l.Returned > 0 THEN 1 END)                                       AS ReturnCount,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Returned END), 0)                                        AS Returns,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Amount - l.Returned END), 0)                             AS Net,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Cost END), 0)                                            AS Cost,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Paid END), 0)                                            AS Paid,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Due END), 0)                                             AS Due,
           ISNULL(SUM(CASE WHEN l.Cur = 1 THEN l.Discount END), 0)                                        AS Discount,
           COUNT(DISTINCT CASE WHEN l.Cur = 1 THEN l.Buyer END)                                           AS Buyers,
           ISNULL(SUM(CASE WHEN l.Cur = 0 THEN l.Amount - l.Returned END), 0)                             AS PrevNet,
           COUNT(CASE WHEN l.Cur = 0 THEN 1 END)                                                          AS PrevBills
      FROM (VALUES (1, 'POS', N'POS Sales'), (2, 'DIRECT', N'Direct Sales'), (3, 'IPD', N'IPD Sales')) c (Sort, Channel, Label)
      LEFT JOIN #L l ON l.Channel = c.Channel AND l.Status <> 'CANCELLED'
     GROUP BY c.Sort, c.Channel, c.Label
     ORDER BY c.Sort;

    -- 2 net sales per day and channel (every day of the period, zero when nothing was sold)
    ;WITH n AS (SELECT TOP (@days) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS v FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    SELECT DATEADD(DAY, n.v, @From) AS Day,
           ISNULL(SUM(CASE WHEN l.Channel = 'POS'    THEN l.Amount - l.Returned END), 0) AS Pos,
           ISNULL(SUM(CASE WHEN l.Channel = 'DIRECT' THEN l.Amount - l.Returned END), 0) AS Direct,
           ISNULL(SUM(CASE WHEN l.Channel = 'IPD'    THEN l.Amount - l.Returned END), 0) AS Ipd
      FROM n LEFT JOIN #L l ON l.Cur = 1 AND l.Status <> 'CANCELLED' AND CAST(l.DocAt AS DATE) = DATEADD(DAY, n.v, @From)
     GROUP BY n.v
     ORDER BY n.v;

    -- 3 money received in the period by mode (pharmacy bills only; IPD is paid on the IP bill)
    SELECT ISNULL(pm.MethodName, pm.MethodCode) AS Mode,
           SUM(CASE WHEN s.CustomerKind IN ('PATIENT', 'CUSTOMER') THEN 0 ELSE pd.PaidAmount END) AS Pos,
           SUM(CASE WHEN s.CustomerKind IN ('PATIENT', 'CUSTOMER') THEN pd.PaidAmount ELSE 0 END) AS Direct
      FROM dbo.PaymentDetail pd
      JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
      JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
      JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
     WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.BranchId = @BranchId AND s.CompanyId = @CompanyId AND pd.IsActive = 1
       AND pd.CreatedDate >= @start AND pd.CreatedDate < @end
     GROUP BY ISNULL(pm.MethodName, pm.MethodCode)
     ORDER BY SUM(pd.PaidAmount) DESC;

    -- 4 top 10 items of the period by net value (the quantity kept after returns)
    SELECT TOP 10 i.ItemName, SUM(t.Qty) AS Qty, SUM(t.Value) AS Value,
           SUM(CASE WHEN t.Channel = 'POS' THEN t.Value ELSE 0 END)    AS Pos,
           SUM(CASE WHEN t.Channel = 'DIRECT' THEN t.Value ELSE 0 END) AS Direct,
           SUM(CASE WHEN t.Channel = 'IPD' THEN t.Value ELSE 0 END)    AS Ipd
      FROM (SELECT CASE WHEN s.CustomerKind IN ('PATIENT', 'CUSTOMER') THEN 'DIRECT' ELSE 'POS' END AS Channel, x.ItemId, x.Qty - x.ReturnedQty AS Qty,
                   CAST(x.Amount * (x.Qty - x.ReturnedQty) / NULLIF(x.Qty, 0) AS DECIMAL(18,2)) AS Value
              FROM dbo.PhSaleDtl x JOIN dbo.PhSale s ON s.SaleId = x.SaleId
             WHERE s.CompanyId = @CompanyId AND s.BranchId = @BranchId AND s.Status = 'POSTED' AND s.SaleDate >= @start AND s.SaleDate < @end
            UNION ALL
            SELECT 'IPD', l.ItemId, l.Qty - l.ReturnedQty, CAST(ROUND((l.Qty - l.ReturnedQty) * l.UnitPrice, 2) AS DECIMAL(18,2))
              FROM dbo.IpdPhIssueLine l JOIN dbo.IpdPhIssue x ON x.IssueId = l.IssueId
             WHERE x.CompanyId = @CompanyId AND x.BranchId = @BranchId AND x.Kind = 'ISSUE' AND x.IssueAt >= @start AND x.IssueAt < @end) t
      JOIN dbo.PhItem i ON i.ItemId = t.ItemId
     GROUP BY i.ItemId, i.ItemName
    HAVING SUM(t.Value) > 0
     ORDER BY SUM(t.Value) DESC;

    -- the list: documents of the period, filtered by channel and search
    SELECT * INTO #F FROM #L
     WHERE Cur = 1 AND (@Channel IS NULL OR Channel = @Channel)
       AND (@Search IS NULL OR ISNULL(DocNo, '') LIKE @like OR ISNULL(Party, '') LIKE @like OR ISNULL(PartyRef, '') LIKE @like
            OR ISNULL(Mobile, '') LIKE @like OR ISNULL(Doctor, '') LIKE @like);

    -- 5 the requested page (pageSize 0 = every row)
    SELECT f.Channel, f.DocId, f.RefId, f.DocNo, f.DocAt, f.Party, f.PartyRef, f.Mobile, f.Doctor, f.Items, f.Amount, f.Returned,
           CASE WHEN f.Status = 'CANCELLED' THEN 0 ELSE f.Amount - f.Returned END AS Net, f.Paid, f.Due, f.Status,
           (SELECT TOP 1 ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = f.CreatedBy) AS CreatedBy
      FROM #F f
     ORDER BY f.DocAt DESC, f.DocId DESC
    OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;

    -- 6 totals of the filtered documents (cancelled bills count as rows, not as money)
    SELECT COUNT(*) AS TotalRows,
           ISNULL(SUM(CASE WHEN Status <> 'CANCELLED' THEN Amount END), 0)            AS Amount,
           ISNULL(SUM(CASE WHEN Status <> 'CANCELLED' THEN Returned END), 0)          AS Returned,
           ISNULL(SUM(CASE WHEN Status <> 'CANCELLED' THEN Amount - Returned END), 0) AS Net,
           ISNULL(SUM(CASE WHEN Status <> 'CANCELLED' THEN Paid END), 0)              AS Paid,
           ISNULL(SUM(CASE WHEN Status <> 'CANCELLED' THEN Due END), 0)               AS Due,
           COUNT(CASE WHEN Status = 'CANCELLED' THEN 1 END)                           AS Cancelled
      FROM #F;
END
GO

-- ── page: Pharmacy > Sales > Sales Dashboard ─────────────────────────────────────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.SALES';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL; SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.SALES' AND CompanyId = @co;
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'PHARMACY.SALESDASHBOARD', @Title = N'Sales Dashboard',
         @Controller = N'PhSalesDashboard', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 5, @Icon = N'bi bi-bar-chart-line me-2',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhSalesDashboard', @Action = N'Index', @Source = 'SEED';
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2568 applied: Pharmacy Sales Dashboard (POS / Direct / IPD), usp_Api_PhSalesDash_Get, page PHARMACY.SALESDASHBOARD.';
GO
