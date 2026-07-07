-- ============================================================
-- Script: 59_doctor_dashboard_visit_time.sql
-- Description: Exposes AppointmentTime and SlotEndTime to Doctor Dashboard
-- ============================================================

ALTER PROCEDURE dbo.usp_Api_DoctorDashboard_GetQueue
    @BranchId INT,
    @DoctorId INT = NULL,
    @Date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Date IS NULL SET @Date = CAST(GETDATE() AS DATE);

    -- ResultSet 1: Consulting queue list
    SELECT 
        s.OPDServiceId,
        s.VisitDate,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.PatientId,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                           AS PatientName,
        p.Gender,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
               - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END                          AS Age,
        d.FullName                   AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0)     AS TotalAmount,
        s.Status,
        p.PhotoPath,
        (SELECT TOP 1 PaymentStatus FROM PaymentHeader 
         WHERE ModuleCode = 'OPD' AND ModuleRefId = s.OPDServiceId AND IsActive = 1) AS PaymentStatus,
        CAST(
            CASE WHEN EXISTS (SELECT 1 FROM EmrPatientConsultation e WHERE e.OPDServiceId = s.OPDServiceId)
            THEN 1 ELSE 0 END
        AS BIT) AS IsEmrDone,
        -- Video fields
        ISNULL(
            (SELECT TOP 1 sm.ConsultingType
             FROM PatientOPDServiceItem i
             JOIN ServiceMaster sm ON sm.ServiceId = i.ServiceId
             WHERE i.OPDServiceId = s.OPDServiceId AND sm.ConsultingType = 'Video' AND i.IsActive = 1),
            'Walk-In'
        )                            AS ConsultingType,
        (SELECT TOP 1 vc.PatientRoomUrl
         FROM tbl_VideoConsultation vc
         WHERE vc.OPDServiceId = s.OPDServiceId AND vc.Status = 'Scheduled')
                                     AS VideoPatientUrl,
        (SELECT TOP 1 vc.DoctorHostUrl
         FROM tbl_VideoConsultation vc
         WHERE vc.OPDServiceId = s.OPDServiceId AND vc.Status = 'Scheduled')
                                     AS VideoHostUrl,
        -- New Time fields
        s.AppointmentTime            AS SlotStartTime,
        (SELECT TOP 1 SlotDurationMinutes FROM DoctorScheduleMaster WHERE ScheduleId = s.ScheduleId) AS SlotDurationMinutes
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT JOIN DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE s.BranchId = @BranchId
      AND CAST(s.VisitDate AS DATE) = @Date
      AND s.IsActive = 1
      AND p.IsActive = 1
      AND s.Status IN ('Consulting', 'Completed', 'Skipped')
      AND (@DoctorId IS NULL OR @DoctorId = 0 OR s.ConsultingDoctorId = @DoctorId)
    ORDER BY 
        CASE 
            WHEN s.Status = 'Consulting' THEN 0 
            WHEN s.Status = 'Skipped' THEN 1 
            ELSE 2 
        END ASC,
        s.TokenNo ASC;

    -- ResultSet 2: Summary Stats
    SELECT 
        (SELECT COUNT(*) 
         FROM PatientOPDService 
         WHERE BranchId = @BranchId 
           AND CAST(VisitDate AS DATE) = @Date 
           AND IsActive = 1 
           AND Status IN ('Consulting', 'Skipped')
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalWaiting,

        (SELECT COUNT(*) 
         FROM PatientOPDService 
         WHERE BranchId = @BranchId 
           AND CAST(VisitDate AS DATE) = @Date 
           AND IsActive = 1 
           AND Status = 'Completed'
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalCompleted;
END
