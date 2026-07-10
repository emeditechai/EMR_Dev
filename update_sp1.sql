ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetById
    @OPDServiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Header
    SELECT
        s.OPDServiceId,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                        AS PatientName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        d.FullName                AS ConsultingDoctorName,
        s.VisitDate,
        ISNULL(s.TotalAmount, 0)  AS TotalAmount,
        s.Status,
        s.AppointmentTime,
        s.CreatedDate
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    WHERE s.OPDServiceId = @OPDServiceId;

    -- RS2: Line items
    SELECT
        si.ItemId,
        si.ServiceType,
        ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
        ISNULL(si.ServiceCharges, 0)     AS ServiceCharges,
        ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
        sm.GstPercentage                 AS GstPercentage
    FROM PatientOPDServiceItem si
    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE si.OPDServiceId = @OPDServiceId AND si.IsActive = 1
    ORDER BY si.ItemId;
END
