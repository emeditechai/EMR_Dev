-- 2577: IPD packages - standard rules (2026-11-28). Needs 2570-2576. Safe to re-run.
--   1  Validity: a package is given only when it is valid on the admission date (Hospital Package > Valid From / Valid To).
--   2  Payer: CASH = any active hospital package; INSURANCE = a package agreed with the patient's insurer / TPA
--      (Insurance Tariff Configuration, entitlement Package, active and effective on the admission date); CORPORATE = a package in
--      the corporate's rate master (Corporate Hospital Rate, service Package); SCHEME = no hospital package (government schemes
--      are billed on their own package codes).
--   3  Price: the package line of the bill is the payer's agreed rate (insurer rate; corporate rate and / or discount), else the
--      package amount.
--   4  Outside the package: what is billed outside the package is worked out (banner, Billing tab).
-- Checked at admission, edit admission and Package tab. REPLACES usp_Api_IpdAdmission_Save, usp_Api_IpdAdmission_Update,
-- usp_Api_IpdBill_SetPackage, fn_Ipd_BillLines (package line), usp_Api_IpdAdmission_Get, usp_Api_IpdBill_Preview (live + the rules):
-- re-run 2577 after 2571-2576 or any older IPD script. Errors 60000-60019.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- the package for a payer on a date: Message NULL = allowed; Amount = the price to bill; RateSource = where the price comes from
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PackageCheck (@PackageId INT, @BranchId INT, @OnDate DATE, @PayerType VARCHAR(12), @InsuranceTpaId INT, @CorporateId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(CASE
                WHEN p.HospitalPackage_ID IS NULL OR p.Status <> 1 OR p.Branch_ID <> @BranchId THEN N'Choose an active package of this branch.'
                WHEN ISNULL(p.TotalPackageAmount, 0) <= 0 THEN N'This package has no amount (Master > Hospital Package): it cannot be applied.'
                WHEN p.ValidFrom IS NOT NULL AND CAST(p.ValidFrom AS DATE) > @OnDate
                    THEN CONCAT(N'Package ', p.Package_Name, N' is valid only from ', FORMAT(p.ValidFrom, 'dd-MMM-yyyy'), N' (the admission is on ', FORMAT(@OnDate, 'dd-MMM-yyyy'), N').')
                WHEN p.ValidTo IS NOT NULL AND CAST(p.ValidTo AS DATE) < @OnDate
                    THEN CONCAT(N'Package ', p.Package_Name, N' expired on ', FORMAT(p.ValidTo, 'dd-MMM-yyyy'), N' (the admission is on ', FORMAT(@OnDate, 'dd-MMM-yyyy'), N'): renew it in Master > Hospital Package or choose another.')
                WHEN @PayerType = 'SCHEME' THEN N'A government scheme patient is billed on the scheme''s own package codes: a hospital package cannot be applied.'
                WHEN @PayerType = 'INSURANCE' AND ins.InsTariff_ID IS NULL
                    THEN CONCAT(N'Package ', p.Package_Name, N' is not agreed with this insurer / TPA on the admission date (Master > Insurance Tariff Configuration > Package).')
                WHEN @PayerType = 'CORPORATE' AND corp.CorpRate_ID IS NULL
                    THEN CONCAT(N'Package ', p.Package_Name, N' is not in this corporate''s rate master on the admission date (Master > Corporate Hospital Rate > Package).')
                END AS NVARCHAR(400)) AS Message,
           CAST(CASE WHEN @PayerType = 'INSURANCE' AND ins.Rate > 0 THEN ins.Rate
                     WHEN @PayerType = 'CORPORATE' AND corp.CorpRate_ID IS NOT NULL
                         THEN ROUND((CASE WHEN corp.RateType IN ('Rate', 'Both') AND corp.Rate > 0 THEN corp.Rate ELSE p.TotalPackageAmount END)
                                    * (1 - CASE WHEN corp.RateType IN ('Discount', 'Both') THEN ISNULL(corp.DiscountPercent, 0) ELSE 0 END / 100.0), 2)
                     ELSE p.TotalPackageAmount END AS DECIMAL(18,2)) AS Amount,
           CAST(CASE WHEN @PayerType = 'INSURANCE' AND ins.Rate > 0 THEN 'INSURER' WHEN @PayerType = 'CORPORATE' AND corp.CorpRate_ID IS NOT NULL THEN 'CORPORATE' ELSE 'PACKAGE' END AS VARCHAR(10)) AS RateSource,
           p.Package_Name AS PackageName
    FROM (SELECT 1 AS One) o
    LEFT JOIN dbo.HospitalPackageMaster p ON p.HospitalPackage_ID = @PackageId
    OUTER APPLY (SELECT TOP 1 t.InsTariff_ID, t.Rate FROM dbo.InsuranceTariffMaster t
                 WHERE @PayerType = 'INSURANCE' AND t.InsuranceTPA_ID = @InsuranceTpaId AND t.Branch_ID = @BranchId AND t.EntitlementType = N'Package' AND t.Reference_ID = @PackageId
                   AND t.Status = 1 AND CAST(t.Effective_From AS DATE) <= @OnDate AND CAST(t.Effective_To AS DATE) >= @OnDate
                 ORDER BY t.Effective_From DESC) ins
    OUTER APPLY (SELECT TOP 1 c.CorpRate_ID, c.RateType, c.Rate, c.DiscountPercent FROM dbo.CorporateHospitalRateMaster c
                 WHERE @PayerType = 'CORPORATE' AND c.Corporate_ID = @CorporateId AND c.Branch_ID = @BranchId AND c.RateServiceType = N'Package' AND c.ReferenceMaster_ID = @PackageId
                   AND c.Status = 1 AND CAST(c.Effective_From AS DATE) <= @OnDate AND (c.Effective_To IS NULL OR CAST(c.Effective_To AS DATE) >= @OnDate)
                 ORDER BY c.Effective_From DESC) corp
);
GO

-- the package of an admission, priced for its payer (the package line of the bill)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_AdmissionPackage (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT a.AdmissionId, a.PackageId, c.Amount, c.RateSource, c.Message
    FROM dbo.IpdAdmission a
    OUTER APPLY (SELECT TOP 1 InsuranceTpaId, CorporateId FROM dbo.IpdAdmissionPayer py WHERE py.AdmissionId = a.AdmissionId AND py.Seq = 1) py
    CROSS APPLY dbo.fn_Ipd_PackageCheck(a.PackageId, a.BranchId, CAST(a.AdmissionAt AS DATE), a.PayerType, py.InsuranceTpaId, py.CorporateId) c
    WHERE a.AdmissionId = @AdmissionId AND a.PackageId IS NOT NULL
);
GO

-- what is billed outside the package of an admission (lines not covered by it), as of @AsOf
CREATE OR ALTER FUNCTION dbo.fn_Ipd_OutsidePackage (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS OutsideAmount, COUNT(l.Head) AS OutsideLines
    FROM dbo.IpdAdmission a
    CROSS APPLY dbo.fn_Ipd_BillLines(a.AdmissionId, @AsOf) l
    WHERE a.AdmissionId = @AdmissionId AND a.PackageId IS NOT NULL AND ISNULL(l.IsPackageItem, 0) = 0 AND l.Head NOT IN ('PACKAGE', 'ADJUST') AND ISNULL(l.Net, 0) > 0
);
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
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AdmittingDoctorId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54011, 'Choose the admitting doctor.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                       WHERE m.DoctorId = @AdmittingDoctorId AND m.IsActive = 1)
            THROW 54025, 'The admitting doctor must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @ConsultantDoctorId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54012, 'Choose the consultant (treating doctor).', 1;
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

-- ── edit admission (live + 2577 package rules) ──
-- ── edit admission (live + 2572: C1 MLC) ──
-- ── edit admission (2423) + the dependencies above ──────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Update
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT,
    @AdmissionType VARCHAR(20), @AdmissionSource VARCHAR(20), @ReferralDoctorId INT = NULL, @AdmittingDoctorId INT, @ConsultantDoctorId INT,
    @DepartmentId INT = NULL, @ProvisionalDiagnosis NVARCHAR(500) = NULL, @DiagnosisCode NVARCHAR(20) = NULL, @ReasonForAdmission NVARCHAR(500) = NULL,
    @ExpectedDischargeAt DATETIME = NULL, @TariffCategoryId INT, @PayerType VARCHAR(12), @PackageId INT = NULL, @Remarks NVARCHAR(1000) = NULL,
    @Payers NVARCHAR(MAX) = NULL, @Attendants NVARCHAR(MAX) = NULL, @IsMlc BIT = 0, @Mlc NVARCHAR(MAX) = NULL, @CanChangeTariff BIT = 0,
    @CanChangePackage BIT = 0, @PackageReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @oldTc INT, @oldPayer VARCHAR(12), @open BIT, @admAt DATETIME, @oldTcName NVARCHAR(150), @newTcName NVARCHAR(150),
                @oldPkg INT, @oldDept INT, @oldCon INT, @oldAdm INT, @bed INT, @bill INT, @oldPt VARCHAR(20), @newPt VARCHAR(20);
        -- locked: a bill / transfer / charge cannot slip in between the checks and the save
        SELECT @oldTc = TariffCategoryId, @oldPayer = PayerType, @open = IsOpen, @admAt = AdmissionAt, @oldPkg = PackageId, @oldDept = DepartmentId,
               @oldCon = ConsultantDoctorId, @oldAdm = AdmittingDoctorId, @bed = CurrentBedId, @bill = BillId
        FROM dbo.IpdAdmission WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54201, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 54202, 'The admission is closed and cannot be changed.', 1;
        IF @bill IS NOT NULL OR EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND Status = 'BILL_FINAL') THROW 54230, 'The final bill is made: cancel the bill to change the admission.', 1;
        SET @PackageId = NULLIF(@PackageId, 0);
        SET @AdmissionType = UPPER(@AdmissionType); SET @AdmissionSource = UPPER(@AdmissionSource); SET @PayerType = UPPER(@PayerType);
        IF @AdmissionType NOT IN ('ELECTIVE', 'EMERGENCY', 'DAYCARE', 'MATERNITY', 'TRANSFERIN') THROW 54203, 'Choose the admission type.', 1;
        IF @AdmissionSource NOT IN ('DIRECT', 'OPD', 'EMERGENCY', 'REFERRAL') THROW 54204, 'Choose the admission source.', 1;
        IF @PayerType NOT IN ('CASH', 'CORPORATE', 'INSURANCE', 'SCHEME') THROW 54205, 'Choose the payer.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AdmittingDoctorId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54206, 'Choose the admitting doctor.', 1;
        IF @AdmittingDoctorId <> (SELECT AdmittingDoctorId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId)
           AND NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                           WHERE m.DoctorId = @AdmittingDoctorId AND m.IsActive = 1)
            THROW 54215, 'The admitting doctor must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @ConsultantDoctorId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54207, 'Choose the consultant (treating doctor).', 1;
        IF @ConsultantDoctorId <> (SELECT ConsultantDoctorId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId)
           AND NOT EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster x ON x.DeptId = m.DeptId AND x.IsActive = 1 AND x.DeptType = 'IPD'
                           WHERE m.DoctorId = @ConsultantDoctorId AND m.IsActive = 1)
            THROW 54216, 'The consultant (treating doctor) must belong to an IPD department (Master > Doctor > departments of type IPD).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId AND IsActive = 1 AND CompanyId = @CompanyId AND (BranchId = @BranchId OR BranchId IS NULL))
            THROW 54208, 'Choose the tariff category.', 1;
        IF NULLIF(@DepartmentId, 0) IS NOT NULL AND ISNULL(@DepartmentId, 0) <> ISNULL((SELECT DepartmentId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId), 0)
           AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster WHERE DeptId = @DepartmentId AND IsActive = 1 AND DeptType = 'IPD')
            THROW 54217, 'Choose an IPD department (Master > Department, type IPD).', 1;
        -- the bed must stay in a ward of the department (as at admission): a change of ward is a bed transfer
        IF ISNULL(NULLIF(@DepartmentId, 0), 0) <> ISNULL(@oldDept, 0) AND NULLIF(@DepartmentId, 0) IS NOT NULL AND @bed IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId WHERE b.BedId = @bed AND w.DepartmentId IS NOT NULL AND w.DepartmentId <> @DepartmentId)
            THROW 54234, 'The patient''s bed is in a ward of another department. Use Transfer Bed (with "update department") to move the patient to a bed of the new department.', 1;
        -- a package change re-prices the charges: it needs the Package permission (and a reason when a package is replaced or removed), as the Package button
        IF ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0)
        BEGIN
            IF ISNULL(@CanChangePackage, 0) = 0 THROW 54235, 'You are not allowed to change the package of an admission (Package permission).', 1;
            IF @oldPkg IS NOT NULL AND NULLIF(LTRIM(RTRIM(@PackageReason)), N'') IS NULL THROW 54236, 'Enter the reason for changing the package.', 1;
        END
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1 AND ISNULL(TotalPackageAmount, 0) > 0)
            AND ISNULL(@PackageId, 0) <> ISNULL((SELECT PackageId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId), 0)
            THROW 54232, 'Choose an active package of this branch that has an amount.', 1;
        IF @TariffCategoryId <> @oldTc AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_IcuDailyRate(@BranchId, a.CurrentBedId, @TariffCategoryId, CAST(GETDATE() AS DATE)) r2
                                                         WHERE a.AdmissionId = @AdmissionId) /* 2493 icu */
           AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, a.CurrentBedId, @TariffCategoryId, CAST(GETDATE() AS DATE)) r
                                                         WHERE a.AdmissionId = @AdmissionId AND a.CurrentBedId IS NOT NULL)
            THROW 54231, 'The patient''s bed has no rate in the new tariff category (Master > IPD > Bed / Room Tariff): add the rate first.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId
                       AND CASE @PayerType WHEN 'CASH' THEN CASE WHEN PatientCategory LIKE N'%Cash%' OR PatientCategory LIKE N'%Self%' OR PatientCategory LIKE N'%Staff%' OR PatientCategory LIKE N'%Employee%' THEN 1 ELSE 0 END
                                           WHEN 'CORPORATE' THEN CASE WHEN PatientCategory LIKE N'%Corporate%' THEN 1 ELSE 0 END
                                           WHEN 'INSURANCE' THEN CASE WHEN PatientCategory LIKE N'%Insurance%' OR PatientCategory LIKE N'%TPA%' THEN 1 ELSE 0 END
                                           ELSE CASE WHEN PatientCategory LIKE N'%Government%' OR PatientCategory LIKE N'%Scheme%' THEN 1 ELSE 0 END END = 1)
            THROW 54233, 'The tariff category does not belong to the chosen payer (Master > Tariff Category > Patient Category).', 1;
        IF (@TariffCategoryId <> @oldTc OR @PayerType <> @oldPayer) AND ISNULL(@CanChangeTariff, 0) = 0
            THROW 54209, 'You are not allowed to change the payer or tariff category of an admission (it re-prices the whole stay).', 1;
        IF @ExpectedDischargeAt IS NOT NULL AND @ExpectedDischargeAt <= @admAt THROW 54210, 'The expected discharge must be after the admission time.', 1;

        DECLARE @P TABLE (Seq INT IDENTITY(1,1), PayerType VARCHAR(12), InsuranceTpaId INT, CorporateId INT, SchemeId INT, PolicyNo NVARCHAR(60), MemberId NVARCHAR(60),
                          CardHolderName NVARCHAR(150), RelationToHolder NVARCHAR(50), PolicyValidTo DATE, EmployeeId NVARCHAR(60), CardFilePath NVARCHAR(400), Remarks NVARCHAR(300));
        IF ISJSON(@Payers) = 1
            INSERT @P (PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
            SELECT UPPER(j.PayerType), j.InsuranceTpaId, j.CorporateId, j.SchemeId, LEFT(NULLIF(j.PolicyNo, N''), 60), LEFT(NULLIF(j.MemberId, N''), 60), LEFT(NULLIF(j.CardHolderName, N''), 150),
                   LEFT(NULLIF(j.RelationToHolder, N''), 50), j.PolicyValidTo, LEFT(NULLIF(j.EmployeeId, N''), 60), LEFT(NULLIF(j.CardFilePath, N''), 400), LEFT(NULLIF(j.Remarks, N''), 300)
            FROM OPENJSON(@Payers) WITH (PayerType VARCHAR(12), InsuranceTpaId INT, CorporateId INT, SchemeId INT, PolicyNo NVARCHAR(100), MemberId NVARCHAR(100), CardHolderName NVARCHAR(200),
                                         RelationToHolder NVARCHAR(100), PolicyValidTo DATE, EmployeeId NVARCHAR(100), CardFilePath NVARCHAR(500), Remarks NVARCHAR(500)) j
            WHERE j.PayerType IN ('CORPORATE', 'INSURANCE', 'SCHEME');
        IF @PayerType <> 'CASH' AND NOT EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND PayerType = @PayerType) THROW 54211, 'Enter the payer details (insurance / TPA, corporate or scheme).', 1;
        IF @PayerType = 'INSURANCE' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND (InsuranceTpaId IS NULL OR PolicyNo IS NULL)) THROW 54212, 'Choose the insurance / TPA and enter the policy number.', 1;
        IF @PayerType = 'CORPORATE' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND CorporateId IS NULL) THROW 54213, 'Choose the corporate.', 1;
        IF @PayerType = 'SCHEME' AND EXISTS (SELECT 1 FROM @P WHERE Seq = 1 AND SchemeId IS NULL) THROW 54214, 'Choose the government scheme.', 1;
        -- 2577: the package is valid on the admission date and allowed for the payer
        IF @PackageId IS NOT NULL
           AND (ISNULL(@oldPkg, 0) <> @PackageId OR @PayerType <> @oldPayer
                OR EXISTS (SELECT 1 FROM @P n LEFT JOIN dbo.IpdAdmissionPayer o ON o.AdmissionId = @AdmissionId AND o.Seq = 1
                           WHERE n.Seq = 1 AND (ISNULL(n.InsuranceTpaId, 0) <> ISNULL(o.InsuranceTpaId, 0) OR ISNULL(n.CorporateId, 0) <> ISNULL(o.CorporateId, 0))))
        BEGIN
            DECLARE @pkgMsg NVARCHAR(400) = (SELECT c.Message FROM dbo.fn_Ipd_PackageCheck(@PackageId, @BranchId, CAST(@admAt AS DATE), @PayerType,
                                                (SELECT TOP 1 InsuranceTpaId FROM @P WHERE Seq = 1), (SELECT TOP 1 CorporateId FROM @P WHERE Seq = 1)) c);
            IF @pkgMsg IS NOT NULL THROW 60000, @pkgMsg, 1;
        END

        SELECT @oldPt = PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId);
        SELECT @oldTcName = Name FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @oldTc;
        SELECT @newTcName = Name FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId;
        UPDATE dbo.IpdAdmission SET AdmissionType = @AdmissionType, AdmissionSource = @AdmissionSource, ReferralDoctorId = NULLIF(@ReferralDoctorId, 0),
               AdmittingDoctorId = @AdmittingDoctorId, ConsultantDoctorId = @ConsultantDoctorId, DepartmentId = NULLIF(@DepartmentId, 0),
               ProvisionalDiagnosis = NULLIF(LTRIM(RTRIM(@ProvisionalDiagnosis)), N''), DiagnosisCode = NULLIF(LTRIM(RTRIM(@DiagnosisCode)), N''),
               ReasonForAdmission = NULLIF(LTRIM(RTRIM(@ReasonForAdmission)), N''), ExpectedDischargeAt = @ExpectedDischargeAt, TariffCategoryId = @TariffCategoryId,
               PayerType = @PayerType, PackageId = @PackageId, IsMlc = ISNULL(@IsMlc, 0), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), ModifiedBy = @UserId, ModifiedDate = @now
        WHERE AdmissionId = @AdmissionId;

        DELETE dbo.IpdAdmissionPayer WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdAdmissionPayer (AdmissionId, Seq, PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
        SELECT @AdmissionId, ROW_NUMBER() OVER (ORDER BY Seq), PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks
        FROM @P WHERE @PayerType <> 'CASH' OR Seq > 1;

        DELETE dbo.IpdAttendant WHERE AdmissionId = @AdmissionId;
        IF ISJSON(@Attendants) = 1
            INSERT dbo.IpdAttendant (AdmissionId, Name, Relation, Phone, Address, IdTypeId, IdNumber, IsPrimary, PassNo)
            SELECT @AdmissionId, LEFT(LTRIM(RTRIM(j.Name)), 150), LEFT(NULLIF(j.Relation, N''), 50), LEFT(NULLIF(j.Phone, N''), 20), LEFT(NULLIF(j.Address, N''), 400),
                   NULLIF(j.IdTypeId, 0), LEFT(NULLIF(j.IdNumber, N''), 60), ISNULL(j.IsPrimary, 0), LEFT(NULLIF(j.PassNo, N''), 30)
            FROM OPENJSON(@Attendants) WITH (Name NVARCHAR(200), Relation NVARCHAR(100), Phone NVARCHAR(40), Address NVARCHAR(500), IdTypeId INT, IdNumber NVARCHAR(100), IsPrimary BIT, PassNo NVARCHAR(60)) j
            WHERE NULLIF(LTRIM(RTRIM(j.Name)), N'') IS NOT NULL;

        -- 2572 (C1): a medico-legal case needs the nature of the case and who brought the patient
        IF ISNULL(@IsMlc, 0) = 1 AND (ISJSON(@Mlc) <> 1 OR NULLIF(LTRIM(RTRIM(JSON_VALUE(@Mlc, '$.Nature'))), N'') IS NULL
                                       OR NULLIF(LTRIM(RTRIM(JSON_VALUE(@Mlc, '$.BroughtBy'))), N'') IS NULL)
            THROW 59660, 'Medico-legal case: enter the nature of the case and who brought the patient (the police intimation can follow, before the final bill).', 1;
        IF ISNULL(@IsMlc, 0) = 1
        BEGIN
            DECLARE @mj NVARCHAR(MAX) = CASE WHEN ISJSON(@Mlc) = 1 THEN @Mlc ELSE N'{}' END;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdMlc WHERE AdmissionId = @AdmissionId) INSERT dbo.IpdMlc (AdmissionId) VALUES (@AdmissionId);
            UPDATE m SET MlcNo = LEFT(NULLIF(j.MlcNo, N''), 40), Nature = LEFT(NULLIF(j.Nature, N''), 40), IncidentAt = j.IncidentAt, IncidentPlace = LEFT(NULLIF(j.IncidentPlace, N''), 200),
                   BroughtBy = LEFT(NULLIF(j.BroughtBy, N''), 150), BroughtByPhone = LEFT(NULLIF(j.BroughtByPhone, N''), 20), PoliceStation = LEFT(NULLIF(j.PoliceStation, N''), 150),
                   OfficerName = LEFT(NULLIF(j.OfficerName, N''), 150), InformedAt = j.InformedAt, Remarks = LEFT(NULLIF(j.Remarks, N''), 500), ModifiedBy = @UserId, ModifiedDate = @now
            FROM dbo.IpdMlc m
            CROSS APPLY OPENJSON(@mj) WITH (MlcNo NVARCHAR(100), Nature NVARCHAR(100), IncidentAt DATETIME, IncidentPlace NVARCHAR(300), BroughtBy NVARCHAR(200), BroughtByPhone NVARCHAR(40),
                                           PoliceStation NVARCHAR(200), OfficerName NVARCHAR(200), InformedAt DATETIME, Remarks NVARCHAR(600)) j
            WHERE m.AdmissionId = @AdmissionId;
        END
        -- an MLC record is never deleted (medico-legal); un-ticking only clears the flag

        -- dependencies of the change (SQLScripts/2476)
        DECLARE @tariffRepriced INT = 0, @tariffKept INT = 0, @phRepriced INT = 0;
        IF ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0) EXEC dbo.usp_Ipd_ApplyPackageFlags @AdmissionId = @AdmissionId;
        IF @TariffCategoryId <> @oldTc
            EXEC dbo.usp_Ipd_RepriceTariff @AdmissionId = @AdmissionId, @Repriced = @tariffRepriced OUTPUT, @Kept = @tariffKept OUTPUT;
        SELECT @newPt = PriceType FROM dbo.fn_Ipd_PhPriceType(@AdmissionId);
        IF @newPt <> @oldPt EXEC dbo.usp_Ipd_RepricePharmacy @AdmissionId = @AdmissionId, @CompanyId = @CompanyId, @Repriced = @phRepriced OUTPUT;
        IF ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0)
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'PACKAGE', CONCAT(N'Package ', ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @oldPkg), N'none'), N' → ',
                    ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), N'none'), N' (edit admission)',
                    ISNULL(N': ' + NULLIF(LTRIM(RTRIM(@PackageReason)), N''), N'')), @UserId);

        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'EDIT', CONCAT(N'Admission details updated',
                CASE WHEN @TariffCategoryId <> @oldTc THEN N'; tariff category ' + ISNULL(@oldTcName, N'?') + N' → ' + ISNULL(@newTcName, N'?') END,
                CASE WHEN @PayerType <> @oldPayer THEN N'; payer ' + @oldPayer + N' → ' + @PayerType END,
                CASE WHEN @ConsultantDoctorId <> @oldCon THEN N'; consultant ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @oldCon), N'?') + N' → ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @ConsultantDoctorId), N'?') END,
                CASE WHEN @AdmittingDoctorId <> @oldAdm THEN N'; admitting doctor ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @oldAdm), N'?') + N' → ' + ISNULL((SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @AdmittingDoctorId), N'?') END,
                CASE WHEN ISNULL(NULLIF(@DepartmentId, 0), 0) <> ISNULL(@oldDept, 0) THEN N'; department ' + ISNULL((SELECT DeptName FROM dbo.DepartmentMaster WHERE DeptId = @oldDept), N'none') + N' → ' + ISNULL((SELECT DeptName FROM dbo.DepartmentMaster WHERE DeptId = NULLIF(@DepartmentId, 0)), N'none') END,
                CASE WHEN @tariffRepriced + @tariffKept > 0 THEN CONCAT(N'; ', @tariffRepriced, N' charge(s) re-priced to the new tariff', CASE WHEN @tariffKept > 0 THEN CONCAT(N', ', @tariffKept, N' kept (edited rate or no rate in the new tariff)') END) END,
                CASE WHEN @phRepriced > 0 THEN CONCAT(N'; ', @phRepriced, N' pharmacy line(s) re-priced for the new payer') END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId,
               @tariffRepriced AS TariffRepriced, @tariffKept AS TariffKept, @phRepriced AS PharmacyRepriced,
               CAST(CASE WHEN ISNULL(@PackageId, 0) <> ISNULL(@oldPkg, 0) THEN 1 ELSE 0 END AS BIT) AS PackageChanged;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── package tab (live + 2577 package rules) ──
-- Package button (2434), the flags now in usp_Ipd_ApplyPackageFlags
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_SetPackage @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @PackageId INT = NULL, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @bill INT, @old INT, @status VARCHAR(20);
        SELECT @open = IsOpen, @bill = BillId, @old = PackageId, @status = Status FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54931, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 54932, 'The package can be changed only before the final bill.', 1;
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1)
            THROW 54933, 'Choose an active package of this branch.', 1;
        IF @PackageId IS NOT NULL AND ISNULL((SELECT TotalPackageAmount FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), 0) <= 0
            THROW 54936, 'This package has no amount (Master > Hospital Package): it cannot be applied.', 1;
        -- 2577: valid on the admission date and allowed for the payer of the admission
        IF @PackageId IS NOT NULL
        BEGIN
            DECLARE @pkgMsg NVARCHAR(400) = (SELECT c.Message FROM dbo.IpdAdmission a
                OUTER APPLY (SELECT TOP 1 InsuranceTpaId, CorporateId FROM dbo.IpdAdmissionPayer py WHERE py.AdmissionId = a.AdmissionId AND py.Seq = 1) py
                CROSS APPLY dbo.fn_Ipd_PackageCheck(@PackageId, @BranchId, CAST(a.AdmissionAt AS DATE), a.PayerType, py.InsuranceTpaId, py.CorporateId) c
                WHERE a.AdmissionId = @AdmissionId);
            IF @pkgMsg IS NOT NULL THROW 60001, @pkgMsg, 1;
        END
        IF ISNULL(@old, 0) = ISNULL(@PackageId, 0) THROW 54934, 'The admission is already on this package.', 1;
        IF @old IS NOT NULL AND NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54935, 'Enter the reason for changing the package.', 1;
        UPDATE dbo.IpdAdmission SET PackageId = @PackageId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdmissionId = @AdmissionId;
        EXEC dbo.usp_Ipd_ApplyPackageFlags @AdmissionId = @AdmissionId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'PACKAGE', CONCAT(N'Package ', ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @old), N'none'), N' → ',
                ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), N'none'), ISNULL(N': ' + NULLIF(LTRIM(RTRIM(@Reason)), N''), N'')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── bill lines (live + 2577 payer package rate) ──
-- ── 4. bill lines (replaces 2434): ICU days with an ICU tariff are priced by its heads ─────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BillLines (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    WITH adm AS
    (
        SELECT a.AdmissionId, a.BillId, a.PackageId, a.AdmissionAt,
               (SELECT MAX(pc.Days) FROM dbo.fn_Ipd_PackageCover(a.PackageId) pc WHERE pc.Head = 'BED') AS PkgDays
        FROM dbo.IpdAdmission a WHERE a.AdmissionId = @AdmissionId
    )
    -- bed days (live) priced from the Bed / Room Tariff
    SELECT CAST(CONCAT('B', bd.DayNo, '-', v.Code) AS NVARCHAR(40)) AS LineKey,
           CAST(CASE WHEN bd.IsIcu = 1 THEN 'ICU' ELSE 'BED' END AS VARCHAR(20)) AS Head,
           CAST(bd.DayDate AS DATETIME) AS ChargeAt, CAST(v.Code AS NVARCHAR(50)) AS ItemCode,
           CAST(CASE WHEN bd.NoTariff = 1 AND pk.InPkg = 0 THEN N'No bed tariff for ' + ISNULL(bd.BedCategoryName, N'this bed')
                     WHEN bd.NoTariff = 1 THEN N'Bed (in package)' ELSE v.Name END AS NVARCHAR(250)) AS ItemName,
           CAST(CONCAT(N'Day ', bd.DayNo, N' · ', bd.WardName, N' / ', bd.RoomNumber, N' / ', bd.BedNumber) AS NVARCHAR(300)) AS Detail,
           CAST(NULL AS NVARCHAR(150)) AS DoctorName,
           CAST(1 AS DECIMAL(18,3)) AS Qty, v.Amount AS Rate,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE v.Amount END AS DECIMAL(18,2)) AS Gross, CAST(0 AS DECIMAL(18,2)) AS Discount,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE bd.GstPercent END AS DECIMAL(5,2)) AS GstPercent,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE ROUND(v.Amount * bd.GstPercent / 100, 2) END AS DECIMAL(18,2)) AS GstAmount,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE v.Amount + ROUND(v.Amount * bd.GstPercent / 100, 2) END AS DECIMAL(18,2)) AS Net,
           CAST('ACCRUED' AS VARCHAR(10)) AS Status, CAST('IPD' AS VARCHAR(10)) AS SourceModule, CAST(NULL AS NVARCHAR(50)) AS SourceNo,
           CAST(pk.InPkg AS BIT) AS IsPackageItem, CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE bd.NoTariff END AS BIT) AS NoTariff, bd.UsedFallback, bd.DayNo, v.Sort
    FROM adm
    CROSS APPLY dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) bd
    CROSS APPLY (SELECT CASE WHEN bd.IsIcu = 0 AND bd.DayNo <= ISNULL(adm.PkgDays, 0) THEN 1 ELSE 0 END AS InPkg) pk
    CROSS APPLY (VALUES ('ROOM', N'Room Rent', bd.RoomCharge, 1), ('BED', N'Bed Charge', bd.BedCharge, 2),
                        ('NURSING', N'Nursing Charge', bd.NursingCharge, 3), ('RMO', N'RMO Charge', bd.RmoCharge, 4), ('ATTENDANT', N'Attendant Charge', bd.AttendantCharge, 5),
                        ('ISOLATION', N'Isolation Charge', bd.IsolationCharge, 6), ('NOTARIFF', N'', CAST(0 AS DECIMAL(18,2)), 7)) v (Code, Name, Amount, Sort)
    WHERE adm.BillId IS NULL AND bd.IcuTariffId IS NULL
      AND ((bd.NoTariff = 0 AND v.Code <> 'NOTARIFF' AND v.Amount > 0) OR (bd.NoTariff = 1 AND v.Code = 'NOTARIFF'))

    UNION ALL
    -- ICU days (live) priced from the ICU tariff: mandatory heads every day, optional heads on days the device was in use;
    -- a head not billed "Per Day" only once, on the first ICU day it applies
    SELECT CAST(CONCAT('I', bd.DayNo, '-', dt.IcuTariffDetailId) AS NVARCHAR(40)), CAST('ICU' AS VARCHAR(20)), CAST(bd.DayDate AS DATETIME),
           CAST(dt.RateHeadCode AS NVARCHAR(50)), CAST(dt.RateHeadName AS NVARCHAR(250)),
           CAST(CONCAT(N'Day ', bd.DayNo, N' · ', bd.IcuName, N' · ', bd.RoomNumber, N' / ', bd.BedNumber) AS NVARCHAR(300)),
           CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), CAST(dt.RateAmount AS DECIMAL(18,2)), CAST(dt.RateAmount AS DECIMAL(18,2)),
           CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)), CAST(dt.RateAmount AS DECIMAL(18,2)),
           CAST('ACCRUED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), CAST(NULL AS NVARCHAR(50)), CAST(0 AS BIT), CAST(0 AS BIT), bd.UsedFallback, bd.DayNo,
           10 + ISNULL(dt.DisplayOrder, 0)
    FROM adm
    CROSS APPLY dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) bd
    JOIN dbo.IcuTariffDetail dt ON dt.IcuTariffId = bd.IcuTariffId AND dt.RateAmount > 0
    WHERE adm.BillId IS NULL AND bd.IcuTariffId IS NOT NULL
      AND (dt.IsMandatory = 1
           OR EXISTS (SELECT 1 FROM dbo.IpdIcuDevice dv WHERE dv.AdmissionId = @AdmissionId AND dv.Status = 'ACTIVE' AND dv.HeadCode = dt.RateHeadCode
                      AND dv.StartAt < DATEADD(DAY, 1, CAST(bd.DayDate AS DATETIME)) AND (dv.StopAt IS NULL OR dv.StopAt > CAST(bd.DayDate AS DATETIME))
                      AND dv.StartAt <= @AsOf))
      AND (ISNULL(dt.BillingFrequency, N'Per Day') IN (N'Per Day', N'Daily', N'Day')
           OR bd.DayNo = (SELECT MIN(b2.DayNo) FROM dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) b2
                          WHERE b2.IcuTariffId IS NOT NULL
                            AND (dt.IsMandatory = 1
                                 OR EXISTS (SELECT 1 FROM dbo.IpdIcuDevice dv WHERE dv.AdmissionId = @AdmissionId AND dv.Status = 'ACTIVE' AND dv.HeadCode = dt.RateHeadCode
                                            AND dv.StartAt < DATEADD(DAY, 1, CAST(b2.DayDate AS DATETIME)) AND (dv.StopAt IS NULL OR dv.StopAt > CAST(b2.DayDate AS DATETIME))))))

    UNION ALL
    -- the package amount (live, once)
    SELECT CAST('PKG' AS NVARCHAR(40)), CAST('PACKAGE' AS VARCHAR(20)), adm.AdmissionAt, CAST(p.Package_Code AS NVARCHAR(50)), CAST(p.Package_Name AS NVARCHAR(250)),
           CAST(N'Package' AS NVARCHAR(300)), CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), CAST(ISNULL(pr.Amount, p.TotalPackageAmount) AS DECIMAL(18,2)),
           CAST(ISNULL(pr.Amount, p.TotalPackageAmount) AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)),
           CAST(ISNULL(pr.Amount, p.TotalPackageAmount) AS DECIMAL(18,2)), CAST('ACCRUED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), CAST(NULL AS NVARCHAR(50)),
           CAST(0 AS BIT), CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm JOIN dbo.HospitalPackageMaster p ON p.HospitalPackage_ID = adm.PackageId
    OUTER APPLY (SELECT Amount FROM dbo.fn_Ipd_AdmissionPackage(adm.AdmissionId)) pr   -- 2577: the payer's agreed package rate
    WHERE adm.BillId IS NULL AND adm.AdmissionAt <= @AsOf

    UNION ALL
    -- posted charges (live)
    SELECT CAST(CONCAT('C', c.ChargeId) AS NVARCHAR(40)), c.Head, c.ChargeAt, c.ItemCode, c.ItemName,
           CAST(CASE WHEN c.SourceNo IS NOT NULL THEN CONCAT(c.SourceModule, N' ', c.SourceNo) ELSE c.Remarks END AS NVARCHAR(300)),
           CAST(doc.FullName AS NVARCHAR(150)),
           c.Qty, c.Rate, c.Gross, c.Discount, c.GstPercent, c.GstAmount, c.Net,
           CAST('POSTED' AS VARCHAR(10)), c.SourceModule, c.SourceNo, c.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm
    JOIN dbo.IpdCharge c ON c.AdmissionId = adm.AdmissionId AND c.Status = 'POSTED' AND c.ChargeAt <= @AsOf
    LEFT JOIN dbo.DoctorMaster doc ON doc.DoctorId = c.DoctorId
    WHERE adm.BillId IS NULL

    UNION ALL
    -- the final bill: its frozen lines
    SELECT l.LineKey, l.Head, l.ChargeAt, l.ItemCode, l.ItemName, l.Detail, l.DoctorName, l.Qty, l.Rate, l.Gross,
           CAST(l.ItemDiscount + l.BillDiscount AS DECIMAL(18,2)), l.GstPercent, l.GstAmount, l.Net,
           CAST('BILLED' AS VARCHAR(10)), l.SourceModule, l.SourceNo, l.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), l.DayNo, l.Sort
    FROM adm JOIN dbo.IpdBillLine l ON l.BillId = adm.BillId

    UNION ALL
    SELECT CAST('ROUNDOFF' AS NVARCHAR(40)), CAST('ADJUST' AS VARCHAR(20)), b.BillUpToAt, CAST(NULL AS NVARCHAR(50)), CAST(N'Round off' AS NVARCHAR(250)),
           CAST(NULL AS NVARCHAR(300)), CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), b.RoundOff, CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)),
           CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)), b.RoundOff, CAST('BILLED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), b.BillNo,
           CAST(0 AS BIT), CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm JOIN dbo.IpdBill b ON b.BillId = adm.BillId WHERE b.RoundOff <> 0
);
GO

-- ── IPD Patient workspace (live + 2577 outside-package amount) ──
-- ── IPD Patient workspace (live + 2575: banner alerts) ──
-- ── usp_Api_IpdAdmission_Get ──
-- ── one admission: banner and every block of the patient workspace ──────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Get @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    -- 1 header + live money
    SELECT h.*, lt.Net AS BillNow, lt.Days AS BedDays, lt.NoTariff, mo.AdvanceTotal, mo.RefundTotal, mo.NetAdvance,
           CAST(lt.Net - ps.PayerShare - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue, ps.PayerShare AS PayerShareNow, ps.ApprovedAmount AS PayerApproved,
           CAST(CASE WHEN h.IsOpen = 1 AND h.PayerType = 'CASH' AND (lt.Net > mo.NetAdvance OR (mo.NetAdvance > 0 AND lt.Net >= mo.NetAdvance * h.DepositAlertPercent / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           DATEDIFF(DAY, h.AdmissionAt, ISNULL(h.DischargeAt, @now)) + 1 AS DayCount,
           -- 2575: alerts of the banner
           pa.PreAuthAlert, pa.PreAuthUsedPercent, pa.PreAuthApproved, pa.PreAuthOverBy,
           x.CodeStatus, x.IsolationType, x.IsolationReason, x.IsolationSince, x.ReadmitDays, rd.IpNo AS ReadmitOfIpNo,
           CAST(CASE WHEN pd.PatientId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsDeceased,
           CAST(CASE WHEN x.IsMlc = 1 AND (NULLIF(LTRIM(RTRIM(ml.PoliceStation)), N'') IS NULL OR ml.InformedAt IS NULL) THEN 1 ELSE 0 END AS BIT) AS MlcPoliceDue,
           CAST(CASE WHEN x.AdmissionType = 'DAYCARE' AND h.IsOpen = 1 AND DATEDIFF(HOUR, h.AdmissionAt, @now) > gs.DaycareMaxHours THEN 1 ELSE 0 END AS BIT) AS DaycareOverstay,
           CAST(CASE WHEN pkd.Days > 0 AND lt.Days > pkd.Days THEN lt.Days - pkd.Days ELSE 0 END AS INT) AS PackageOverstayDays, pkd.Days AS PackageDays,
           (SELECT COUNT(*) FROM dbo.IpdEscalation e WHERE e.AdmissionId = h.AdmissionId AND e.Status = 'OPEN') AS OpenEscalations,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = h.AdmissionId AND o.OrderType = 'MED' AND o.Status = 'ACTIVE' AND ISNULL(o.VerifyStatus, '') <> 'VERIFIED') AS UnverifiedOrders,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = h.AdmissionId AND o.OrderType = 'MED' AND o.Status = 'ACTIVE' AND o.VerifyStatus = 'QUERY') AS PharmacistQueries,
           al.Recorded AS AllergyRecorded, mo2.IpNo AS MotherIpNo, adj.SuppNet, adj.CreditNet, gs.MarScanRequired, gs.MarNeedsVerify,
           CAST(lt.Net - ps.PayerShare - mo.NetAdvance + adj.AdjNet AS DECIMAL(18,2)) AS BalanceAfterAdjustments,
           op.OutsideAmount AS OutsidePackageAmount, op.OutsideLines AS OutsidePackageLines, ap.RateSource AS PackageRateSource, ap.Amount AS PackageAmount   -- 2577
    FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h
    CROSS APPLY dbo.fn_Ipd_LiveTotal(h.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(h.AdmissionId) mo
    CROSS APPLY dbo.fn_Ipd_PayerShare(h.AdmissionId, lt.Net) ps
    CROSS APPLY dbo.fn_Ipd_PreAuthAlert(h.AdmissionId, lt.Net) pa
    CROSS APPLY dbo.fn_Ipd_GapSettings(h.BranchId) gs
    CROSS APPLY dbo.fn_Ipd_PostBillAdj(h.AdmissionId) adj
    CROSS APPLY dbo.fn_Ipd_AllergyStatus(h.PatientId) al
    JOIN dbo.IpdAdmission x ON x.AdmissionId = h.AdmissionId
    LEFT JOIN dbo.IpdAdmission rd ON rd.AdmissionId = x.ReadmitOfAdmissionId
    LEFT JOIN dbo.IpdAdmission mo2 ON mo2.AdmissionId = x.MotherAdmissionId
    LEFT JOIN dbo.PatientDeceased pd ON pd.PatientId = h.PatientId
    LEFT JOIN dbo.IpdMlc ml ON ml.AdmissionId = h.AdmissionId
    OUTER APPLY (SELECT MAX(c.Days) AS Days FROM dbo.fn_Ipd_PackageCover(x.PackageId) c WHERE c.Head = 'BED') pkd
    OUTER APPLY (SELECT OutsideAmount, OutsideLines FROM dbo.fn_Ipd_OutsidePackage(h.AdmissionId, @now) WHERE x.PackageId IS NOT NULL) op
    OUTER APPLY (SELECT Amount, RateSource FROM dbo.fn_Ipd_AdmissionPackage(h.AdmissionId)) ap;   -- 2541
    IF @@ROWCOUNT = 0 RETURN;
    -- 2 payers
    SELECT py.PayerId, py.Seq, py.PayerType, py.InsuranceTpaId, py.CorporateId, py.SchemeId, COALESCE(ins.Name, corp.Corporate_Name, sch.SchemeName) AS PayerName,
           py.PolicyNo, py.MemberId, py.CardHolderName, py.RelationToHolder, py.PolicyValidTo, py.EmployeeId, py.CardFilePath, py.Remarks
    FROM dbo.IpdAdmissionPayer py
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = py.CorporateId
    LEFT JOIN dbo.GovernmentSchemeMaster sch ON sch.Scheme_ID = py.SchemeId
    WHERE py.AdmissionId = @AdmissionId ORDER BY py.Seq;
    -- 3 attendants
    SELECT a.AttendantId, a.Name, a.Relation, a.Phone, a.Address, a.IdTypeId, it.IdentificationTypeName AS IdTypeName, a.IdNumber, a.IsPrimary, a.PassNo
    FROM dbo.IpdAttendant a LEFT JOIN dbo.IdentificationTypeMaster it ON it.IdentificationTypeId = a.IdTypeId
    WHERE a.AdmissionId = @AdmissionId ORDER BY a.IsPrimary DESC, a.AttendantId;
    -- 4 MLC
    SELECT m.* FROM dbo.IpdMlc m WHERE m.AdmissionId = @AdmissionId;
    -- 5 consents (text read separately for print)
    SELECT c.AdmissionConsentId, c.ConsentId, c.ConsentType, c.Language, c.Version, c.SignedByName, c.SignedByRelation, c.WitnessName, c.SignaturePath,
           c.WitnessSignaturePath, c.SignedAt, u.FullName AS CapturedByName
    FROM dbo.IpdAdmissionConsent c LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    WHERE c.AdmissionId = @AdmissionId ORDER BY c.SignedAt;
    -- 6 bed movements
    SELECT m.MovementId, m.MoveType, m.EndType, m.FromAt, m.ToAt, m.BedId, b.BedNumber, r.RoomNumber, w.WardName, bc.CategoryName AS BedCategoryName, m.Reason,
           u.FullName AS CreatedByName
    FROM dbo.IpdBedMovement m
    JOIN dbo.BedMaster b ON b.BedId = m.BedId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = m.RoomId
    LEFT JOIN dbo.WardMaster w ON w.WardId = m.WardId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = m.BedCategoryId
    LEFT JOIN dbo.Users u ON u.Id = m.CreatedBy
    WHERE m.AdmissionId = @AdmissionId ORDER BY m.FromAt, m.MovementId;
    -- 7 advances and refunds (with the modes of each receipt)
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.RefNo, v.Remarks, v.CreatedDate, u.FullName AS CreatedByName,
           CASE WHEN v.Kind IN ('ADVANCE', 'SETTLE') THEN
                STUFF((SELECT N', ' + pm.MethodName + N' ₹' + FORMAT(pd.PaidAmount, 'N2', 'en-IN')
                       FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                       WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
                ELSE v.Mode END AS Modes
    FROM dbo.IpdAdvance v LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy
    WHERE v.AdmissionId = @AdmissionId AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
    -- 8 documents
    SELECT d.DocumentId, d.DocType, d.Title, d.FilePath, d.Remarks, d.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdDocument d LEFT JOIN dbo.Users u ON u.Id = d.CreatedBy
    WHERE d.AdmissionId = @AdmissionId AND d.IsActive = 1 ORDER BY d.CreatedDate DESC;
    -- 9 activity log
    SELECT l.LogId, l.Action, l.FromStatus, l.ToStatus, l.Remarks, l.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdStatusLog l LEFT JOIN dbo.Users u ON u.Id = l.CreatedBy
    WHERE l.AdmissionId = @AdmissionId ORDER BY l.LogId DESC;
END;
GO

-- ── bill preview (live + 2577 outside-package amount) ──
-- ── bill preview (2541) + 2571: what still blocks the final bill, the discount limit, the room-rent deduction ─
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Preview @CompanyId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admAt DATETIME, @bill INT, @br INT, @status VARCHAR(20);
    SELECT @admAt = AdmissionAt, @bill = BillId, @br = BranchId, @status = Status FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND Status <> 'CANCELLED';
    IF @admAt IS NULL RETURN;
    SET @UpTo = ISNULL(@UpTo, GETDATE());
    CREATE TABLE #IpdBillCalc (LineKey NVARCHAR(40), Head VARCHAR(20), ChargeAt DATETIME, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Detail NVARCHAR(300), DoctorName NVARCHAR(150),
        Qty DECIMAL(18,3), Rate DECIMAL(18,2), Gross DECIMAL(18,2), ItemDiscount DECIMAL(18,2), BillDiscount DECIMAL(18,2), GstPercent DECIMAL(5,2), GstAmount DECIMAL(18,2),
        Net DECIMAL(18,2), SourceModule VARCHAR(10), SourceNo NVARCHAR(50), IsPackageItem BIT, NoTariff BIT, DayNo INT, Sort INT, ChargeId BIGINT);
    DECLARE @g DECIMAL(18,2), @id DECIMAL(18,2), @bd DECIMAL(18,2), @tx DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @nt BIT, @err NVARCHAR(400);
    BEGIN TRY
        IF @bill IS NULL
            EXEC dbo.usp_Ipd_BillCalc @AdmissionId = @AdmissionId, @UpTo = @UpTo, @DiscountType = @DiscountType, @DiscountValue = @DiscountValue,
                 @Gross = @g OUTPUT, @ItemDiscount = @id OUTPUT, @BillDiscount = @bd OUTPUT, @Taxable = @tx OUTPUT, @Gst = @gst OUTPUT, @RoundOff = @ro OUTPUT, @Net = @net OUTPUT, @NoTariff = @nt OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    IF @bill IS NOT NULL
        INSERT #IpdBillCalc (LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
                             SourceModule, SourceNo, IsPackageItem, NoTariff, DayNo, Sort, ChargeId)
        SELECT LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, 0, DayNo, Sort, ChargeId FROM dbo.IpdBillLine WHERE BillId = @bill;
    IF @bill IS NOT NULL
        SELECT @g = Gross, @id = ItemDiscount, @bd = BillDiscount, @tx = Taxable, @gst = Gst, @ro = RoundOff, @net = Net, @nt = 0, @UpTo = BillUpToAt FROM dbo.IpdBill WHERE BillId = @bill;
    DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId)), @adj DECIMAL(18,2);
    DECLARE @payer DECIMAL(18,2) = 0, @coPay DECIMAL(18,2) = 0, @auth DECIMAL(18,2) = NULL, @payerName NVARCHAR(200) = NULL, @paStatus VARCHAR(20) = NULL, @pdd DECIMAL(18,2) = 0;
    IF @bill IS NOT NULL
        SELECT @payer = b.PayerShare - b.PayerToPatient, @coPay = b.CoPayAmount, @auth = CASE WHEN b.PayerAuthorised > 0 THEN b.PayerAuthorised END, @payerName = t.Name, @pdd = b.ProportionateDeduction
        FROM dbo.IpdBill b LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = b.InsuranceTpaId WHERE b.BillId = @bill;
    ELSE
        SELECT @payer = sp.PayerShare, @coPay = sp.CoPayAmount, @auth = pa.Authorised, @payerName = t.Name, @pdd = ISNULL(pd.Deduction, 0),
               @paStatus = (SELECT TOP 1 x.Status FROM dbo.IpdPreAuth x WHERE x.AdmissionId = @AdmissionId AND x.IsLive = 1)
        FROM dbo.IpdAdmission a
        LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1 AND py.PayerType = 'INSURANCE'
        LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = py.InsuranceTpaId
        OUTER APPLY (SELECT TOP 1 Authorised, CoPayPercent, Deductible, NonPayable, RoomRentLimit, IcuRentLimit FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId)) pa
        OUTER APPLY (SELECT d.Deduction FROM dbo.fn_Ipd_PropDeduction(@AdmissionId, @UpTo, pa.RoomRentLimit, pa.IcuRentLimit) d WHERE ISNULL(pa.RoomRentLimit, 0) > 0 OR ISNULL(pa.IcuRentLimit, 0) > 0) pd
        OUTER APPLY dbo.fn_Ipd_PayerSplit(ISNULL(@net, 0), pa.Authorised, pa.CoPayPercent, pa.Deductible, ISNULL(pa.NonPayable, 0) + ISNULL(pd.Deduction, 0)) sp
        WHERE a.AdmissionId = @AdmissionId AND a.PayerType = 'INSURANCE';
    SET @payer = ISNULL(@payer, 0); SET @coPay = ISNULL(@coPay, 0); SET @pdd = ISNULL(@pdd, 0);
    SET @adj = CASE WHEN @bill IS NOT NULL THEN (SELECT AdvanceAdjusted FROM dbo.IpdBill WHERE BillId = @bill) WHEN @held < ISNULL(@net, 0) - @payer THEN @held ELSE ISNULL(@net, 0) - @payer END;
    IF @adj < 0 SET @adj = 0;
    DECLARE @postAdj DECIMAL(18,2) = (SELECT AdjNet FROM dbo.fn_Ipd_PostBillAdj(@AdmissionId));
    DECLARE @gs TABLE (FinalBillNeedsAdvice BIT, DiscountLimitPercent DECIMAL(5,2));
    INSERT @gs SELECT FinalBillNeedsAdvice, DiscountLimitPercent FROM dbo.fn_Ipd_GapSettings(@br);
    -- 1 totals
    SELECT @UpTo AS UpTo, @bill AS BillId, (SELECT BillNo FROM dbo.IpdBill WHERE BillId = @bill) AS BillNo, (SELECT BillAt FROM dbo.IpdBill WHERE BillId = @bill) AS BillAt, (SELECT SettleTotal FROM dbo.fn_Ipd_Money(@AdmissionId)) AS SettleTotal, ISNULL(@g, 0) AS Gross, ISNULL(@id, 0) AS ItemDiscount, ISNULL(@bd, 0) AS BillDiscount, ISNULL(@tx, 0) AS Taxable, ISNULL(@gst, 0) AS Gst,
           ISNULL(@ro, 0) AS RoundOff, ISNULL(@net, 0) AS Net, @held AS AdvanceHeld, @adj AS AdvanceAdjusted, @payer AS PayerShare, CAST(ISNULL(@net, 0) - @payer AS DECIMAL(18,2)) AS PatientShare,
           @coPay AS CoPayAmount, @auth AS PayerAuthorised, @payerName AS PayerName, @paStatus AS PreAuthStatus, @pdd AS ProportionateDeduction, @postAdj AS PostBillAdjustments,
           CAST(CASE WHEN ISNULL(@net, 0) - @payer + @postAdj - @held > 0 THEN ISNULL(@net, 0) - @payer + @postAdj - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN @held - (ISNULL(@net, 0) - @payer + @postAdj) > 0 THEN @held - (ISNULL(@net, 0) - @payer + @postAdj) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           ISNULL(@nt, 0) AS NoTariff, @err AS Error,
           (SELECT COUNT(*) FROM #IpdBillCalc) AS Lines,
           (SELECT COUNT(*) FROM #IpdBillCalc WHERE IsPackageItem = 1) AS PackageLines,
           CAST(CASE WHEN @bill IS NULL AND @status = 'ADMITTED' AND (SELECT FinalBillNeedsAdvice FROM @gs) = 1 THEN 1 ELSE 0 END AS BIT) AS NeedsAdvice,
           (SELECT DiscountLimitPercent FROM @gs) AS DiscountLimitPercent,
           -- 2577: billed outside the package
           (SELECT SUM(Net) FROM #IpdBillCalc WHERE (SELECT PackageId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId) IS NOT NULL AND ISNULL(IsPackageItem, 0) = 0 AND Head NOT IN ('PACKAGE', 'ADJUST')) AS OutsidePackageAmount,
           (SELECT Net FROM #IpdBillCalc WHERE Head = 'PACKAGE') AS PackageAmount;
    -- 2 heads
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(l.Head) AS Lines, CAST(ISNULL(SUM(l.Gross), 0) AS DECIMAL(18,2)) AS Gross,
           CAST(ISNULL(SUM(l.ItemDiscount + l.BillDiscount), 0) AS DECIMAL(18,2)) AS Discount, CAST(ISNULL(SUM(l.GstAmount), 0) AS DECIMAL(18,2)) AS Gst,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS Net
    FROM dbo.fn_Ipd_Heads() hd LEFT JOIN #IpdBillCalc l ON l.Head = hd.Head
    WHERE hd.Head <> 'ADJUST'
    GROUP BY hd.Head, hd.HeadName, hd.Sort HAVING COUNT(l.Head) > 0 OR @bill IS NULL ORDER BY hd.Sort;
    -- 3 what blocks the final bill (none once it is made)
    SELECT b.Sort, b.Kind, b.Message FROM dbo.fn_Ipd_FinalBillBlockers(@AdmissionId) b WHERE @bill IS NULL ORDER BY b.Sort;
END;
GO


PRINT '2577 IPD package rules - done.';
GO
