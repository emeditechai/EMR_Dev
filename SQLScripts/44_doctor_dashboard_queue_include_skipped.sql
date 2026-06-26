USE [Dev_EMR]
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDashboard_GetQueue
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
        (SELECT TOP 1 PaymentStatus FROM PaymentHeader 
         WHERE ModuleCode = 'OPD' AND ModuleRefId = s.OPDServiceId AND IsActive = 1) AS PaymentStatus
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
        -- Total waiting/skipped in active consulting queue today for this doctor
        (SELECT COUNT(*) 
         FROM PatientOPDService 
         WHERE BranchId = @BranchId 
           AND CAST(VisitDate AS DATE) = @Date 
           AND IsActive = 1 
           AND Status IN ('Consulting', 'Skipped')
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalWaiting,

        -- Total completed consultations today for this doctor
        (SELECT COUNT(*) 
         FROM PatientOPDService 
         WHERE BranchId = @BranchId 
           AND CAST(VisitDate AS DATE) = @Date 
           AND IsActive = 1 
           AND Status = 'Completed'
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalCompleted;
END
GO
