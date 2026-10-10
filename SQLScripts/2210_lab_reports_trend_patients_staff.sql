-- ============================================================================
-- Migration: 2210_lab_reports_trend_patients_staff.sql
-- Description: three Reports > LAB management registers from the LAB Reports Roadmap, on the shared register pattern
--   (one procedure per report returning Summary / Groups / Rows / Options, run through api/reports/lab/run/{report},
--   page on _LabReportShell + lab-report.js). Visibility: branch first (usp_LabReport_CheckAccess), Administrator /
--   super admin see every user's data, everyone else only their own.
--     LR-24 Revenue & Footfall Trend      usp_Api_LabReport_RevenueTrend        by bill date (money by receipt date)
--     LR-26 Patient Analytics             usp_Api_LabReport_PatientAnalytics    by bill date
--     LR-27 Staff Productivity  QI        usp_Api_LabReport_StaffProductivity   by the date of each action
--   Revenue is worked out as in the Owner MIS (2200): net of active bills (B2B at the partner rate), so the figures
--   agree. Pages are added to Reports > LAB with their VIEW endpoints; no role or user grant is seeded. Read-only.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- LR-24 Revenue & Footfall Trend - is the lab growing, and when is it busiest? Active bills of the branch by bill date:
-- revenue (net, B2B at the partner rate), bills, patients, tests, B2C / B2B; money received by receipt date (wallet
-- deductions left out, as in the Owner MIS). Growth against the previous period of the same length, month-on-month
-- change, and bills by hour of day x day of week (the staffing heatmap). Own data: bills they created; money they received.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_RevenueTrend
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @BillingType   VARCHAR(10)   = NULL,   -- B2C / B2B
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,   -- not used: a trend has no record to search
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    IF @OwnOnly = 1 SET @CreatedBy = @UserId;
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    DECLARE @Days INT = DATEDIFF(DAY, @FromDate, @ToDate) + 1;
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @PrevFrom DATETIME = DATEADD(DAY, -@Days, @From);
    -- month-on-month needs the month before the first month of the range
    DECLARE @MonthFrom DATETIME = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@FromDate), MONTH(@FromDate), 1));
    DECLARE @LoadFrom DATETIME = CASE WHEN @MonthFrom < @PrevFrom THEN @MonthFrom ELSE @PrevFrom END;

    SELECT lo.LabOrderId, lo.OrderDate, CAST(lo.OrderDate AS DATE) AS BillDay, lo.PatientId,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT) AS IsB2B,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
           (SELECT COUNT(1) FROM dbo.LabOrderItem li WHERE li.LabOrderId = lo.LabOrderId AND li.IsActive = 1) AS Tests,
           CAST(CASE WHEN lo.OrderDate >= @From AND lo.OrderDate < @To THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           CAST(CASE WHEN lo.OrderDate >= @PrevFrom AND lo.OrderDate < @From THEN 1 ELSE 0 END AS BIT) AS InPrev,
           (DATEDIFF(DAY, '19000101', CAST(lo.OrderDate AS DATE)) % 7) + 1 AS WeekdayNo,   -- 1 = Monday
           DATEPART(HOUR, lo.OrderDate) AS HourNo
    INTO #O
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND lo.OrderDate >= @LoadFrom AND lo.OrderDate < @To
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0));

    -- money received at the branch by receipt date (wallet deductions are not money at the counter)
    SELECT CAST(COALESCE(pd.PaymentDate, pd.CreatedDate) AS DATE) AS PaidDay, pd.PaidAmount,
           CAST(CASE WHEN COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId
    WHERE ph.BranchId = @BranchId AND pd.IsActive = 1
      AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @PrevFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To
      AND (@CreatedBy IS NULL OR pd.CreatedBy = @CreatedBy)
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0));

    -- one row per calendar day of the period, days without bills included
    ;WITH n AS (SELECT TOP (@Days) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    SELECT DATEADD(DAY, n.i, @FromDate) AS DayDate INTO #D FROM n;

    SELECT CONVERT(VARCHAR(10), d.DayDate, 23) AS Day, DATENAME(WEEKDAY, d.DayDate) AS WeekdayName,
           (DATEDIFF(DAY, '19000101', d.DayDate) % 7) + 1 AS WeekdayNo,
           CONVERT(VARCHAR(7), d.DayDate, 23) AS Month,
           ISNULL(o.Bills, 0) AS Bills, ISNULL(o.B2CBills, 0) AS B2CBills, ISNULL(o.B2BBills, 0) AS B2BBills,
           ISNULL(o.Patients, 0) AS Patients, ISNULL(o.Tests, 0) AS Tests,
           ISNULL(o.Revenue, 0) AS Revenue, ISNULL(o.B2CRevenue, 0) AS B2CRevenue, ISNULL(o.B2BRevenue, 0) AS B2BRevenue,
           ISNULL(p.Collected, 0) AS Collected,
           CAST(CASE WHEN ISNULL(o.Bills, 0) > 0 THEN o.Revenue / o.Bills END AS DECIMAL(18, 2)) AS AvgBillValue
    INTO #R
    FROM #D d
    LEFT JOIN (SELECT BillDay, COUNT(1) AS Bills, SUM(CASE WHEN IsB2B = 0 THEN 1 ELSE 0 END) AS B2CBills, SUM(CASE WHEN IsB2B = 1 THEN 1 ELSE 0 END) AS B2BBills,
                      COUNT(DISTINCT PatientId) AS Patients, SUM(Tests) AS Tests, SUM(NetAmount) AS Revenue,
                      SUM(CASE WHEN IsB2B = 0 THEN NetAmount ELSE 0 END) AS B2CRevenue, SUM(CASE WHEN IsB2B = 1 THEN NetAmount ELSE 0 END) AS B2BRevenue
               FROM #O WHERE InPeriod = 1 GROUP BY BillDay) o ON o.BillDay = d.DayDate
    LEFT JOIN (SELECT PaidDay, SUM(PaidAmount) AS Collected FROM #P WHERE InPeriod = 1 GROUP BY PaidDay) p ON p.PaidDay = d.DayDate;

    DECLARE @Rev DECIMAL(18, 2) = (SELECT ISNULL(SUM(NetAmount), 0) FROM #O WHERE InPeriod = 1);
    DECLARE @PrevRev DECIMAL(18, 2) = (SELECT ISNULL(SUM(NetAmount), 0) FROM #O WHERE InPrev = 1);
    DECLARE @Bills INT = (SELECT COUNT(1) FROM #O WHERE InPeriod = 1);
    DECLARE @PrevBills INT = (SELECT COUNT(1) FROM #O WHERE InPrev = 1);
    DECLARE @Pat INT = (SELECT COUNT(DISTINCT PatientId) FROM #O WHERE InPeriod = 1);
    DECLARE @PrevPat INT = (SELECT COUNT(DISTINCT PatientId) FROM #O WHERE InPrev = 1);

    -- RS1 summary
    SELECT @Rev AS Revenue, @Bills AS Bills, @Pat AS Patients,
           (SELECT ISNULL(SUM(Tests), 0) FROM #O WHERE InPeriod = 1) AS Tests,
           (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1) AS Collected,
           (SELECT ISNULL(SUM(NetAmount), 0) FROM #O WHERE InPeriod = 1 AND IsB2B = 0) AS B2CRevenue,
           (SELECT ISNULL(SUM(NetAmount), 0) FROM #O WHERE InPeriod = 1 AND IsB2B = 1) AS B2BRevenue,
           CAST(CASE WHEN @Bills > 0 THEN @Rev / @Bills END AS DECIMAL(18, 2)) AS AvgBillValue,
           CAST(@Rev / @Days AS DECIMAL(18, 2)) AS AvgDailyRevenue,
           CAST(@Bills * 1.0 / @Days AS DECIMAL(10, 1)) AS AvgDailyBills,
           @Days AS Days, @PrevRev AS PrevRevenue, @PrevBills AS PrevBills, @PrevPat AS PrevPatients,
           CAST(CASE WHEN @PrevRev > 0 THEN (@Rev - @PrevRev) * 100.0 / @PrevRev END AS DECIMAL(10, 1)) AS RevenueGrowthPct,
           CAST(CASE WHEN @PrevBills > 0 THEN (@Bills - @PrevBills) * 100.0 / @PrevBills END AS DECIMAL(10, 1)) AS BillsGrowthPct,
           CAST(CASE WHEN @PrevPat > 0 THEN (@Pat - @PrevPat) * 100.0 / @PrevPat END AS DECIMAL(10, 1)) AS PatientsGrowthPct,
           CONVERT(VARCHAR(10), CAST(@PrevFrom AS DATE), 23) AS PrevFrom, CONVERT(VARCHAR(10), DATEADD(DAY, -1, CAST(@From AS DATE)), 23) AS PrevTo,
           (SELECT TOP 1 Day FROM #R WHERE Revenue > 0 ORDER BY Revenue DESC, Day) AS PeakDay,
           (SELECT MAX(Revenue) FROM #R) AS PeakDayRevenue,
           (SELECT TOP 1 DATENAME(WEEKDAY, DATEADD(DAY, WeekdayNo - 1, '19000101')) FROM #O WHERE InPeriod = 1 GROUP BY WeekdayNo ORDER BY COUNT(1) DESC, WeekdayNo) AS BusiestWeekday,
           (SELECT TOP 1 HourNo FROM #O WHERE InPeriod = 1 GROUP BY HourNo ORDER BY COUNT(1) DESC, HourNo) AS BusiestHour;

    -- RS2 groups
    -- month-on-month: each month against the calendar month before it (the month before the range included)
    SELECT CONVERT(VARCHAR(7), BillDay, 23) AS Month, COUNT(1) AS Bills, COUNT(DISTINCT PatientId) AS Patients, SUM(Tests) AS Tests,
           SUM(NetAmount) AS Revenue, SUM(CASE WHEN IsB2B = 0 THEN NetAmount ELSE 0 END) AS B2CRevenue,
           SUM(CASE WHEN IsB2B = 1 THEN NetAmount ELSE 0 END) AS B2BRevenue
    INTO #M FROM #O GROUP BY CONVERT(VARCHAR(7), BillDay, 23);

    DECLARE @WeekdayCount TABLE (WeekdayNo INT, DayCount INT);
    INSERT INTO @WeekdayCount SELECT WeekdayNo, COUNT(1) FROM #R GROUP BY WeekdayNo;

    SELECT 'byDay' AS GroupKey, NULL AS GroupId, Day AS GroupName, 0 AS SortOrder,
           Bills, Patients, Tests, Revenue, B2CRevenue, B2BRevenue, Collected, AvgBillValue,
           CAST(NULL AS DECIMAL(18, 2)) AS PrevRevenue, CAST(NULL AS DECIMAL(10, 1)) AS GrowthPct, CAST(NULL AS DECIMAL(10, 1)) AS BillsPerDay
    FROM #R
    UNION ALL
    SELECT 'byMonth', NULL, m.Month, 0, m.Bills, m.Patients, m.Tests, m.Revenue, m.B2CRevenue, m.B2BRevenue,
           (SELECT ISNULL(SUM(Collected), 0) FROM #R r WHERE r.Month = m.Month),
           CAST(CASE WHEN m.Bills > 0 THEN m.Revenue / m.Bills END AS DECIMAL(18, 2)),
           pm.Revenue,
           CAST(CASE WHEN pm.Revenue > 0 THEN (m.Revenue - pm.Revenue) * 100.0 / pm.Revenue END AS DECIMAL(10, 1)),
           NULL
    FROM #M m
    LEFT JOIN #M pm ON pm.Month = CONVERT(VARCHAR(7), DATEADD(MONTH, -1, CAST(m.Month + '-01' AS DATE)), 23)
    WHERE m.Month >= CONVERT(VARCHAR(7), @FromDate, 23)
    UNION ALL
    SELECT 'byWeekday', w.WeekdayNo, DATENAME(WEEKDAY, DATEADD(DAY, w.WeekdayNo - 1, '19000101')), w.WeekdayNo,
           ISNULL(x.Bills, 0), ISNULL(x.Patients, 0), ISNULL(x.Tests, 0), ISNULL(x.Revenue, 0), ISNULL(x.B2CRevenue, 0), ISNULL(x.B2BRevenue, 0),
           (SELECT ISNULL(SUM(Collected), 0) FROM #R r WHERE r.WeekdayNo = w.WeekdayNo),
           CAST(CASE WHEN x.Bills > 0 THEN x.Revenue / x.Bills END AS DECIMAL(18, 2)), NULL, NULL,
           CAST(ISNULL(x.Bills, 0) * 1.0 / NULLIF(w.DayCount, 0) AS DECIMAL(10, 1))
    FROM @WeekdayCount w
    LEFT JOIN (SELECT WeekdayNo, COUNT(1) AS Bills, COUNT(DISTINCT PatientId) AS Patients, SUM(Tests) AS Tests, SUM(NetAmount) AS Revenue,
                      SUM(CASE WHEN IsB2B = 0 THEN NetAmount ELSE 0 END) AS B2CRevenue, SUM(CASE WHEN IsB2B = 1 THEN NetAmount ELSE 0 END) AS B2BRevenue
               FROM #O WHERE InPeriod = 1 GROUP BY WeekdayNo) x ON x.WeekdayNo = w.WeekdayNo
    UNION ALL
    SELECT 'byHour', HourNo, RIGHT('0' + CAST(HourNo AS VARCHAR(2)), 2) + ':00 - ' + RIGHT('0' + CAST(HourNo AS VARCHAR(2)), 2) + ':59', HourNo,
           COUNT(1), COUNT(DISTINCT PatientId), SUM(Tests), SUM(NetAmount),
           SUM(CASE WHEN IsB2B = 0 THEN NetAmount ELSE 0 END), SUM(CASE WHEN IsB2B = 1 THEN NetAmount ELSE 0 END), NULL,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)), NULL, NULL, CAST(COUNT(1) * 1.0 / @Days AS DECIMAL(10, 1))
    FROM #O WHERE InPeriod = 1 GROUP BY HourNo
    UNION ALL
    SELECT 'byBillingType', NULL, CASE WHEN IsB2B = 1 THEN 'B2B' ELSE 'B2C' END, CAST(IsB2B AS INT),
           COUNT(1), COUNT(DISTINCT PatientId), SUM(Tests), SUM(NetAmount),
           SUM(CASE WHEN IsB2B = 0 THEN NetAmount ELSE 0 END), SUM(CASE WHEN IsB2B = 1 THEN NetAmount ELSE 0 END), NULL,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)), NULL, NULL, NULL
    FROM #O WHERE InPeriod = 1 GROUP BY IsB2B
    UNION ALL
    -- staffing heatmap: bills by day of week x hour (GroupId = weekday * 100 + hour); drawn by the page, not a "Group by"
    SELECT 'heat', WeekdayNo * 100 + HourNo, LEFT(DATENAME(WEEKDAY, DATEADD(DAY, WeekdayNo - 1, '19000101')), 3) + ' ' + RIGHT('0' + CAST(HourNo AS VARCHAR(2)), 2) + ':00',
           WeekdayNo * 100 + HourNo, COUNT(1), COUNT(DISTINCT PatientId), SUM(Tests), SUM(NetAmount), NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM #O WHERE InPeriod = 1 GROUP BY WeekdayNo, HourNo
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows: one per day of the period, latest first
    SELECT * FROM #R ORDER BY Day DESC;

    -- RS4 filter options: who created bills of the branch
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(u.Id AS VARCHAR(20)) AS Value, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Text
    FROM dbo.LabOrder lo INNER JOIN dbo.Users u ON u.Id = lo.CreatedBy
    WHERE lo.BranchId = @BranchId AND lo.OrderDate >= @From AND lo.OrderDate < @To;

    DROP TABLE #O; DROP TABLE #P; DROP TABLE #D; DROP TABLE #R; DROP TABLE #M;
END;
GO

-- ============================================================================
-- LR-26 Patient Analytics - who are our patients, and do they come back? Patients with an active bill at the branch
-- in the period. New = their first LAB bill at this branch is in the period; returning = they had one before.
-- Age at their latest bill of the period. Visits = bills in the period. Top tests by age band from the bill lines
-- (package / profile / test, as the Owner MIS). Own data: patients on bills they created (those bills only).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_PatientAnalytics
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @PatientType   VARCHAR(10)   = NULL,   -- NEW / RETURNING
    @AgeBand       VARCHAR(10)   = NULL,   -- 0-12 / 13-17 / 18-30 / 31-45 / 46-60 / 61+ / UNKNOWN
    @Gender        VARCHAR(10)   = NULL,   -- MALE / FEMALE / OTHER
    @CreatedBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    IF @OwnOnly = 1 SET @CreatedBy = @UserId;
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @PatientType = NULLIF(UPPER(LTRIM(RTRIM(@PatientType))), '');
    SET @AgeBand = NULLIF(UPPER(LTRIM(RTRIM(@AgeBand))), '');
    SET @Gender = NULLIF(UPPER(LTRIM(RTRIM(@Gender))), '');

    SELECT lo.LabOrderId, lo.PatientId, lo.OrderDate,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount
    INTO #B
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy);

    -- bill lines: what was done (package / profile / test name)
    SELECT b.PatientId, b.LabOrderId,
           COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, lim.Test_Name, 'Item ' + CAST(li.InvestigationId AS VARCHAR(20))) AS TestName
    INTO #L
    FROM #B b
    INNER JOIN dbo.LabOrderItem li ON li.LabOrderId = b.LabOrderId AND li.IsActive = 1
    LEFT  JOIN dbo.LabInvestigationMaster lim ON li.[Type] <> 'P' AND lim.Test_ID = li.InvestigationId
    LEFT  JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId;

    SELECT p.PatientId, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           p.PhoneNumber,
           CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(p.Gender, '')))) IN ('MALE', 'M') THEN 'MALE'
                WHEN UPPER(LTRIM(RTRIM(ISNULL(p.Gender, '')))) IN ('FEMALE', 'F') THEN 'FEMALE' ELSE 'OTHER' END AS Gender,
           x.Visits, x.Spent, x.FirstInPeriod, x.LastInPeriod,
           (SELECT COUNT(1) FROM #L l WHERE l.PatientId = p.PatientId) AS Tests,
           fv.FirstEver, fv.VisitsEver,
           (SELECT MAX(lo2.OrderDate) FROM dbo.LabOrder lo2 WHERE lo2.PatientId = p.PatientId AND lo2.BranchId = @BranchId AND lo2.IsActive = 1 AND lo2.OrderDate < @From) AS PreviousVisit,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, p.DateOfBirth, x.LastInPeriod) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, x.LastInPeriod), p.DateOfBirth) > x.LastInPeriod THEN 1 ELSE 0 END END AS AgeYears,
           (SELECT STRING_AGG(t.TestName, ', ') WITHIN GROUP (ORDER BY t.n DESC, t.TestName)
              FROM (SELECT TOP 3 l.TestName, COUNT(1) AS n FROM #L l WHERE l.PatientId = p.PatientId GROUP BY l.TestName ORDER BY COUNT(1) DESC, l.TestName) t) AS TopTests
    INTO #R
    FROM (SELECT PatientId, COUNT(1) AS Visits, SUM(NetAmount) AS Spent, MIN(OrderDate) AS FirstInPeriod, MAX(OrderDate) AS LastInPeriod
          FROM #B GROUP BY PatientId) x
    INNER JOIN dbo.PatientMaster p ON p.PatientId = x.PatientId
    OUTER APPLY (SELECT MIN(lo1.OrderDate) AS FirstEver, COUNT(1) AS VisitsEver FROM dbo.LabOrder lo1
                  WHERE lo1.PatientId = p.PatientId AND lo1.BranchId = @BranchId AND lo1.IsActive = 1 AND lo1.OrderDate < @To) fv;

    ALTER TABLE #R ADD PatientType VARCHAR(10), AgeBand VARCHAR(10), AgeBandOrder INT, VisitBand VARCHAR(5), DaysSincePrevious INT;
    UPDATE #R SET PatientType = CASE WHEN FirstEver >= @From THEN 'NEW' ELSE 'RETURNING' END,
                  AgeBand = CASE WHEN AgeYears IS NULL OR AgeYears < 0 THEN 'UNKNOWN' WHEN AgeYears <= 12 THEN '0-12' WHEN AgeYears <= 17 THEN '13-17'
                                 WHEN AgeYears <= 30 THEN '18-30' WHEN AgeYears <= 45 THEN '31-45' WHEN AgeYears <= 60 THEN '46-60' ELSE '61+' END,
                  VisitBand = CASE WHEN Visits >= 3 THEN '3+' ELSE CAST(Visits AS VARCHAR(2)) END,
                  DaysSincePrevious = CASE WHEN PreviousVisit IS NOT NULL THEN DATEDIFF(DAY, PreviousVisit, FirstInPeriod) END;
    UPDATE #R SET AgeBandOrder = CASE AgeBand WHEN '0-12' THEN 1 WHEN '13-17' THEN 2 WHEN '18-30' THEN 3 WHEN '31-45' THEN 4 WHEN '46-60' THEN 5 WHEN '61+' THEN 6 ELSE 7 END;

    IF @PatientType IS NOT NULL DELETE FROM #R WHERE PatientType <> @PatientType;
    IF @AgeBand IS NOT NULL DELETE FROM #R WHERE AgeBand <> @AgeBand;
    IF @Gender IS NOT NULL DELETE FROM #R WHERE Gender <> @Gender;
    IF @Search IS NOT NULL DELETE FROM #R WHERE NOT (PatientCode LIKE '%' + @Search + '%' OR PatientName LIKE '%' + @Search + '%' OR PhoneNumber LIKE '%' + @Search + '%');
    DELETE l FROM #L l WHERE NOT EXISTS (SELECT 1 FROM #R r WHERE r.PatientId = l.PatientId);

    -- RS1 summary
    SELECT COUNT(1) AS Patients,
           SUM(CASE WHEN PatientType = 'NEW' THEN 1 ELSE 0 END) AS NewPatients,
           SUM(CASE WHEN PatientType = 'RETURNING' THEN 1 ELSE 0 END) AS Returning,
           CAST(CASE WHEN COUNT(1) > 0 THEN SUM(CASE WHEN PatientType = 'RETURNING' THEN 1 ELSE 0 END) * 100.0 / COUNT(1) END AS DECIMAL(10, 1)) AS ReturningPct,
           SUM(CASE WHEN Visits >= 2 THEN 1 ELSE 0 END) AS RepeatInPeriod,
           ISNULL(SUM(Visits), 0) AS Visits,
           CAST(AVG(Visits * 1.0) AS DECIMAL(10, 2)) AS AvgVisits,
           ISNULL(SUM(Tests), 0) AS Tests,
           ISNULL(SUM(Spent), 0) AS Revenue,
           CAST(CASE WHEN COUNT(1) > 0 THEN SUM(Spent) / COUNT(1) END AS DECIMAL(18, 2)) AS RevenuePerPatient,
           SUM(CASE WHEN Gender = 'MALE' THEN 1 ELSE 0 END) AS Male,
           SUM(CASE WHEN Gender = 'FEMALE' THEN 1 ELSE 0 END) AS Female,
           SUM(CASE WHEN Gender = 'OTHER' THEN 1 ELSE 0 END) AS OtherGender,
           CAST(AVG(AgeYears * 1.0) AS DECIMAL(10, 1)) AS AvgAge,
           CAST(AVG(DaysSincePrevious * 1.0) AS DECIMAL(10, 1)) AS AvgDaysBetweenVisits,
           (SELECT TOP 1 AgeBand FROM #R WHERE AgeBand <> 'UNKNOWN' GROUP BY AgeBand ORDER BY COUNT(1) DESC, AgeBand) AS TopAgeBand,
           (SELECT TOP 1 TestName FROM #L GROUP BY TestName ORDER BY COUNT(1) DESC, TestName) AS TopTest
    FROM #R;

    -- RS2 groups, each with the top 3 tests of its patients
    ;WITH g AS (
        SELECT 'byType' AS GroupKey, PatientType AS GroupName, CASE PatientType WHEN 'NEW' THEN 0 ELSE 1 END AS SortOrder, PatientId FROM #R
        UNION ALL SELECT 'byAgeBand', AgeBand, AgeBandOrder, PatientId FROM #R
        UNION ALL SELECT 'byGender', Gender, CASE Gender WHEN 'MALE' THEN 0 WHEN 'FEMALE' THEN 1 ELSE 2 END, PatientId FROM #R
        UNION ALL SELECT 'byVisits', VisitBand, CASE VisitBand WHEN '1' THEN 1 WHEN '2' THEN 2 ELSE 3 END, PatientId FROM #R),
    gt AS (
        SELECT g.GroupKey, g.GroupName, l.TestName, COUNT(1) AS n,
               ROW_NUMBER() OVER (PARTITION BY g.GroupKey, g.GroupName ORDER BY COUNT(1) DESC, l.TestName) AS rn
        FROM g INNER JOIN #L l ON l.PatientId = g.PatientId
        GROUP BY g.GroupKey, g.GroupName, l.TestName)
    SELECT g.GroupKey, CAST(NULL AS INT) AS GroupId, CAST(g.GroupName AS NVARCHAR(400)) AS GroupName, MIN(g.SortOrder) AS SortOrder,
           COUNT(1) AS Patients,
           SUM(CASE WHEN r.PatientType = 'NEW' THEN 1 ELSE 0 END) AS NewPatients,
           SUM(CASE WHEN r.PatientType = 'RETURNING' THEN 1 ELSE 0 END) AS Returning,
           SUM(r.Visits) AS Visits, CAST(AVG(r.Visits * 1.0) AS DECIMAL(10, 2)) AS AvgVisits,
           SUM(r.Tests) AS Tests, CAST(SUM(r.Spent) AS DECIMAL(18, 2)) AS Revenue,
           CAST(SUM(r.Spent) / COUNT(1) AS DECIMAL(18, 2)) AS RevenuePerPatient,
           CAST((SELECT STRING_AGG(gt.TestName, ', ') WITHIN GROUP (ORDER BY gt.rn) FROM gt
             WHERE gt.GroupKey = g.GroupKey AND gt.GroupName = g.GroupName AND gt.rn <= 3) AS NVARCHAR(MAX)) AS TopTests
    INTO #G
    FROM g INNER JOIN #R r ON r.PatientId = g.PatientId
    GROUP BY g.GroupKey, g.GroupName;

    -- for the charts of the page (not "Group by" choices): the 10 tests taken by most patients, and patients by day
    -- (new = their first bill at the branch was that day)
    INSERT INTO #G (GroupKey, GroupId, GroupName, SortOrder, Patients, NewPatients, Returning, Visits, AvgVisits, Tests, Revenue, RevenuePerPatient, TopTests)
    SELECT TOP 10 'tests', NULL, l.TestName, 0, COUNT(DISTINCT l.PatientId), NULL, NULL, COUNT(DISTINCT l.LabOrderId), NULL, COUNT(1), NULL, NULL, NULL
    FROM #L l GROUP BY l.TestName ORDER BY COUNT(DISTINCT l.PatientId) DESC, COUNT(1) DESC, l.TestName;

    INSERT INTO #G (GroupKey, GroupId, GroupName, SortOrder, Patients, NewPatients, Returning, Visits, AvgVisits, Tests, Revenue, RevenuePerPatient, TopTests)
    SELECT 'trend', NULL, CONVERT(VARCHAR(10), CAST(b.OrderDate AS DATE), 23), 0,
           COUNT(DISTINCT b.PatientId),
           COUNT(DISTINCT CASE WHEN CAST(r.FirstEver AS DATE) = CAST(b.OrderDate AS DATE) THEN b.PatientId END),
           COUNT(DISTINCT CASE WHEN CAST(r.FirstEver AS DATE) <> CAST(b.OrderDate AS DATE) THEN b.PatientId END),
           COUNT(1), NULL, NULL, SUM(b.NetAmount), NULL, NULL
    FROM #B b INNER JOIN #R r ON r.PatientId = b.PatientId
    GROUP BY CAST(b.OrderDate AS DATE);

    SELECT * FROM #G ORDER BY GroupKey, SortOrder, CASE WHEN GroupKey = 'tests' THEN Patients END DESC, GroupName;

    -- RS3 rows: one per patient, most visits first
    SELECT * FROM #R ORDER BY Visits DESC, Spent DESC, PatientName;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(u.Id AS VARCHAR(20)) AS Value, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Text
    FROM dbo.LabOrder lo INNER JOIN dbo.Users u ON u.Id = lo.CreatedBy
    WHERE lo.BranchId = @BranchId AND lo.OrderDate >= @From AND lo.OrderDate < @To;

    DROP TABLE #G; DROP TABLE #R; DROP TABLE #L; DROP TABLE #B;
END;
GO

-- ============================================================================
-- LR-27 Staff Productivity - NABL / NABH quality indicator. What each user of the branch did in the period, by the
-- date of each action: bills raised, money receipts taken (wallet deductions left out), specimens collected, results
-- entered (parameters), results validated, results signed / approved (each level), reports printed; and errors:
-- re-collects (specimens they collected that were rejected or sent for re-collection) and un-authorizations (results
-- they had approved that were withdrawn). An action whose person is not on record (history rebuilt from the audit trail)
-- is counted under "Not recorded". Own data: their own row only.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_StaffProductivity
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Activity      VARCHAR(20)   = NULL,   -- BILL / RECEIPT / SAMPLE / ENTERED / VALIDATED / APPROVED / PRINTED / RECOLLECT / UNAUTHORIZED
    @StaffId       INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    IF @OwnOnly = 1 SET @StaffId = @UserId;
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Activity = NULLIF(UPPER(LTRIM(RTRIM(@Activity))), '');

    CREATE TABLE #A (StaffId INT, Activity VARCHAR(20), LabOrderId INT, OccurredOn DATETIME, Qty INT, Amount DECIMAL(18, 2) NULL);

    -- bills raised
    INSERT INTO #A
    SELECT lo.CreatedBy, 'BILL', lo.LabOrderId, lo.OrderDate, 1,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2))
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    WHERE lo.BranchId = @BranchId AND lo.OrderDate >= @From AND lo.OrderDate < @To AND lo.CreatedBy IS NOT NULL;

    -- money receipts taken (one receipt number = one receipt)
    INSERT INTO #A
    SELECT pd.CreatedBy, 'RECEIPT', MIN(ph.ModuleRefId), MIN(COALESCE(pd.PaymentDate, pd.CreatedDate)), 1, SUM(pd.PaidAmount)
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    WHERE ph.BranchId = @BranchId AND pd.IsActive = 1 AND pd.CreatedBy IS NOT NULL
      AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To
    GROUP BY pd.CreatedBy, ISNULL(pd.ReceiptNo, CAST(pd.PaymentDetailId AS VARCHAR(30)));

    -- specimens collected (a profile counts once, as LR-11)
    INSERT INTO #A
    SELECT l.ChangedBy, 'SAMPLE', l.LabOrderId, MIN(l.ChangedOn),
           COUNT(DISTINCT COALESCE(l.BarcodeNo, CASE WHEN l.ProfileId IS NOT NULL THEN CONCAT('P', l.LabOrderId, '-', l.ProfileId) ELSE CONCAT('S', l.SampleCollectionId) END)), NULL
    FROM dbo.LabSampleStatusLog l
    WHERE l.BranchId = @BranchId AND l.ToStatusId = 2 AND l.ChangedOn >= @From AND l.ChangedOn < @To
    GROUP BY l.ChangedBy, l.LabOrderId;

    -- results entered (parameters), at the branch that holds the sample
    INSERT INTO #A
    SELECT led.CreatedBy, 'ENTERED', led.LabOrderId, MIN(led.CreatedDate), COUNT(1), NULL
    FROM dbo.labentrydetails led
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
    WHERE led.CreatedDate >= @From AND led.CreatedDate < @To AND led.CreatedBy IS NOT NULL
      AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId) OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId))
    GROUP BY led.CreatedBy, led.LabOrderId;

    -- results validated (the validation entry of the audit trail, with its result count)
    INSERT INTO #A
    SELECT a.UserId, 'VALIDATED', a.ReferenceId, MIN(a.CreatedDate),
           SUM(ISNULL(TRY_CAST(JSON_VALUE(a.MetadataJson, '$.ResultCount') AS INT), 1)), NULL
    FROM dbo.AuditLogs a
    WHERE a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportValidated' AND a.BranchId = @BranchId
      AND a.CreatedDate >= @From AND a.CreatedDate < @To AND a.UserId IS NOT NULL AND a.ReferenceId IS NOT NULL
    GROUP BY a.UserId, a.ReferenceId;

    -- results signed / approved (each level counts)
    INSERT INTO #A
    SELECT ap.ApprovedBy, 'APPROVED', ap.LabOrderId, MIN(ap.ApprovedDate), COUNT(1), NULL
    FROM dbo.LabReportApproval ap
    WHERE ap.BranchId = @BranchId AND ap.ApprovedDate >= @From AND ap.ApprovedDate < @To AND ap.ApprovedBy IS NOT NULL
    GROUP BY ap.ApprovedBy, ap.LabOrderId;

    -- reports printed
    INSERT INTO #A
    SELECT a.UserId, 'PRINTED', MIN(a.ReferenceId), MIN(a.CreatedDate), COUNT(1), NULL
    FROM dbo.AuditLogs a
    WHERE a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportPrinted' AND a.BranchId = @BranchId
      AND a.CreatedDate >= @From AND a.CreatedDate < @To AND a.UserId IS NOT NULL
    GROUP BY a.UserId, a.ReferenceNo;

    -- errors: specimens rejected / sent for re-collection, put against the person who had collected them
    INSERT INTO #A
    SELECT c.ChangedBy, 'RECOLLECT', r.LabOrderId, MIN(r.ChangedOn),
           COUNT(DISTINCT COALESCE(r.BarcodeNo, CASE WHEN r.ProfileId IS NOT NULL THEN CONCAT('P', r.LabOrderId, '-', r.ProfileId) ELSE CONCAT('S', r.SampleCollectionId) END)), NULL
    FROM dbo.LabSampleStatusLog r
    OUTER APPLY (SELECT TOP 1 c1.ChangedBy FROM dbo.LabSampleStatusLog c1
                  WHERE c1.SampleCollectionId = r.SampleCollectionId AND c1.ToStatusId = 2 AND c1.ChangedOn <= r.ChangedOn
                  ORDER BY c1.ChangedOn DESC, c1.LogId DESC) c
    WHERE r.BranchId = @BranchId AND r.ToStatusId IN (3, 4) AND r.ChangedOn >= @From AND r.ChangedOn < @To
    GROUP BY c.ChangedBy, r.LabOrderId;

    -- errors: approved results withdrawn, put against who had approved them (kept with the withdrawal from 2209,
    -- read from the approval entry of the audit trail before that)
    INSERT INTO #A
    SELECT x.ApprovedById, 'UNAUTHORIZED', x.LabOrderId, MIN(x.UnapprovedDate), COUNT(1), NULL
    FROM (SELECT un.LabOrderId, un.UnapprovedDate,
                 COALESCE(un.PreviousApprovedBy,
                          (SELECT TOP 1 a.UserId FROM dbo.AuditLogs a
                            WHERE un.PreviousApprovedDate IS NOT NULL AND a.ModuleCode = 'LAB' AND a.ActionName = 'LAB.ReportApproved'
                              AND a.ReferenceId = un.LabOrderId
                              AND a.CreatedDate BETWEEN DATEADD(SECOND, -30, un.PreviousApprovedDate) AND DATEADD(MINUTE, 2, un.PreviousApprovedDate)
                            ORDER BY ABS(DATEDIFF(SECOND, un.PreviousApprovedDate, a.CreatedDate)))) AS ApprovedById
          FROM dbo.LabReportUnapproval un
          INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = un.SamplecollectionID
          WHERE un.UnapprovedDate >= @From AND un.UnapprovedDate < @To
            AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId) OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId))) x
    GROUP BY x.ApprovedById, x.LabOrderId;

    -- actions whose person is not on record (history rebuilt before the logs existed) stay in the totals as "Not recorded"
    IF @StaffId IS NOT NULL DELETE FROM #A WHERE StaffId IS NULL OR StaffId <> @StaffId;

    SELECT a.StaffId, COALESCE(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username, 'Not recorded') AS StaffName, NULLIF(LTRIM(RTRIM(u.Role)), '') AS StaffRole,
           a.Activity,
           CASE a.Activity WHEN 'BILL' THEN 1 WHEN 'RECEIPT' THEN 2 WHEN 'SAMPLE' THEN 3 WHEN 'ENTERED' THEN 4 WHEN 'VALIDATED' THEN 5
                           WHEN 'APPROVED' THEN 6 WHEN 'PRINTED' THEN 7 WHEN 'RECOLLECT' THEN 8 ELSE 9 END AS ActivityOrder,
           CASE a.Activity WHEN 'BILL' THEN 'Bill raised' WHEN 'RECEIPT' THEN 'Money receipt' WHEN 'SAMPLE' THEN 'Specimens collected'
                           WHEN 'ENTERED' THEN 'Results entered' WHEN 'VALIDATED' THEN 'Results validated' WHEN 'APPROVED' THEN 'Results signed'
                           WHEN 'PRINTED' THEN 'Report printed' WHEN 'RECOLLECT' THEN 'Re-collect (error)' ELSE 'Un-authorized (error)' END AS ActivityName,
           CAST(CASE WHEN a.Activity IN ('RECOLLECT', 'UNAUTHORIZED') THEN 1 ELSE 0 END AS BIT) AS IsError,
           a.LabOrderId, lo.BillNo, lo.TokenNo, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           a.OccurredOn, CONVERT(VARCHAR(10), CAST(a.OccurredOn AS DATE), 23) AS Day, a.Qty, a.Amount
    INTO #R
    FROM #A a
    LEFT JOIN dbo.Users u ON u.Id = a.StaffId
    LEFT JOIN dbo.LabOrder lo ON lo.LabOrderId = a.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE (@Activity IS NULL OR a.Activity = @Activity)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR u.FullName LIKE '%' + @Search + '%');

    -- RS1 summary
    SELECT COUNT(DISTINCT StaffId) AS Staff,
           ISNULL(SUM(CASE WHEN Activity = 'BILL' THEN Qty END), 0) AS Bills,
           ISNULL(SUM(CASE WHEN Activity = 'RECEIPT' THEN Qty END), 0) AS Receipts,
           ISNULL(SUM(CASE WHEN Activity = 'RECEIPT' THEN Amount END), 0) AS Collected,
           ISNULL(SUM(CASE WHEN Activity = 'SAMPLE' THEN Qty END), 0) AS Samples,
           ISNULL(SUM(CASE WHEN Activity = 'ENTERED' THEN Qty END), 0) AS Entered,
           ISNULL(SUM(CASE WHEN Activity = 'VALIDATED' THEN Qty END), 0) AS Validated,
           ISNULL(SUM(CASE WHEN Activity = 'APPROVED' THEN Qty END), 0) AS Approved,
           ISNULL(SUM(CASE WHEN Activity = 'PRINTED' THEN Qty END), 0) AS Printed,
           ISNULL(SUM(CASE WHEN Activity = 'RECOLLECT' THEN Qty END), 0) AS Recollects,
           ISNULL(SUM(CASE WHEN Activity = 'UNAUTHORIZED' THEN Qty END), 0) AS Unauthorized,
           CAST(SUM(CASE WHEN Activity = 'RECOLLECT' THEN Qty END) * 100.0 / NULLIF(SUM(CASE WHEN Activity = 'SAMPLE' THEN Qty END), 0) AS DECIMAL(10, 1)) AS RecollectRatePct,
           CAST(SUM(CASE WHEN Activity = 'UNAUTHORIZED' THEN Qty END) * 100.0 / NULLIF(SUM(CASE WHEN Activity = 'APPROVED' THEN Qty END), 0) AS DECIMAL(10, 1)) AS UnauthorizedRatePct,
           (SELECT TOP 1 StaffName FROM #R WHERE IsError = 0 AND StaffId IS NOT NULL GROUP BY StaffId, StaffName ORDER BY COUNT(DISTINCT CONCAT(Activity, ':', LabOrderId)) DESC, StaffName) AS BusiestStaff
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byStaff' AS GroupKey, StaffId AS GroupId, StaffName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byActivity', ActivityOrder, ActivityName, ActivityOrder, * FROM #R
        UNION ALL SELECT 'byDate', NULL, Day, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(DISTINCT StaffId) AS Staff,
           ISNULL(SUM(CASE WHEN Activity = 'BILL' THEN Qty END), 0) AS Bills,
           ISNULL(SUM(CASE WHEN Activity = 'RECEIPT' THEN Qty END), 0) AS Receipts,
           ISNULL(SUM(CASE WHEN Activity = 'RECEIPT' THEN Amount END), 0) AS Collected,
           ISNULL(SUM(CASE WHEN Activity = 'SAMPLE' THEN Qty END), 0) AS Samples,
           ISNULL(SUM(CASE WHEN Activity = 'ENTERED' THEN Qty END), 0) AS Entered,
           ISNULL(SUM(CASE WHEN Activity = 'VALIDATED' THEN Qty END), 0) AS Validated,
           ISNULL(SUM(CASE WHEN Activity = 'APPROVED' THEN Qty END), 0) AS Approved,
           ISNULL(SUM(CASE WHEN Activity = 'PRINTED' THEN Qty END), 0) AS Printed,
           ISNULL(SUM(CASE WHEN Activity = 'RECOLLECT' THEN Qty END), 0) AS Recollects,
           ISNULL(SUM(CASE WHEN Activity = 'UNAUTHORIZED' THEN Qty END), 0) AS Unauthorized,
           ISNULL(SUM(Qty), 0) AS Quantity,
           CAST(SUM(CASE WHEN Activity = 'RECOLLECT' THEN Qty END) * 100.0 / NULLIF(SUM(CASE WHEN Activity = 'SAMPLE' THEN Qty END), 0) AS DECIMAL(10, 1)) AS RecollectRatePct,
           CAST(SUM(CASE WHEN Activity = 'UNAUTHORIZED' THEN Qty END) * 100.0 / NULLIF(SUM(CASE WHEN Activity = 'APPROVED' THEN Qty END), 0) AS DECIMAL(10, 1)) AS UnauthorizedRatePct
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, COUNT(1) DESC, GroupName;

    -- RS3 rows: one per person, activity and bill, latest first
    SELECT * FROM #R ORDER BY OccurredOn DESC, StaffName, ActivityOrder;

    -- RS4 filter options: users of the branch
    SELECT DISTINCT 'staffId' AS FilterKey, CAST(u.Id AS VARCHAR(20)) AS Value, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Text
    FROM dbo.Users u INNER JOIN dbo.UserBranches ub ON ub.UserId = u.Id AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1
    WHERE ISNULL(u.IsActive, 0) = 1;

    DROP TABLE #R; DROP TABLE #A;
END;
GO

-- ── menu pages and endpoints (database navigation, Reports > LAB) ───────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.LABREVENUETREND',       N'Revenue & Footfall Trend', N'LabRevenueTrend',       210, N'bi bi-graph-up-arrow me-2'),
    (N'REPORTS.LABPATIENTANALYTICS',   N'Patient Analytics',        N'LabPatientAnalytics',   215, N'bi bi-people me-2'),
    (N'REPORTS.LABSTAFFPRODUCTIVITY',  N'Staff Productivity',       N'LabStaffProductivity',  220, N'bi bi-person-workspace me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pc; FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title,
                 @Controller = N'Reports', @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon,
                 @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2210 applied: Reports > LAB > LR-24, LR-26, LR-27.';
GO
