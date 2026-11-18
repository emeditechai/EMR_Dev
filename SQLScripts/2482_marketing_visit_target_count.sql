-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2482  Marketing visit target: count one visit per doctor per day, and an app visit only when it was Verified.
--   New: dbo.fn_Mkt_TargetVisits. Uses it (only the visit count changes, nothing else in them):
--     usp_Mkt_MyTarget (app My Target), usp_Api_MktTarget_Get (LAB > Marketing Executive Sales Target),
--     usp_Api_LabReport_MarketingBusiness (Reports > LAB > Marketing Executive Business), usp_Api_LabReport_OwnerMis.
--   Before: every visit row counted (repeat visits, Outside / Unconfirmed visits, the web log and the app twice).
--   Needs 2447, 2449, 2458. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
-- the visits that count against a visit target: one per executive, doctor and day.
--   Doctor Visit Log entries (web, entered by the office) count; app visits count only when VERIFIED.
--   A lead already added to Doctor Master is the same doctor in both, so a day is not counted twice.
CREATE OR ALTER FUNCTION dbo.fn_Mkt_TargetVisits (@From DATETIME, @To DATETIME)
RETURNS TABLE
AS
RETURN
    SELECT mv.BranchId, mv.ExecutiveId, CAST(mv.VisitDate AS DATE) AS VisitDay, 'D' + CAST(mv.DoctorId AS VARCHAR(12)) AS DoctorKey
      FROM dbo.MarketingDoctorVisit mv
     WHERE mv.IsDeleted = 0 AND mv.VisitDate >= @From AND mv.VisitDate < @To
    UNION
    SELECT fv.BranchId, fv.ExecutiveId, CAST(fv.VisitDate AS DATE),
           CASE WHEN fd.DoctorId IS NOT NULL THEN 'D' + CAST(fd.DoctorId AS VARCHAR(12)) ELSE 'F' + CAST(fv.ForecastDoctorId AS VARCHAR(12)) END
      FROM dbo.ForecastDoctorVisit fv
      JOIN dbo.ForecastDoctor fd ON fd.ForecastDoctorId = fv.ForecastDoctorId
     WHERE fv.VisitStatus = 'VERIFIED' AND fv.VisitDate >= @From AND fv.VisitDate < @To;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Mkt_MyTarget
    @UserId    INT,
    @CompanyId INT,
    @BranchId  INT,
    @FyStart   DATE = NULL      -- any date in the year wanted; NULL = the current financial year
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Exec INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @Exec IS NULL THROW 50000, 'No marketing executive uses this login. Contact the office.', 1;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @CurFy DATE = dbo.fn_Mkt_FyStart(@CompanyId, @Today);
    SET @FyStart = dbo.fn_Mkt_FyStart(@CompanyId, ISNULL(@FyStart, @Today));
    -- the previous, current and next year only
    IF @FyStart < DATEADD(YEAR, -1, @CurFy) OR @FyStart > DATEADD(YEAR, 1, @CurFy)
        THROW 50000, 'Targets can be seen for the previous, current and next financial year only.', 1;

    DECLARE @IsLab BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.MarketingExecutive WHERE ExecutiveId = @Exec AND ExecutiveType = 'LAB') THEN 1 ELSE 0 END;
    DECLARE @TargetId INT, @Frequency VARCHAR(10);
    SELECT @TargetId = TargetId, @Frequency = Frequency FROM dbo.MarketingTarget
     WHERE BranchId = @BranchId AND ExecutiveId = @Exec AND FyStart = @FyStart AND CompanyId = @CompanyId;

    -- the periods of the saved frequency (monthly when no target is set, so the actuals still show month by month)
    CREATE TABLE #P (BucketNo TINYINT, PeriodLabel NVARCHAR(40), FromDate DATE, ToDate DATE, SalesTarget DECIMAL(18,2), VisitTarget INT,
                     IsPast BIT, IsCurrent BIT, SalesActual DECIMAL(18,2), VisitActual INT);
    IF @IsLab = 1
        INSERT #P
        SELECT g.BucketNo, g.PeriodLabel, g.FromDate, g.ToDate,
               CAST(ISNULL(s.SalesTarget, 0) AS DECIMAL(18,2)), ISNULL(s.VisitTarget, 0),
               CAST(CASE WHEN g.ToDate < @Today THEN 1 ELSE 0 END AS BIT),
               CAST(CASE WHEN @Today BETWEEN g.FromDate AND g.ToDate THEN 1 ELSE 0 END AS BIT),
               CAST(ISNULL(sale.NetAmount, 0) AS DECIMAL(18,2)), ISNULL(v.Visits, 0)
        FROM dbo.fn_Mkt_Buckets(@FyStart, ISNULL(@Frequency, 'MONTHLY')) g
        LEFT JOIN dbo.MarketingTargetBucket s ON s.TargetId = @TargetId AND s.BucketNo = g.BucketNo
        -- the same sales figure as usp_Api_MktTarget_Get and Reports > LAB > Marketing Executive Business
        OUTER APPLY (SELECT SUM(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.IsActive = 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) END
                                     ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END) AS NetAmount
                     FROM dbo.LabOrder lo
                     LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
                     WHERE lo.BranchId = @BranchId AND lo.MarketingExecutiveId = @Exec AND g.FromDate <= @Today
                       AND lo.OrderDate >= g.FromDate AND lo.OrderDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) sale
        OUTER APPLY (SELECT COUNT(1) AS Visits FROM dbo.fn_Mkt_TargetVisits(g.FromDate, DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) tv
                 WHERE tv.BranchId = @BranchId AND tv.ExecutiveId = @Exec) v   -- 2482: one per doctor per day, app visits Verified only;

    -- RS1 header: the year, the frequency and the year's totals
    SELECT e.ExecutiveName, e.ExecutiveCode, e.ExecutiveType, @IsLab AS IsLab,
           (SELECT BranchName FROM dbo.Branchmaster WHERE BranchID = @BranchId) AS BranchName,
           @FyStart AS FyStart, DATEADD(DAY, -1, DATEADD(YEAR, 1, @FyStart)) AS FyEnd,
           dbo.fn_Acc_FinancialYear(@FyStart, MONTH(@FyStart)) AS FyLabel,
           CAST(CASE WHEN @FyStart = @CurFy THEN 1 ELSE 0 END AS BIT) AS IsCurrentYear,
           DATEADD(YEAR, -1, @CurFy) AS PreviousFyStart, @CurFy AS CurrentFyStart,
           CAST(CASE WHEN @TargetId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasTarget, @Frequency AS Frequency, t.Remarks,
           ISNULL(t.ModifiedDate, t.CreatedDate) AS LastChanged,
           CAST(ISNULL((SELECT SUM(SalesTarget) FROM #P), 0) AS DECIMAL(18,2)) AS YearSalesTarget,
           CAST(ISNULL((SELECT SUM(SalesActual) FROM #P), 0) AS DECIMAL(18,2)) AS YearSalesActual,
           ISNULL((SELECT SUM(VisitTarget) FROM #P), 0) AS YearVisitTarget,
           ISNULL((SELECT SUM(VisitActual) FROM #P), 0) AS YearVisitActual
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.MarketingTarget t ON t.TargetId = @TargetId
    WHERE e.ExecutiveId = @Exec;

    -- RS2 the periods
    SELECT BucketNo, PeriodLabel, FromDate, ToDate, SalesTarget, SalesActual, VisitTarget, VisitActual, IsPast, IsCurrent
    FROM #P ORDER BY BucketNo;
END;
GO

-- one executive's target for a year. @Frequency NULL = the saved one (MONTHLY when nothing is saved); another frequency
-- returns its empty buckets (the screen asks before replacing the saved ones). RS1 header, RS2 buckets with actuals so far.
CREATE OR ALTER PROCEDURE dbo.usp_Api_MktTarget_Get @CompanyId INT, @BranchId INT, @ExecutiveId INT, @FyStart DATE, @Frequency VARCHAR(10) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own INT = dbo.fn_Mkt_OwnExecutive(@CompanyId, @UserId);
    IF @own IS NOT NULL AND @own <> @ExecutiveId THROW 56101, 'You can see your own target only.', 1;
    DECLARE @TargetId INT, @Saved VARCHAR(10);
    SELECT @TargetId = TargetId, @Saved = Frequency FROM dbo.MarketingTarget WHERE BranchId = @BranchId AND ExecutiveId = @ExecutiveId AND FyStart = @FyStart;
    SET @Frequency = ISNULL(NULLIF(UPPER(@Frequency), ''), ISNULL(@Saved, 'MONTHLY'));
    IF @Frequency NOT IN ('MONTHLY','QUARTERLY','HALFYEARLY','YEARLY') THROW 56102, 'Choose the frequency.', 1;

    SELECT e.ExecutiveId, e.ExecutiveName, e.ExecutiveCode, e.IsActive, @FyStart AS FyStart, DATEADD(DAY, -1, DATEADD(YEAR, 1, @FyStart)) AS FyEnd,
           dbo.fn_Acc_FinancialYear(@FyStart, MONTH(@FyStart)) AS FyLabel, @Frequency AS Frequency, @Saved AS SavedFrequency, @TargetId AS TargetId,
           t.Remarks, t.CreatedDate, uc.FullName AS CreatedByName, t.ModifiedDate, um.FullName AS ModifiedByName,
           CAST(CASE WHEN @own IS NULL THEN 0 ELSE 1 END AS BIT) AS IsOwnView
    FROM dbo.MarketingExecutive e
    LEFT JOIN dbo.MarketingTarget t ON t.TargetId = @TargetId
    LEFT JOIN dbo.Users uc ON uc.Id = t.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = t.ModifiedBy
    WHERE e.ExecutiveId = @ExecutiveId AND e.CompanyId = @CompanyId AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB';
    IF @@ROWCOUNT = 0 THROW 56103, 'The LAB marketing executive was not found.', 1;

    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT g.BucketNo, g.PeriodLabel, g.FromDate, g.ToDate,
           CAST(ISNULL(s.SalesTarget, 0) AS DECIMAL(18,2)) AS SalesTarget, ISNULL(s.VisitTarget, 0) AS VisitTarget,
           CAST(CASE WHEN g.ToDate < @today THEN 1 ELSE 0 END AS BIT) AS IsPast,
           CAST(CASE WHEN @today BETWEEN g.FromDate AND g.ToDate THEN 1 ELSE 0 END AS BIT) AS IsCurrent,
           CAST(ISNULL(sale.NetAmount, 0) AS DECIMAL(18,2)) AS SalesActual, ISNULL(v.Visits, 0) AS VisitActual
    FROM dbo.fn_Mkt_Buckets(@FyStart, @Frequency) g
    LEFT JOIN dbo.MarketingTargetBucket s ON s.TargetId = @TargetId AND @Saved = @Frequency AND s.BucketNo = g.BucketNo
    OUTER APPLY (SELECT SUM(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.IsActive = 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) END
                                 ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END) AS NetAmount
                 FROM dbo.LabOrder lo
                 LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
                 WHERE lo.BranchId = @BranchId AND lo.MarketingExecutiveId = @ExecutiveId AND g.FromDate <= @today
                   AND lo.OrderDate >= g.FromDate AND lo.OrderDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) sale
    OUTER APPLY (SELECT COUNT(1) AS Visits FROM dbo.fn_Mkt_TargetVisits(g.FromDate, DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) tv
                 WHERE tv.BranchId = @BranchId AND tv.ExecutiveId = @ExecutiveId) v   -- 2482: one per doctor per day, app visits Verified only
    ORDER BY g.BucketNo;
END;
GO

-- ── Reports > LAB > Marketing Executive Business: targets from the Sales Target setup (2446) ──────────────────────
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
    LEFT  JOIN dbo.MarketingExecutive me ON me.ExecutiveId = lo.MarketingExecutiveId /* 2445 */ AND me.IsDeleted = 0 AND me.ExecutiveType = 'LAB'
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
    SELECT 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) AS ExecKey, e.ExecutiveName, e.ExecutiveCode, e.ExecutiveType, e.MonthlyTarget, e.IsActive,
           CAST(0 AS DECIMAL(18, 2)) AS PeriodTarget, CAST(0 AS DECIMAL(18, 1)) AS VisitTarget, 0 AS VisitCount, CAST(NULL AS VARCHAR(10)) AS Frequency
    INTO #E
    FROM dbo.MarketingExecutive e
    WHERE e.CompanyId = @Company AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
      AND (@ExecType IS NULL OR e.ExecutiveType = @ExecType)
      AND (@AnyEx = 1 OR 'E' + CAST(e.ExecutiveId AS VARCHAR(10)) IN (SELECT ExecKey FROM @Ex))
      AND (e.IsActive = 1 OR EXISTS (SELECT 1 FROM #R r WHERE r.ExecKey = 'E' + CAST(e.ExecutiveId AS VARCHAR(10))));

    -- 2446: targets from LAB > Marketing Executive Sales Target (this branch): each bucket pro-rated by the days of the period inside it
    UPDATE x SET PeriodTarget = ISNULL(t.Sales, 0), VisitTarget = ISNULL(t.Visit, 0), Frequency = t.Frequency,
                 VisitCount = (SELECT COUNT(1) FROM dbo.fn_Mkt_TargetVisits(@From, @To) tv   -- 2482
                               WHERE tv.BranchId = @BranchId AND 'E' + CAST(tv.ExecutiveId AS VARCHAR(10)) = x.ExecKey)
    FROM #E x
    OUTER APPLY (SELECT SUM(b.SalesTarget * o.Days / (DATEDIFF(DAY, b.FromDate, b.ToDate) + 1.0)) AS Sales,
                        SUM(b.VisitTarget * o.Days / (DATEDIFF(DAY, b.FromDate, b.ToDate) + 1.0)) AS Visit,
                        MAX(mt.Frequency) AS Frequency
                 FROM dbo.MarketingTarget mt
                 JOIN dbo.MarketingTargetBucket b ON b.TargetId = mt.TargetId
                 CROSS APPLY (SELECT DATEDIFF(DAY, CASE WHEN b.FromDate > @FromDate THEN b.FromDate ELSE @FromDate END,
                                                   CASE WHEN b.ToDate < @ToDate THEN b.ToDate ELSE @ToDate END) + 1 AS Days) o
                 WHERE mt.BranchId = @BranchId AND 'E' + CAST(mt.ExecutiveId AS VARCHAR(10)) = x.ExecKey
                   AND b.FromDate <= @ToDate AND b.ToDate >= @FromDate) t;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT PatientCode) AS PatientCount, COUNT(DISTINCT CASE WHEN DoctorKey <> 'SELF' THEN DoctorKey END) AS DoctorCount,
           (SELECT COUNT(1) FROM #E) AS ExecutiveCount, COUNT(DISTINCT CASE WHEN ExecKey <> 'NONE' THEN ExecKey END) AS ExecutivesWithBusiness,
           SUM(CASE WHEN ExecKey = 'NONE' THEN 1 ELSE 0 END) AS UntaggedBills,
           ISNULL(SUM(TestCount), 0) AS TestCount, ISNULL(SUM(BillAmount), 0) AS BillAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount,
           ISNULL(SUM(DueAmount), 0) AS DueAmount,
           ISNULL(SUM(CASE WHEN ExecKey <> 'NONE' THEN NetAmount END), 0) AS TaggedNetAmount,
           CAST(ISNULL((SELECT SUM(PeriodTarget) FROM #E), 0) AS DECIMAL(18, 2)) AS PeriodTarget,
           CAST(ISNULL((SELECT SUM(VisitTarget) FROM #E), 0) AS DECIMAL(18, 1)) AS VisitTarget, ISNULL((SELECT SUM(VisitCount) FROM #E), 0) AS VisitCount,
           CAST(@Months AS DECIMAL(9, 2)) AS PeriodMonths
    FROM #R;

    -- RS2 groups: byExecutive (every executive of the scope + Not tagged) and byDoctor (executive -> doctor)
    SELECT 'byExecutive' AS GroupKey, x.ExecKey, x.ExecutiveName, x.ExecutiveCode, x.ExecutiveType, x.MonthlyTarget, x.IsActive,
           x.PeriodTarget,
           CAST(NULL AS VARCHAR(20)) AS DoctorKey, CAST(NULL AS NVARCHAR(200)) AS DoctorName,
           ISNULL(b.DoctorCount, 0) AS DoctorCount, ISNULL(b.BillCount, 0) AS BillCount, ISNULL(b.PatientCount, 0) AS PatientCount, ISNULL(b.TestCount, 0) AS TestCount,
           ISNULL(b.BillAmount, 0) AS BillAmount, ISNULL(b.DiscountAmount, 0) AS DiscountAmount, ISNULL(b.CancelledAmount, 0) AS CancelledAmount,
           ISNULL(b.NetAmount, 0) AS NetAmount, ISNULL(b.PaidAmount, 0) AS PaidAmount, ISNULL(b.DueAmount, 0) AS DueAmount,
           CAST(CASE WHEN x.PeriodTarget > 0 THEN ISNULL(b.NetAmount, 0) * 100 / x.PeriodTarget END AS DECIMAL(9, 1)) AS AchievementPct,
           CASE WHEN x.ExecKey = 'NONE' THEN 1 ELSE 0 END AS SortOrder,
           x.VisitTarget, x.VisitCount, CAST(CASE WHEN x.VisitTarget > 0 THEN x.VisitCount * 100.0 / x.VisitTarget END AS DECIMAL(9, 1)) AS VisitAchievementPct, x.Frequency
    FROM (SELECT ExecKey, ExecutiveName, ExecutiveCode, ExecutiveType, MonthlyTarget, IsActive, PeriodTarget, VisitTarget, VisitCount, Frequency FROM #E
          UNION ALL
          SELECT 'NONE', 'Not tagged', NULL, NULL, 0, CAST(1 AS BIT), 0, 0, 0, NULL WHERE @ExecType IS NULL AND (@AnyEx = 1 OR EXISTS (SELECT 1 FROM @Ex WHERE ExecKey = 'NONE'))) x
    OUTER APPLY (SELECT COUNT(DISTINCT CASE WHEN r.DoctorKey <> 'SELF' THEN r.DoctorKey END) AS DoctorCount, COUNT(1) AS BillCount, COUNT(DISTINCT r.PatientCode) AS PatientCount,
                        SUM(r.TestCount) AS TestCount, SUM(r.BillAmount) AS BillAmount, SUM(r.DiscountAmount) AS DiscountAmount, SUM(r.CancelledAmount) AS CancelledAmount,
                        SUM(r.NetAmount) AS NetAmount, SUM(r.PaidAmount) AS PaidAmount, SUM(r.DueAmount) AS DueAmount
                 FROM #R r WHERE r.ExecKey = x.ExecKey) b
    UNION ALL
    SELECT 'byDoctor', r.ExecKey, MAX(r.ExecutiveName), MAX(r.ExecutiveCode), MAX(r.ExecutiveType), NULL, NULL, NULL,
           r.DoctorKey, MAX(r.RefDoctorName), 1, COUNT(1), COUNT(DISTINCT r.PatientCode), SUM(r.TestCount),
           SUM(r.BillAmount), SUM(r.DiscountAmount), SUM(r.CancelledAmount), SUM(r.NetAmount), SUM(r.PaidAmount), SUM(r.DueAmount), NULL,
           CASE WHEN r.ExecKey = 'NONE' THEN 1 ELSE 0 END, NULL, NULL, NULL, NULL
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_OwnerMis
    @BranchId     INT,
    @FromDate     DATE,
    @ToDate       DATE,
    @AllBranches  BIT = 0,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @sw DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @sw; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @Days INT = DATEDIFF(DAY, @FromDate, @ToDate) + 1;
    DECLARE @PrevFrom DATETIME = DATEADD(DAY, -@Days, @From), @PrevTo DATETIME = @From;
    DECLARE @ByMonth BIT = CASE WHEN @Days > 62 THEN 1 ELSE 0 END;

    -- ── branches in scope ────────────────────────────────────────────────────
    DECLARE @Br TABLE (BranchId INT PRIMARY KEY, BranchName NVARCHAR(200));
    IF ISNULL(@AllBranches, 0) = 1
        INSERT INTO @Br
        SELECT b.BranchID, b.BranchName
        FROM dbo.Branchmaster b
        WHERE b.IsActive = 1
          AND b.CompanyId = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId)
          AND (ISNULL(@IsSuperAdmin, 0) = 1
               OR EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = @UserId AND ub.BranchID = b.BranchID AND ISNULL(ub.IsActive, 1) = 1));
    ELSE
        INSERT INTO @Br SELECT BranchID, BranchName FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    -- ── bills of the period (and of the previous period, for growth) ─────────
    SELECT lo.LabOrderId, lo.BranchId, lo.OrderDate, lo.PatientId,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, lo.AgentType, lo.B2BAgentID, lo.RefDoctorId, lo.ReferralDoctorId, lo.MarketingExecutiveId /* 2449 */,
           CAST(lo.IsActive AS BIT) AS IsActive,
           CAST(CASE WHEN lo.OrderDate >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           CAST(lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) AS DECIMAL(18, 2)) AS GrossAmount /* 2240: + misc charges with GST */,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
           ph.PaymentHeaderId
    INTO #O
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.OrderDate >= @PrevFrom AND lo.OrderDate < @To;

    ALTER TABLE #O ADD DueAmount DECIMAL(18, 2);
    UPDATE #O SET DueAmount = CASE WHEN IsActive = 0 OR NetAmount - PaidAmount < 0 THEN 0 ELSE NetAmount - PaidAmount END;

    -- ── bill lines of the period: revenue per test (lines of a bill add up to the bill's net) ──
    SELECT o.LabOrderId, o.BranchId, o.IsB2B, li.LabOrderItemId,
           CASE WHEN li.[Type] = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS Kind,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Code END, lim.Test_Code, '') AS TestCode,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, lim.Test_Name, 'Item ' + CAST(li.InvestigationId AS VARCHAR(20))) AS TestName,
           CASE WHEN li.[Type] = 'P' THEN 'Packages' ELSE ISNULL(dm.DeptName, 'Not set') END AS Department,
           CAST(li.Price AS DECIMAL(18, 2)) AS Mrp,
           CAST(CASE WHEN o.IsB2B = 1 THEN ISNULL(li.B2BRate, li.Price) ELSE COALESCE(pli.NetLineAmount, li.Price) END AS DECIMAL(18, 4)) AS Basis,
           o.NetAmount AS BillNet
    INTO #L
    FROM #O o
    INNER JOIN dbo.LabOrderItem li ON li.LabOrderId = o.LabOrderId AND li.IsActive = 1
    LEFT  JOIN dbo.LabInvestigationMaster lim ON li.[Type] <> 'P' AND lim.Test_ID = li.InvestigationId
    LEFT  JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT  JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = o.PaymentHeaderId AND pli.ModuleLineRefId = li.LabOrderItemId AND pli.IsActive = 1
    WHERE o.InPeriod = 1 AND o.IsActive = 1;

    ALTER TABLE #L ADD NetLine DECIMAL(18, 2), Discount DECIMAL(18, 2), PartnerMargin DECIMAL(18, 2);
    ;WITH s AS (SELECT LabOrderId, SUM(Basis) AS SumBasis FROM #L GROUP BY LabOrderId)
    UPDATE l SET NetLine = CAST(CASE WHEN s.SumBasis > 0 THEN l.Basis * l.BillNet / s.SumBasis ELSE 0 END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.LabOrderId = l.LabOrderId;
    UPDATE #L SET Discount = CASE WHEN IsB2B = 0 THEN Mrp - NetLine ELSE 0 END,
                  PartnerMargin = CASE WHEN IsB2B = 1 THEN Mrp - NetLine ELSE 0 END;

    -- ── 2250: cost of the tests billed in the period (BOM consumption, SQLScripts/2249) ──
    -- actual    = the consumption runs recorded for the line on its own bill (re-runs included, at the cost of each run),
    --             wherever and whenever the test was run (cost follows the bill, as revenue does);
    -- estimated = an in-house test billed but not run yet, at its current BOM cost (shown apart as "not run yet").
    -- A package line is its member tests / profile tests; an outsourced test has no BOM cost.
    ALTER TABLE #L ADD TestId INT, IsPackage BIT NOT NULL DEFAULT 0, ActualCost DECIMAL(18, 2) NOT NULL DEFAULT 0,
                       PendingCost DECIMAL(18, 2) NOT NULL DEFAULT 0, Runs INT NOT NULL DEFAULT 0, Reruns INT NOT NULL DEFAULT 0,
                       PendingTests INT NOT NULL DEFAULT 0, NoBomTests INT NOT NULL DEFAULT 0;
    UPDATE l SET TestId = li.InvestigationId, IsPackage = CASE WHEN li.[Type] = 'P' THEN 1 ELSE 0 END
    FROM #L l INNER JOIN dbo.LabOrderItem li ON li.LabOrderItemId = l.LabOrderItemId;

    SELECT l.LabOrderItemId, l.LabOrderId, CASE WHEN l.IsPackage = 1 THEN pd.Test_ID ELSE l.TestId END AS UnitTestId,
           CASE WHEN l.IsPackage = 1 THEN l.TestId END AS PackageId
    INTO #LU
    FROM #L l
    LEFT JOIN dbo.LabInvestigationProfileDetail pd ON l.IsPackage = 1 AND pd.Profile_ID = l.TestId AND ISNULL(pd.IsDeleted, 0) = 0
    WHERE l.IsPackage = 0 OR pd.Test_ID IS NOT NULL;

    ALTER TABLE #LU ADD ActualCost DECIMAL(18, 2), Runs INT, Reruns INT, NoBomRuns INT, Outsourced BIT, EstCost DECIMAL(18, 2);
    UPDATE u SET ActualCost = ISNULL(x.Cost, 0), Runs = ISNULL(x.Runs, 0), Reruns = ISNULL(x.Reruns, 0), NoBomRuns = ISNULL(x.NoBom, 0),
                 Outsourced = CASE WHEN ISNULL(m.Is_Outsourced, 0) = 1
                                     OR EXISTS (SELECT 1 FROM dbo.SampleCollection sc
                                                LEFT JOIN dbo.LabInvestigationProfileHeader ph ON ph.Profile_ID = sc.ProfileId
                                                WHERE sc.Laborderid = u.LabOrderId AND ISNULL(sc.IsoutSource, 0) = 1
                                                  AND (sc.InvestigationID = u.UnitTestId OR ph.Test_ID = u.UnitTestId)) THEN 1 ELSE 0 END,
                 EstCost = dbo.ufn_Qc_TestMaterialCost(u.UnitTestId, NULL)
    FROM #LU u
    LEFT JOIN dbo.LabInvestigationMaster m ON m.Test_ID = u.UnitTestId
    OUTER APPLY (SELECT SUM(c.MaterialCost) AS Cost, COUNT(1) AS Runs, SUM(CASE WHEN c.RunNo > 1 THEN 1 ELSE 0 END) AS Reruns,
                        SUM(CASE WHEN c.Status = 'NO_BOM' THEN 1 ELSE 0 END) AS NoBom
                 FROM dbo.QcConsumption c
                 WHERE c.LabOrderId = u.LabOrderId AND c.TestId = u.UnitTestId AND ISNULL(c.PackageId, 0) = ISNULL(u.PackageId, 0)) x;

    UPDATE l SET ActualCost = x.ActualCost, PendingCost = x.PendingCost, Runs = x.Runs, Reruns = x.Reruns,
                 PendingTests = x.PendingTests, NoBomTests = x.NoBomTests
    FROM #L l
    INNER JOIN (SELECT LabOrderItemId, SUM(ActualCost) AS ActualCost,
                       SUM(CASE WHEN Runs = 0 AND Outsourced = 0 THEN ISNULL(EstCost, 0) ELSE 0 END) AS PendingCost,
                       SUM(Runs) AS Runs, SUM(Reruns) AS Reruns,
                       SUM(CASE WHEN Runs = 0 AND Outsourced = 0 AND EstCost IS NOT NULL THEN 1 ELSE 0 END) AS PendingTests,
                       SUM(CASE WHEN Outsourced = 0 AND ((Runs > 0 AND NoBomRuns = Runs) OR (Runs = 0 AND EstCost IS NULL)) THEN 1 ELSE 0 END) AS NoBomTests
                FROM #LU GROUP BY LabOrderItemId) x ON x.LabOrderItemId = l.LabOrderItemId;

    -- per bill: tests, MRP and partner margin of its lines (for the doctor and partner tables)
    ALTER TABLE #O ADD Tests INT NOT NULL DEFAULT 0, LineMrp DECIMAL(18, 2) NOT NULL DEFAULT 0, LineMargin DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET Tests = x.Tests, LineMrp = x.Mrp, LineMargin = x.Margin
    FROM #O o INNER JOIN (SELECT LabOrderId, COUNT(1) AS Tests, SUM(Mrp) AS Mrp, SUM(PartnerMargin) AS Margin FROM #L GROUP BY LabOrderId) x
         ON x.LabOrderId = o.LabOrderId;

    -- 2250: cost per bill = BOM material of its lines + collection kits (estimated: one kit per sample type collected in-house)
    ALTER TABLE #O ADD MaterialCost DECIMAL(18, 2) NOT NULL DEFAULT 0, KitCost DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET MaterialCost = ISNULL((SELECT SUM(l.ActualCost + l.PendingCost) FROM #L l WHERE l.LabOrderId = o.LabOrderId), 0),
                 KitCost = ISNULL((SELECT SUM(ISNULL(dbo.ufn_Qc_SampleKitCost(s.SampleTypeId), 0))
                                   FROM (SELECT DISTINCT m.Sample_Type_ID AS SampleTypeId
                                         FROM dbo.SampleCollection sc
                                         INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = sc.InvestigationID
                                         WHERE sc.Laborderid = o.LabOrderId AND sc.Is_Active = 1 AND sc.Iscancelled = 0
                                           AND ISNULL(sc.IsoutSource, 0) = 0 AND m.Sample_Type_ID IS NOT NULL) s), 0)
    FROM #O o WHERE o.InPeriod = 1 AND o.IsActive = 1;

    -- ── tests approved in the period: lab TAT (received at lab -> approval) against the TAT hours (dbo.ufn_LabReport_TatUnits) ──
    SELECT ISNULL(dm.DeptName, 'Not set') AS Department, t.LabHours AS Hours,
           CAST(CASE WHEN t.TatStatus IN ('ONTIME', 'BREACH') THEN 1 ELSE 0 END AS BIT) AS HasTarget,
           CAST(CASE WHEN t.TatStatus = 'ONTIME' THEN 1 ELSE 0 END AS BIT) AS Within
    INTO #T
    FROM dbo.ufn_LabReport_TatUnits(@From, @To) t
    INNER JOIN @Br br ON br.BranchId = t.HolderBranchId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = t.DepartmentId;

    -- ── quality: specimens collected / rejected / sent for re-collection (as LR-11), retests ──
    SELECT l.ToStatusId, l.RejectionReasonId, l.RejectionReason,
           COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END) AS SpecimenKey
    INTO #Q
    FROM dbo.LabSampleStatusLog l
    INNER JOIN @Br br ON br.BranchId = l.BranchId
    WHERE l.ToStatusId IN (2, 3, 4) AND l.ChangedOn >= @From AND l.ChangedOn < @To;

    DECLARE @Specimens INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 2);
    DECLARE @Rejected INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 4);
    DECLARE @Recollect INT = (SELECT COUNT(DISTINCT SpecimenKey) FROM #Q WHERE ToStatusId = 3);
    DECLARE @Retests INT = (SELECT COUNT(1) FROM dbo.LabReportUnapproval u
                            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = u.LabOrderId
                            INNER JOIN @Br br ON br.BranchId = lo.BranchId
                            WHERE u.Action = 'RETEST' AND u.UnapprovedDate >= @From AND u.UnapprovedDate < @To);

    -- ── money received in the period (receipt date); wallet deductions are shown apart (paid earlier as top-ups) ──
    SELECT pd.PaidAmount, ISNULL(pm.MethodName, 'Unknown') AS Mode,
           CAST(CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 1 ELSE 0 END AS BIT) AS FromWallet,
           CAST(CASE WHEN COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           ph.BranchId, COALESCE(pd.PaymentDate, pd.CreatedDate) AS PaidOn
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    INNER JOIN @Br br ON br.BranchId = ph.BranchId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.IsActive = 1 AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @PrevFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    DECLARE @Refunds DECIMAL(18, 2) = (SELECT ISNULL(SUM(r.RefundAmount), 0) FROM dbo.BillRefund r
                                       INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = r.ModuleRefId
                                       INNER JOIN @Br br ON br.BranchId = lo.BranchId
                                       WHERE r.ModuleCode = 'LAB' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P'
                                         AND r.RefundDate >= @From AND r.RefundDate < @To);

    DECLARE @CancelledAmount DECIMAL(18, 2) = (SELECT ISNULL(SUM(bc.CancelledAmount), 0) FROM dbo.BillCancellation bc
                                               INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
                                               INNER JOIN @Br br ON br.BranchId = lo.BranchId
                                               WHERE bc.ModuleCode = 'LAB' AND bc.IsActive = 1 AND bc.CancellationDate >= @From AND bc.CancellationDate < @To);

    -- ── outstanding today (all open bills of the branches), for ageing ───────
    SELECT CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B, DATEDIFF(DAY, lo.OrderDate, GETDATE()) AS AgeDays,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END
                - ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS Due
    INTO #D
    FROM dbo.LabOrder lo
    INNER JOIN @Br br ON br.BranchId = lo.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.IsActive = 1;
    DELETE FROM #D WHERE Due <= 0;

    -- RS1 summary
    SELECT
        (SELECT COUNT(1) FROM @Br) AS BranchCount,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN 1 ELSE 0 END) AS BillCount,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
        SUM(CASE WHEN InPeriod = 1 AND IsActive = 0 THEN 1 ELSE 0 END) AS CancelledBills,
        @CancelledAmount AS CancelledAmount,
        COUNT(DISTINCT CASE WHEN InPeriod = 1 AND IsActive = 1 THEN PatientId END) AS PatientCount,
        (SELECT COUNT(1) FROM #L) AS TestCount,
        (SELECT ISNULL(SUM(Mrp), 0) FROM #L) AS GrossAmount,
        (SELECT ISNULL(SUM(Discount), 0) FROM #L) AS DiscountAmount,
        (SELECT ISNULL(SUM(PartnerMargin), 0) FROM #L) AS PartnerMargin,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN NetAmount END), 0) AS NetRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 0 THEN NetAmount END), 0) AS B2CRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 AND IsB2B = 1 THEN NetAmount END), 0) AS B2BRevenue,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN PaidAmount END), 0) AS CollectedOnPeriodBills,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN DueAmount END), 0) AS PeriodBillsDue,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1 AND FromWallet = 0) AS Collected,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1 AND FromWallet = 1) AS PaidFromWallet,
        @Refunds AS Refunds,
        (SELECT ISNULL(SUM(Due), 0) FROM #D) AS OutstandingNow,
        -- previous period of the same length, for growth
        SUM(CASE WHEN InPeriod = 0 AND IsActive = 1 THEN 1 ELSE 0 END) AS PrevBillCount,
        ISNULL(SUM(CASE WHEN InPeriod = 0 AND IsActive = 1 THEN NetAmount END), 0) AS PrevNetRevenue,
        COUNT(DISTINCT CASE WHEN InPeriod = 0 AND IsActive = 1 THEN PatientId END) AS PrevPatientCount,
        (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 0 AND FromWallet = 0) AS PrevCollected,
        (SELECT COUNT(1) FROM #T) AS ReportsApproved,
        (SELECT COUNT(1) FROM #T WHERE HasTarget = 1) AS TatTests,
        (SELECT COUNT(1) FROM #T WHERE Within = 1) AS TatWithin,
        (SELECT CAST(AVG(Hours) AS DECIMAL(10, 1)) FROM #T WHERE Hours IS NOT NULL) AS TatAvgHours,
        @Specimens AS SpecimensCollected, @Rejected AS SpecimensRejected, @Recollect AS SpecimensRecollect, @Retests AS Retests,
        -- 2250: cost and gross profit of the tests billed in the period
        (SELECT ISNULL(SUM(ActualCost), 0) FROM #L) AS MaterialActual,
        (SELECT ISNULL(SUM(PendingCost), 0) FROM #L) AS MaterialPending,
        ISNULL(SUM(CASE WHEN InPeriod = 1 AND IsActive = 1 THEN KitCost END), 0) AS KitCost,
        (SELECT ISNULL(SUM(Runs), 0) FROM #L) AS TestRuns, (SELECT ISNULL(SUM(Reruns), 0) FROM #L) AS Reruns,
        (SELECT ISNULL(SUM(PendingTests), 0) FROM #L) AS PendingTests, (SELECT ISNULL(SUM(NoBomTests), 0) FROM #L) AS NoBomTests,
        (SELECT ISNULL(SUM(c.MaterialCost), 0) FROM dbo.QcConsumption c INNER JOIN @Br br ON br.BranchId = c.BranchId
          WHERE c.ConsumedOn >= @From AND c.ConsumedOn < @To) AS ConsumedInPeriod,
        @Days AS PeriodDays,
        CONVERT(VARCHAR(10), CAST(@PrevFrom AS DATE), 23) AS PrevFrom,
        CONVERT(VARCHAR(10), DATEADD(DAY, -1, CAST(@PrevTo AS DATE)), 23) AS PrevTo
    FROM #O;

    -- RS2 trend: billed / collected per day (per month for long periods)
    ;WITH b AS (
        SELECT CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), OrderDate, 23) ELSE CONVERT(VARCHAR(10), OrderDate, 23) END AS Bucket,
               COUNT(1) AS Bills, SUM(NetAmount) AS Billed
        FROM #O WHERE InPeriod = 1 AND IsActive = 1
        GROUP BY CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), OrderDate, 23) ELSE CONVERT(VARCHAR(10), OrderDate, 23) END),
    c AS (
        SELECT CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), PaidOn, 23) ELSE CONVERT(VARCHAR(10), PaidOn, 23) END AS Bucket,
               SUM(PaidAmount) AS Collected
        FROM #P WHERE InPeriod = 1 AND FromWallet = 0
        GROUP BY CASE WHEN @ByMonth = 1 THEN CONVERT(VARCHAR(7), PaidOn, 23) ELSE CONVERT(VARCHAR(10), PaidOn, 23) END)
    SELECT COALESCE(b.Bucket, c.Bucket) AS Bucket, ISNULL(b.Bills, 0) AS Bills, ISNULL(b.Billed, 0) AS Billed, ISNULL(c.Collected, 0) AS Collected,
           CAST(@ByMonth AS BIT) AS ByMonth
    FROM b FULL OUTER JOIN c ON c.Bucket = b.Bucket
    ORDER BY Bucket;

    -- RS3 revenue by test
    SELECT Kind, TestCode, TestName, Department,
           COUNT(1) AS Tests, SUM(CASE WHEN IsB2B = 0 THEN 1 ELSE 0 END) AS B2CTests, SUM(CASE WHEN IsB2B = 1 THEN 1 ELSE 0 END) AS B2BTests,
           SUM(Mrp) AS Gross, SUM(Discount) AS Discount, SUM(PartnerMargin) AS PartnerMargin, SUM(NetLine) AS Net,
           CAST(SUM(NetLine) / NULLIF(COUNT(1), 0) AS DECIMAL(18, 2)) AS AvgRealised,
           SUM(ActualCost) AS ActualCost, SUM(PendingCost) AS PendingCost, SUM(ActualCost + PendingCost) AS MaterialCost,
           SUM(NetLine) - SUM(ActualCost + PendingCost) AS Profit, SUM(PendingTests) AS PendingTests, SUM(Reruns) AS Reruns, SUM(NoBomTests) AS NoBomTests
    FROM #L GROUP BY Kind, TestCode, TestName, Department
    ORDER BY Net DESC;

    -- RS4 by department: revenue and TAT compliance
    ;WITH r AS (SELECT Department, COUNT(1) AS Tests, SUM(Mrp) AS Gross, SUM(Discount) AS Discount, SUM(PartnerMargin) AS PartnerMargin, SUM(NetLine) AS Net, SUM(ActualCost + PendingCost) AS Cost
                FROM #L GROUP BY Department),
    t AS (SELECT Department, COUNT(1) AS Reported, SUM(CASE WHEN HasTarget = 1 THEN 1 ELSE 0 END) AS TatTests,
                 SUM(CASE WHEN Within = 1 THEN 1 ELSE 0 END) AS TatWithin, CAST(AVG(Hours) AS DECIMAL(10, 1)) AS AvgHours
          FROM #T GROUP BY Department)
    SELECT COALESCE(r.Department, t.Department) AS Department, ISNULL(r.Tests, 0) AS Tests, ISNULL(r.Gross, 0) AS Gross,
           ISNULL(r.Discount, 0) AS Discount, ISNULL(r.PartnerMargin, 0) AS PartnerMargin, ISNULL(r.Net, 0) AS Net,
           ISNULL(r.Cost, 0) AS MaterialCost, ISNULL(r.Net, 0) - ISNULL(r.Cost, 0) AS Profit,
           ISNULL(t.Reported, 0) AS Reported, ISNULL(t.TatTests, 0) AS TatTests, ISNULL(t.TatWithin, 0) AS TatWithin, t.AvgHours
    FROM r FULL OUTER JOIN t ON t.Department = r.Department
    ORDER BY ISNULL(r.Net, 0) DESC;

    -- RS5 by referring doctor
    SELECT COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)), ''),
                    NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), ''), 'Self / walk-in') AS Doctor,
           COUNT(1) AS Bills, COUNT(DISTINCT o.PatientId) AS Patients, SUM(o.Tests) AS Tests,
           SUM(CASE WHEN o.IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills, SUM(CASE WHEN o.IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
           SUM(o.NetAmount) AS Net, SUM(o.DueAmount) AS Due,
           SUM(o.MaterialCost + o.KitCost) AS Cost, SUM(o.NetAmount) - SUM(o.MaterialCost + o.KitCost) AS Profit
    FROM #O o
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.RefDoctorId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    WHERE o.InPeriod = 1 AND o.IsActive = 1
    GROUP BY o.RefDoctorId, o.ReferralDoctorId, d.NamePrefix, d.FullName, rd.Salutation, rd.DoctorName
    ORDER BY Net DESC;

    -- RS6 by B2B partner
    SELECT CASE o.AgentType WHEN 'F' THEN 'Franchise' WHEN 'C' THEN 'Corporate' ELSE 'Other' END AS PartnerType,
           CASE o.AgentType WHEN 'F' THEN f.Franchise_Code ELSE c.Corporate_Code END AS PartnerCode,
           ISNULL(CASE o.AgentType WHEN 'F' THEN f.Franchise_Name ELSE c.Corporate_Name END, 'Unknown partner') AS Partner,
           COUNT(1) AS Bills, SUM(o.Tests) AS Tests, SUM(o.LineMrp) AS Mrp, SUM(o.NetAmount) AS Billed, SUM(o.LineMargin) AS MarginGiven,
           SUM(o.PaidAmount) AS Collected, SUM(o.DueAmount) AS Due,
           SUM(o.MaterialCost + o.KitCost) AS Cost, SUM(o.NetAmount) - SUM(o.MaterialCost + o.KitCost) AS Profit
    FROM #O o
    LEFT JOIN dbo.LabFranchiseMaster f ON o.AgentType = 'F' AND f.Franchise_ID = o.B2BAgentID
    LEFT JOIN dbo.CorporateMaster c ON o.AgentType = 'C' AND c.Corporate_ID = o.B2BAgentID
    WHERE o.InPeriod = 1 AND o.IsActive = 1 AND o.IsB2B = 1
    GROUP BY o.AgentType, o.B2BAgentID, f.Franchise_Code, f.Franchise_Name, c.Corporate_Code, c.Corporate_Name
    ORDER BY Billed DESC;

    -- RS7 quality: rejection / re-collection reasons
    SELECT ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, q.RejectionReason))), ''), 'Not recorded') AS Reason,
           COUNT(DISTINCT CASE WHEN q.ToStatusId = 4 THEN q.SpecimenKey END) AS Rejected,
           COUNT(DISTINCT CASE WHEN q.ToStatusId = 3 THEN q.SpecimenKey END) AS Recollect
    FROM #Q q
    LEFT JOIN dbo.LabSampleRejectionReasonMaster rr ON rr.Reason_ID = q.RejectionReasonId
    WHERE q.ToStatusId IN (3, 4)
    GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(COALESCE(rr.Reason_Text, q.RejectionReason))), ''), 'Not recorded')
    ORDER BY COUNT(DISTINCT q.SpecimenKey) DESC;

    -- RS8 outstanding ageing today (B2C buckets as Outstanding Dues, B2B as B2B Outstanding)
    SELECT Segment, Bucket, SortOrder, COUNT(1) AS Bills, SUM(Due) AS Due
    FROM (SELECT CASE WHEN IsB2B = 1 THEN 'B2B' ELSE 'B2C' END AS Segment,
                 CASE WHEN IsB2B = 0 THEN CASE WHEN AgeDays <= 2 THEN '0-2' WHEN AgeDays <= 7 THEN '3-7' WHEN AgeDays <= 30 THEN '8-30' ELSE '30+' END
                      ELSE CASE WHEN AgeDays <= 30 THEN '0-30' WHEN AgeDays <= 60 THEN '31-60' WHEN AgeDays <= 90 THEN '61-90' ELSE '90+' END END AS Bucket,
                 CASE WHEN IsB2B = 0 THEN CASE WHEN AgeDays <= 2 THEN 1 WHEN AgeDays <= 7 THEN 2 WHEN AgeDays <= 30 THEN 3 ELSE 4 END
                      ELSE CASE WHEN AgeDays <= 30 THEN 1 WHEN AgeDays <= 60 THEN 2 WHEN AgeDays <= 90 THEN 3 ELSE 4 END END AS SortOrder,
                 Due
          FROM #D) x
    GROUP BY Segment, Bucket, SortOrder
    ORDER BY Segment, SortOrder;

    -- RS9 collection by payment mode (receipts of the period)
    SELECT CASE WHEN FromWallet = 1 THEN 'Franchise wallet' ELSE Mode END AS Mode, COUNT(1) AS Receipts, SUM(PaidAmount) AS Amount
    FROM #P WHERE InPeriod = 1
    GROUP BY CASE WHEN FromWallet = 1 THEN 'Franchise wallet' ELSE Mode END
    ORDER BY Amount DESC;

    -- RS10 by branch
    SELECT br.BranchName AS Branch,
           (SELECT COUNT(1) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Bills,
           (SELECT ISNULL(SUM(o.NetAmount), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Net,
           (SELECT ISNULL(SUM(p.PaidAmount), 0) FROM #P p WHERE p.BranchId = br.BranchId AND p.InPeriod = 1 AND p.FromWallet = 0) AS Collected,
           (SELECT ISNULL(SUM(o.DueAmount), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Due,
           (SELECT ISNULL(SUM(o.MaterialCost + o.KitCost), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Cost,
           (SELECT ISNULL(SUM(o.NetAmount - o.MaterialCost - o.KitCost), 0) FROM #O o WHERE o.BranchId = br.BranchId AND o.InPeriod = 1 AND o.IsActive = 1) AS Profit
    FROM @Br br
    ORDER BY Net DESC;

    -- RS11 2250: items consumed for the tests billed in the period (actual BOM consumption of their runs)
    SELECT i.ItemCode, i.ItemName, cat.CategoryName AS Category, cu.UnitName AS Unit, COUNT(DISTINCT c.ConsumptionId) AS Runs,
           CAST(SUM(cl.Qty) AS DECIMAL(18, 4)) AS Qty, CAST(SUM(cl.LineCost) AS DECIMAL(18, 2)) AS Cost
    FROM dbo.QcConsumption c
    INNER JOIN (SELECT DISTINCT LabOrderId FROM #L) b ON b.LabOrderId = c.LabOrderId
    INNER JOIN dbo.QcConsumptionLine cl ON cl.ConsumptionId = c.ConsumptionId
    INNER JOIN dbo.InvItem i ON i.ItemId = cl.ItemId
    INNER JOIN dbo.InvItemCategory cat ON cat.CategoryId = i.CategoryId
    INNER JOIN dbo.InvUnit cu ON cu.UnitId = i.ConsumptionUnitId
    GROUP BY i.ItemCode, i.ItemName, cat.CategoryName, cu.UnitName
    ORDER BY Cost DESC;

    -- RS12 2449: by LAB marketing executive (the executive stored on the bill, SQLScripts/2445). Every LAB executive of the
    -- company (active, or with business in the period) and "Not tagged". Sales / visit targets of the branches in scope from
    -- LAB > Marketing Executive Sales Target (SQLScripts/2447), each bucket pro-rated by the days of the period inside it;
    -- visits = Doctor Visit Log + Marketing Executive App.
    DECLARE @Co INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);
    ;WITH b AS (
        SELECT o.MarketingExecutiveId AS ExecutiveId, COUNT(1) AS Bills, SUM(CASE WHEN o.IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills,
               SUM(CASE WHEN o.IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills, COUNT(DISTINCT o.PatientId) AS Patients, SUM(o.Tests) AS Tests,
               COUNT(DISTINCT COALESCE('D' + CAST(o.RefDoctorId AS VARCHAR(10)), 'R' + CAST(o.ReferralDoctorId AS VARCHAR(10)))) AS Doctors,
               SUM(o.LineMrp) AS Mrp, SUM(o.NetAmount) AS Net, SUM(o.PaidAmount) AS Collected, SUM(o.DueAmount) AS Due,
               SUM(o.MaterialCost + o.KitCost) AS Cost
        FROM #O o WHERE o.InPeriod = 1 AND o.IsActive = 1 GROUP BY o.MarketingExecutiveId),
    pv AS (SELECT o.MarketingExecutiveId AS ExecutiveId, SUM(o.NetAmount) AS PrevNet FROM #O o WHERE o.InPeriod = 0 AND o.IsActive = 1 GROUP BY o.MarketingExecutiveId),
    x AS (
        SELECT e.ExecutiveId, e.ExecutiveCode, e.ExecutiveName, e.IsActive FROM dbo.MarketingExecutive e
        WHERE e.CompanyId = @Co AND e.IsDeleted = 0 AND e.ExecutiveType = 'LAB'
          AND (e.IsActive = 1 OR EXISTS (SELECT 1 FROM b WHERE b.ExecutiveId = e.ExecutiveId))
        UNION ALL SELECT NULL, NULL, N'Not tagged', CAST(1 AS BIT) WHERE EXISTS (SELECT 1 FROM b WHERE b.ExecutiveId IS NULL))
    SELECT ISNULL(x.ExecutiveCode, '—') AS ExecutiveCode, x.ExecutiveName AS Executive,
           CASE WHEN x.ExecutiveId IS NULL THEN 'Not tagged' WHEN x.IsActive = 1 THEN 'Active' ELSE 'Inactive' END AS Status,
           (SELECT COUNT(1) FROM dbo.DoctorMaster d WHERE d.MarketingExecutiveId = x.ExecutiveId AND d.IsActive = 1) AS TaggedDoctors,
           ISNULL(b.Doctors, 0) AS Doctors, ISNULL(b.Bills, 0) AS Bills, ISNULL(b.B2CBills, 0) AS B2CBills, ISNULL(b.B2BBills, 0) AS B2BBills,
           ISNULL(b.Patients, 0) AS Patients, ISNULL(b.Tests, 0) AS Tests, ISNULL(b.Mrp, 0) AS Mrp, ISNULL(b.Net, 0) AS Net,
           ISNULL(b.Collected, 0) AS Collected, ISNULL(b.Due, 0) AS Due, ISNULL(b.Cost, 0) AS Cost, ISNULL(b.Net, 0) - ISNULL(b.Cost, 0) AS Profit,
           ISNULL(pv.PrevNet, 0) AS PrevNet,
           CAST(t.Sales AS DECIMAL(18, 2)) AS Target, CAST(t.Visit AS DECIMAL(18, 1)) AS VisitTarget,
           CASE WHEN x.ExecutiveId IS NULL THEN NULL ELSE
               (SELECT COUNT(1) FROM dbo.fn_Mkt_TargetVisits(@From, @To) tv INNER JOIN @Br br ON br.BranchId = tv.BranchId   -- 2482
                 WHERE tv.ExecutiveId = x.ExecutiveId) END AS Visits
    FROM x
    LEFT JOIN b ON (b.ExecutiveId = x.ExecutiveId OR (b.ExecutiveId IS NULL AND x.ExecutiveId IS NULL))
    LEFT JOIN pv ON (pv.ExecutiveId = x.ExecutiveId OR (pv.ExecutiveId IS NULL AND x.ExecutiveId IS NULL))
    OUTER APPLY (SELECT SUM(bk.SalesTarget * o.Days / (DATEDIFF(DAY, bk.FromDate, bk.ToDate) + 1.0)) AS Sales,
                        SUM(bk.VisitTarget * o.Days / (DATEDIFF(DAY, bk.FromDate, bk.ToDate) + 1.0)) AS Visit
                 FROM dbo.MarketingTarget mt
                 INNER JOIN @Br br ON br.BranchId = mt.BranchId
                 INNER JOIN dbo.MarketingTargetBucket bk ON bk.TargetId = mt.TargetId
                 CROSS APPLY (SELECT DATEDIFF(DAY, CASE WHEN bk.FromDate > @FromDate THEN bk.FromDate ELSE @FromDate END,
                                                   CASE WHEN bk.ToDate < @ToDate THEN bk.ToDate ELSE @ToDate END) + 1 AS Days) o
                 WHERE mt.ExecutiveId = x.ExecutiveId AND bk.FromDate <= @ToDate AND bk.ToDate >= @FromDate) t
    ORDER BY CASE WHEN x.ExecutiveId IS NULL THEN 1 ELSE 0 END, ISNULL(b.Net, 0) DESC, x.ExecutiveName;

    DROP TABLE #LU; DROP TABLE #O; DROP TABLE #L; DROP TABLE #T; DROP TABLE #Q; DROP TABLE #P; DROP TABLE #D;
END;
GO
PRINT 'Script 2482 applied: visit target counts one Verified visit per doctor per day.';
GO
