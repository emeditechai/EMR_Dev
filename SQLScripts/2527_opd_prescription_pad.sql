-- ============================================================================================================
-- Migration: 2527_opd_prescription_pad.sql   (application database; needs 2341 for CertificateDoctorProfile)
-- OPD > Service Booking / Patient Registration: "Print Dr. Prescription" - the doctor's prescription pad printed for a
-- consultation visit, with the visit filled in (the doctor writes the prescription by hand):
--   Registration ID (patient code), Visit ID (OPD bill no), Visit Date / time, Token, patient name, age, sex, address, phone,
--   consultant, consultant's registration no. (+ council), department (speciality), qualification under the signature.
-- The doctor's qualification and registration no. / council come from the doctor's certificate profile (OPD > Certificates,
-- 2341); the registration no. falls back to the Doctor Master licence no.
--   usp_Api_ServiceBooking_PrescriptionPad @OPDServiceId, @BranchId : one row (none = not this branch's visit)
-- Endpoints: OPD/PrintPrescriptionPad (WEB) and api/servicebookings/{id}/prescription-pad (API).
-- Permission control PRINT_PRESCRIPTION ("Print doctor prescription pad") on OPD.SERVICEBOOKING and OPD.PATIENTREGISTRATION,
-- managed per role on the permission screens. No role is granted. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_PrescriptionPad
    @OPDServiceId INT,
    @BranchId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dob DATE, @at DATE;
    SELECT @dob = CAST(p.DateOfBirth AS DATE), @at = CAST(s.VisitDate AS DATE)
      FROM dbo.PatientOPDService s JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
     WHERE s.OPDServiceId = @OPDServiceId;
    -- age on the visit date: years, else months, else days
    DECLARE @y INT, @m INT, @d INT, @age NVARCHAR(20);
    IF @dob IS NOT NULL AND @dob <= @at
    BEGIN
        SET @m = DATEDIFF(MONTH, @dob, @at) - CASE WHEN DAY(@at) < DAY(@dob) THEN 1 ELSE 0 END;
        SET @y = @m / 12;
        SET @d = DATEDIFF(DAY, @dob, @at);
        SET @age = CASE WHEN @y >= 1 THEN CONCAT(@y, ' Y') WHEN @m >= 1 THEN CONCAT(@m, ' M') ELSE CONCAT(@d, ' D') END;
    END

    SELECT s.OPDServiceId, s.BranchId, s.OPDBillNo, s.TokenNo, s.VisitDate, s.AppointmentTime, s.CreatedDate, s.Status,
           p.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(p.Salutation)), '') + ' ', p.FirstName, ' ' + NULLIF(LTRIM(RTRIM(p.MiddleName)), ''), ' ', p.LastName))) AS PatientName,
           p.Gender, p.DateOfBirth, @age AS AgeText,
           p.PhoneNumber,
           NULLIF(CONCAT_WS(N', ', NULLIF(LTRIM(RTRIM(p.Address)), N''), a.AreaName, c.CityName, dm.DistrictName, st.StateName,
                            NULLIF(LTRIM(RTRIM(p.Pincode)), N'')), N'') AS Address,
           d.DoctorId,
           LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(d.NamePrefix)), '') + ' ', d.FullName))) AS DoctorName,
           sp.SpecialityName AS Department,
           NULLIF(LTRIM(RTRIM(cp.Qualification)), N'') AS Qualification,
           COALESCE(NULLIF(LTRIM(RTRIM(cp.RegistrationNo)), N''), NULLIF(LTRIM(RTRIM(d.MedicalLicenseNo)), N'')) AS RegistrationNo,
           NULLIF(LTRIM(RTRIM(cp.RegistrationCouncil)), N'') AS RegistrationCouncil,
           -- a consultation visit: a Consulting line, or the consulting doctor on the visit
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem i WHERE i.OPDServiceId = s.OPDServiceId AND i.IsActive = 1 AND i.ServiceType = 'Consulting')
                     THEN 1 ELSE 0 END AS BIT) AS HasConsultation,
           ISNULL(NULLIF(u.FullName, N''), u.Username) AS CreatedByUser
      FROM dbo.PatientOPDService s
      JOIN dbo.PatientMaster p ON p.PatientId = s.PatientId
      LEFT JOIN dbo.AreaMaster a ON a.AreaId = p.AreaId
      LEFT JOIN dbo.CityMaster c ON c.CityId = p.CityId
      LEFT JOIN dbo.DistrictMaster dm ON dm.DistrictId = p.DistrictId
      LEFT JOIN dbo.StateMaster st ON st.StateId = p.StateId
      LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
      LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
      LEFT JOIN dbo.CertificateDoctorProfile cp ON cp.DoctorId = d.DoctorId
      LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy
     WHERE s.OPDServiceId = @OPDServiceId
       AND (@BranchId IS NULL OR s.BranchId = @BranchId);
END
GO

-- ── permission control + endpoints ─────────────────────────────────────────────────────────────────────────
MERGE dbo.PermissionControlVocabulary AS t
USING (VALUES ('PRINT_PRESCRIPTION', N'Print prescription pad', N'Print the doctor''s prescription pad of a consultation visit', 137, 0)) s (Code, Title, Descr, Sort, Sens)
ON t.Control_Code = s.Code
WHEN NOT MATCHED THEN INSERT (Control_Code, Title, Description, Sort_Order, Is_Sensitive) VALUES (s.Code, s.Title, s.Descr, s.Sort, s.Sens);
GO
DECLARE @pc NVARCHAR(60), @page INT, @ctl INT;
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM (VALUES (N'OPD.SERVICEBOOKING'), (N'OPD.PATIENTREGISTRATION')) x (v);
OPEN k; FETCH NEXT FROM k INTO @pc;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @page = NULL; SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = @pc;
    IF @page IS NOT NULL
    BEGIN
        SET @ctl = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PRINT_PRESCRIPTION', @Title = N'Print doctor prescription pad',
             @Sort_Order = 55, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'OPD', @Action = N'PrintPrescriptionPad', @Source = 'SEED';
        UPDATE dbo.PageEndpointMap SET Control_ID = @ctl
         WHERE Page_ID = @page AND App = 'WEB' AND Http_Method = 'GET' AND Controller = N'OPD' AND Action = N'PrintPrescriptionPad';
    END
    FETCH NEXT FROM k INTO @pc;
END
CLOSE k; DEALLOCATE k;
-- the API action, mapped like its neighbour GetById
IF NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'ServiceBookings' AND Action = N'GetPrescriptionPad')
    INSERT dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, IsActive, CreatedDate, Source, Discovered_On, Last_Seen_On, Is_Orphaned, Is_Public)
    SELECT TOP 1 Page_ID, Control_ID, 'API', 'GET', N'ServiceBookings', N'GetPrescriptionPad', N'api/servicebookings/{id}/prescription-pad', IsActive, GETDATE(), Source,
           GETDATE(), GETDATE(), 0, Is_Public
      FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'ServiceBookings' AND Action = N'GetById';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2527 applied: OPD - doctor prescription pad print.';
GO
