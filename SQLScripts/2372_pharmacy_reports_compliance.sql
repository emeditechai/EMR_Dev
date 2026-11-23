-- ============================================================================================================
-- Migration: 2372_pharmacy_reports_compliance.sql
-- Reports > Pharmacy, statutory & compliance (C2, C3 of the Pharmacy Reports plan), read through EMR.Api.
--   C2 Schedule X / NDPS register: drugs whose schedule is narcotic (X, NDPS). Register view (default): each drug's opening balance, then every
--      receipt and issue with the supplier / invoice or the patient, address, prescriber, reg. no. and Rx no., and the running balance
--      (the statutory register). @Option DAILY: per drug per day - opening, received, sold, other out, closing.
--   C3 Prescription (Rx) sales register: bills with prescription-only drugs (schedules H, H1, X, NDPS): doctor, reg. no., Rx no. / date, the Rx items;
--      bills without the doctor or Rx number are flagged (@Option MISSING).
-- Quantities in sale units. Run after 2371. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── C2 Schedule X / NDPS register ────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_NdpsRegister
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT i.ItemId, i.ItemCode, i.ItemName, i.Strength, i.ScheduleCode, su.UomCode AS SaleUom
      INTO #I
      FROM dbo.PhItem i JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
     WHERE i.CompanyId = @CompanyId AND sc.IsNarcotic = 1 AND (@Schedule IS NULL OR i.ScheduleCode = @Schedule)
       AND (@Search IS NULL OR i.ItemName LIKE @like OR i.ItemCode = @Search);
    -- every movement of those drugs, with who it came from / went to
    SELECT l.LedgerId, l.ItemId, l.TxnDate, l.DocType, l.DocNo, b.BatchNo, l.QtyIn, l.QtyOut, l.BranchId,
           CASE WHEN l.TxnDate < @From THEN 1 ELSE 0 END AS Before,
           CASE l.DocType WHEN 'GRN' THEN (SELECT sp.SupplierName + ISNULL(N' · inv ' + g.InvoiceNo, N'') + ISNULL(N' · DL ' + sp.DrugLicenceNo, N'')
                                             FROM dbo.PhGrn g JOIN dbo.PhSupplier sp ON sp.SupplierId = g.SupplierId WHERE g.GrnId = l.DocId)
                          WHEN 'PRET' THEN (SELECT N'Returned to ' + sp.SupplierName FROM dbo.PhPurchaseReturn r JOIN dbo.PhSupplier sp ON sp.SupplierId = r.SupplierId WHERE r.ReturnId = l.DocId)
                          ELSE dbo.fn_PhLedgerDocName(l.DocType) END AS Party,
           COALESCE(sr.PatientName, NULLIF(sa.CustomerName, N'')) AS PatientName, COALESCE(sr.PatientAddress, NULLIF(sa.Address, N'')) AS PatientAddress,
           COALESCE(sr.PrescriberName, NULLIF(sa.DoctorName, N'')) AS PrescriberName, COALESCE(sr.PrescriberRegNo, NULLIF(sa.DoctorRegNo, N'')) AS PrescriberRegNo,
           COALESCE(sr.RxNo, NULLIF(sa.RxNo, N'')) AS RxNo
      INTO #M
      FROM dbo.PhStockLedger l JOIN #I i ON i.ItemId = l.ItemId JOIN dbo.PhBatch b ON b.BatchId = l.BatchId
      OUTER APPLY (SELECT TOP 1 r.PatientName, r.PatientAddress, r.PrescriberName, r.PrescriberRegNo, r.RxNo FROM dbo.PhScheduleRegister r
                    WHERE l.DocType IN ('SALE', 'SCAN') AND r.SaleId = l.DocId AND r.BatchId = l.BatchId ORDER BY r.RegisterId) sr
      LEFT JOIN dbo.PhSale sa ON l.DocType IN ('SALE', 'SCAN') AND sa.SaleId = l.DocId   -- the bill's own details when the register has no entry
     WHERE (@BranchId IS NULL OR l.BranchId = @BranchId) AND l.TxnDate < @end AND l.DocType NOT IN ('ISO', 'ISI');   -- store to store: no change for the branch

    CREATE TABLE #R (Rn INT, ItemCode NVARCHAR(40), ItemName NVARCHAR(200), ScheduleCode VARCHAR(10), SaleUom NVARCHAR(20), EntryDate DATETIME, DocNo NVARCHAR(60),
                     Particulars NVARCHAR(300), BatchNo NVARCHAR(40), PatientName NVARCHAR(200), PatientAddress NVARCHAR(400), Prescriber NVARCHAR(200), PrescriberRegNo NVARCHAR(60),
                     RxNo NVARCHAR(60), Opening DECIMAL(18,3), Received DECIMAL(18,3), Issued DECIMAL(18,3), OtherOut DECIMAL(18,3), Balance DECIMAL(18,3), RowKind VARCHAR(10));
    IF @Option = 'DAILY'
    BEGIN
        -- per drug per day: opening, received (purchases, returns from patients, transfers in), sold, other out, closing
        WITH d AS (
            SELECT ItemId, CAST(TxnDate AS DATE) AS Day,
                   SUM(CASE WHEN DocType IN ('GRN', 'SRET', 'SCAN', 'TRFI') OR (DocType IN ('ADJ', 'PCNT') AND QtyIn > 0) THEN QtyIn ELSE 0 END) AS Received,
                   SUM(CASE WHEN DocType = 'SALE' THEN QtyOut ELSE 0 END) AS Sold,
                   SUM(CASE WHEN DocType <> 'SALE' THEN QtyOut ELSE 0 END) AS OtherOut
              FROM #M WHERE Before = 0 GROUP BY ItemId, CAST(TxnDate AS DATE))
        INSERT #R
        SELECT ROW_NUMBER() OVER (ORDER BY i.ItemName, d.Day), i.ItemCode, i.ItemName, i.ScheduleCode, i.SaleUom, d.Day, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               ISNULL((SELECT SUM(QtyIn - QtyOut) FROM #M m WHERE m.ItemId = d.ItemId AND m.TxnDate < d.Day), 0),
               d.Received, d.Sold, d.OtherOut,
               ISNULL((SELECT SUM(QtyIn - QtyOut) FROM #M m WHERE m.ItemId = d.ItemId AND m.TxnDate < DATEADD(DAY, 1, d.Day)), 0), 'DAY'
          FROM d JOIN #I i ON i.ItemId = d.ItemId;
    END
    ELSE
    BEGIN
        -- the register: an opening line per drug, then each movement with the running balance
        INSERT #R
        SELECT 0, i.ItemCode, i.ItemName, i.ScheduleCode, i.SaleUom, CAST(@From AS DATETIME), NULL, N'Opening balance', NULL, NULL, NULL, NULL, NULL, NULL,
               ISNULL((SELECT SUM(QtyIn - QtyOut) FROM #M m WHERE m.ItemId = i.ItemId AND m.Before = 1), 0), NULL, NULL, NULL,
               ISNULL((SELECT SUM(QtyIn - QtyOut) FROM #M m WHERE m.ItemId = i.ItemId AND m.Before = 1), 0), 'OPEN'
          FROM #I i
         WHERE EXISTS (SELECT 1 FROM #M m WHERE m.ItemId = i.ItemId);
        INSERT #R
        SELECT 0, i.ItemCode, i.ItemName, i.ScheduleCode, i.SaleUom, m.TxnDate, m.DocNo, m.Party, m.BatchNo, m.PatientName, m.PatientAddress, m.PrescriberName, m.PrescriberRegNo, m.RxNo,
               NULL, NULLIF(m.QtyIn, 0), CASE WHEN m.DocType = 'SALE' THEN NULLIF(m.QtyOut, 0) END, CASE WHEN m.DocType <> 'SALE' THEN NULLIF(m.QtyOut, 0) END,
               SUM(m.QtyIn - m.QtyOut) OVER (PARTITION BY m.ItemId ORDER BY m.TxnDate, m.LedgerId ROWS UNBOUNDED PRECEDING), 'MOVE'
          FROM #M m JOIN #I i ON i.ItemId = m.ItemId
         WHERE m.Before = 1 OR m.Before = 0;
        DELETE r FROM #R r WHERE r.RowKind = 'MOVE' AND r.EntryDate < @From;    -- earlier movements only made the running balance
        WITH o AS (SELECT Rn, ROW_NUMBER() OVER (ORDER BY ItemName, CASE RowKind WHEN 'OPEN' THEN 0 ELSE 1 END, EntryDate) AS k FROM #R) UPDATE o SET Rn = k;
    END

    SELECT COUNT(DISTINCT ItemCode) AS Drugs, ISNULL(SUM(Received), 0) AS Received, ISNULL(SUM(Issued), 0) AS Issued, ISNULL(SUM(OtherOut), 0) AS OtherOut,
           ISNULL(SUM(CASE WHEN RowKind = 'MOVE' AND Issued > 0 AND (NULLIF(LTRIM(Prescriber), N'') IS NULL OR NULLIF(LTRIM(RxNo), N'') IS NULL) THEN 1 ELSE 0 END), 0) AS MissingRx,
           (SELECT ISNULL(SUM(QtyIn - QtyOut), 0) FROM #M) AS ClosingStock
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(Received) AS Received, SUM(Issued) AS Issued, SUM(OtherOut) AS OtherOut FROM #R;
END
GO

-- ── C3 Prescription (Rx) sales register ──────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_PhRpt_RxSalesRegister
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Page INT = 1, @PageSize INT = 50,
    @UserId INT = NULL, @Mode VARCHAR(10) = NULL, @Kind VARCHAR(10) = NULL, @CategoryId INT = NULL, @ManufacturerId INT = NULL,
    @Schedule VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL, @Option VARCHAR(20) = NULL, @SupplierId INT = NULL, @StoreId INT = NULL, @LedgerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%', @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT s.SaleId, d.SaleDtlId, i.ItemName, i.ScheduleCode, d.Qty, su.UomCode, d.Amount
      INTO #D
      FROM dbo.PhSale s JOIN dbo.PhSaleDtl d ON d.SaleId = s.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
     WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED' AND s.SaleDate >= @From AND s.SaleDate < @end
       AND (sc.RxRequired = 1 OR i.PrescriptionRequired = 1) AND (@Schedule IS NULL OR i.ScheduleCode = @Schedule);
    SELECT ROW_NUMBER() OVER (ORDER BY s.SaleDate, s.SaleId) AS Rn, s.SaleId, b.BranchCode, s.SaleNo, s.SaleDate,
           ISNULL(NULLIF(s.CustomerName, N''), N'Walk-in') AS Patient, pm.PatientCode, s.Mobile, s.Address,
           NULLIF(LTRIM(RTRIM(s.DoctorName)), N'') AS Doctor, NULLIF(LTRIM(RTRIM(s.DoctorRegNo)), N'') AS DoctorRegNo, NULLIF(LTRIM(RTRIM(s.RxNo)), N'') AS RxNo, s.RxDate,
           (SELECT STRING_AGG(x.ItemName + N' (' + x.ScheduleCode + N') x ' + FORMAT(x.Qty, '0.##') + N' ' + x.UomCode, N'; ') FROM #D x WHERE x.SaleId = s.SaleId) AS RxItems,
           (SELECT COUNT(*) FROM #D x WHERE x.SaleId = s.SaleId) AS RxLines,
           (SELECT SUM(x.Amount) FROM #D x WHERE x.SaleId = s.SaleId) AS RxValue,
           STUFF(CONCAT(CASE WHEN NULLIF(LTRIM(RTRIM(s.DoctorName)), N'') IS NULL THEN N', doctor' END, CASE WHEN NULLIF(LTRIM(RTRIM(s.DoctorRegNo)), N'') IS NULL THEN N', reg. no.' END,
                        CASE WHEN NULLIF(LTRIM(RTRIM(s.RxNo)), N'') IS NULL THEN N', Rx no.' END,
                        CASE WHEN EXISTS (SELECT 1 FROM #D x WHERE x.SaleId = s.SaleId AND x.ScheduleCode IN ('H1', 'X', 'NDPS')) AND NULLIF(LTRIM(RTRIM(s.Address)), N'') IS NULL THEN N', patient address' END), 1, 2, N'') AS Missing,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CreatedBy) AS DispensedBy
      INTO #G
      FROM dbo.PhSale s JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
     WHERE s.SaleId IN (SELECT SaleId FROM #D) AND (@UserId IS NULL OR s.CreatedBy = @UserId)
       AND (@Search IS NULL OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.DoctorName LIKE @like OR s.RxNo LIKE @like OR s.DoctorRegNo LIKE @like);
    SELECT * , CASE WHEN Missing IS NULL THEN N'Recorded' ELSE N'Missing: ' + Missing END AS RxStatus INTO #R FROM #G
     WHERE ISNULL(@Option, '') <> 'MISSING' OR Missing IS NOT NULL;

    SELECT COUNT(*) AS Bills, ISNULL(SUM(RxLines), 0) AS RxLines, ISNULL(SUM(RxValue), 0) AS RxValue, ISNULL(SUM(CASE WHEN Missing IS NULL THEN 1 ELSE 0 END), 0) AS Recorded,
           ISNULL(SUM(CASE WHEN Missing IS NOT NULL THEN 1 ELSE 0 END), 0) AS MissingRx,
           CASE WHEN COUNT(*) = 0 THEN 0 ELSE SUM(CASE WHEN Missing IS NULL THEN 1.0 ELSE 0 END) * 100 / COUNT(*) END AS CompliancePct
      FROM #R;
    SELECT * FROM #R ORDER BY Rn OFFSET (CASE WHEN @PageSize > 0 THEN (@Page - 1) * @PageSize ELSE 0 END) ROWS
     FETCH NEXT (CASE WHEN @PageSize > 0 THEN @PageSize ELSE 2147483647 END) ROWS ONLY;
    SELECT COUNT(*) AS TotalRows, SUM(RxLines) AS RxLines, SUM(RxValue) AS RxValue FROM #R;
END
GO

-- ── menu: pages under Reports > Pharmacy ─────────────────────────────────────────────────────────────────
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100));
INSERT @Pages VALUES
 (N'REPORTS.PHARMACY.NDPSREGISTER',    N'Schedule X / NDPS Register',        N'NdpsRegister',    560, N'bi bi-shield-lock me-2'),
 (N'REPORTS.PHARMACY.RXSALESREGISTER', N'Prescription (Rx) Sales Register',  N'RxSalesRegister', 570, N'bi bi-prescription me-2');

DECLARE @co INT, @reports INT, @ph INT, @page INT, @view INT, @exp INT, @pc NVARCHAR(100), @title NVARCHAR(150), @action NVARCHAR(100), @sort INT, @icon NVARCHAR(100);
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS';
OPEN co; FETCH NEXT FROM co INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @reports = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS' AND CompanyId = @co;
    SET @ph = NULL;
    EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @reports, @Menu_Type = 'MENU', @Menu_Code = N'REPORTS.PHARMACY', @Title = N'Pharmacy',
         @Icon = N'bi bi-capsule-pill me-2', @Sort_Order = 25, @UserId = NULL, @Menu_ID = @ph OUTPUT;
    DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
    OPEN p; FETCH NEXT FROM p INTO @pc, @title, @action, @sort, @icon;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @ph, @Page_Code = @pc, @Title = @title, @Controller = N'PhReports', @Action = @action,
             @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @exp = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EXPORT', @Title = N'Export to Excel / PDF', @Sort_Order = 20, @Control_ID = @exp OUTPUT;
        DECLARE @a1 NVARCHAR(100) = @action, @a2 NVARCHAR(100) = @action + N'Data', @a3 NVARCHAR(100) = @action + N'Export';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a1, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a2, @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @exp, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhReports', @Action = @a3, @Source = 'SEED';
        FETCH NEXT FROM p INTO @pc, @title, @action, @sort, @icon;
    END
    CLOSE p; DEALLOCATE p;
    FETCH NEXT FROM co INTO @co;
END
CLOSE co; DEALLOCATE co;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2372 applied: Reports > Pharmacy, Schedule X / NDPS register (C2) and Rx sales register (C3).';
GO
