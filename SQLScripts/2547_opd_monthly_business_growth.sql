-- ============================================================================================================
-- 2547: Reports > OPD > OPD Monthly Business Growth - month-wise growth or loss of the OPD (same page as LAB 2546).
--   usp_Api_OpdReport_MonthlyGrowth returns, for each month of the range (up to 24 months) and the 12 months before it
--   (for the same month last year):
--     RS1 months       bills (= visits), cancelled bills, patients (new = first OPD bill ever), appointments / walk-ins,
--                      gross, discount, GST, net revenue (consulting / registration & other services), doctor share
--                      (Doctor Payout share lines of the month's bills), gross profit, receipts, refunds, cancelled
--                      amount, due on the month's bills.
--     RS2 doctors      net revenue per consulting doctor per month.
--     RS3 specialities net revenue per speciality (the doctor's primary speciality) per month.
--     RS4 services     net revenue per service billed per month (each bill's net shared over its lines by charge).
--     RS5 branches     net revenue and bills per branch per month.
--     RS6 meta         branches in scope.
--   Definitions as the OPD registers (2211): a bill is a PatientOPDService row, bill date = CreatedDate, net = the
--   PaymentHeader net (TotalAmount when there is none), receipts by receipt date. Doctor share is brought up to date
--   for the range first (usp_DoctorPayout_Accrue, as the Doctor Share Register does).
--   Scope: the current branch, or all branches the user works in (super admin: all of the company).
--   Page REPORTS.OPDMONTHLYGROWTH (Reports > OPD). No grants are seeded: give them in Role Permissions.
-- Needs 2211, 2213. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_MonthlyGrowth
    @BranchId     INT,
    @FromMonth    DATE,          -- any day of the first month
    @ToMonth      DATE,          -- any day of the last month
    @AllBranches  BIT = 0,
    @UserId       INT = NULL,
    @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;

    SET @FromMonth = DATEFROMPARTS(YEAR(@FromMonth), MONTH(@FromMonth), 1);
    SET @ToMonth   = DATEFROMPARTS(YEAR(@ToMonth), MONTH(@ToMonth), 1);
    IF @ToMonth < @FromMonth BEGIN DECLARE @sw DATE = @FromMonth; SET @FromMonth = @ToMonth; SET @ToMonth = @sw; END
    IF DATEDIFF(MONTH, @FromMonth, @ToMonth) > 23
        THROW 50020, 'Please select up to 24 months.', 1;

    DECLARE @LoadFrom DATETIME = DATEADD(MONTH, -12, @FromMonth);           -- same month last year
    DECLARE @To       DATETIME = DATEADD(MONTH, 1, @ToMonth);

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

    -- doctor share lines up to date for the range (each branch)
    DECLARE @AccFrom DATE = @FromMonth, @AccTo DATE = DATEADD(DAY, -1, CAST(@To AS DATE)), @ab INT;
    IF @AccTo > CAST(GETDATE() AS DATE) SET @AccTo = CAST(GETDATE() AS DATE);
    IF @AccTo >= @AccFrom
    BEGIN
        DECLARE ac CURSOR LOCAL FAST_FORWARD FOR SELECT BranchId FROM @Br;
        OPEN ac; FETCH NEXT FROM ac INTO @ab;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_DoctorPayout_Accrue @BranchId = @ab, @FromDate = @AccFrom, @ToDate = @AccTo, @UserId = @UserId;
            FETCH NEXT FROM ac INTO @ab;
        END
        CLOSE ac; DEALLOCATE ac;
    END

    -- ── the months (range + 12 before it) ────────────────────────────────────
    CREATE TABLE #M (MonthStart DATE PRIMARY KEY, InRange BIT);
    DECLARE @m DATE = CAST(@LoadFrom AS DATE);
    WHILE @m <= @ToMonth
    BEGIN
        INSERT #M VALUES (@m, CASE WHEN @m >= @FromMonth THEN 1 ELSE 0 END);
        SET @m = DATEADD(MONTH, 1, @m);
    END

    -- ── bills ────────────────────────────────────────────────────────────────
    SELECT s.OPDServiceId, s.BranchId, s.PatientId, s.ConsultingDoctorId AS DoctorId,
           DATEFROMPARTS(YEAR(s.CreatedDate), MONTH(s.CreatedDate), 1) AS MonthStart,
           CAST(s.IsActive AS BIT) AS IsActive,
           CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
           CAST(ISNULL(s.TotalAmount, 0) AS DECIMAL(18, 2)) AS Gross,
           CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS Discount,
           CAST(ISNULL(ph.TotalCgstAmount, 0) + ISNULL(ph.TotalSgstAmount, 0) + ISNULL(ph.TotalIgstAmount, 0) AS DECIMAL(18, 2)) AS Tax,
           CAST(ISNULL(ph.NetAmount, s.TotalAmount) AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount
    INTO #O
    FROM dbo.PatientOPDService s
    INNER JOIN @Br br ON br.BranchId = s.BranchId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'OPD' AND ph.ModuleRefId = s.OPDServiceId AND ph.IsActive = 1
    WHERE s.CreatedDate >= @LoadFrom AND s.CreatedDate < @To;
    CREATE CLUSTERED INDEX IX_O ON #O (OPDServiceId);

    -- bill lines: each line's share of the bill's net, by its charge
    SELECT o.OPDServiceId, o.MonthStart,
           CASE WHEN si.ServiceType = 'Consulting' THEN 'C' WHEN ISNULL(sm.IsRegistration, 0) = 1 THEN 'R' ELSE 'S' END AS Kind,
           ISNULL(NULLIF(LTRIM(RTRIM(sm.ItemName)), ''), CASE WHEN si.ServiceType = 'Consulting' THEN N'Consultation' ELSE N'Other service' END) AS Service,
           CAST(ISNULL(si.ServiceCharges, 0) AS DECIMAL(18, 4)) AS Basis, o.NetAmount AS BillNet
    INTO #L
    FROM #O o
    INNER JOIN dbo.PatientOPDServiceItem si ON si.OPDServiceId = o.OPDServiceId AND si.IsActive = 1
    LEFT  JOIN dbo.ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE o.IsActive = 1;

    ALTER TABLE #L ADD NetLine DECIMAL(18, 2);
    ;WITH s AS (SELECT OPDServiceId, SUM(Basis) AS SumBasis, COUNT(1) AS Lines FROM #L GROUP BY OPDServiceId)
    UPDATE l SET NetLine = CAST(CASE WHEN s.SumBasis > 0 THEN l.Basis * l.BillNet / s.SumBasis ELSE l.BillNet / s.Lines END AS DECIMAL(18, 2))
    FROM #L l INNER JOIN s ON s.OPDServiceId = l.OPDServiceId;

    -- per bill: consulting / registration / other net, doctor share
    ALTER TABLE #O ADD ConsultNet DECIMAL(18, 2) NOT NULL DEFAULT 0, RegNet DECIMAL(18, 2) NOT NULL DEFAULT 0,
                       ServiceNet DECIMAL(18, 2) NOT NULL DEFAULT 0, DoctorShare DECIMAL(18, 2) NOT NULL DEFAULT 0;
    UPDATE o SET ConsultNet = x.C, RegNet = x.R, ServiceNet = x.S
    FROM #O o INNER JOIN (SELECT OPDServiceId, SUM(CASE WHEN Kind = 'C' THEN NetLine ELSE 0 END) AS C,
                                 SUM(CASE WHEN Kind = 'R' THEN NetLine ELSE 0 END) AS R,
                                 SUM(CASE WHEN Kind = 'S' THEN NetLine ELSE 0 END) AS S
                          FROM #L GROUP BY OPDServiceId) x ON x.OPDServiceId = o.OPDServiceId;
    -- a bill without lines counts as consulting
    UPDATE #O SET ConsultNet = NetAmount WHERE IsActive = 1 AND ConsultNet = 0 AND RegNet = 0 AND ServiceNet = 0;
    UPDATE o SET DoctorShare = x.Share
    FROM #O o INNER JOIN (SELECT dd.VisitId, SUM(dd.NetPayable) AS Share FROM dbo.DoctorDisbursal dd
                          WHERE dd.IsActive = 1 AND dd.VisitId IN (SELECT OPDServiceId FROM #O)
                          GROUP BY dd.VisitId) x ON x.VisitId = o.OPDServiceId;

    -- new patients: the month of the patient's first active OPD bill ever (any branch)
    SELECT f.PatientId, DATEFROMPARTS(YEAR(f.FirstBill), MONTH(f.FirstBill), 1) AS FirstMonth
    INTO #NP
    FROM (SELECT s.PatientId, MIN(s.CreatedDate) AS FirstBill FROM dbo.PatientOPDService s
          WHERE s.IsActive = 1 AND s.PatientId IN (SELECT PatientId FROM #O WHERE IsActive = 1)
          GROUP BY s.PatientId) f
    WHERE EXISTS (SELECT 1 FROM #O o WHERE o.PatientId = f.PatientId AND o.IsActive = 1
                    AND o.MonthStart = DATEFROMPARTS(YEAR(f.FirstBill), MONTH(f.FirstBill), 1));

    -- receipts (receipt date)
    SELECT DATEFROMPARTS(YEAR(COALESCE(pd.PaymentDate, pd.CreatedDate)), MONTH(COALESCE(pd.PaymentDate, pd.CreatedDate)), 1) AS MonthStart,
           pd.PaidAmount
    INTO #P
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    INNER JOIN @Br br ON br.BranchId = ph.BranchId
    WHERE pd.IsActive = 1 AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @LoadFrom AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    -- RS1 months
    SELECT CONVERT(VARCHAR(7), m.MonthStart, 23) AS Month, m.InRange,
           ISNULL(b.Bills, 0) AS Bills, ISNULL(b.CancelledBills, 0) AS CancelledBills,
           ISNULL(b.Patients, 0) AS Patients,
           ISNULL((SELECT COUNT(1) FROM #NP np WHERE np.FirstMonth = m.MonthStart), 0) AS NewPatients,
           ISNULL(b.Booked, 0) AS Appointments, ISNULL(b.Bills, 0) - ISNULL(b.Booked, 0) AS WalkIns,
           ISNULL(b.Doctors, 0) AS Doctors,
           ISNULL(b.Gross, 0) AS Gross, ISNULL(b.Discount, 0) AS Discount, ISNULL(b.Tax, 0) AS Tax,
           ISNULL(b.Net, 0) AS NetRevenue,
           ISNULL(b.ConsultNet, 0) AS ConsultRevenue, ISNULL(b.RegNet, 0) AS RegistrationRevenue, ISNULL(b.ServiceNet, 0) AS ServiceRevenue,
           ISNULL(b.DoctorShare, 0) AS DoctorShare,
           ISNULL(b.Net, 0) - ISNULL(b.DoctorShare, 0) AS GrossProfit,
           ISNULL(b.Due, 0) AS DueOnBills,
           ISNULL((SELECT SUM(p.PaidAmount) FROM #P p WHERE p.MonthStart = m.MonthStart), 0) AS Collected,
           ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r
                   INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = r.ModuleRefId
                   INNER JOIN @Br br ON br.BranchId = s.BranchId
                   WHERE r.ModuleCode = 'OPD' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P'
                     AND r.RefundDate >= m.MonthStart AND r.RefundDate < DATEADD(MONTH, 1, m.MonthStart)), 0) AS Refunds,
           ISNULL((SELECT SUM(bc.CancelledAmount) FROM dbo.BillCancellation bc
                   INNER JOIN dbo.PatientOPDService s ON s.OPDServiceId = bc.ModuleRefId
                   INNER JOIN @Br br ON br.BranchId = s.BranchId
                   WHERE bc.ModuleCode = 'OPD' AND bc.IsActive = 1
                     AND bc.CancellationDate >= m.MonthStart AND bc.CancellationDate < DATEADD(MONTH, 1, m.MonthStart)), 0) AS CancelledAmount,
           DAY(EOMONTH(m.MonthStart)) AS DaysInMonth,
           CASE WHEN m.MonthStart = DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1) THEN DAY(GETDATE())
                WHEN m.MonthStart > CAST(GETDATE() AS DATE) THEN 0 ELSE DAY(EOMONTH(m.MonthStart)) END AS DaysElapsed
    FROM #M m
    OUTER APPLY (SELECT SUM(CASE WHEN o.IsActive = 1 THEN 1 ELSE 0 END) AS Bills,
                        SUM(CASE WHEN o.IsActive = 0 THEN 1 ELSE 0 END) AS CancelledBills,
                        COUNT(DISTINCT CASE WHEN o.IsActive = 1 THEN o.PatientId END) AS Patients,
                        SUM(CASE WHEN o.IsActive = 1 AND o.IsBooked = 1 THEN 1 ELSE 0 END) AS Booked,
                        COUNT(DISTINCT CASE WHEN o.IsActive = 1 THEN o.DoctorId END) AS Doctors,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Gross END) AS Gross,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Discount END) AS Discount,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.Tax END) AS Tax,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.NetAmount END) AS Net,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.ConsultNet END) AS ConsultNet,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.RegNet END) AS RegNet,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.ServiceNet END) AS ServiceNet,
                        SUM(CASE WHEN o.IsActive = 1 THEN o.DoctorShare END) AS DoctorShare,
                        SUM(CASE WHEN o.IsActive = 1 AND o.NetAmount > o.PaidAmount THEN o.NetAmount - o.PaidAmount ELSE 0 END) AS Due
                 FROM #O o WHERE o.MonthStart = m.MonthStart) b
    ORDER BY m.MonthStart;

    -- RS2 consulting doctor by month (range months only)
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'No doctor') AS Doctor,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, o.DoctorId, d.NamePrefix, d.FullName
    ORDER BY o.MonthStart, Net DESC;

    -- RS3 speciality by month
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month, ISNULL(sp.SpecialityName, 'No speciality') AS Speciality,
           COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, sp.SpecialityName
    ORDER BY o.MonthStart, Net DESC;

    -- RS4 service by month
    SELECT CONVERT(VARCHAR(7), l.MonthStart, 23) AS Month, l.Service, COUNT(1) AS Bills, SUM(l.NetLine) AS Net
    FROM #L l WHERE l.MonthStart >= @FromMonth
    GROUP BY l.MonthStart, l.Service
    ORDER BY l.MonthStart, Net DESC;

    -- RS5 branch by month
    SELECT CONVERT(VARCHAR(7), o.MonthStart, 23) AS Month, br.BranchName AS Branch, COUNT(1) AS Bills, SUM(o.NetAmount) AS Net
    FROM #O o INNER JOIN @Br br ON br.BranchId = o.BranchId
    WHERE o.IsActive = 1 AND o.MonthStart >= @FromMonth
    GROUP BY o.MonthStart, br.BranchName
    ORDER BY o.MonthStart, Net DESC;

    -- RS6 meta
    SELECT (SELECT COUNT(1) FROM @Br) AS BranchCount,
           CONVERT(VARCHAR(7), @FromMonth, 23) AS FromMonth, CONVERT(VARCHAR(7), @ToMonth, 23) AS ToMonth;

    DROP TABLE #M; DROP TABLE #O; DROP TABLE #L; DROP TABLE #NP; DROP TABLE #P;
END;
GO

-- ── menu page and endpoints (database navigation) ────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.OPD' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.OPDMONTHLYGROWTH',
             @Title = N'OPD Monthly Business Growth', @Controller = N'Reports', @Action = N'OpdMonthlyGrowth', @Show_In_Menu = 1, @Sort_Order = 31,
             @Icon = N'bi bi-bar-chart-line me-2', @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'OpdMonthlyGrowth', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetOpdMonthlyGrowthData', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2547 applied: Reports > OPD > OPD Monthly Business Growth.';
GO
