-- 2578: IPD doctor lists - a hospital doctor who also refers patients (Doctor Master > Referral ticked) is listed (2026-11-28).
--   Before: every doctor with the Referral flag was left out of the IPD doctor lists, so only doctors without it could admit,
--   treat, sign or operate. Now: a doctor is a hospital doctor when the Referral flag is off OR the doctor has an active
--   department in Doctor Master; only external referral-only doctors (no department) stay out. Suspended doctors are left out of
--   the admission lists and refused as admitting doctor / consultant on a new admission.
-- REPLACES usp_Api_Ipd_Lookups, usp_Api_IpdOt_Lookups, usp_Api_IpdDischarge_Data, usp_Api_IpdAdmission_Save (live + this rule):
--   Referred By (any active doctor of Doctor Master) now carries the doctor's department types (DeptTypes) for the label.
-- re-run 2578 after 2423 / 2492 / 2557 / 2572 / 2577. Safe to re-run.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── lookups for the admission page (one round trip) ─────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_Lookups @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1 doctors of the branch (not referral-only doctors), with their first department; IsIpd = mapped to a department
    --   of type IPD (Master > Doctor): only those can be the admitting doctor or the consultant
    SELECT d.DoctorId, LTRIM(RTRIM(CONCAT(NULLIF(d.NamePrefix, '') + ' ', d.FullName))) AS DoctorName,
           dd.DeptId, dep.DeptName, sp.SpecialityName,
           CAST(CASE WHEN ipd.Names IS NULL THEN 0 ELSE 1 END AS BIT) AS IsIpd, ipd.Names AS IpdDeptNames, ipd.FirstDeptId AS IpdDeptId
    FROM dbo.DoctorMaster d
    OUTER APPLY (SELECT STRING_AGG(x.DeptName, ', ') WITHIN GROUP (ORDER BY x.DeptName) AS Names, MIN(x.DeptId) AS FirstDeptId
                 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                 WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1) ipd
    OUTER APPLY (SELECT TOP 1 m.DeptId FROM dbo.DoctorDepartmentMap m WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 ORDER BY m.DoctorDepartmentMapId) dd
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = dd.DeptId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    WHERE d.IsActive = 1 AND d.CompanyId = @CompanyId AND ISNULL(d.IsSuspended, 0) = 0 AND (ISNULL(d.IsReferralDoctor, 0) = 0 OR EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap rm WHERE rm.DoctorId = d.DoctorId AND rm.IsActive = 1))   -- 2578
      AND (EXISTS (SELECT 1 FROM dbo.DoctorBranchMap bm WHERE bm.DoctorId = d.DoctorId AND bm.BranchId = @BranchId AND bm.IsActive = 1)
           OR NOT EXISTS (SELECT 1 FROM dbo.DoctorBranchMap bm WHERE bm.DoctorId = d.DoctorId AND bm.IsActive = 1))
    ORDER BY d.FullName;
    -- 2 "Referred by": every active doctor of the company (hospital and referral doctors)
    SELECT d.DoctorId, LTRIM(RTRIM(CONCAT(NULLIF(d.NamePrefix, '') + ' ', d.FullName))) AS DoctorName,
           CAST(ISNULL(d.IsReferralDoctor, 0) AS BIT) AS IsReferralDoctor,
           (SELECT STRING_AGG(t.DeptType, ', ') WITHIN GROUP (ORDER BY t.DeptType) FROM (SELECT DISTINCT x.DeptType FROM dbo.DoctorDepartmentMap m
              JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 AND NULLIF(x.DeptType, '') IS NOT NULL) t) AS DeptTypes   -- 2578
    FROM dbo.DoctorMaster d WHERE d.IsActive = 1 AND d.CompanyId = @CompanyId ORDER BY d.FullName;
    -- 3 IPD departments (Master > Department, type IPD): the wards of the bed board belong to them
    SELECT DeptId, DeptName, DeptType FROM dbo.DepartmentMaster
    WHERE IsActive = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL) AND DeptType = 'IPD' ORDER BY DeptName;
    -- 4 tariff categories, with how many bed / room rates of this branch are in force today (the page prefers a category that has rates)
    SELECT tc.TariffCategoryId, tc.Code, tc.Name, tc.PatientCategory,
           (SELECT COUNT(*) FROM dbo.BedRoomTariffMaster t WHERE t.TariffCategoryId = tc.TariffCategoryId AND t.BranchId = @BranchId AND t.IsActive = 1
              AND t.EffectiveFrom <= CAST(GETDATE() AS DATE) AND (t.EffectiveTo IS NULL OR t.EffectiveTo >= CAST(GETDATE() AS DATE))) AS BedRates
    FROM dbo.TariffCategoryMaster tc
    WHERE tc.IsActive = 1 AND tc.CompanyId = @CompanyId AND (tc.BranchId = @BranchId OR tc.BranchId IS NULL) ORDER BY tc.Name;
    -- 5 insurance / TPA
    SELECT InsuranceTPA_ID AS Id, Name, Type, NetworkCategory, AuthorizationRequired FROM dbo.InsuranceTPAMaster
    WHERE Status = 1 AND Branch_ID = @BranchId ORDER BY Name;
    -- 6 corporates
    SELECT Corporate_ID AS Id, Corporate_Name AS Name, Credit_Limit AS CreditLimit FROM dbo.CorporateMaster
    WHERE Status = 1 AND Branch_ID = @BranchId AND (Effective_To IS NULL OR Effective_To >= CAST(GETDATE() AS DATE)) ORDER BY Corporate_Name;
    -- 7 government schemes
    SELECT Scheme_ID AS Id, SchemeName AS Name, SchemeType FROM dbo.GovernmentSchemeMaster
    WHERE IsActive = 1 AND Branch_ID = @BranchId AND (Effective_To IS NULL OR Effective_To >= CAST(GETDATE() AS DATE)) ORDER BY SchemeName;
    -- 8 packages
    SELECT HospitalPackage_ID AS Id, Package_Name AS Name, Package_Type AS PackageType, TotalPackageAmount AS Amount FROM dbo.HospitalPackageMaster
    WHERE Status = 1 AND Branch_ID = @BranchId AND (ValidTo IS NULL OR ValidTo >= GETDATE()) AND ISNULL(TotalPackageAmount, 0) > 0 ORDER BY Package_Name;
    -- 9 IPD consents
    SELECT Consent_ID AS Id, ConsentType, Language, Version, WitnessRequired FROM dbo.ConsentMaster
    WHERE Status = 1 AND Type = 'IPD' AND Branch_ID = @BranchId ORDER BY ConsentType, Language;
    -- 10 payment modes
    SELECT PaymentMethodId, UPPER(MethodCode) AS MethodCode, MethodName FROM dbo.PaymentMethodMaster
    WHERE IsActive = 1 AND UPPER(MethodCode) <> 'POINTS' ORDER BY PaymentMethodId;
    -- 11 IPD settings of the branch (defaults when Hospital Settings has no row)
    SELECT ISNULL(s.IpdNumberPrefix, N'IP') AS IpdNumberPrefix, ISNULL(s.IpdBedChargeMode, 'CALENDAR') AS IpdBedChargeMode,
           ISNULL(s.IpdDischargeGraceHour, 12) AS IpdDischargeGraceHour, ISNULL(s.IpdHourlyGraceHours, 2) AS IpdHourlyGraceHours,
           s.IpdDefaultTariffCategoryId, ISNULL(s.IpdMinAdvanceDays, 0) AS IpdMinAdvanceDays, ISNULL(s.IpdDepositAlertPercent, 80) AS IpdDepositAlertPercent,
           ISNULL(s.IpdEstimateValidityDays, 7) AS IpdEstimateValidityDays, ISNULL(s.IpdDefaultDischargeHour, 11) AS IpdDefaultDischargeHour,
           CAST(ISNULL(s.IpdBlockWardGenderMismatch, 1) AS BIT) AS IpdBlockWardGenderMismatch, CAST(ISNULL(s.IpdConsentRequired, 0) AS BIT) AS IpdConsentRequired
    FROM (SELECT 1 AS x) one LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId;
    -- 12 bed categories
    SELECT BedCategoryId, CategoryName FROM dbo.BedCategoryMaster WHERE IsActive = 1 AND CompanyId = @CompanyId ORDER BY CategoryName;
    -- 13-19 patient demographic lists (same masters as OPD / LAB registration)
    SELECT RelationId AS Id, RelationName AS Name FROM dbo.RelationMaster WHERE IsActive = 1 ORDER BY SortOrder, RelationName;
    SELECT IdentificationTypeId AS Id, IdentificationTypeName AS Name FROM dbo.IdentificationTypeMaster WHERE IsActive = 1 ORDER BY IdentificationTypeName;
    SELECT ReligionId AS Id, ReligionName AS Name FROM dbo.ReligionMaster WHERE IsActive = 1 ORDER BY ReligionName;
    SELECT OccupationId AS Id, OccupationName AS Name FROM dbo.OccupationMaster WHERE IsActive = 1 ORDER BY OccupationName;
    SELECT MaritalStatusId AS Id, StatusName AS Name FROM dbo.MaritalStatusMaster WHERE IsActive = 1 ORDER BY StatusName;
    SELECT LanguageId AS Id, LanguageName AS Name FROM dbo.LanguageMaster WHERE IsActive = 1 ORDER BY LanguageName;
    SELECT CountryId AS Id, CountryName AS Name FROM dbo.CountryMaster WHERE IsActive = 1 ORDER BY CountryName;
END;
GO

-- ── 4. lookups, schedule, booking data ──────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_Lookups @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1 OTs
    SELECT o.OtId AS Id, o.OtCode AS Code, o.OtName AS Name, o.OtType, CAST(ISNULL(o.EmergencyAvailable, 0) AS BIT) AS EmergencyAvailable
    FROM dbo.OtMaster o WHERE o.BranchId = @BranchId AND o.IsActive = 1 ORDER BY o.OtName;
    -- 2 procedures (default duration in minutes)
    SELECT p.ProcedureId AS Id, p.ProcedureCode AS Code, p.ProcedureName AS Name, p.ProcedureCategory AS Category,
           ISNULL(p.DurationHours, 0) * 60 + ISNULL(p.DurationMinutes, 0) AS Minutes, CAST(ISNULL(p.AnaesthesiaRequired, 0) AS BIT) AS AnaesthesiaRequired,
           CAST(ISNULL(p.ConsentRequired, 0) AS BIT) AS ConsentRequired
    FROM dbo.ProcedureMaster p WHERE p.BranchId = @BranchId AND p.IsActive = 1 ORDER BY p.ProcedureName;
    -- 3 doctors (active, not suspended); anaesthesia specialists first in the anaesthetist list
    SELECT d.DoctorId AS Id, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS Name, sp.SpecialityName AS Speciality,
           CAST(CASE WHEN sp.SpecialityName LIKE N'%naesth%' OR sp.SpecialityName LIKE N'%nesth%' THEN 1 ELSE 0 END AS BIT) AS IsAnaesthetist
    FROM dbo.DoctorMaster d
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    WHERE d.IsActive = 1 AND ISNULL(d.IsSuspended, 0) = 0 AND (ISNULL(d.IsReferralDoctor, 0) = 0 OR EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap rm WHERE rm.DoctorId = d.DoctorId AND rm.IsActive = 1)) AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
    ORDER BY d.FullName;
    -- 4 anaesthesia types
    SELECT t.AnaesthesiaTypeId AS Id, t.TypeCode AS Code, t.TypeName AS Name FROM dbo.AnaesthesiaTypeMaster t
    WHERE t.BranchId = @BranchId AND t.IsActive = 1 ORDER BY t.TypeName;
    -- 5 consent forms (IPD)
    SELECT c.Consent_ID AS Id, c.ConsentType AS Name, c.Language,
           CASE WHEN c.ConsentType LIKE N'%naesth%' OR c.ConsentType LIKE N'%nesth%' THEN 'ANAES'
                WHEN c.ConsentType LIKE N'%urg%' OR c.ConsentType LIKE N'%perat%' THEN 'SURG' ELSE 'OTHER' END AS Purpose
    FROM dbo.ConsentMaster c WHERE c.Status = 1 AND c.Type = 'IPD' AND (c.Branch_ID = @BranchId OR c.Branch_ID IS NULL) ORDER BY c.ConsentType;
    -- 6 checklist template
    SELECT Phase, Code, ItemText, Kind, AllowNa, Sort FROM dbo.fn_Ipd_OtChecklistItems() ORDER BY Phase, Sort;
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
    WHERE d.IsActive = 1 AND (ISNULL(d.IsReferralDoctor, 0) = 0 OR EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap rm WHERE rm.DoctorId = d.DoctorId AND rm.IsActive = 1)) AND ISNULL(d.IsSuspended, 0) = 0 AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
    ORDER BY d.FullName;
END;
GO

-- ── admission (live + 2577 package rules) ──
-- ── admission (live + 2572: C1 MLC, C2 deceased, C3 ward age, C6 readmission) ──
-- ── admit ───────────────────────────────────────────────────────────────────────────────────────────────────
-- The patient is created / updated first by EMR.Web through the Patient Master service (as OPD and LAB do);
-- this procedure takes the admission, the bed, payers, attendants, MLC, consent and the advance in one transaction.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @RequestKey UNIQUEIDENTIFIER = NULL,
    @PatientId INT, @AdmissionAt DATETIME = NULL, @AdmissionType VARCHAR(20), @AdmissionSource VARCHAR(20),
    @OpdServiceId INT = NULL, @ReferralDoctorId INT = NULL, @AdmittingDoctorId INT, @ConsultantDoctorId INT, @DepartmentId INT = NULL,
    @ProvisionalDiagnosis NVARCHAR(500) = NULL, @DiagnosisCode NVARCHAR(20) = NULL, @ReasonForAdmission NVARCHAR(500) = NULL,
    @ExpectedDischargeAt DATETIME = NULL, @BedId INT, @TariffCategoryId INT, @PayerType VARCHAR(12), @PackageId INT = NULL,
    @EstimateId INT = NULL, @Remarks NVARCHAR(1000) = NULL,
    @Payers NVARCHAR(MAX) = NULL, @Attendants NVARCHAR(MAX) = NULL, @IsMlc BIT = 0, @Mlc NVARCHAR(MAX) = NULL,
    @Consent NVARCHAR(MAX) = NULL, @Payments NVARCHAR(MAX) = NULL,
    @CanWaiveAdvance BIT = 0, @AdvanceWaiveReason NVARCHAR(300) = NULL, @CanBackdate BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();

    -- a retried save of the same admission form returns the admission it made
    IF @RequestKey IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE RequestKey = @RequestKey)
    BEGIN
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, a.AdmissionId, a.IpNo,
               (SELECT TOP 1 DocNo FROM dbo.IpdAdvance v WHERE v.AdmissionId = a.AdmissionId AND v.Kind = 'ADVANCE' ORDER BY v.AdvanceId) AS ReceiptNo,
               (SELECT TOP 1 AdvanceId FROM dbo.IpdAdvance v WHERE v.AdmissionId = a.AdmissionId AND v.Kind = 'ADVANCE' ORDER BY v.AdvanceId) AS AdvanceId,
               CAST(1 AS BIT) AS Existing
        FROM dbo.IpdAdmission a WHERE a.RequestKey = @RequestKey;
        RETURN;
    END;

    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @AdmissionAt = ISNULL(@AdmissionAt, @now);
        SET @AdmissionType = UPPER(ISNULL(@AdmissionType, 'ELECTIVE')); SET @AdmissionSource = UPPER(ISNULL(@AdmissionSource, 'DIRECT')); SET @PayerType = UPPER(ISNULL(@PayerType, 'CASH'));
        IF @AdmissionType NOT IN ('ELECTIVE', 'EMERGENCY', 'DAYCARE', 'MATERNITY', 'TRANSFERIN') THROW 54001, 'Choose the admission type.', 1;
        IF @AdmissionSource NOT IN ('DIRECT', 'OPD', 'EMERGENCY', 'REFERRAL') THROW 54002, 'Choose the admission source.', 1;
        IF @PayerType NOT IN ('CASH', 'CORPORATE', 'INSURANCE', 'SCHEME') THROW 54003, 'Choose the payer (Cash, Corporate, Insurance / TPA or Government scheme).', 1;
        IF @AdmissionAt > DATEADD(MINUTE, 5, @now) THROW 54004, 'The admission date and time cannot be in the future.', 1;
        IF @AdmissionAt < DATEADD(MINUTE, -30, @now) AND ISNULL(@CanBackdate, 0) = 0
            THROW 54005, 'You are not allowed to enter an earlier admission time (more than 30 minutes back). Ask a user with the Back-date permission.', 1;
        IF @AdmissionAt < DATEADD(DAY, -7, @now) THROW 54006, 'The admission time can be at most 7 days back.', 1;
        IF @ExpectedDischargeAt IS NOT NULL AND @ExpectedDischargeAt <= @AdmissionAt THROW 54007, 'The expected discharge must be after the admission time.', 1;

        DECLARE @gender NVARCHAR(20);
        SELECT @gender = Gender FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId AND IsActive = 1;
        IF @@ROWCOUNT = 0 THROW 54010, 'The patient was not found in this company. Search the patient again.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AdmittingDoctorId AND IsActive = 1 AND ISNULL(IsSuspended, 0) = 0 AND CompanyId = @CompanyId) THROW 54011, 'Choose the admitting doctor.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                       WHERE m.DoctorId = @AdmittingDoctorId AND m.IsActive = 1)
            THROW 54025, 'The admitting doctor must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @ConsultantDoctorId AND IsActive = 1 AND ISNULL(IsSuspended, 0) = 0 AND CompanyId = @CompanyId) THROW 54012, 'Choose the consultant (treating doctor).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                       WHERE m.DoctorId = @ConsultantDoctorId AND m.IsActive = 1)
            THROW 54026, 'The consultant (treating doctor) must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId AND IsActive = 1 AND CompanyId = @CompanyId AND (BranchId = @BranchId OR BranchId IS NULL))
            THROW 54013, 'Choose the tariff category (rates of the stay).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId
                       AND CASE @PayerType WHEN 'CASH' THEN CASE WHEN PatientCategory LIKE N'%Cash%' OR PatientCategory LIKE N'%Self%' OR PatientCategory LIKE N'%Staff%' OR PatientCategory LIKE N'%Employee%' THEN 1 ELSE 0 END
                                           WHEN 'CORPORATE' THEN CASE WHEN PatientCategory LIKE N'%Corporate%' THEN 1 ELSE 0 END
                                           WHEN 'INSURANCE' THEN CASE WHEN PatientCategory LIKE N'%Insurance%' OR PatientCategory LIKE N'%TPA%' THEN 1 ELSE 0 END
                                           ELSE CASE WHEN PatientCategory LIKE N'%Government%' OR PatientCategory LIKE N'%Scheme%' THEN 1 ELSE 0 END END = 1)
            THROW 54039, 'The tariff category does not belong to the chosen payer (Master > Tariff Category > Patient Category).', 1;
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1 AND ISNULL(TotalPackageAmount, 0) > 0)
            THROW 54014, 'The package is not active in this branch.', 1;
        IF NULLIF(@DepartmentId, 0) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @DepartmentId AND IsActive = 1 AND DeptType = 'IPD')
            THROW 54027, 'Choose an IPD department (Master > Department, type IPD).', 1;
        IF NULLIF(@DepartmentId, 0) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId WHERE b.BedId = @BedId AND w.DepartmentId = @DepartmentId)
            THROW 54028, 'The bed is not in a ward of the chosen department. Choose a bed of that department, or change the department.', 1;

        -- payer details
        DECLARE @P TABLE (Seq INT IDENTITY(1,1), PayerType VARCHAR(12), InsuranceTpaId INT, CorporateId INT, SchemeId INT, PolicyNo NVARCHAR(60), MemberId NVARCHAR(60),
                          CardHolderName NVARCHAR(150), RelationToHolder NVARCHAR(50), PolicyValidTo DATE, EmployeeId NVARCHAR(60), CardFilePath NVARCHAR(400), Remarks NVARCHAR(300));
        IF ISJSON(@Payers) = 1
            INSERT @P (PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
            SELECT UPPER(j.PayerType), j.InsuranceTpaId, j.CorporateId, j.SchemeId, LEFT(NULLIF(j.PolicyNo, N''), 60), LEFT(NULLIF(j.MemberId, N''), 60), LEFT(NULLIF(j.CardHolderName, N''), 150),
                   LEFT(NULLIF(j.RelationToHolder, N''), 50), j.PolicyValidTo, LEFT(NULLIF(j.EmployeeId, N''), 60), LEFT(NULLIF(j.CardFilePath, N''), 400), LEFT(NULLIF(j.Remarks, N''), 300)
            FROM OPENJSON(@Payers) WITH (PayerType VARCHAR(12), InsuranceTpaId INT, CorporateId INT, SchemeId INT, PolicyNo NVARCHAR(100), MemberId NVARCHAR(100), CardHolderName NVARCHAR(200),
                                         RelationToHolder NVARCHAR(100), PolicyValidTo DATE, EmployeeId NVARCHAR(100), CardFilePath NVARCHAR(500), Remarks NVARCHAR(500)) j
            WHERE j.PayerType IN ('CORPORATE', 'INSURANCE', 'SCHEME');
        IF @PayerType <> 'CASH' AND NOT EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND PayerType = @PayerType)
            THROW 54015, 'Enter the payer details (insurance / TPA, corporate or scheme).', 1;
        IF @PayerType = 'INSURANCE' AND NOT EXISTS (SELECT 1 FROM @P p JOIN dbo.InsuranceTPAMaster m ON m.InsuranceTPA_ID = p.InsuranceTpaId AND m.Status = 1 WHERE p.Seq = 1)
            THROW 54016, 'Choose the insurance company / TPA.', 1;
        IF @PayerType = 'INSURANCE' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND PolicyNo IS NULL) THROW 54017, 'Enter the policy / card number.', 1;
        IF EXISTS (SELECT 1 FROM @P WHERE PolicyValidTo IS NOT NULL AND PolicyValidTo < CAST(@AdmissionAt AS DATE)) THROW 54038, 'The policy / card has expired before the admission date: check the payer details.', 1;
        IF @PayerType = 'CORPORATE' AND NOT EXISTS (SELECT 1 FROM @P p JOIN dbo.CorporateMaster m ON m.Corporate_ID = p.CorporateId AND m.Status = 1 WHERE p.Seq = 1)
            THROW 54018, 'Choose the corporate.', 1;
        IF @PayerType = 'SCHEME' AND NOT EXISTS (SELECT 1 FROM @P p JOIN dbo.GovernmentSchemeMaster m ON m.Scheme_ID = p.SchemeId AND m.IsActive = 1 WHERE p.Seq = 1)
            THROW 54019, 'Choose the government scheme.', 1;
        -- 2577: the package is valid on the admission date and allowed for the payer
        IF @PackageId IS NOT NULL
        BEGIN
            DECLARE @pkgMsg NVARCHAR(400) = (SELECT c.Message FROM dbo.fn_Ipd_PackageCheck(@PackageId, @BranchId, CAST(@AdmissionAt AS DATE), @PayerType,
                                                (SELECT TOP 1 InsuranceTpaId FROM @P WHERE Seq = 1), (SELECT TOP 1 CorporateId FROM @P WHERE Seq = 1)) c);
            IF @pkgMsg IS NOT NULL THROW 60000, @pkgMsg, 1;
        END
        IF @PayerType = 'CASH' DELETE @P WHERE Seq = 1 AND PayerType <> 'CASH';

        -- settings
        DECLARE @minDays INT, @blockGender BIT, @consentReq BIT;
        SELECT @minDays = IpdMinAdvanceDays, @blockGender = IpdBlockWardGenderMismatch, @consentReq = IpdConsentRequired FROM dbo.HospitalSettings WHERE BranchID = @BranchId;
        SET @minDays = ISNULL(@minDays, 0); SET @blockGender = ISNULL(@blockGender, 1); SET @consentReq = ISNULL(@consentReq, 0);

        -- consent
        DECLARE @cId INT, @cBy NVARCHAR(150), @cRel NVARCHAR(50), @cWit NVARCHAR(150), @cSig NVARCHAR(400), @cWSig NVARCHAR(400);
        IF ISJSON(@Consent) = 1
            SELECT @cId = j.ConsentId, @cBy = LEFT(NULLIF(LTRIM(RTRIM(j.SignedByName)), N''), 150), @cRel = LEFT(NULLIF(j.SignedByRelation, N''), 50),
                   @cWit = LEFT(NULLIF(LTRIM(RTRIM(j.WitnessName)), N''), 150), @cSig = LEFT(NULLIF(j.SignaturePath, N''), 400), @cWSig = LEFT(NULLIF(j.WitnessSignaturePath, N''), 400)
            FROM OPENJSON(@Consent) WITH (ConsentId INT, SignedByName NVARCHAR(200), SignedByRelation NVARCHAR(100), WitnessName NVARCHAR(200), SignaturePath NVARCHAR(500), WitnessSignaturePath NVARCHAR(500)) j;
        IF @cId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.ConsentMaster WHERE Consent_ID = @cId AND Status = 1 AND Type = 'IPD') THROW 54020, 'The consent form is not an active IPD consent.', 1;
        IF @cId IS NOT NULL AND @cBy IS NULL THROW 54021, 'Enter who signed the consent (patient or relative).', 1;
        IF @cId IS NOT NULL AND (SELECT WitnessRequired FROM dbo.ConsentMaster WHERE Consent_ID = @cId) = 1 AND @cWit IS NULL THROW 54022, 'This consent needs a witness: enter the witness name.', 1;
        IF @consentReq = 1 AND @cId IS NULL THROW 54023, 'The general admission consent must be taken before admission (Hospital Settings > IPD).', 1;

        -- estimate
        IF @EstimateId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdEstimate WHERE EstimateId = @EstimateId AND BranchId = @BranchId AND Status = 'ACTIVE')
            THROW 54024, 'The pre-admission estimate is not active (already used or cancelled).', 1;

        DECLARE @Pay TABLE (Amount DECIMAL(18,4));
        IF ISJSON(@Payments) = 1 INSERT @Pay SELECT j.Amount FROM OPENJSON(@Payments) WITH (Amount DECIMAL(18,4)) j WHERE ISNULL(j.Amount, 0) > 0;
        DECLARE @advance DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM @Pay);
        -- one open admission per patient
        DECLARE @openIp NVARCHAR(40), @openBed NVARCHAR(50);
        SELECT TOP 1 @openIp = a.IpNo, @openBed = b.BedNumber
        FROM dbo.IpdAdmission a WITH (UPDLOCK, HOLDLOCK) LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
        WHERE a.PatientId = @PatientId AND a.IsOpen = 1;
        IF @openIp IS NOT NULL BEGIN SET @msg = N'The patient is already admitted (' + @openIp + ISNULL(N', bed ' + @openBed, N'') + N'). Open that admission instead.'; THROW 54030, @msg, 1; END;

        -- 2572 (C2): a patient recorded as deceased cannot be admitted
        IF EXISTS (SELECT 1 FROM dbo.PatientDeceased WHERE PatientId = @PatientId)
            THROW 59661, 'This patient is recorded as deceased (death record of an earlier admission). Check that the right patient is chosen.', 1;
        -- 2572 (C6): readmission within Hospital Settings IpdReadmitDays (30) of the last discharge
        DECLARE @readmitOf INT, @readmitDays INT;
        SELECT TOP 1 @readmitOf = x.AdmissionId, @readmitDays = DATEDIFF(DAY, x.DischargeAt, @AdmissionAt)
        FROM dbo.IpdAdmission x WHERE x.PatientId = @PatientId AND x.Status = 'DISCHARGED' AND x.DischargeAt <= @AdmissionAt
          AND x.DischargeAt >= DATEADD(DAY, -(SELECT ReadmitDays FROM dbo.fn_Ipd_GapSettings(@BranchId)), @AdmissionAt)
        ORDER BY x.DischargeAt DESC;

        -- the bed: locked for the rest of the transaction
        DECLARE @ward INT, @room INT, @cat INT, @bStatus NVARCHAR(30), @bNo NVARCHAR(50), @wGender NVARCHAR(20), @wName NVARCHAR(150);
        SELECT @ward = b.WardId, @room = b.RoomId, @cat = b.BedCategoryId, @bStatus = b.BedStatus, @bNo = b.BedNumber, @wGender = w.Gender, @wName = w.WardName
        FROM dbo.BedMaster b WITH (UPDLOCK, HOLDLOCK) JOIN dbo.WardMaster w ON w.WardId = b.WardId
        WHERE b.BedId = @BedId AND b.BranchId = @BranchId AND b.IsActive = 1;
        IF @ward IS NULL THROW 54031, 'Choose an active bed of this branch.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdBedMovement WITH (UPDLOCK, HOLDLOCK) WHERE BedId = @BedId AND ToAt IS NULL)
        BEGIN SET @msg = N'Bed ' + @bNo + N' was just given to another patient. Choose another bed.'; THROW 54032, @msg, 1; END;
        -- a bed reserved for this patient (Bed Board > Reserve, SQLScripts/2431) can be used; any other reserved bed cannot
        DECLARE @resId INT = (SELECT TOP 1 x.ReservationId FROM dbo.IpdBedReservation x JOIN dbo.PatientMaster p ON p.PatientId = @PatientId
                              WHERE x.BedId = @BedId AND x.Status = 'ACTIVE' AND (x.PatientId = @PatientId OR (x.PatientId IS NULL AND x.Phone = p.PhoneNumber)));
        IF ISNULL(@bStatus, N'Available') <> N'Available' AND NOT (@bStatus = N'Reserved' AND @resId IS NOT NULL)
        BEGIN SET @msg = N'Bed ' + @bNo + N' is ' + @bStatus + N'. Choose an available bed.'; THROW 54033, @msg, 1; END;
        IF @blockGender = 1 AND @wGender IN (N'Male', N'Female') AND ISNULL(@gender, N'') IN (N'Male', N'Female') AND @wGender <> @gender
        BEGIN SET @msg = @wName + N' is a ' + LOWER(@wGender) + N' ward; the patient is ' + LOWER(@gender) + N'. Choose a bed in a suitable ward.'; THROW 54034, @msg, 1; END;

        -- 2572 (C3): the ward's age range (Ward Master > Min / Max age in days, e.g. NICU 0-28 days)
        DECLARE @wMin INT, @wMax INT, @ageDays INT;
        SELECT @wMin = MinAgeDays, @wMax = MaxAgeDays FROM dbo.WardMaster WHERE WardId = @ward;
        SELECT @ageDays = DATEDIFF(DAY, DateOfBirth, @AdmissionAt) FROM dbo.PatientMaster WHERE PatientId = @PatientId;
        IF @ageDays IS NOT NULL AND ((@wMin IS NOT NULL AND @ageDays < @wMin) OR (@wMax IS NOT NULL AND @ageDays > @wMax))
        BEGIN SET @msg = CONCAT(@wName, N' is for patients aged ', dbo.fn_Ipd_AgeRangeText(@wMin, @wMax), N'; the patient is ', dbo.fn_Ipd_DaysText(@ageDays), N'. Choose a bed in a suitable ward.'); THROW 59662, @msg, 1; END;

        IF NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_BedRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE)))
           AND NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_IcuDailyRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE))) /* 2493 icu */
        BEGIN SET @msg = N'Bed ' + @bNo + N' has no rate for this tariff category (Master > IPD > Bed / Room Tariff): it cannot be given. Choose a bed with a rate or add the rate.'; THROW 54037, @msg, 1; END;
        -- minimum advance for cash patients: N days of this bed (Hospital Settings > IPD)
        IF @minDays > 0 AND @PayerType = 'CASH'
        BEGIN
            DECLARE @daily DECIMAL(18,2) = (SELECT TOP 1 (RoomCharge + BedCharge + NursingCharge + RmoCharge + AttendantCharge + IsolationCharge)
                                                   * (1 + CASE WHEN ISNULL((SELECT IpdRoomGstThreshold FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 5000) = 0
                                                                 OR RoomCharge + BedCharge + NursingCharge + RmoCharge + AttendantCharge + IsolationCharge > ISNULL((SELECT IpdRoomGstThreshold FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 5000)
                                                               THEN GstPercentage ELSE 0 END / 100)
                                            FROM dbo.fn_Ipd_BedRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE)));
            DECLARE @need DECIMAL(18,2) = ROUND(COALESCE(@daily, (SELECT DailyRate FROM dbo.fn_Ipd_IcuDailyRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE))), 0) * @minDays, 0);
            IF @need > 0 AND @advance < @need
            BEGIN
                IF ISNULL(@CanWaiveAdvance, 0) = 0
                BEGIN SET @msg = CONCAT(N'A minimum advance of ₹', FORMAT(@need, 'N2', 'en-IN'), N' (', @minDays, N' day(s) of this bed) is needed for a cash patient. Collect it, or ask a user with the Waive Advance permission.'); THROW 54035, @msg, 1; END;
                IF NULLIF(LTRIM(RTRIM(@AdvanceWaiveReason)), N'') IS NULL THROW 54036, 'Enter the reason for admitting without the minimum advance.', 1;
            END
            ELSE SET @AdvanceWaiveReason = NULL;
        END
        ELSE SET @AdvanceWaiveReason = NULL;

        DECLARE @ipNo NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IP', @DocDate = @AdmissionAt, @DocNo = @ipNo OUTPUT;

        INSERT dbo.IpdAdmission (CompanyId, BranchId, IpNo, PatientId, AdmissionAt, AdmissionType, AdmissionSource, OpdServiceId, ReferralDoctorId, AdmittingDoctorId,
               ConsultantDoctorId, DepartmentId, ProvisionalDiagnosis, DiagnosisCode, ReasonForAdmission, ExpectedDischargeAt, CurrentBedId, TariffCategoryId, PayerType,
               PackageId, IsMlc, EstimateId, Status, IsOpen, AdvanceWaived, AdvanceWaiveReason, Remarks, RequestKey, CreatedBy)
        VALUES (@CompanyId, @BranchId, @ipNo, @PatientId, @AdmissionAt, @AdmissionType, @AdmissionSource, @OpdServiceId, NULLIF(@ReferralDoctorId, 0), @AdmittingDoctorId,
               @ConsultantDoctorId, NULLIF(@DepartmentId, 0), NULLIF(LTRIM(RTRIM(@ProvisionalDiagnosis)), N''), NULLIF(LTRIM(RTRIM(@DiagnosisCode)), N''),
               NULLIF(LTRIM(RTRIM(@ReasonForAdmission)), N''), @ExpectedDischargeAt, @BedId, @TariffCategoryId, @PayerType, @PackageId, ISNULL(@IsMlc, 0), @EstimateId,
               'ADMITTED', 1, CASE WHEN @AdvanceWaiveReason IS NULL THEN 0 ELSE 1 END, @AdvanceWaiveReason, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @RequestKey, @UserId);
        DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);

        UPDATE dbo.IpdAdmission SET ReadmitOfAdmissionId = @readmitOf, ReadmitDays = @readmitDays WHERE AdmissionId = @id;   -- 2572 (C6)
        INSERT dbo.IpdBedMovement (AdmissionId, BedId, WardId, RoomId, BedCategoryId, FromAt, MoveType, CreatedBy)
        VALUES (@id, @BedId, @ward, @room, @cat, @AdmissionAt, 'ADMIT', @UserId);
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @BedId, @ToStatus = N'Occupied', @Reason = N'Patient admitted', @AdmissionId = @id, @UserId = @UserId, @RefType = 'ADMIT';
        IF @resId IS NOT NULL UPDATE dbo.IpdBedReservation SET Status = 'USED', AdmissionId = @id, ModifiedBy = @UserId, ModifiedDate = @now WHERE ReservationId = @resId;
        -- the OPD admission advice of this patient is done (SQLScripts/2438)
        IF OBJECT_ID('dbo.IpdAdmissionAdvice', 'U') IS NOT NULL
            EXEC sp_executesql N'UPDATE dbo.IpdAdmissionAdvice SET Status = ''ADMITTED'', AdmissionId = @a, ModifiedBy = @u, ModifiedDate = GETDATE() WHERE PatientId = @p AND BranchId = @b AND Status = ''PENDING''',
                  N'@a INT, @u INT, @p INT, @b INT', @a = @id, @u = @UserId, @p = @PatientId, @b = @BranchId;

        INSERT dbo.IpdAdmissionPayer (AdmissionId, Seq, PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
        SELECT @id, ROW_NUMBER() OVER (ORDER BY Seq), PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks
        FROM @P;

        IF ISJSON(@Attendants) = 1
            INSERT dbo.IpdAttendant (AdmissionId, Name, Relation, Phone, Address, IdTypeId, IdNumber, IsPrimary, PassNo)
            SELECT @id, LEFT(LTRIM(RTRIM(j.Name)), 150), LEFT(NULLIF(j.Relation, N''), 50), LEFT(NULLIF(j.Phone, N''), 20), LEFT(NULLIF(j.Address, N''), 400),
                   NULLIF(j.IdTypeId, 0), LEFT(NULLIF(j.IdNumber, N''), 60), ISNULL(j.IsPrimary, 0), LEFT(NULLIF(j.PassNo, N''), 30)
            FROM OPENJSON(@Attendants) WITH (Name NVARCHAR(200), Relation NVARCHAR(100), Phone NVARCHAR(40), Address NVARCHAR(500), IdTypeId INT, IdNumber NVARCHAR(100), IsPrimary BIT, PassNo NVARCHAR(60)) j
            WHERE NULLIF(LTRIM(RTRIM(j.Name)), N'') IS NOT NULL;

        -- 2572 (C1): a medico-legal case needs the nature of the case and who brought the patient
        IF ISNULL(@IsMlc, 0) = 1 AND (ISJSON(@Mlc) <> 1 OR NULLIF(LTRIM(RTRIM(JSON_VALUE(@Mlc, '$.Nature'))), N'') IS NULL
                                       OR NULLIF(LTRIM(RTRIM(JSON_VALUE(@Mlc, '$.BroughtBy'))), N'') IS NULL)
            THROW 59660, 'Medico-legal case: enter the nature of the case and who brought the patient (the police intimation can follow, before the final bill).', 1;
        IF ISNULL(@IsMlc, 0) = 1
            INSERT dbo.IpdMlc (AdmissionId, MlcNo, Nature, IncidentAt, IncidentPlace, BroughtBy, BroughtByPhone, PoliceStation, OfficerName, InformedAt, Remarks, ModifiedBy, ModifiedDate)
            SELECT @id, LEFT(NULLIF(j.MlcNo, N''), 40), LEFT(NULLIF(j.Nature, N''), 40), j.IncidentAt, LEFT(NULLIF(j.IncidentPlace, N''), 200), LEFT(NULLIF(j.BroughtBy, N''), 150),
                   LEFT(NULLIF(j.BroughtByPhone, N''), 20), LEFT(NULLIF(j.PoliceStation, N''), 150), LEFT(NULLIF(j.OfficerName, N''), 150), j.InformedAt, LEFT(NULLIF(j.Remarks, N''), 500), @UserId, @now
            FROM (SELECT ISNULL(NULLIF(@Mlc, N''), N'{}') AS js) x
            CROSS APPLY OPENJSON(CASE WHEN ISJSON(x.js) = 1 THEN x.js ELSE N'{}' END)
                WITH (MlcNo NVARCHAR(100), Nature NVARCHAR(100), IncidentAt DATETIME, IncidentPlace NVARCHAR(300), BroughtBy NVARCHAR(200), BroughtByPhone NVARCHAR(40),
                      PoliceStation NVARCHAR(200), OfficerName NVARCHAR(200), InformedAt DATETIME, Remarks NVARCHAR(600)) j;

        IF @cId IS NOT NULL
            INSERT dbo.IpdAdmissionConsent (AdmissionId, ConsentId, ConsentType, Language, Version, ContentHtml, SignedByName, SignedByRelation, WitnessName, SignaturePath, WitnessSignaturePath, SignedAt, CreatedBy)
            SELECT @id, c.Consent_ID, c.ConsentType, c.Language, c.Version, dbo.fn_Ipd_FillConsent(c.ConsentTemplateContent, @id, @cRel, @cWit, @now),
                   @cBy, @cRel, @cWit, @cSig, @cWSig, @now, @UserId
            FROM dbo.ConsentMaster c WHERE c.Consent_ID = @cId;

        IF @EstimateId IS NOT NULL
            UPDATE dbo.IpdEstimate SET Status = 'CONVERTED', AdmissionId = @id, ModifiedBy = @UserId, ModifiedDate = @now WHERE EstimateId = @EstimateId;

        INSERT dbo.IpdStatusLog (AdmissionId, Action, ToStatus, Remarks, CreatedBy)
        VALUES (@id, 'ADMIT', 'ADMITTED', CONCAT(N'Admitted to ', @wName, N' / bed ', @bNo, CASE WHEN @AdvanceWaiveReason IS NOT NULL THEN N'; minimum advance waived: ' + @AdvanceWaiveReason END), @UserId);

        DECLARE @advId INT = NULL, @rcpt NVARCHAR(50) = NULL;
        IF @advance > 0
            EXEC dbo.usp_Ipd_PostAdvance @AdmissionId = @id, @UserId = @UserId, @Payments = @Payments, @Remarks = N'At admission', @AdvanceId = @advId OUTPUT, @ReceiptNo = @rcpt OUTPUT;

        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS AdmissionId, @ipNo AS IpNo, @rcpt AS ReceiptNo, @advId AS AdvanceId, CAST(0 AS BIT) AS Existing;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() IN (2601, 2627)
            SELECT CAST(0 AS BIT) AS Success, N'The bed or the patient was just taken by another admission. Refresh the beds and try again.' AS Error;
        ELSE IF ERROR_NUMBER() >= 50000
            SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error;
        ELSE THROW;
    END CATCH
END;
GO

PRINT '2578 IPD doctor lists - done.';
GO
