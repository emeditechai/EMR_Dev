-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2443  Reports > LAB > Marketing Executive Business
--   LAB bills (B2C and B2B) by the marketing executive of their referral doctor (Doctor Master tag, SQLScripts/2441).
--   Bills without a referral doctor, or whose doctor has no executive, are "Not tagged". Same money as Referral Doctor
--   Billing: bill amount, discount, cancelled (net of discount taken back), net, paid, due.
--   Result sets (the LAB report shape): 1 summary · 2 groups: byExecutive (every executive of the scope, even without
--   business, with monthly target, target for the period = monthly target x days / 30.44, achievement % on net) and
--   byDoctor (executive -> doctor) · 3 bills · 4 options (executives) · 5 lines (tests / misc of the bills).
--   Filters: ExecutiveIds (E<id>, NONE; comma list), ExecType (OPD / LAB / IPD / MED), BillingType (B2C / B2B).
--   Page REPORTS.LABMARKETINGBUSINESS (VIEW). Needs 2440, 2441. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_MarketingBusiness
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @ExecutiveIds  VARCHAR(1000) = NULL,   -- E<ExecutiveId> / NONE, comma separated; NULL = all
    @ExecType      VARCHAR(5)    = NULL,   -- OPD / LAB / IPD / MED
    @BillingType   VARCHAR(3)    = NULL,   -- B2C / B2B
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CreatedBy INT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN @UserId END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @Months DECIMAL(9, 4) = (DATEDIFF(DAY, @FromDate, @ToDate) + 1) / 30.44;
    DECLARE @Company INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    SET @ExecType = NULL;   -- this LAB report covers LAB marketing executives only (param kept for the caller)

    DECLARE @Ex TABLE (ExecKey VARCHAR(20) PRIMARY KEY);
    INSERT @Ex SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(ISNULL(@ExecutiveIds, ''), ',') WHERE LTRIM(RTRIM(value)) <> '';
    DECLARE @AnyEx BIT = CASE WHEN EXISTS (SELECT 1 FROM @Ex) THEN 0 ELSE 1 END;

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END AS PartnerName,
        CASE WHEN me.ExecutiveId IS NULL THEN 'NONE' ELSE 'E' + CAST(me.ExecutiveId AS VARCHAR(10)) END AS ExecKey,
        ISNULL(me.ExecutiveName, 'Not tagged') AS ExecutiveName, me.ExecutiveCode, me.ExecutiveType,
        dk.DoctorKey, ISNULL(dk.DoctorName, 'Self / Direct') AS RefDoctorName,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber, NULLIF(LTRIM(RTRIM(p.Gender)), '') AS Gender,
        ISNULL(items.TestCount, 0) AS TestCount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0))
                  ELSE lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) END AS DECIMAL(18, 2)) AS BillAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0
                  WHEN ISNULL(ph.HeaderDiscountAmount, 0) > ISNULL(ph.LineDiscountTotal, 0) THEN ph.HeaderDiscountAmount
                  ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        CAST(ISNULL(canc.CancelledAmount, 0) AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.IsActive = 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) END
                  ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(0 AS DECIMAL(18, 2)) AS DueAmount,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(lo.IsB2B, 0) = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'PAID'
             WHEN ISNULL(lo.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 'PAID'
             WHEN ISNULL(ph.TotalPaid, 0) > 0 THEN 'PARTIAL'
             ELSE 'UNPAID' END AS PaymentStatus,
        CAST(CASE WHEN lo.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT  JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT  JOIN dbo.MarketingExecutive me ON me.ExecutiveId = rdoc.MarketingExecutiveId AND me.IsDeleted = 0 AND me.ExecutiveType = 'LAB'
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    CROSS APPLY (SELECT
        CASE WHEN rdoc.DoctorId IS NOT NULL THEN 'D' + CAST(rdoc.DoctorId AS VARCHAR(10))
             WHEN rd.ReferralDoctorId IS NOT NULL THEN 'R' + CAST(rd.ReferralDoctorId AS VARCHAR(10)) ELSE 'SELF' END AS DoctorKey,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''),
                 NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS DoctorName) dk
    OUTER APPLY (SELECT COUNT(1) AS TestCount FROM dbo.LabOrderItem loi WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    OUTER APPLY (SELECT SUM(ISNULL(bc.CancelledAmount, 0) - ISNULL(bc.DiscountAdjusted, 0)) AS CancelledAmount FROM dbo.BillCancellation bc
                  WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId = lo.LabOrderId AND bc.IsActive = 1) canc
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR me.ExecutiveName LIKE '%' + @Search + '%' OR rdoc.FullName LIKE '%' + @Search + '%');
    DELETE FROM #R WHERE NOT (@AnyEx = 1 OR ExecKey IN (SELECT ExecKey FROM @Ex));
    IF @ExecType IS NOT NULL DELETE FROM #R WHERE ISNULL(ExecutiveType, '') <> @ExecType;
    UPDATE #R SET DueAmount = CASE WHEN IsCancelled = 0 AND NetAmount - PaidAmount > 0 THEN NetAmount - PaidAmount ELSE 0 END;

    -- the executives of the scope (with or without business in the period)
    SELECT 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) AS ExecKey, e.ExecutiveName, e.ExecutiveCode, e.ExecutiveType, e.MonthlyTarget, e.IsActive
    INTO #E
    FROM dbo.MarketingExecutive e
    WHERE e.CompanyId = @Company AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
      AND (@ExecType IS NULL OR e.ExecutiveType = @ExecType)
      AND (@AnyEx = 1 OR 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) IN (SELECT ExecKey FROM @Ex))
      AND (e.IsActive = 1 OR EXISTS (SELECT 1 FROM #R r WHERE r.ExecKey = 'E' + CAST(e.ExecutiveId AS VARCHAR(10))));

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PatientCode) AS PatientCount, COUNT(DISTINCT CASE WHEN DoctorKey <> 'SELF' THEN DoctorKey END) AS DoctorCount,
           (SELECT COUNT(1) FROM #E) AS ExecutiveCount, COUNT(DISTINCT CASE WHEN ExecKey <> 'NONE' THEN ExecKey END) AS ExecutivesWithBusiness,
           SUM(CASE WHEN ExecKey = 'NONE' THEN 1 ELSE 0 END) AS UntaggedBills,
           ISNULL(SUM(TestCount), 0) AS TestCount, ISNULL(SUM(BillAmount), 0) AS BillAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount,
           ISNULL(SUM(DueAmount), 0) AS DueAmount,
           ISNULL(SUM(CASE WHEN ExecKey <> 'NONE' THEN NetAmount END), 0) AS TaggedNetAmount,
           CAST(ISNULL((SELECT SUM(MonthlyTarget) FROM #E), 0) * @Months AS DECIMAL(18, 2)) AS PeriodTarget,
           CAST(@Months AS DECIMAL(9, 2)) AS PeriodMonths
    FROM #R;

    -- RS2 groups: byExecutive (every executive of the scope + Not tagged) and byDoctor (executive -> doctor)
    SELECT 'byExecutive' AS GroupKey, x.ExecKey, x.ExecutiveName, x.ExecutiveCode, x.ExecutiveType, x.MonthlyTarget, x.IsActive,
           CAST(x.MonthlyTarget * @Months AS DECIMAL(18, 2)) AS PeriodTarget,
           CAST(NULL AS VARCHAR(20)) AS DoctorKey, CAST(NULL AS NVARCHAR(200)) AS DoctorName,
           ISNULL(b.DoctorCount, 0) AS DoctorCount, ISNULL(b.BillCount, 0) AS BillCount, ISNULL(b.PatientCount, 0) AS PatientCount, ISNULL(b.TestCount, 0) AS TestCount,
           ISNULL(b.BillAmount, 0) AS BillAmount, ISNULL(b.DiscountAmount, 0) AS DiscountAmount, ISNULL(b.CancelledAmount, 0) AS CancelledAmount,
           ISNULL(b.NetAmount, 0) AS NetAmount, ISNULL(b.PaidAmount, 0) AS PaidAmount, ISNULL(b.DueAmount, 0) AS DueAmount,
           CAST(CASE WHEN x.MonthlyTarget * @Months > 0 THEN ISNULL(b.NetAmount, 0) * 100 / (x.MonthlyTarget * @Months) END AS DECIMAL(9, 1)) AS AchievementPct,
           CASE WHEN x.ExecKey = 'NONE' THEN 1 ELSE 0 END AS SortOrder
    FROM (SELECT ExecKey, ExecutiveName, ExecutiveCode, ExecutiveType, MonthlyTarget, IsActive FROM #E
          UNION ALL
          SELECT 'NONE', 'Not tagged', NULL, NULL, 0, CAST(1 AS BIT) WHERE @ExecType IS NULL AND (@AnyEx = 1 OR EXISTS (SELECT 1 FROM @Ex WHERE ExecKey = 'NONE'))) x
    OUTER APPLY (SELECT COUNT(DISTINCT CASE WHEN r.DoctorKey <> 'SELF' THEN r.DoctorKey END) AS DoctorCount, COUNT(1) AS BillCount, COUNT(DISTINCT r.PatientCode) AS PatientCount,
                        SUM(r.TestCount) AS TestCount, SUM(r.BillAmount) AS BillAmount, SUM(r.DiscountAmount) AS DiscountAmount, SUM(r.CancelledAmount) AS CancelledAmount,
                        SUM(r.NetAmount) AS NetAmount, SUM(r.PaidAmount) AS PaidAmount, SUM(r.DueAmount) AS DueAmount
                 FROM #R r WHERE r.ExecKey = x.ExecKey) b
    UNION ALL
    SELECT 'byDoctor', r.ExecKey, MAX(r.ExecutiveName), MAX(r.ExecutiveCode), MAX(r.ExecutiveType), NULL, NULL, NULL,
           r.DoctorKey, MAX(r.RefDoctorName), 1, COUNT(1), COUNT(DISTINCT r.PatientCode), SUM(r.TestCount),
           SUM(r.BillAmount), SUM(r.DiscountAmount), SUM(r.CancelledAmount), SUM(r.NetAmount), SUM(r.PaidAmount), SUM(r.DueAmount), NULL,
           CASE WHEN r.ExecKey = 'NONE' THEN 1 ELSE 0 END
    FROM #R r GROUP BY r.ExecKey, r.DoctorKey
    ORDER BY GroupKey DESC, SortOrder, NetAmount DESC, ExecutiveName;

    -- RS3 bills (executive, doctor, date)
    SELECT * FROM #R ORDER BY CASE WHEN ExecKey = 'NONE' THEN 1 ELSE 0 END, ExecutiveName, RefDoctorName, BillDate, LabOrderId;

    -- RS4 options: the company's executives, and Not tagged
    SELECT 'executive' AS FilterKey, 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) AS Value,
           e.ExecutiveName + N' — ' + CASE e.ExecutiveType WHEN 'MED' THEN N'MED (Pharmacy)' ELSE e.ExecutiveType END + N' (' + e.ExecutiveCode + N')'
               + CASE WHEN e.IsActive = 0 THEN N' · inactive' ELSE N'' END AS Text
    FROM dbo.MarketingExecutive e WHERE e.CompanyId = @Company AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
    UNION ALL SELECT 'executive', 'NONE', N'Not tagged'
    ORDER BY 3;

    -- RS5 lines of the bills (tests / profiles / packages, cancelled ones marked, misc charges)
    SELECT x.LabOrderId, ROW_NUMBER() OVER (PARTITION BY x.LabOrderId ORDER BY x.Kind, x.ItemId) AS LineSeq, x.TestCode, x.TestName, x.ItemType, x.Rate, x.IsCancelled
      FROM (
    SELECT loi.LabOrderId, 0 AS Kind, loi.LabOrderItemId AS ItemId,
           CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
           ISNULL(CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END, 'Unknown test') AS TestName,
           CASE WHEN loi.Type = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           CAST(CASE WHEN r.BillingType = 'B2B' THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END AS DECIMAL(18, 2)) AS Rate,
           CAST(CASE WHEN loi.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled
      FROM #R r JOIN dbo.LabOrderItem loi ON loi.LabOrderId = r.LabOrderId
      LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
      LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    UNION ALL
    SELECT mc.LabOrderId, 1, mc.LabOrderMiscChargeId, 'MISC', mc.ChargeName, 'Misc', CAST(ISNULL(mc.NetAmount, mc.Amount) AS DECIMAL(18, 2)),
           CAST(CASE WHEN mc.IsActive = 0 THEN 1 ELSE 0 END AS BIT)
      FROM #R r JOIN dbo.LabOrderMiscCharge mc ON mc.LabOrderId = r.LabOrderId
      ) x
     ORDER BY x.LabOrderId, LineSeq;

    DROP TABLE #R; DROP TABLE #E;
END;
GO

-- ── page: Reports > LAB > Marketing Executive Business ─────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @co INT = 1, @menu INT = (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB'), @page INT, @view INT;
IF @menu IS NULL THROW 51430, 'Menu REPORTS.LAB is missing.', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABMARKETINGBUSINESS', @Title = N'Marketing Executive Business',
     @Controller = N'Reports', @Action = N'LabMarketingBusiness', @Show_In_Menu = 1, @Sort_Order = 16, @Icon = N'bi bi-person-badge me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Reports', @Action = N'LabMarketingBusiness', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabOrderBooking', @Action = N'PrintBill', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2443 Marketing Executive Business report - done.';
GO
