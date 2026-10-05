-- ============================================================================
-- Migration: 2215_opd_dashboard_enhanced_stats.sql
-- Description: OPD > Dashboard redesign. usp_Api_OPD_Dashboard_GetStats keeps every result set and column it had,
--   and adds what the new page shows:
--     RS1 summary      + in consultation, net billed, discount, collected that day (OPD receipts, any bill), still due on
--                        the day's bills (net - paid), bills with dues, booked / walk-in visits
--     RS4 roster       + patients in consultation per doctor
--     RS5 bookings     all bookings of the day (was the latest 10), + net amount, payment status (P / R / U, worked
--                        out from net and paid: the column was never returned, so every amount showed as unpaid),
--                        booked or walk-in, speciality, registration time
--     RS6 appointments + the same new columns
--     RS7 (new)        the 7 days ending on the date: visits, revenue, new patients (trend chart)
--   Read-only. Only the OPD dashboard calls this procedure.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_OPD_Dashboard_GetStats
    @BranchId  INT,
    @Date      DATE,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Date variables
    DECLARE @DayOfWeek TINYINT;
    -- Map to 1=Mon, 7=Sun regardless of @@DATEFIRST
    SET @DayOfWeek = (DATEPART(WEEKDAY, @Date) + @@DATEFIRST - 2) % 7 + 1;
    IF @DayOfWeek = 7 SET @DayOfWeek = 0;
    DECLARE @Next DATE = DATEADD(DAY, 1, @Date);

    -- the day's visits with their money (used by RS1, RS5, RS6)
    SELECT s.OPDServiceId, s.PatientId, s.ConsultingDoctorId, s.Status, s.TokenNo, s.OPDBillNo, s.VisitDate, s.AppointmentTime,
           s.CreatedDate, s.ScheduleId,
           CAST(ISNULL(s.TotalAmount, 0) AS DECIMAL(18, 2)) AS TotalAmount,
           CAST(ISNULL(ph.NetAmount, ISNULL(s.TotalAmount, 0)) AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS TotalPaid,
           CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount
    INTO #V
    FROM dbo.PatientOPDService s
    LEFT JOIN dbo.PaymentHeader ph ON ph.OPDServiceId = s.OPDServiceId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
    WHERE s.BranchId = @BranchId
      AND (@CompanyId IS NULL OR @CompanyId <= 0 OR s.CompanyId = @CompanyId)
      AND CAST(s.VisitDate AS DATE) = @Date
      AND s.IsActive = 1;

    -- Summary statistics calculations
    DECLARE @TotalPatients INT;
    SELECT @TotalPatients = COUNT(*)
    FROM dbo.PatientMaster
    WHERE BranchId = @BranchId
      AND (@CompanyId IS NULL OR @CompanyId <= 0 OR CompanyId = @CompanyId)
      AND IsActive = 1;

    DECLARE @TodayNewPatients INT;
    SELECT @TodayNewPatients = COUNT(*)
    FROM dbo.PatientMaster
    WHERE BranchId = @BranchId
      AND (@CompanyId IS NULL OR @CompanyId <= 0 OR CompanyId = @CompanyId)
      AND IsActive = 1
      AND CAST(CreatedDate AS DATE) = @Date;

    -- OPD money received at the branch that day (any bill, dues of earlier bills included)
    DECLARE @Collected DECIMAL(18, 2) = (
        SELECT ISNULL(SUM(pd.PaidAmount), 0)
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'OPD' AND ph.IsActive = 1
        WHERE ph.BranchId = @BranchId AND pd.IsActive = 1
          AND (@CompanyId IS NULL OR @CompanyId <= 0 OR ph.CompanyId = @CompanyId)
          AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @Date AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @Next);

    -- Return ResultSet 1: Summary Stats
    SELECT
        @TotalPatients AS TotalPatientsCount,
        @TodayNewPatients AS TodayNewRegistrations,
        COUNT(*) AS TodayTotalBookings,
        ISNULL(SUM(TotalAmount), 0) AS TodayTotalRevenue,
        ISNULL(SUM(CASE WHEN Status = 'Registered' THEN 1 ELSE 0 END), 0) AS TodayRegisteredCount,
        ISNULL(SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END), 0) AS TodayCompletedCount,
        ISNULL(SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END), 0) AS TodayCancelledCount,
        ISNULL(SUM(CASE WHEN Status = 'Consulting' THEN 1 ELSE 0 END), 0) AS TodayConsultingCount,
        ISNULL(SUM(NetAmount), 0) AS TodayNetAmount,
        ISNULL(SUM(DiscountAmount), 0) AS TodayDiscount,
        @Collected AS TodayCollected,
        ISNULL(SUM(CASE WHEN NetAmount > TotalPaid THEN NetAmount - TotalPaid ELSE 0 END), 0) AS TodayDue,
        ISNULL(SUM(CASE WHEN NetAmount > TotalPaid THEN 1 ELSE 0 END), 0) AS TodayDueBills,
        ISNULL(SUM(CASE WHEN ScheduleId IS NOT NULL THEN 1 ELSE 0 END), 0) AS TodayBookedCount,
        ISNULL(SUM(CASE WHEN ScheduleId IS NULL THEN 1 ELSE 0 END), 0) AS TodayWalkInCount
    FROM #V;

    -- Return ResultSet 2: Bookings by Status
    SELECT Status, COUNT(*) AS Count
    FROM #V
    GROUP BY Status;

    -- Return ResultSet 3: Bookings by Service Type
    SELECT
        ISNULL(si.ServiceType, 'Other') AS ServiceType,
        COUNT(*) AS Count,
        SUM(ISNULL(si.ServiceCharges, 0)) AS Revenue
    FROM dbo.PatientOPDServiceItem si
    INNER JOIN #V s ON s.OPDServiceId = si.OPDServiceId
    WHERE si.IsActive = 1
    GROUP BY si.ServiceType;

    -- Return ResultSet 4: Today's Doctor Roster Status / Summary
    SELECT
        d.DoctorId,
        d.FullName AS DoctorName,
        dsm.ScheduleId,
        dsm.StartTime,
        dsm.EndTime,
        drm.RoomName,
        fm.FloorName,
        (SELECT TOP 1 ds.SpecialityName
         FROM dbo.DoctorSpecialityMaster ds
         WHERE ds.SpecialityId = d.PrimarySpecialityId AND ds.IsActive = 1) AS Speciality,
        (SELECT COUNT(*) FROM #V s WHERE s.ConsultingDoctorId = d.DoctorId AND s.Status <> 'Cancelled') AS TotalVisits,
        (SELECT COUNT(*) FROM #V s WHERE s.ConsultingDoctorId = d.DoctorId AND s.Status = 'Completed') AS CompletedVisits,
        (SELECT COUNT(*) FROM #V s WHERE s.ConsultingDoctorId = d.DoctorId AND s.Status = 'Registered') AS PendingVisits,
        (SELECT COUNT(*) FROM #V s WHERE s.ConsultingDoctorId = d.DoctorId AND s.Status = 'Consulting') AS InConsultationVisits
    FROM dbo.DoctorScheduleMaster dsm
    INNER JOIN dbo.DoctorMaster d ON dsm.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorRoomMapping drmapping ON drmapping.DoctorId = d.DoctorId
    LEFT JOIN dbo.DoctorRoomMaster drm ON drm.RoomId = drmapping.RoomId
    LEFT JOIN dbo.FloorMaster fm ON fm.FloorId = drm.FloorId
    WHERE dsm.BranchId = @BranchId
      AND dsm.DayOfWeek = @DayOfWeek
      AND dsm.IsActive = 1
      AND dsm.EffectiveFrom <= @Date
      AND (dsm.EffectiveTo IS NULL OR dsm.EffectiveTo >= @Date)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.DoctorScheduleException de
          WHERE de.DoctorId = dsm.DoctorId
            AND de.BranchId = dsm.BranchId
            AND de.ExceptionDate = @Date
            AND de.IsActive = 1
      )
    ORDER BY dsm.StartTime;

    -- the day's bookings with patient, doctor and payment status (RS5 = all of them, RS6 = the booked ones)
    SELECT
        s.OPDServiceId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        )) AS PatientName,
        s.TokenNo,
        s.OPDBillNo,
        d.FullName AS ConsultingDoctorName,
        s.TotalAmount,
        s.TotalPaid,
        s.Status,
        s.VisitDate,
        s.AppointmentTime,
        s.NetAmount,
        CASE WHEN s.NetAmount > 0 AND s.TotalPaid >= s.NetAmount THEN 'P' WHEN s.NetAmount <= 0 THEN 'P'
             WHEN s.TotalPaid > 0 THEN 'R' ELSE 'U' END AS PaymentStatus,
        CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
        (SELECT TOP 1 ds.SpecialityName FROM dbo.DoctorSpecialityMaster ds WHERE ds.SpecialityId = d.PrimarySpecialityId) AS Speciality,
        s.CreatedDate AS RegisteredAt
    INTO #B
    FROM #V s
    INNER JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE p.IsActive = 1;

    -- Return ResultSet 5: the day's bookings (latest first)
    SELECT * FROM #B ORDER BY OPDServiceId DESC;

    -- Return ResultSet 6: the day's scheduled appointments
    SELECT * FROM #B WHERE AppointmentTime IS NOT NULL ORDER BY AppointmentTime ASC;

    -- Return ResultSet 7: the 7 days ending on the date (trend)
    ;WITH days AS (SELECT DATEADD(DAY, -n, @Date) AS Day FROM (VALUES (0), (1), (2), (3), (4), (5), (6)) x(n))
    SELECT dd.Day,
           (SELECT COUNT(*) FROM dbo.PatientOPDService s
             WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND (@CompanyId IS NULL OR @CompanyId <= 0 OR s.CompanyId = @CompanyId)
               AND CAST(s.VisitDate AS DATE) = dd.Day) AS Visits,
           (SELECT ISNULL(SUM(s.TotalAmount), 0) FROM dbo.PatientOPDService s
             WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND (@CompanyId IS NULL OR @CompanyId <= 0 OR s.CompanyId = @CompanyId)
               AND CAST(s.VisitDate AS DATE) = dd.Day) AS Revenue,
           (SELECT COUNT(*) FROM dbo.PatientMaster pm
             WHERE pm.BranchId = @BranchId AND pm.IsActive = 1 AND (@CompanyId IS NULL OR @CompanyId <= 0 OR pm.CompanyId = @CompanyId)
               AND CAST(pm.CreatedDate AS DATE) = dd.Day) AS NewPatients
    FROM days dd
    ORDER BY dd.Day;

    DROP TABLE #B; DROP TABLE #V;
END;
GO

PRINT 'Script 2215 applied: OPD dashboard statistics (consultation, collection, dues, payment status, trend).';
GO
