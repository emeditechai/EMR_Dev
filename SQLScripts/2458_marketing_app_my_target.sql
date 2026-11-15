-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2458  Marketing Executive App: "My Target" - the signed-in executive's own sales and doctor-visit target
--   The targets are set on the web in LAB > Marketing Executive Sales Target (2447: MarketingTarget, MarketingTargetBucket).
--   usp_Mkt_MyTarget (api/marketing/my-target) reads them for the executive of the login, the branch of the token and a
--   financial year (the current one by default), with the actuals so far, worked out exactly as usp_Api_MktTarget_Get does:
--     sales  = net amount of the LAB bills of this branch tagged to the executive (LabOrder.MarketingExecutiveId),
--     visits = Doctor Visit Log (MarketingDoctorVisit) + the visits logged in the app (ForecastDoctorVisit).
--   Read only: the executive can see the own target only and cannot change it.
--   RS1 header (one row), RS2 the periods of the year (none when the executive is not of type LAB).
--   Run after 2446 and 2447. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET NOCOUNT ON;
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
        OUTER APPLY (SELECT (SELECT COUNT(1) FROM dbo.MarketingDoctorVisit mv WHERE mv.BranchId = @BranchId AND mv.ExecutiveId = @Exec AND mv.IsDeleted = 0
                               AND mv.VisitDate >= g.FromDate AND mv.VisitDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME)))
                          + (SELECT COUNT(1) FROM dbo.ForecastDoctorVisit fv WHERE fv.BranchId = @BranchId AND fv.ExecutiveId = @Exec
                               AND fv.VisitDate >= g.FromDate AND fv.VisitDate < DATEADD(DAY, 1, CAST(g.ToDate AS DATETIME))) AS Visits) v;

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
PRINT 'Script 2458 applied: usp_Mkt_MyTarget (Marketing Executive App, My Target).';
GO
