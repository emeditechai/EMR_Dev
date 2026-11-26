-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2560: IPD discharge follow-up integrated with OPD booking.
--   IpdFollowUp.Status VISITED + OpdServiceId / VisitedAt: an OPD Service Booking of the patient closes the follow-up -
--     opened from the discharge screen ("OPD booking", that follow-up) or booked straight at the OPD desk (the patient's
--     BOOKED follow-up with the same doctor within 15 days of the visit date).
--   usp_Api_IpdFollowUp_LinkOpd       called by the OPD booking after the bill is saved
--   usp_Api_IpdFollowUp_ForPatient    BOOKED follow-ups of a patient, shown on OPD New Service Booking
--   usp_Api_IpdDischarge_Data / _Print  follow-ups carry the OPD bill; the print keeps a visited follow-up
--   Permission: OPD/IpdFollowUps under OPD Service Booking VIEW. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.IpdFollowUp', 'OpdServiceId') IS NULL ALTER TABLE dbo.IpdFollowUp ADD OpdServiceId INT NULL;
IF COL_LENGTH('dbo.IpdFollowUp', 'VisitedAt') IS NULL ALTER TABLE dbo.IpdFollowUp ADD VisitedAt DATETIME NULL;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_IpdFollowUp_Status' AND definition NOT LIKE '%VISITED%')
    ALTER TABLE dbo.IpdFollowUp DROP CONSTRAINT CK_IpdFollowUp_Status;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_IpdFollowUp_Status')
    ALTER TABLE dbo.IpdFollowUp ADD CONSTRAINT CK_IpdFollowUp_Status CHECK (Status IN ('BOOKED', 'VISITED', 'CANCELLED'));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdFollowUp_Patient' AND object_id = OBJECT_ID('dbo.IpdFollowUp'))
    CREATE INDEX IX_IpdFollowUp_Patient ON dbo.IpdFollowUp (PatientId, Status, FollowUpDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdFollowUp_LinkOpd @CompanyId INT, @BranchId INT, @UserId INT, @OpdServiceId INT, @FollowUpId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pid INT, @doc INT, @vd DATE, @fid INT;
    SELECT @pid = o.PatientId, @doc = o.ConsultingDoctorId, @vd = CAST(ISNULL(o.VisitDate, o.CreatedDate) AS DATE)
    FROM dbo.PatientOPDService o
    WHERE o.OPDServiceId = @OpdServiceId AND o.BranchId = @BranchId AND ISNULL(o.IsActive, 1) = 1;
    IF @pid IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS Success, N'The OPD booking was not found.' AS Error, CAST(NULL AS INT) AS FollowUpId;
        RETURN;
    END
    -- the follow-up opened from the discharge screen, else the patient's booked follow-up with this doctor nearest the visit date
    SELECT TOP 1 @fid = f.FollowUpId
    FROM dbo.IpdFollowUp f
    WHERE f.PatientId = @pid AND f.CompanyId = @CompanyId AND f.Status = 'BOOKED'
      AND (f.FollowUpId = @FollowUpId
           OR (@FollowUpId IS NULL AND f.DoctorId = @doc AND f.FollowUpDate BETWEEN DATEADD(DAY, -15, @vd) AND DATEADD(DAY, 15, @vd)))
    ORDER BY ABS(DATEDIFF(DAY, f.FollowUpDate, @vd));
    IF @fid IS NOT NULL
        UPDATE dbo.IpdFollowUp SET Status = 'VISITED', OpdServiceId = @OpdServiceId, VisitedAt = GETDATE(), ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE FollowUpId = @fid AND Status = 'BOOKED';
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @fid AS FollowUpId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdFollowUp_ForPatient @CompanyId INT, @BranchId INT, @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.FollowUpId, f.FollowUpDate, f.SlotTime, f.ScheduleId, f.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName,
           f.Notes, a.IpNo, f.BranchId, CASE WHEN f.BranchId = @BranchId THEN 1 ELSE 0 END AS ThisBranch
    FROM dbo.IpdFollowUp f
    JOIN dbo.IpdAdmission a ON a.AdmissionId = f.AdmissionId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId
    WHERE f.PatientId = @PatientId AND f.CompanyId = @CompanyId AND f.Status = 'BOOKED' AND f.FollowUpDate >= DATEADD(DAY, -15, CAST(GETDATE() AS DATE))
    ORDER BY f.FollowUpDate, f.SlotTime;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Data @CompanyId INT, @BranchId INT, @AdmissionId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId) RETURN;
    DECLARE @now DATETIME = GETDATE();
    -- 0 header and state
    SELECT a.IpNo, a.Status, a.IsOpen, a.AdmissionAt, a.DischargeAt, a.PayerType, a.IsMlc, a.ConsultantDoctorId, cd.FullName AS ConsultantName,
           a.ProvisionalDiagnosis, a.DiagnosisCode, p.PatientId, p.PatientCode, p.Gender, p.KnownAllergies,
           LTRIM(RTRIM(CONCAT(p.Salutation, ' ', p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName,
           st.*, CAST(DATEDIFF(MINUTE, st.AdvisedAt, ISNULL(st.GatePassAt, @now)) AS INT) AS TatMinutes,
           (SELECT TOP 1 md.DoctorId FROM dbo.DoctorMaster md WHERE md.LinkedUserId = @UserId AND md.IsActive = 1 AND @UserId IS NOT NULL ORDER BY md.DoctorId) AS MyDoctorId
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    CROSS APPLY dbo.fn_Ipd_DischargeState(a.AdmissionId) st
    WHERE a.AdmissionId = @AdmissionId;
    -- 1 discharge (live one)
    SELECT d.*, ad.FullName AS AdvisedByDoctorName, u.FullName AS GatePassByName, uc.FullName AS CreatedByName
    FROM dbo.IpdDischarge d
    LEFT JOIN dbo.DoctorMaster ad ON ad.DoctorId = d.AdvisedByDoctorId
    LEFT JOIN dbo.Users u ON u.Id = d.GatePassBy
    LEFT JOIN dbo.Users uc ON uc.Id = d.CreatedBy
    WHERE d.AdmissionId = @AdmissionId AND d.Status <> 'CANCELLED';
    -- 2 clearances
    SELECT c.ClearanceId, c.Dept, c.Status, c.Checklist, c.Remarks, c.ClearedAt, u.FullName AS ClearedByName
    FROM dbo.IpdDischargeClearance c
    JOIN dbo.IpdDischarge d ON d.DischargeId = c.DischargeId AND d.Status <> 'CANCELLED'
    LEFT JOIN dbo.Users u ON u.Id = c.ClearedBy
    WHERE c.AdmissionId = @AdmissionId
    ORDER BY CASE c.Dept WHEN 'PHARMACY' THEN 1 WHEN 'LAB' THEN 2 WHEN 'NURSING' THEN 3 ELSE 4 END;
    -- 3 summaries (every version)
    SELECT s.*, d.FullName AS SignedByDoctorName, u.FullName AS CreatedByName, um.FullName AS ModifiedByName, us.FullName AS SignedByUserName
    FROM dbo.IpdDischargeSummary s
    LEFT JOIN dbo.Users us ON us.Id = s.SignedByUserId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.SignedByDoctorId
    LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = s.ModifiedBy
    WHERE s.AdmissionId = @AdmissionId ORDER BY s.Version DESC;
    -- 4 LAMA / DAMA form
    SELECT l.*, d.FullName AS ExplainedByDoctorName
    FROM dbo.IpdLamaRecord l LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = l.ExplainedByDoctorId
    WHERE l.AdmissionId = @AdmissionId AND l.IsActive = 1;
    -- 5 death record
    SELECT r.*, d.FullName AS CertifiedByDoctorName
    FROM dbo.IpdDeathRecord r LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.CertifiedByDoctorId
    WHERE r.AdmissionId = @AdmissionId AND r.IsActive = 1;
    -- 6 follow-ups
    SELECT f.FollowUpId, f.DoctorId, d.FullName AS DoctorName, f.FollowUpDate, f.ScheduleId, f.SlotTime, f.Notes, f.Status, f.CancelReason, f.CreatedDate, u.FullName AS CreatedByName,
           f.OpdServiceId, f.VisitedAt, o.OPDBillNo, o.TokenNo AS OpdTokenNo
    FROM dbo.IpdFollowUp f LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId LEFT JOIN dbo.Users u ON u.Id = f.CreatedBy
    LEFT JOIN dbo.PatientOPDService o ON o.OPDServiceId = f.OpdServiceId
    WHERE f.AdmissionId = @AdmissionId ORDER BY f.Status, f.FollowUpDate;
    -- 7 LAB items not reported yet (clearance)
    SELECT lo.BillNo, li.LabOrderItemId, COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, i.Test_Name) AS ItemName,
           CASE WHEN ISNULL(st.Collected, 0) = 0 AND ISNULL(st.Entered, 0) = 0 THEN 'NOT_COLLECTED' WHEN st.ReportLevel = 2 THEN 'VALIDATED' ELSE 'IN_PROCESS' END AS ItemStatus
    FROM dbo.LabOrder lo
    JOIN dbo.LabOrderItem li ON li.LabOrderId = lo.LabOrderId AND li.IsActive = 1
    LEFT JOIN dbo.LabInvestigationMaster i ON li.[Type] <> 'P' AND i.Test_ID = li.InvestigationId
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    OUTER APPLY dbo.fn_Ipd_LabItemStatus(li.LabOrderItemId) st
    WHERE lo.AdmissionId = @AdmissionId AND ISNULL(st.ReportLevel, 0) < 3;
    -- 8 doctors (advice, LAMA, death certificate, summary signer, follow-up)
    SELECT d.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName, d.MedicalLicenseNo
    FROM dbo.DoctorMaster d
    WHERE d.IsActive = 1 AND ISNULL(d.IsReferralDoctor, 0) = 0 AND ISNULL(d.IsSuspended, 0) = 0 AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
    ORDER BY d.FullName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Print @CompanyId INT, @BranchId INT, @AdmissionId INT, @SummaryId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId) RETURN;
    -- 0 header
    SELECT a.AdmissionId, a.BranchId, a.IpNo, a.Status, a.AdmissionAt, a.DischargeAt, a.AdmissionType, a.PayerType, a.IsMlc, p.PatientCode, p.Gender, p.PhoneNumber, p.Address,
           LTRIM(RTRIM(CONCAT(p.Salutation, ' ', p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName, p.GuardianName, p.DateOfBirth,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL ELSE CONCAT(DATEDIFF(YEAR, p.DateOfBirth, a.AdmissionAt) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, a.AdmissionAt), p.DateOfBirth) > a.AdmissionAt THEN 1 ELSE 0 END, N' Y') END AS AgeText,
           LTRIM(RTRIM(ISNULL(cd.NamePrefix + ' ', '') + cd.FullName)) AS ConsultantName, dep.DeptName AS DepartmentName, w.WardName, bm.BedNumber,
           ad.FullName AS AdmittingDoctorName, ml.MlcNo
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.DoctorMaster ad ON ad.DoctorId = a.AdmittingDoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
    LEFT JOIN dbo.BedMaster bm ON bm.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = bm.WardId
    OUTER APPLY (SELECT TOP 1 m.MlcNo FROM dbo.IpdMlc m WHERE m.AdmissionId = a.AdmissionId) ml
    WHERE a.AdmissionId = @AdmissionId;
    -- 1 summary: the one asked for, else the signed one, else the draft
    SELECT TOP 1 s.*, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS SignedByDoctorName, d.MedicalLicenseNo AS SignedByRegNo, CAST(CASE WHEN NULLIF(d.SignaturePath, N'') IS NULL THEN 0 ELSE 1 END AS BIT) AS SignedByHasSignature,
           ub.FullName AS SignedByUserName
    FROM dbo.IpdDischargeSummary s
    LEFT JOIN dbo.Users ub ON ub.Id = s.SignedByUserId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.SignedByDoctorId
    WHERE s.AdmissionId = @AdmissionId AND (@SummaryId IS NULL OR s.SummaryId = @SummaryId)
    ORDER BY CASE WHEN @SummaryId IS NOT NULL THEN 0 WHEN s.Status = 'SIGNED' THEN 1 WHEN s.Status = 'DRAFT' THEN 2 ELSE 3 END, s.Version DESC;
    -- 2 discharge
    SELECT TOP 1 d.*, LTRIM(RTRIM(ISNULL(dd.NamePrefix + ' ', '') + dd.FullName)) AS AdvisedByDoctorName, u.FullName AS GatePassByName
    FROM dbo.IpdDischarge d LEFT JOIN dbo.DoctorMaster dd ON dd.DoctorId = d.AdvisedByDoctorId LEFT JOIN dbo.Users u ON u.Id = d.GatePassBy
    WHERE d.AdmissionId = @AdmissionId AND d.Status <> 'CANCELLED' ORDER BY d.DischargeId DESC;
    -- 3 LAMA / DAMA
    SELECT l.*, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS ExplainedByDoctorName, d.MedicalLicenseNo AS ExplainedByRegNo
    FROM dbo.IpdLamaRecord l LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = l.ExplainedByDoctorId
    WHERE l.AdmissionId = @AdmissionId AND l.IsActive = 1;
    -- 4 death
    SELECT r.*, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS CertifiedByDoctorName, d.MedicalLicenseNo AS CertifiedByRegNo, CAST(CASE WHEN NULLIF(d.SignaturePath, N'') IS NULL THEN 0 ELSE 1 END AS BIT) AS CertifiedByHasSignature
    FROM dbo.IpdDeathRecord r LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.CertifiedByDoctorId
    WHERE r.AdmissionId = @AdmissionId AND r.IsActive = 1;
    -- 5 follow-ups
    SELECT f.FollowUpDate, f.SlotTime, f.Notes, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName
    FROM dbo.IpdFollowUp f LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId
    WHERE f.AdmissionId = @AdmissionId AND f.Status IN ('BOOKED', 'VISITED') ORDER BY f.FollowUpDate;
    -- 6 bill (gate pass)
    SELECT b.BillNo, b.BillAt, b.Net, b.PayerShare, st.PatientBalance FROM dbo.IpdBill b CROSS APPLY dbo.fn_Ipd_DischargeState(@AdmissionId) st
    WHERE b.BillId = (SELECT BillId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId) AND b.Status = 'FINAL';
END;
GO

-- ── permissions: the follow-up banner of OPD New Service Booking ──
DECLARE @page INT, @view INT;
DECLARE pp CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.SERVICEBOOKING';
OPEN pp; FETCH NEXT FROM pp INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'OPD', @Action = N'IpdFollowUps', @Source = 'SEED';
    FETCH NEXT FROM pp INTO @page;
END
CLOSE pp; DEALLOCATE pp;
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2560 applied: IPD follow-up linked to OPD booking.';
GO
