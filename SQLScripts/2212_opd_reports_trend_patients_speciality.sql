-- ============================================================================
-- Migration: 2212_opd_reports_trend_patients_speciality.sql
-- Description: three Reports > OPD management analytics from the OPD Reports Roadmap, on the shared register pattern
--   (one procedure per report returning Summary / Groups / Rows / Options, run through api/reports/opd/run/{report},
--   page on _LabReportShell + lab-report.js), the OPD counterparts of LAB LR-24 / LR-26.
--     OR-24 OPD Revenue & Footfall Trend           usp_Api_OpdReport_RevenueTrend            by bill date (money by receipt date)
--     OR-25 OPD Patient Analytics                  usp_Api_OpdReport_PatientAnalytics        by bill date
--     OR-26 Speciality & Department Performance    usp_Api_OpdReport_SpecialityPerformance   by bill date, Administrators only
--   A visit is an active OPD bill (PatientOPDService, IsActive = 1); revenue is its net (PaymentHeader.NetAmount, which
--   a partial cancellation already reduces), as in OR-17. New patient = their first active OPD bill at the branch.
--   Visibility as the other OPD reports: branch first (usp_LabReport_CheckAccess), Administrator / super admin see every
--   user's data, everyone else only bills they created; OR-26 compares specialities and is for Administrators only.
--   Pages are added to Reports > OPD with their VIEW endpoints; no role or user grant is seeded. Read-only.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- OR-24 OPD Revenue & Footfall Trend - is the OPD growing, and when is it busiest? Active OPD bills of the branch by
-- bill date: revenue (net), visits, patients, new patients, booked / walk-in; money received by receipt date. Growth
-- against the previous period of the same length, month-on-month change, and visits by hour of day x day of week
-- (the staffing heatmap). Own data: bills they created; money they received.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_RevenueTrend
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @VisitMode     VARCHAR(10)   = NULL,   -- BOOKED / WALKIN
    @DoctorId      INT           = NULL,
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
    SET @VisitMode = NULLIF(UPPER(LTRIM(RTRIM(@VisitMode))), '');
    DECLARE @Days INT = DATEDIFF(DAY, @FromDate, @ToDate) + 1;
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @PrevFrom DATETIME = DATEADD(DAY, -@Days, @From);
    -- month-on-month needs the month before the first month of the range
    DECLARE @MonthFrom DATETIME = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@FromDate), MONTH(@FromDate), 1));
    DECLARE @LoadFrom DATETIME = CASE WHEN @MonthFrom < @PrevFrom THEN @MonthFrom ELSE @PrevFrom END;

    SELECT s.OPDServiceId, s.CreatedDate AS BillDate, CAST(s.CreatedDate AS DATE) AS BillDay, s.PatientId, s.ConsultingDoctorId AS DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
           CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
           CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService s0
                                       WHERE s0.PatientId = s.PatientId AND s0.BranchId = @BranchId AND s0.IsActive = 1
                                         AND (s0.CreatedDate < s.CreatedDate OR (s0.CreatedDate = s.CreatedDate AND s0.OPDServiceId < s.OPDServiceId)))
                     THEN 1 ELSE 0 END AS BIT) AS IsNew,
           CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
           CAST(CASE WHEN s.CreatedDate >= @From AND s.CreatedDate < @To THEN 1 ELSE 0 END AS BIT) AS InPeriod,
           CAST(CASE WHEN s.CreatedDate >= @PrevFrom AND s.CreatedDate < @From THEN 1 ELSE 0 END AS BIT) AS InPrev,
           (DATEDIFF(DAY, '19000101', CAST(s.CreatedDate AS DATE)) % 7) + 1 AS WeekdayNo,   -- 1 = Monday
           DATEPART(HOUR, s.CreatedDate) AS HourNo
    INTO #O
    FROM dbo.PatientOPDService s
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.CreatedDate >= @LoadFrom AND s.CreatedDate < @To
      AND (@CreatedBy IS NULL OR s.CreatedBy = @CreatedBy)
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND (@VisitMode IS NULL OR (@VisitMode = 'BOOKED' AND s.ScheduleId IS NOT NULL) OR (@VisitMode = 'WALKIN' AND s.ScheduleId IS NULL));

    -- OPD money received at the branch by receipt date (as OR-19)
    SELECT CAST(COALESCE(pd.PaymentDate, pd.CreatedDate) AS DATE) AS PaidDay, pd.PaidAmount,
           CAST(CASE WHEN COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From THEN 1 ELSE 0 END AS BIT) AS InPeriod
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = ph.ModuleRefId
    WHERE ph.BranchId = @BranchId AND pd.IsActive = 1
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @PrevFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To
      AND (@CreatedBy IS NULL OR pd.CreatedBy = @CreatedBy)
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND (@VisitMode IS NULL OR (@VisitMode = 'BOOKED' AND s.ScheduleId IS NOT NULL) OR (@VisitMode = 'WALKIN' AND s.ScheduleId IS NULL));

    -- one row per calendar day of the period, days without visits included
    ;WITH n AS (SELECT TOP (@Days) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    SELECT DATEADD(DAY, n.i, @FromDate) AS DayDate INTO #D FROM n;

    SELECT CONVERT(VARCHAR(10), d.DayDate, 23) AS Day, DATENAME(WEEKDAY, d.DayDate) AS WeekdayName,
           (DATEDIFF(DAY, '19000101', d.DayDate) % 7) + 1 AS WeekdayNo,
           CONVERT(VARCHAR(7), d.DayDate, 23) AS Month,
           ISNULL(o.Visits, 0) AS Visits, ISNULL(o.Patients, 0) AS Patients, ISNULL(o.NewPatients, 0) AS NewPatients,
           ISNULL(o.BookedVisits, 0) AS BookedVisits, ISNULL(o.WalkInVisits, 0) AS WalkInVisits,
           ISNULL(o.Revenue, 0) AS Revenue, ISNULL(p.Collected, 0) AS Collected,
           CAST(CASE WHEN ISNULL(o.Visits, 0) > 0 THEN o.Revenue / o.Visits END AS DECIMAL(18, 2)) AS AvgBillValue
    INTO #R
    FROM #D d
    LEFT JOIN (SELECT BillDay, COUNT(1) AS Visits, COUNT(DISTINCT PatientId) AS Patients, SUM(CAST(IsNew AS INT)) AS NewPatients,
                      SUM(CAST(IsBooked AS INT)) AS BookedVisits, SUM(1 - CAST(IsBooked AS INT)) AS WalkInVisits, SUM(NetAmount) AS Revenue
               FROM #O WHERE InPeriod = 1 GROUP BY BillDay) o ON o.BillDay = d.DayDate
    LEFT JOIN (SELECT PaidDay, SUM(PaidAmount) AS Collected FROM #P WHERE InPeriod = 1 GROUP BY PaidDay) p ON p.PaidDay = d.DayDate;

    DECLARE @Rev DECIMAL(18, 2) = (SELECT ISNULL(SUM(NetAmount), 0) FROM #O WHERE InPeriod = 1);
    DECLARE @PrevRev DECIMAL(18, 2) = (SELECT ISNULL(SUM(NetAmount), 0) FROM #O WHERE InPrev = 1);
    DECLARE @Visits INT = (SELECT COUNT(1) FROM #O WHERE InPeriod = 1);
    DECLARE @PrevVisits INT = (SELECT COUNT(1) FROM #O WHERE InPrev = 1);
    DECLARE @Pat INT = (SELECT COUNT(DISTINCT PatientId) FROM #O WHERE InPeriod = 1);
    DECLARE @PrevPat INT = (SELECT COUNT(DISTINCT PatientId) FROM #O WHERE InPrev = 1);
    DECLARE @New INT = (SELECT COUNT(1) FROM #O WHERE InPeriod = 1 AND IsNew = 1);
    DECLARE @PrevNew INT = (SELECT COUNT(1) FROM #O WHERE InPrev = 1 AND IsNew = 1);
    DECLARE @Booked INT = (SELECT COUNT(1) FROM #O WHERE InPeriod = 1 AND IsBooked = 1);

    -- RS1 summary
    SELECT @Rev AS Revenue, @Visits AS Visits, @Pat AS Patients, @New AS NewPatients, @Booked AS BookedVisits, @Visits - @Booked AS WalkInVisits,
           CAST(CASE WHEN @Visits > 0 THEN @Booked * 100.0 / @Visits END AS DECIMAL(10, 1)) AS BookedPct,
           (SELECT ISNULL(SUM(PaidAmount), 0) FROM #P WHERE InPeriod = 1) AS Collected,
           CAST(CASE WHEN @Visits > 0 THEN @Rev / @Visits END AS DECIMAL(18, 2)) AS AvgBillValue,
           CAST(@Rev / @Days AS DECIMAL(18, 2)) AS AvgDailyRevenue,
           CAST(@Visits * 1.0 / @Days AS DECIMAL(10, 1)) AS AvgDailyVisits,
           @Days AS Days, @PrevRev AS PrevRevenue, @PrevVisits AS PrevVisits, @PrevPat AS PrevPatients, @PrevNew AS PrevNewPatients,
           CAST(CASE WHEN @PrevRev > 0 THEN (@Rev - @PrevRev) * 100.0 / @PrevRev END AS DECIMAL(10, 1)) AS RevenueGrowthPct,
           CAST(CASE WHEN @PrevVisits > 0 THEN (@Visits - @PrevVisits) * 100.0 / @PrevVisits END AS DECIMAL(10, 1)) AS VisitsGrowthPct,
           CAST(CASE WHEN @PrevPat > 0 THEN (@Pat - @PrevPat) * 100.0 / @PrevPat END AS DECIMAL(10, 1)) AS PatientsGrowthPct,
           CAST(CASE WHEN @PrevNew > 0 THEN (@New - @PrevNew) * 100.0 / @PrevNew END AS DECIMAL(10, 1)) AS NewGrowthPct,
           CONVERT(VARCHAR(10), CAST(@PrevFrom AS DATE), 23) AS PrevFrom, CONVERT(VARCHAR(10), DATEADD(DAY, -1, CAST(@From AS DATE)), 23) AS PrevTo,
           (SELECT TOP 1 Day FROM #R WHERE Visits > 0 ORDER BY Visits DESC, Revenue DESC, Day) AS PeakDay,
           (SELECT MAX(Visits) FROM #R) AS PeakDayVisits,
           (SELECT TOP 1 DATENAME(WEEKDAY, DATEADD(DAY, WeekdayNo - 1, '19000101')) FROM #O WHERE InPeriod = 1 GROUP BY WeekdayNo ORDER BY COUNT(1) DESC, WeekdayNo) AS BusiestWeekday,
           (SELECT TOP 1 HourNo FROM #O WHERE InPeriod = 1 GROUP BY HourNo ORDER BY COUNT(1) DESC, HourNo) AS BusiestHour;

    -- RS2 groups
    -- month-on-month: each month against the calendar month before it (the month before the range included)
    SELECT CONVERT(VARCHAR(7), BillDay, 23) AS Month, COUNT(1) AS Visits, COUNT(DISTINCT PatientId) AS Patients, SUM(CAST(IsNew AS INT)) AS NewPatients,
           SUM(CAST(IsBooked AS INT)) AS BookedVisits, SUM(1 - CAST(IsBooked AS INT)) AS WalkInVisits, SUM(NetAmount) AS Revenue
    INTO #M FROM #O GROUP BY CONVERT(VARCHAR(7), BillDay, 23);

    DECLARE @WeekdayCount TABLE (WeekdayNo INT, DayCount INT);
    INSERT INTO @WeekdayCount SELECT WeekdayNo, COUNT(1) FROM #R GROUP BY WeekdayNo;

    SELECT * FROM (
    SELECT 'byDay' AS GroupKey, NULL AS GroupId, CAST(Day AS NVARCHAR(300)) AS GroupName, 0 AS SortOrder,
           Visits, Patients, NewPatients, BookedVisits, WalkInVisits, Revenue, Collected, AvgBillValue,
           CAST(NULL AS DECIMAL(18, 2)) AS PrevRevenue, CAST(NULL AS DECIMAL(10, 1)) AS GrowthPct, CAST(NULL AS DECIMAL(10, 1)) AS VisitsPerDay
    FROM #R
    UNION ALL
    SELECT 'byMonth', NULL, m.Month, 0, m.Visits, m.Patients, m.NewPatients, m.BookedVisits, m.WalkInVisits, m.Revenue,
           (SELECT ISNULL(SUM(Collected), 0) FROM #R r WHERE r.Month = m.Month),
           CAST(CASE WHEN m.Visits > 0 THEN m.Revenue / m.Visits END AS DECIMAL(18, 2)),
           pm.Revenue,
           CAST(CASE WHEN pm.Revenue > 0 THEN (m.Revenue - pm.Revenue) * 100.0 / pm.Revenue END AS DECIMAL(10, 1)),
           NULL
    FROM #M m
    LEFT JOIN #M pm ON pm.Month = CONVERT(VARCHAR(7), DATEADD(MONTH, -1, CAST(m.Month + '-01' AS DATE)), 23)
    WHERE m.Month >= CONVERT(VARCHAR(7), @FromDate, 23)
    UNION ALL
    SELECT 'byWeekday', w.WeekdayNo, DATENAME(WEEKDAY, DATEADD(DAY, w.WeekdayNo - 1, '19000101')), w.WeekdayNo,
           ISNULL(x.Visits, 0), ISNULL(x.Patients, 0), ISNULL(x.NewPatients, 0), ISNULL(x.BookedVisits, 0), ISNULL(x.WalkInVisits, 0), ISNULL(x.Revenue, 0),
           (SELECT ISNULL(SUM(Collected), 0) FROM #R r WHERE r.WeekdayNo = w.WeekdayNo),
           CAST(CASE WHEN x.Visits > 0 THEN x.Revenue / x.Visits END AS DECIMAL(18, 2)), NULL, NULL,
           CAST(ISNULL(x.Visits, 0) * 1.0 / NULLIF(w.DayCount, 0) AS DECIMAL(10, 1))
    FROM @WeekdayCount w
    LEFT JOIN (SELECT WeekdayNo, COUNT(1) AS Visits, COUNT(DISTINCT PatientId) AS Patients, SUM(CAST(IsNew AS INT)) AS NewPatients,
                      SUM(CAST(IsBooked AS INT)) AS BookedVisits, SUM(1 - CAST(IsBooked AS INT)) AS WalkInVisits, SUM(NetAmount) AS Revenue
               FROM #O WHERE InPeriod = 1 GROUP BY WeekdayNo) x ON x.WeekdayNo = w.WeekdayNo
    UNION ALL
    SELECT 'byHour', HourNo, RIGHT('0' + CAST(HourNo AS VARCHAR(2)), 2) + ':00 - ' + RIGHT('0' + CAST(HourNo AS VARCHAR(2)), 2) + ':59', HourNo,
           COUNT(1), COUNT(DISTINCT PatientId), SUM(CAST(IsNew AS INT)), SUM(CAST(IsBooked AS INT)), SUM(1 - CAST(IsBooked AS INT)), SUM(NetAmount), NULL,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)), NULL, NULL, CAST(COUNT(1) * 1.0 / @Days AS DECIMAL(10, 1))
    FROM #O WHERE InPeriod = 1 GROUP BY HourNo
    UNION ALL
    SELECT 'byVisitMode', NULL, CASE WHEN IsBooked = 1 THEN 'BOOKED' ELSE 'WALKIN' END, 1 - CAST(IsBooked AS INT),
           COUNT(1), COUNT(DISTINCT PatientId), SUM(CAST(IsNew AS INT)), SUM(CAST(IsBooked AS INT)), SUM(1 - CAST(IsBooked AS INT)), SUM(NetAmount), NULL,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)), NULL, NULL, CAST(COUNT(1) * 1.0 / @Days AS DECIMAL(10, 1))
    FROM #O WHERE InPeriod = 1 GROUP BY IsBooked
    UNION ALL
    SELECT 'byDoctor', DoctorId, DoctorName, 0,
           COUNT(1), COUNT(DISTINCT PatientId), SUM(CAST(IsNew AS INT)), SUM(CAST(IsBooked AS INT)), SUM(1 - CAST(IsBooked AS INT)), SUM(NetAmount), NULL,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)), NULL, NULL, CAST(COUNT(1) * 1.0 / @Days AS DECIMAL(10, 1))
    FROM #O WHERE InPeriod = 1 GROUP BY DoctorId, DoctorName
    UNION ALL
    -- staffing heatmap: visits by day of week x hour of the bill (GroupId = weekday * 100 + hour); drawn by the page, not a "Group by"
    SELECT 'heat', WeekdayNo * 100 + HourNo, LEFT(DATENAME(WEEKDAY, DATEADD(DAY, WeekdayNo - 1, '19000101')), 3) + ' ' + RIGHT('0' + CAST(HourNo AS VARCHAR(2)), 2) + ':00',
           WeekdayNo * 100 + HourNo, COUNT(1), COUNT(DISTINCT PatientId), SUM(CAST(IsNew AS INT)), SUM(CAST(IsBooked AS INT)), SUM(1 - CAST(IsBooked AS INT)),
           SUM(NetAmount), NULL, NULL, NULL, NULL, NULL
    FROM #O WHERE InPeriod = 1 GROUP BY WeekdayNo, HourNo
    ) x
    ORDER BY GroupKey, SortOrder, CASE WHEN GroupKey = 'byDay' THEN GroupName END DESC, CASE WHEN GroupKey = 'byMonth' THEN GroupName END, Revenue DESC, GroupName;

    -- RS3 rows: one per day of the period, latest first
    SELECT * FROM #R ORDER BY Day DESC;

    -- RS4 filter options: who created OPD bills of the branch, and the doctors seen
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(u.Id AS VARCHAR(20)) AS Value, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Text
    FROM dbo.PatientOPDService s INNER JOIN dbo.Users u ON u.Id = s.CreatedBy
    WHERE s.BranchId = @BranchId AND s.CreatedDate >= @From AND s.CreatedDate < @To
    UNION
    SELECT DISTINCT 'doctorId', CAST(d.DoctorId AS VARCHAR(20)), ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor')
    FROM dbo.PatientOPDService s INNER JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE s.BranchId = @BranchId AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND (@OwnOnly = 0 OR s.CreatedBy = @UserId);

    DROP TABLE #O; DROP TABLE #P; DROP TABLE #D; DROP TABLE #R; DROP TABLE #M;
END;
GO

-- ============================================================================
-- OR-25 OPD Patient Analytics - who are our OPD patients, where do they come from, and do they come back? Patients
-- with an active OPD bill at the branch in the period. New = their first OPD bill at this branch is in the period;
-- returning = they had one before. Age at their latest visit of the period. Visits = OPD bills in the period. Area =
-- the area / city of the patient's address (Patient Master). The speciality and doctors each group sees most.
-- Own data: patients on bills they created (those bills only).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_PatientAnalytics
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @PatientType   VARCHAR(10)   = NULL,   -- NEW / RETURNING
    @AgeBand       VARCHAR(10)   = NULL,   -- 0-12 / 13-17 / 18-30 / 31-45 / 46-60 / 61+ / UNKNOWN
    @Gender        VARCHAR(10)   = NULL,   -- MALE / FEMALE / OTHER
    @DoctorId      INT           = NULL,
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

    SELECT s.OPDServiceId, s.PatientId, s.CreatedDate AS BillDate, s.ConsultingDoctorId AS DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
           ISNULL(sp.SpecialityName, 'No speciality') AS Speciality,
           CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
           CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount
    INTO #B
    FROM dbo.PatientOPDService s
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND (@CreatedBy IS NULL OR s.CreatedBy = @CreatedBy)
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId);

    SELECT p.PatientId, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           p.PhoneNumber,
           CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(p.Gender, '')))) IN ('MALE', 'M') THEN 'MALE'
                WHEN UPPER(LTRIM(RTRIM(ISNULL(p.Gender, '')))) IN ('FEMALE', 'F') THEN 'FEMALE' ELSE 'OTHER' END AS Gender,
           CAST(COALESCE(NULLIF(LTRIM(RTRIM(a.AreaName)), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(c.CityName)), ''), ''),
                         NULLIF(LTRIM(RTRIM(c.CityName)), ''), 'Not recorded') AS NVARCHAR(300)) AS Area,
           x.Visits, x.Spent, x.BookedVisits, x.FirstInPeriod, x.LastInPeriod,
           (SELECT COUNT(DISTINCT b.DoctorId) FROM #B b WHERE b.PatientId = p.PatientId) AS Doctors,
           (SELECT STRING_AGG(t.DoctorName, ', ') WITHIN GROUP (ORDER BY t.n DESC, t.DoctorName)
              FROM (SELECT TOP 3 b.DoctorName, COUNT(1) AS n FROM #B b WHERE b.PatientId = p.PatientId GROUP BY b.DoctorName ORDER BY COUNT(1) DESC, b.DoctorName) t) AS DoctorsSeen,
           (SELECT STRING_AGG(t.Speciality, ', ') WITHIN GROUP (ORDER BY t.n DESC, t.Speciality)
              FROM (SELECT TOP 3 b.Speciality, COUNT(1) AS n FROM #B b WHERE b.PatientId = p.PatientId GROUP BY b.Speciality ORDER BY COUNT(1) DESC, b.Speciality) t) AS Specialities,
           fv.FirstEver, fv.VisitsEver,
           (SELECT MAX(s2.CreatedDate) FROM dbo.PatientOPDService s2 WHERE s2.PatientId = p.PatientId AND s2.BranchId = @BranchId AND s2.IsActive = 1 AND s2.CreatedDate < @From) AS PreviousVisit,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, p.DateOfBirth, x.LastInPeriod) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, x.LastInPeriod), p.DateOfBirth) > x.LastInPeriod THEN 1 ELSE 0 END END AS AgeYears
    INTO #R
    FROM (SELECT PatientId, COUNT(1) AS Visits, SUM(NetAmount) AS Spent, SUM(CAST(IsBooked AS INT)) AS BookedVisits,
                 MIN(BillDate) AS FirstInPeriod, MAX(BillDate) AS LastInPeriod
          FROM #B GROUP BY PatientId) x
    INNER JOIN dbo.PatientMaster p ON p.PatientId = x.PatientId
    LEFT  JOIN dbo.AreaMaster a ON a.AreaId = p.AreaId
    LEFT  JOIN dbo.CityMaster c ON c.CityId = COALESCE(p.CityId, a.CityId)
    OUTER APPLY (SELECT MIN(s1.CreatedDate) AS FirstEver, COUNT(1) AS VisitsEver FROM dbo.PatientOPDService s1
                  WHERE s1.PatientId = p.PatientId AND s1.BranchId = @BranchId AND s1.IsActive = 1 AND s1.CreatedDate < @To) fv;

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
    DELETE b FROM #B b WHERE NOT EXISTS (SELECT 1 FROM #R r WHERE r.PatientId = b.PatientId);

    -- RS1 summary
    SELECT COUNT(1) AS Patients,
           SUM(CASE WHEN PatientType = 'NEW' THEN 1 ELSE 0 END) AS NewPatients,
           SUM(CASE WHEN PatientType = 'RETURNING' THEN 1 ELSE 0 END) AS Returning,
           CAST(CASE WHEN COUNT(1) > 0 THEN SUM(CASE WHEN PatientType = 'RETURNING' THEN 1 ELSE 0 END) * 100.0 / COUNT(1) END AS DECIMAL(10, 1)) AS ReturningPct,
           SUM(CASE WHEN Visits >= 2 THEN 1 ELSE 0 END) AS RepeatInPeriod,
           ISNULL(SUM(Visits), 0) AS Visits,
           ISNULL(SUM(BookedVisits), 0) AS BookedVisits,
           CAST(AVG(Visits * 1.0) AS DECIMAL(10, 2)) AS AvgVisits,
           ISNULL(SUM(Spent), 0) AS Revenue,
           CAST(CASE WHEN COUNT(1) > 0 THEN SUM(Spent) / COUNT(1) END AS DECIMAL(18, 2)) AS RevenuePerPatient,
           SUM(CASE WHEN Gender = 'MALE' THEN 1 ELSE 0 END) AS Male,
           SUM(CASE WHEN Gender = 'FEMALE' THEN 1 ELSE 0 END) AS Female,
           SUM(CASE WHEN Gender = 'OTHER' THEN 1 ELSE 0 END) AS OtherGender,
           CAST(AVG(AgeYears * 1.0) AS DECIMAL(10, 1)) AS AvgAge,
           CAST(AVG(DaysSincePrevious * 1.0) AS DECIMAL(10, 1)) AS AvgDaysBetweenVisits,
           SUM(CASE WHEN Area <> 'Not recorded' THEN 1 ELSE 0 END) AS AreaRecorded,
           (SELECT TOP 1 AgeBand FROM #R WHERE AgeBand <> 'UNKNOWN' GROUP BY AgeBand ORDER BY COUNT(1) DESC, AgeBand) AS TopAgeBand,
           (SELECT TOP 1 Area FROM #R WHERE Area <> 'Not recorded' GROUP BY Area ORDER BY COUNT(1) DESC, Area) AS TopArea,
           (SELECT TOP 1 Speciality FROM #B GROUP BY Speciality ORDER BY COUNT(DISTINCT PatientId) DESC, COUNT(1) DESC, Speciality) AS TopSpeciality
    FROM #R;

    -- RS2 groups, each with the specialities its patients saw most
    ;WITH g AS (
        SELECT 'byType' AS GroupKey, PatientType AS GroupName, CASE PatientType WHEN 'NEW' THEN 0 ELSE 1 END AS SortOrder, PatientId FROM #R
        UNION ALL SELECT 'byAgeBand', AgeBand, AgeBandOrder, PatientId FROM #R
        UNION ALL SELECT 'byGender', Gender, CASE Gender WHEN 'MALE' THEN 0 WHEN 'FEMALE' THEN 1 ELSE 2 END, PatientId FROM #R
        UNION ALL SELECT 'byVisits', VisitBand, CASE VisitBand WHEN '1' THEN 1 WHEN '2' THEN 2 ELSE 3 END, PatientId FROM #R
        UNION ALL SELECT 'byArea', Area, CASE WHEN Area = 'Not recorded' THEN 1 ELSE 0 END, PatientId FROM #R),
    gs AS (
        SELECT g.GroupKey, g.GroupName, b.Speciality, COUNT(DISTINCT b.PatientId) AS n,
               ROW_NUMBER() OVER (PARTITION BY g.GroupKey, g.GroupName ORDER BY COUNT(DISTINCT b.PatientId) DESC, COUNT(1) DESC, b.Speciality) AS rn
        FROM g INNER JOIN #B b ON b.PatientId = g.PatientId
        GROUP BY g.GroupKey, g.GroupName, b.Speciality)
    SELECT CAST(g.GroupKey AS VARCHAR(20)) AS GroupKey, CAST(NULL AS INT) AS GroupId, CAST(g.GroupName AS NVARCHAR(400)) AS GroupName, MIN(g.SortOrder) AS SortOrder,
           COUNT(1) AS Patients,
           SUM(CASE WHEN r.PatientType = 'NEW' THEN 1 ELSE 0 END) AS NewPatients,
           SUM(CASE WHEN r.PatientType = 'RETURNING' THEN 1 ELSE 0 END) AS Returning,
           SUM(r.Visits) AS Visits, CAST(AVG(r.Visits * 1.0) AS DECIMAL(10, 2)) AS AvgVisits,
           SUM(r.BookedVisits) AS BookedVisits, CAST(SUM(r.Spent) AS DECIMAL(18, 2)) AS Revenue,
           CAST(SUM(r.Spent) / COUNT(1) AS DECIMAL(18, 2)) AS RevenuePerPatient,
           CAST((SELECT STRING_AGG(gs.Speciality, ', ') WITHIN GROUP (ORDER BY gs.rn) FROM gs
             WHERE gs.GroupKey = g.GroupKey AND gs.GroupName = g.GroupName AND gs.rn <= 3) AS NVARCHAR(MAX)) AS TopSpecialities
    INTO #G
    FROM g INNER JOIN #R r ON r.PatientId = g.PatientId
    GROUP BY g.GroupKey, g.GroupName;

    -- for the charts of the page (not "Group by" choices): patients by speciality and by doctor (top 10), and patients
    -- by day (new = their first OPD bill at the branch was that day)
    INSERT INTO #G (GroupKey, GroupId, GroupName, SortOrder, Patients, NewPatients, Returning, Visits, AvgVisits, BookedVisits, Revenue, RevenuePerPatient, TopSpecialities)
    SELECT 'specialities', NULL, b.Speciality, 0, COUNT(DISTINCT b.PatientId),
           COUNT(DISTINCT CASE WHEN r.PatientType = 'NEW' THEN b.PatientId END), COUNT(DISTINCT CASE WHEN r.PatientType = 'RETURNING' THEN b.PatientId END),
           COUNT(1), NULL, SUM(CAST(b.IsBooked AS INT)), SUM(b.NetAmount), NULL, NULL
    FROM #B b INNER JOIN #R r ON r.PatientId = b.PatientId
    GROUP BY b.Speciality;

    INSERT INTO #G (GroupKey, GroupId, GroupName, SortOrder, Patients, NewPatients, Returning, Visits, AvgVisits, BookedVisits, Revenue, RevenuePerPatient, TopSpecialities)
    SELECT TOP 10 'doctors', b.DoctorId, b.DoctorName, 0, COUNT(DISTINCT b.PatientId),
           COUNT(DISTINCT CASE WHEN r.PatientType = 'NEW' THEN b.PatientId END), COUNT(DISTINCT CASE WHEN r.PatientType = 'RETURNING' THEN b.PatientId END),
           COUNT(1), NULL, SUM(CAST(b.IsBooked AS INT)), SUM(b.NetAmount), NULL, NULL
    FROM #B b INNER JOIN #R r ON r.PatientId = b.PatientId
    GROUP BY b.DoctorId, b.DoctorName ORDER BY COUNT(DISTINCT b.PatientId) DESC, COUNT(1) DESC, b.DoctorName;

    INSERT INTO #G (GroupKey, GroupId, GroupName, SortOrder, Patients, NewPatients, Returning, Visits, AvgVisits, BookedVisits, Revenue, RevenuePerPatient, TopSpecialities)
    SELECT 'trend', NULL, CONVERT(VARCHAR(10), CAST(b.BillDate AS DATE), 23), 0,
           COUNT(DISTINCT b.PatientId),
           COUNT(DISTINCT CASE WHEN CAST(r.FirstEver AS DATE) = CAST(b.BillDate AS DATE) THEN b.PatientId END),
           COUNT(DISTINCT CASE WHEN CAST(r.FirstEver AS DATE) <> CAST(b.BillDate AS DATE) THEN b.PatientId END),
           COUNT(1), NULL, SUM(CAST(b.IsBooked AS INT)), SUM(b.NetAmount), NULL, NULL
    FROM #B b INNER JOIN #R r ON r.PatientId = b.PatientId
    GROUP BY CAST(b.BillDate AS DATE);

    SELECT * FROM #G ORDER BY GroupKey, SortOrder, CASE WHEN GroupKey IN ('specialities', 'doctors', 'byArea') THEN Patients END DESC, GroupName;

    -- RS3 rows: one per patient, most visits first
    SELECT * FROM #R ORDER BY Visits DESC, Spent DESC, PatientName;

    -- RS4 filter options
    SELECT DISTINCT 'createdBy' AS FilterKey, CAST(u.Id AS VARCHAR(20)) AS Value, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS Text
    FROM dbo.PatientOPDService s INNER JOIN dbo.Users u ON u.Id = s.CreatedBy
    WHERE s.BranchId = @BranchId AND s.CreatedDate >= @From AND s.CreatedDate < @To
    UNION
    SELECT DISTINCT 'doctorId', CAST(d.DoctorId AS VARCHAR(20)), ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor')
    FROM dbo.PatientOPDService s INNER JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE s.BranchId = @BranchId AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND (@OwnOnly = 0 OR s.CreatedBy = @UserId);

    DROP TABLE #G; DROP TABLE #R; DROP TABLE #B;
END;
GO

-- ============================================================================
-- OR-26 Speciality & Department Performance - how does each speciality perform? Active OPD visits of the branch by
-- bill date, under the consulting doctor's primary speciality and OPD department(s) (Doctor Master; a doctor in two OPD
-- departments is shown under both names together, so totals stay right). Per speciality / department / doctor:
-- doctors, visits, patients, new patients, revenue, average wait, follow-up return rate and LAB conversion.
--   Wait      = registration -> consultation start, from the live token log (2191); visits without it are not timed.
--   Follow-up = the same patient came back to a doctor of the same speciality within 30 days of the visit.
--   LAB       = a LAB bill of the same patient at the branch within 7 days of the visit day; each LAB bill is credited
--               to the patient's latest OPD visit before it, so no LAB bill is counted twice.
-- Compares specialities: for Administrators only.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_SpecialityPerformance
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @VisitMode     VARCHAR(10)   = NULL,   -- BOOKED / WALKIN
    @SpecialityId  INT           = NULL,
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,   -- doctor, speciality or department
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0
        THROW 50011, 'Speciality & Department Performance compares specialities and is available to Administrators only.', 1;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @FollowUpDays INT = 30, @LabDays INT = 7;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @VisitMode = NULLIF(UPPER(LTRIM(RTRIM(@VisitMode))), '');

    SELECT s.OPDServiceId, s.PatientId, s.CreatedDate AS BillDate, CONVERT(VARCHAR(7), s.CreatedDate, 23) AS Month,
           s.ConsultingDoctorId AS DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS DoctorName,
           ISNULL(d.PrimarySpecialityId, 0) AS SpecialityId,
           CAST(ISNULL(sp.SpecialityName, 'No speciality') AS NVARCHAR(200)) AS Speciality,
           CAST(COALESCE(dep.OpdDepts, dep.AllDepts, 'No department') AS NVARCHAR(400)) AS Department,
           CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
           CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.PatientOPDService s0
                                       WHERE s0.PatientId = s.PatientId AND s0.BranchId = @BranchId AND s0.IsActive = 1
                                         AND (s0.CreatedDate < s.CreatedDate OR (s0.CreatedDate = s.CreatedDate AND s0.OPDServiceId < s.OPDServiceId)))
                     THEN 1 ELSE 0 END AS BIT) AS IsNew,
           CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
           CAST(CASE WHEN s.Status = 'Completed' THEN 1 ELSE 0 END AS BIT) AS IsCompleted,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.EmrPatientConsultation ec WHERE ec.OPDServiceId = s.OPDServiceId) THEN 1 ELSE 0 END AS BIT) AS IsDocumented,
           CASE WHEN tl.ConsultAt IS NOT NULL AND tl.ConsultAt >= ISNULL(tl.RegisteredAt, s.CreatedDate)
                THEN DATEDIFF(SECOND, ISNULL(tl.RegisteredAt, s.CreatedDate), tl.ConsultAt) / 60.0 END AS WaitMin,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.PatientOPDService s2
                                   LEFT JOIN dbo.DoctorMaster d2 ON d2.DoctorId = s2.ConsultingDoctorId
                                  WHERE s2.PatientId = s.PatientId AND s2.BranchId = @BranchId AND s2.IsActive = 1
                                    AND s2.OPDServiceId <> s.OPDServiceId AND s2.CreatedDate > s.CreatedDate
                                    AND s2.CreatedDate < DATEADD(DAY, @FollowUpDays + 1, CAST(CAST(s.CreatedDate AS DATE) AS DATETIME))
                                    AND ISNULL(d2.PrimarySpecialityId, 0) = ISNULL(d.PrimarySpecialityId, 0))
                     THEN 1 ELSE 0 END AS BIT) AS CameBack
    INTO #V
    FROM dbo.PatientOPDService s
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    OUTER APPLY (SELECT STRING_AGG(CASE WHEN dm.DeptType = 'OPD' THEN dm.DeptName END, ', ') WITHIN GROUP (ORDER BY dm.DeptName) AS OpdDepts,
                        STRING_AGG(dm.DeptName, ', ') WITHIN GROUP (ORDER BY dm.DeptName) AS AllDepts
                   FROM dbo.DoctorDepartmentMap m
                   INNER JOIN dbo.DepartmentMaster dm ON dm.DeptId = m.DeptId AND ISNULL(dm.IsActive, 1) = 1
                  WHERE m.DoctorId = s.ConsultingDoctorId AND ISNULL(m.IsActive, 1) = 1) dep
    OUTER APPLY (SELECT MIN(CASE WHEN l.ToStatus = 'Consulting' THEN l.ChangedAt END) AS ConsultAt,
                        MIN(CASE WHEN l.ToStatus = 'Registered' THEN l.ChangedAt END) AS RegisteredAt
                   FROM dbo.OPDTokenStatusLog l
                  WHERE l.OPDServiceId = s.OPDServiceId AND l.EventType = 'STATUS' AND l.Source = 'LIVE') tl
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.CreatedDate >= @From AND s.CreatedDate < @To
      AND (@DoctorId IS NULL OR s.ConsultingDoctorId = @DoctorId)
      AND (@SpecialityId IS NULL OR ISNULL(d.PrimarySpecialityId, 0) = @SpecialityId)
      AND (@VisitMode IS NULL OR (@VisitMode = 'BOOKED' AND s.ScheduleId IS NOT NULL) OR (@VisitMode = 'WALKIN' AND s.ScheduleId IS NULL));

    IF @Search IS NOT NULL DELETE FROM #V WHERE NOT (DoctorName LIKE '%' + @Search + '%' OR Speciality LIKE '%' + @Search + '%' OR Department LIKE '%' + @Search + '%');

    -- LAB bills of these patients, each credited to the patient's latest OPD visit before it (within @LabDays of its day)
    SELECT lo.LabOrderId, att.OPDServiceId,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount) ELSE ISNULL(lph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS LabAmount
    INTO #L
    FROM dbo.LabOrder lo
    LEFT JOIN dbo.PaymentHeader lph ON lph.ModuleCode = 'LAB' AND lph.ModuleRefId = lo.LabOrderId AND lph.IsActive = 1
    CROSS APPLY (SELECT TOP 1 s.OPDServiceId FROM dbo.PatientOPDService s
                  WHERE s.PatientId = lo.PatientId AND s.BranchId = @BranchId AND s.IsActive = 1
                    AND s.CreatedDate <= lo.OrderDate AND lo.OrderDate < DATEADD(DAY, @LabDays + 1, CAST(CAST(s.CreatedDate AS DATE) AS DATETIME))
                  ORDER BY s.CreatedDate DESC, s.OPDServiceId DESC) att
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND lo.OrderDate >= @From AND lo.OrderDate < DATEADD(DAY, @LabDays + 1, @To)
      AND lo.PatientId IN (SELECT PatientId FROM #V)
      AND att.OPDServiceId IN (SELECT OPDServiceId FROM #V);

    ALTER TABLE #V ADD LabBills INT, LabAmount DECIMAL(18, 2);
    UPDATE v SET LabBills = ISNULL(l.n, 0), LabAmount = ISNULL(l.amt, 0)
    FROM #V v LEFT JOIN (SELECT OPDServiceId, COUNT(1) AS n, SUM(LabAmount) AS amt FROM #L GROUP BY OPDServiceId) l ON l.OPDServiceId = v.OPDServiceId;

    DECLARE @Visits INT = (SELECT COUNT(1) FROM #V);

    -- RS1 summary
    SELECT COUNT(DISTINCT SpecialityId) AS Specialities, COUNT(DISTINCT Department) AS Departments, COUNT(DISTINCT DoctorId) AS Doctors,
           @Visits AS Visits, COUNT(DISTINCT PatientId) AS Patients, ISNULL(SUM(CAST(IsNew AS INT)), 0) AS NewPatients,
           ISNULL(SUM(CAST(IsBooked AS INT)), 0) AS BookedVisits,
           ISNULL(SUM(NetAmount), 0) AS Revenue,
           CAST(CASE WHEN @Visits > 0 THEN SUM(NetAmount) / @Visits END AS DECIMAL(18, 2)) AS RevenuePerVisit,
           SUM(CASE WHEN WaitMin IS NOT NULL THEN 1 ELSE 0 END) AS WaitMeasured,
           CAST(AVG(WaitMin) AS DECIMAL(10, 1)) AS AvgWaitMin,
           ISNULL(SUM(CAST(CameBack AS INT)), 0) AS FollowUps,
           CAST(CASE WHEN @Visits > 0 THEN SUM(CAST(CameBack AS INT)) * 100.0 / @Visits END AS DECIMAL(10, 1)) AS FollowUpRatePct,
           SUM(CASE WHEN LabBills > 0 THEN 1 ELSE 0 END) AS LabVisits,
           CAST(CASE WHEN @Visits > 0 THEN SUM(CASE WHEN LabBills > 0 THEN 1 ELSE 0 END) * 100.0 / @Visits END AS DECIMAL(10, 1)) AS LabConversionPct,
           ISNULL(SUM(LabBills), 0) AS LabBills, ISNULL(SUM(LabAmount), 0) AS LabRevenue,
           ISNULL(SUM(CAST(IsCompleted AS INT)), 0) AS Completed, ISNULL(SUM(CAST(IsDocumented AS INT)), 0) AS Documented,
           (SELECT TOP 1 Speciality FROM #V GROUP BY Speciality ORDER BY SUM(NetAmount) DESC, COUNT(1) DESC, Speciality) AS TopSpeciality,
           (SELECT TOP 1 SUM(NetAmount) FROM #V GROUP BY Speciality ORDER BY SUM(NetAmount) DESC, COUNT(1) DESC, Speciality) AS TopSpecialityRevenue,
           @FollowUpDays AS FollowUpDays, @LabDays AS LabDays
    FROM #V;

    -- RS2 groups: speciality, department, doctor, month; and speciality x month for the trend chart
    ;WITH g AS (
        SELECT 'bySpeciality' AS GroupKey, SpecialityId AS GroupId, Speciality AS GroupName, CASE WHEN SpecialityId = 0 THEN 1 ELSE 0 END AS SortOrder, * FROM #V
        UNION ALL SELECT 'byDepartment', NULL, Department, CASE WHEN Department = 'No department' THEN 1 ELSE 0 END, * FROM #V
        UNION ALL SELECT 'byDoctor', DoctorId, DoctorName, 0, * FROM #V
        UNION ALL SELECT 'byMonth', NULL, Month, 0, * FROM #V
        UNION ALL SELECT 'specMonth', SpecialityId, Month, 0, * FROM #V)
    SELECT GroupKey, GroupId, CAST(GroupName AS NVARCHAR(400)) AS GroupName, MIN(SortOrder) AS SortOrder,
           MIN(Speciality) AS Speciality,
           COUNT(DISTINCT DoctorId) AS Doctors, COUNT(1) AS Visits, COUNT(DISTINCT PatientId) AS Patients, SUM(CAST(IsNew AS INT)) AS NewPatients,
           SUM(CAST(IsBooked AS INT)) AS BookedVisits,
           CAST(SUM(NetAmount) AS DECIMAL(18, 2)) AS Revenue,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)) AS RevenuePerVisit,
           SUM(CASE WHEN WaitMin IS NOT NULL THEN 1 ELSE 0 END) AS WaitMeasured,
           CAST(AVG(WaitMin) AS DECIMAL(10, 1)) AS AvgWaitMin,
           SUM(CAST(CameBack AS INT)) AS FollowUps,
           CAST(SUM(CAST(CameBack AS INT)) * 100.0 / COUNT(1) AS DECIMAL(10, 1)) AS FollowUpRatePct,
           SUM(CASE WHEN LabBills > 0 THEN 1 ELSE 0 END) AS LabVisits,
           CAST(SUM(CASE WHEN LabBills > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(1) AS DECIMAL(10, 1)) AS LabConversionPct,
           SUM(LabAmount) AS LabRevenue
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey IN ('byMonth', 'specMonth') THEN GroupName END, SUM(NetAmount) DESC, GroupName;

    -- RS3 rows: one per doctor (Detail per doctor of the speciality)
    SELECT DoctorId, DoctorName, SpecialityId, Speciality, Department,
           COUNT(1) AS Visits, COUNT(DISTINCT PatientId) AS Patients, SUM(CAST(IsNew AS INT)) AS NewPatients,
           SUM(CAST(IsBooked AS INT)) AS BookedVisits, SUM(1 - CAST(IsBooked AS INT)) AS WalkInVisits,
           CAST(SUM(NetAmount) AS DECIMAL(18, 2)) AS Revenue,
           CAST(SUM(NetAmount) / COUNT(1) AS DECIMAL(18, 2)) AS RevenuePerVisit,
           SUM(CAST(IsCompleted AS INT)) AS Completed, SUM(CAST(IsDocumented AS INT)) AS Documented,
           SUM(CASE WHEN WaitMin IS NOT NULL THEN 1 ELSE 0 END) AS WaitMeasured,
           CAST(AVG(WaitMin) AS DECIMAL(10, 1)) AS AvgWaitMin,
           SUM(CAST(CameBack AS INT)) AS FollowUps,
           CAST(SUM(CAST(CameBack AS INT)) * 100.0 / COUNT(1) AS DECIMAL(10, 1)) AS FollowUpRatePct,
           SUM(CASE WHEN LabBills > 0 THEN 1 ELSE 0 END) AS LabVisits,
           CAST(SUM(CASE WHEN LabBills > 0 THEN 1 ELSE 0 END) * 100.0 / COUNT(1) AS DECIMAL(10, 1)) AS LabConversionPct,
           SUM(LabBills) AS LabBills, CAST(SUM(LabAmount) AS DECIMAL(18, 2)) AS LabRevenue,
           MIN(BillDate) AS FirstVisit, MAX(BillDate) AS LastVisit
    FROM #V
    GROUP BY DoctorId, DoctorName, SpecialityId, Speciality, Department
    ORDER BY Speciality, SUM(NetAmount) DESC, DoctorName;

    -- RS4 filter options: specialities and doctors seen at the branch in the period
    SELECT DISTINCT 'specialityId' AS FilterKey, CAST(sp.SpecialityId AS VARCHAR(20)) AS Value, sp.SpecialityName AS Text
    FROM dbo.PatientOPDService s
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    INNER JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.CreatedDate >= @From AND s.CreatedDate < @To
    UNION
    SELECT DISTINCT 'doctorId', CAST(d.DoctorId AS VARCHAR(20)), ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor')
    FROM dbo.PatientOPDService s INNER JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.CreatedDate >= @From AND s.CreatedDate < @To;

    DROP TABLE #L; DROP TABLE #V;
END;
GO

-- ── menu pages and endpoints (database navigation, Reports > OPD) ───────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.OPDREVENUETREND',         N'OPD Revenue & Footfall Trend',          N'OpdRevenueTrend',         16, N'bi bi-graph-up-arrow me-2'),
    (N'REPORTS.OPDPATIENTANALYTICS',     N'OPD Patient Analytics',                 N'OpdPatientAnalytics',     17, N'bi bi-people me-2'),
    (N'REPORTS.OPDSPECIALITYPERFORMANCE', N'Speciality & Department Performance',  N'OpdSpecialityPerformance', 18, N'bi bi-diagram-3 me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.OPD' AND CompanyId = @co;
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
                 @Controller = N'Reports', @Action = N'GetOpdReportData', @Source = 'SEED';
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2212 applied: Reports > OPD > OR-24, OR-25, OR-26.';
GO
