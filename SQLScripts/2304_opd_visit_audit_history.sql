-- ============================================================================================================
-- Migration: 2304_opd_visit_audit_history.sql
-- OPD Dashboard > OPD visits of the day: an "i" icon per visit opens the Audit History with a workflow tracker -
-- the visit's journey from booking to consultation (like the LAB bill's Audit History, 2297):
--   booked / billed -> registration -> payment -> token -> vitals -> consultation and / or services -> completed,
--   with cancellation / refund. The stages follow what is on the bill: a consultation, other services (dressing...),
--   both, and the registration service (ServiceMaster.IsRegistration) as a stage of its own. Data goes EMR.Web -> EMR.Api (api/opd-visits) -> the procedures below. Read-only.
-- The new endpoints are mapped to the OPD Dashboard page (whoever opens the dashboard sees the history).
-- The dashboard procedure (2215) also returns VisitKind for the day's visits. No role grants change. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── the visit's activity: audit log, token / status changes, vitals of the day, consultation, video, cancellation ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdVisit_ActivityHistory
    @OPDServiceId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @PatientId INT, @VisitDate DATE, @BranchId INT;
    SELECT @PatientId = s.PatientId, @VisitDate = CAST(s.VisitDate AS DATE), @BranchId = s.BranchId
      FROM dbo.PatientOPDService s WHERE s.OPDServiceId = @OPDServiceId;
    IF @PatientId IS NULL RETURN;
    -- a visit with a consultation on the bill, or services only (dressing, procedures...)
    DECLARE @Kind VARCHAR(10) = CASE WHEN EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem i WHERE i.OPDServiceId = @OPDServiceId
                                                    AND ISNULL(i.IsActive, 1) = 1 AND i.ServiceType = 'Consulting') THEN 'CONSULT' ELSE 'SERVICE' END;

    SELECT x.EventDate, x.Source, x.EventType, x.ActionName, x.Description, x.UserId,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS UserName, b.BranchName, x.IpAddress, x.MetadataJson
      FROM (
            -- recorded activity tied to the visit (bill, payment, consultation, cancellation, refund...)
            SELECT a.CreatedDate AS EventDate, CAST('AUDIT' AS VARCHAR(20)) AS Source, a.EventType, a.ActionName, a.Description,
                   a.UserId, a.BranchId, a.IpAddress, a.MetadataJson
              FROM dbo.AuditLogs a
             WHERE a.ModuleCode = 'OPD' AND a.ReferenceId = @OPDServiceId AND a.ActionName NOT LIKE 'DoctorPayout.%'
            UNION ALL
            -- token issued and visit status changes (Registered -> Consulting -> Completed)
            SELECT l.ChangedAt, 'TOKEN', 'Visit',
                   CASE WHEN l.EventType = 'TOKEN' THEN 'OPD.TokenIssued' ELSE 'OPD.VisitStatus' END,
                   CASE WHEN l.EventType = 'TOKEN' THEN CONCAT('Token ', l.TokenNo, ' issued.')
                        WHEN l.FromStatus IS NULL THEN CONCAT('Visit ', LOWER(l.ToStatus), '.')
                        ELSE CONCAT('Status changed from ', l.FromStatus, ' to ', l.ToStatus, '.') END,
                   l.ChangedBy, @BranchId, NULL,
                   (SELECT l.FromStatus AS FromStatus, l.ToStatus AS ToStatus, l.TokenNo AS TokenNo, l.Source AS Origin, @Kind AS VisitKind FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
              FROM dbo.OPDTokenStatusLog l
             WHERE l.OPDServiceId = @OPDServiceId
            UNION ALL
            -- vitals recorded for the patient on the visit day
            SELECT v.RecordedOn, 'VITALS', 'Vitals', 'OPD.VitalsRecorded',
                   CONCAT('Vitals recorded',
                          CASE WHEN v.BPSystolic IS NOT NULL THEN CONCAT(' · BP ', v.BPSystolic, '/', v.BPDiastolic) ELSE '' END,
                          CASE WHEN v.PulseRate IS NOT NULL THEN CONCAT(' · Pulse ', v.PulseRate) ELSE '' END,
                          CASE WHEN v.SpO2 IS NOT NULL THEN CONCAT(' · SpO2 ', v.SpO2, '%') ELSE '' END,
                          CASE WHEN v.Temperature IS NOT NULL THEN CONCAT(' · Temp ', v.Temperature) ELSE '' END,
                          CASE WHEN v.Weight IS NOT NULL THEN CONCAT(' · Wt ', v.Weight) ELSE '' END, '.'),
                   ISNULL(v.RecordedByUserId, v.CreatedBy), @BranchId, NULL, NULL
              FROM dbo.PatientVitals v
             WHERE v.PatientId = @PatientId AND ISNULL(v.IsActive, 1) = 1 AND CAST(v.RecordedOn AS DATE) = @VisitDate
            UNION ALL
            -- follow-up set by the doctor (the consultation itself is in the audit log)
            SELECT c.FollowUpSetOn, 'EMR', 'Consultation', 'OPD.FollowUpSet',
                   CONCAT('Follow-up on ', FORMAT(c.FollowUpDate, 'dd MMM yyyy'), '.'), ISNULL(c.ModifiedBy, c.CreatedBy), @BranchId, NULL, NULL
              FROM dbo.EmrPatientConsultation c
             WHERE c.OPDServiceId = @OPDServiceId AND c.FollowUpDate IS NOT NULL AND c.FollowUpSetOn IS NOT NULL
            UNION ALL
            -- video consultation room created
            SELECT vc.CreatedDate, 'VIDEO', 'Consultation', 'OPD.VideoConsultation',
                   CONCAT('Video consultation room created', CASE WHEN vc.Status IS NOT NULL THEN ' · ' + vc.Status ELSE '' END, '.'),
                   vc.CreatedBy, @BranchId, NULL, NULL
              FROM dbo.tbl_VideoConsultation vc
             WHERE vc.OPDServiceId = @OPDServiceId
           ) x
      LEFT JOIN dbo.Users u ON u.Id = x.UserId
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = x.BranchId
     ORDER BY x.EventDate DESC;
END
GO

-- ── the facts the workflow is worked out from (one row) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdVisit_WorkflowFacts
    @OPDServiceId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.OPDServiceId, s.OPDBillNo, s.TokenNo, s.Status, CAST(ISNULL(s.IsActive, 1) AS BIT) AS IsActive,
           s.VisitDate, s.AppointmentTime, CAST(CASE WHEN s.ScheduleId IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsBooked,
           s.CreatedDate AS BookedAt, (SELECT ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = s.CreatedBy) AS BookedBy,
           LTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName)) AS PatientName, p.PatientCode,
           d.FullName AS DoctorName,
           ph.NetAmount, ph.TotalPaid, ph.BalanceDue, ph.PaidAt,
           tk.TokenAt, tk.TokenBy,
           cs.ConsultStartAt, cs.ConsultStartBy, cd.CompletedAt, cd.CompletedBy,
           vt.VitalsAt, vt.VitalsBy, vt.VitalsCount,
           ec.ConsultationSavedAt, ec.ConsultationBy, ec.FollowUpDate, ec.ReferredTo,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.tbl_VideoConsultation v WHERE v.OPDServiceId = s.OPDServiceId) THEN 1 ELSE 0 END AS BIT) AS IsVideo,
           bc.CancelledAt, bc.CancelledBy, bc.CancellationType, bc.CancelledAmount, bc.CancelReason, bc.CancellationNo
      FROM dbo.PatientOPDService s
      LEFT JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
      LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
     OUTER APPLY (SELECT TOP 1 h.NetAmount, h.TotalPaid, h.BalanceDue, COALESCE(h.LastModifiedDate, h.CreatedDate) AS PaidAt
                    FROM dbo.PaymentHeader h
                   WHERE h.ModuleCode = 'OPD' AND h.ModuleRefId = s.OPDServiceId AND ISNULL(h.IsActive, 1) = 1
                   ORDER BY h.PaymentHeaderId DESC) ph
     OUTER APPLY (SELECT TOP 1 l.ChangedAt AS TokenAt, ISNULL(NULLIF(u.FullName, ''), u.Username) AS TokenBy
                    FROM dbo.OPDTokenStatusLog l LEFT JOIN dbo.Users u ON u.Id = l.ChangedBy
                   WHERE l.OPDServiceId = s.OPDServiceId AND l.EventType = 'TOKEN' ORDER BY l.ChangedAt) tk
     OUTER APPLY (SELECT TOP 1 l.ChangedAt AS ConsultStartAt, ISNULL(NULLIF(u.FullName, ''), u.Username) AS ConsultStartBy
                    FROM dbo.OPDTokenStatusLog l LEFT JOIN dbo.Users u ON u.Id = l.ChangedBy
                   WHERE l.OPDServiceId = s.OPDServiceId AND l.EventType = 'STATUS' AND l.ToStatus = 'Consulting' ORDER BY l.ChangedAt) cs
     OUTER APPLY (SELECT TOP 1 l.ChangedAt AS CompletedAt, ISNULL(NULLIF(u.FullName, ''), u.Username) AS CompletedBy
                    FROM dbo.OPDTokenStatusLog l LEFT JOIN dbo.Users u ON u.Id = l.ChangedBy
                   WHERE l.OPDServiceId = s.OPDServiceId AND l.EventType = 'STATUS' AND l.ToStatus = 'Completed' ORDER BY l.ChangedAt DESC) cd
     OUTER APPLY (SELECT MAX(v.RecordedOn) AS VitalsAt, COUNT(*) AS VitalsCount,
                         (SELECT TOP 1 ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.PatientVitals v2 LEFT JOIN dbo.Users u ON u.Id = ISNULL(v2.RecordedByUserId, v2.CreatedBy)
                           WHERE v2.PatientId = s.PatientId AND ISNULL(v2.IsActive, 1) = 1 AND CAST(v2.RecordedOn AS DATE) = CAST(s.VisitDate AS DATE)
                           ORDER BY v2.RecordedOn DESC) AS VitalsBy
                    FROM dbo.PatientVitals v
                   WHERE v.PatientId = s.PatientId AND ISNULL(v.IsActive, 1) = 1 AND CAST(v.RecordedOn AS DATE) = CAST(s.VisitDate AS DATE)) vt
     OUTER APPLY (SELECT TOP 1 COALESCE(c.ModifiedDate, c.CreatedDate) AS ConsultationSavedAt,
                         (SELECT ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = ISNULL(c.ModifiedBy, c.CreatedBy)) AS ConsultationBy,
                         c.FollowUpDate,
                         (SELECT rd.FullName FROM dbo.DoctorMaster rd WHERE rd.DoctorId = c.ReferToDoctorId) AS ReferredTo
                    FROM dbo.EmrPatientConsultation c
                   WHERE c.OPDServiceId = s.OPDServiceId ORDER BY c.ConsultationId DESC) ec
     OUTER APPLY (SELECT TOP 1 x.CancellationDate AS CancelledAt, x.CancellationType, x.CancelledAmount, x.Reason AS CancelReason, x.CancellationNo,
                         (SELECT ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = x.CreatedBy) AS CancelledBy
                    FROM dbo.BillCancellation x
                   WHERE x.ModuleCode = 'OPD' AND x.ModuleRefId = s.OPDServiceId AND ISNULL(x.IsActive, 1) = 1
                   ORDER BY x.CancellationId DESC) bc
     WHERE s.OPDServiceId = @OPDServiceId;

    -- what is on the bill: consultation(s), services, and the registration service
    SELECT i.ServiceType, ISNULL(sm.ItemName, i.ServiceType) AS ItemName, i.ServiceCharges,
           CAST(ISNULL(sm.IsRegistration, 0) AS BIT) AS IsRegistration
      FROM dbo.PatientOPDServiceItem i
      LEFT JOIN dbo.ServiceMaster sm ON sm.ServiceId = i.ServiceId
     WHERE i.OPDServiceId = @OPDServiceId AND ISNULL(i.IsActive, 1) = 1
     ORDER BY CASE WHEN i.ServiceType = 'Consulting' THEN 1 ELSE 2 END, i.ItemId;

    -- registration: the branch's validity days, and the patient's last registration before this visit
    DECLARE @PatientId INT, @BranchId INT, @CreatedDate DATETIME;
    SELECT @PatientId = PatientId, @BranchId = BranchId, @CreatedDate = CreatedDate FROM dbo.PatientOPDService WHERE OPDServiceId = @OPDServiceId;
    SELECT (SELECT TOP 1 hs.OpdRegistrationValidityDays FROM dbo.HospitalSettings hs WHERE hs.BranchId = @BranchId
             ORDER BY hs.IsActive DESC, hs.Id DESC) AS ValidityDays,
           r.RegisteredAt AS LastRegisteredAt, r.OPDBillNo AS LastRegisteredBillNo
      FROM (SELECT 1 AS x) one
     OUTER APPLY (SELECT TOP 1 ps.CreatedDate AS RegisteredAt, ps.OPDBillNo
                    FROM dbo.PatientOPDService ps
                    JOIN dbo.PatientOPDServiceItem pi ON pi.OPDServiceId = ps.OPDServiceId AND ISNULL(pi.IsActive, 1) = 1
                    JOIN dbo.ServiceMaster sm ON sm.ServiceId = pi.ServiceId AND sm.IsRegistration = 1 AND pi.ServiceType = 'Service'
                   WHERE ps.PatientId = @PatientId AND ps.OPDServiceId <> @OPDServiceId AND ISNULL(ps.IsActive, 1) = 1
                     AND ISNULL(ps.Status, '') <> 'Cancelled' AND ps.CreatedDate < @CreatedDate
                   ORDER BY ps.CreatedDate DESC) r;

    -- every cancellation of the bill, full or part (F / P), oldest first
    SELECT x.CancellationDate, x.CancellationNo, x.CancellationType, x.CancelledAmount, x.Reason,
           (SELECT ISNULL(NULLIF(u.FullName, ''), u.Username) FROM dbo.Users u WHERE u.Id = x.CreatedBy) AS CancelledBy
      FROM dbo.BillCancellation x
     WHERE x.ModuleCode = 'OPD' AND x.ModuleRefId = @OPDServiceId AND ISNULL(x.IsActive, 1) = 1
     ORDER BY x.CancellationDate, x.CancellationId;
END
GO

-- ── OPD Dashboard visits of the day: + VisitKind, so a services-only visit shows "In service", not "In consultation" ──
-- (usp_Api_OPD_Dashboard_GetStats as in 2215, with the one extra column; every other result set and column unchanged)
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
        s.CreatedDate AS RegisteredAt,
        -- 2304: CONSULT when the bill has a doctor consultation, SERVICE when it is services only (dressing...)
        CASE WHEN EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem i WHERE i.OPDServiceId = s.OPDServiceId
                            AND ISNULL(i.IsActive, 1) = 1 AND i.ServiceType = 'Consulting') THEN 'CONSULT' ELSE 'SERVICE' END AS VisitKind
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

-- ── endpoints: under the OPD Dashboard page (Web: OPD/VisitAuditHistoryJson + VisitWorkflowJson; API: OpdVisits) ──
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DASHBOARD';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'VisitAuditHistoryJson', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'VisitWorkflowJson',     @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET', @Controller = N'OpdVisits', @Action = N'Activity', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET', @Controller = N'OpdVisits', @Action = N'Workflow', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO

PRINT 'Script 2304 applied: OPD visit Audit History with workflow.';
GO
