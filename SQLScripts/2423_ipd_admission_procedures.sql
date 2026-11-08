-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2423  IPD Phase 1 · Foundation and Admission (part 2 of 3: stored procedures for EMR.Api api/ipd/...)
--
--   Lookups / beds        usp_Api_Ipd_Lookups, usp_Api_Ipd_Beds
--   Admission             usp_Api_IpdAdmission_Save (admit), _Get, _List, _Update, _Cancel
--   Money                 usp_Ipd_PostAdvance, usp_Ipd_PostLedger, usp_Api_IpdAdvance_Add, _Refund, _Get
--   Consent / documents   fn_Ipd_FillConsent, usp_Api_IpdConsent_Save, _Get, usp_Api_IpdDocument_Save, _Remove
--   Dashboard             usp_Api_Ipd_Dashboard
--   Current billing       fn_Ipd_LiveTotal, fn_Ipd_AdmissionHeader, usp_Api_IpdEstimate_Live, _Lines, _DueList
--   Pre-admission         usp_Api_IpdPreEstimate_Calc, _Save, _Get, _List, _Cancel
--
-- Writes return one row: Success (bit), Error (text) and the ids / numbers made. A refusal rolls back everything.
-- Needs 2422. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── shared helpers ──────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_AgeText (@Dob DATE, @On DATE)
RETURNS NVARCHAR(30)
AS
BEGIN
    IF @Dob IS NULL OR @Dob > @On RETURN N'';
    DECLARE @y INT = DATEDIFF(YEAR, @Dob, @On) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, @Dob, @On), @Dob) > @On THEN 1 ELSE 0 END;
    IF @y >= 1 RETURN CONCAT(@y, N' Y');
    DECLARE @m INT = DATEDIFF(MONTH, @Dob, @On) - CASE WHEN DATEADD(MONTH, DATEDIFF(MONTH, @Dob, @On), @Dob) > @On THEN 1 ELSE 0 END;
    IF @m >= 1 RETURN CONCAT(@m, N' M');
    RETURN CONCAT(DATEDIFF(DAY, @Dob, @On), N' D');
END;
GO

-- The bill as of @AsOf in one row (same lines as the estimate and, from Phase 5, the final bill).
CREATE OR ALTER FUNCTION dbo.fn_Ipd_LiveTotal (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(SUM(Gross), 0) AS DECIMAL(18,2)) AS Gross, CAST(ISNULL(SUM(Discount), 0) AS DECIMAL(18,2)) AS Discount,
           CAST(ISNULL(SUM(GstAmount), 0) AS DECIMAL(18,2)) AS Gst, CAST(ISNULL(SUM(Net), 0) AS DECIMAL(18,2)) AS Net,
           ISNULL(MAX(DayNo), 0) AS Days, CAST(ISNULL(MAX(CAST(NoTariff AS INT)), 0) AS BIT) AS NoTariff,
           CAST(ISNULL(MAX(CAST(UsedFallback AS INT)), 0) AS BIT) AS UsedFallback
    FROM dbo.fn_Ipd_BillLines(@AdmissionId, @AsOf)
);
GO

-- Banner / print header of an admission: patient, stay, bed, doctors, payer.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_AdmissionHeader (@CompanyId INT, @AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT a.AdmissionId, a.CompanyId, a.BranchId, a.IpNo, a.Status, a.IsOpen, a.AdmissionAt, a.AdmissionType, a.AdmissionSource,
           a.PatientId, p.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', NULLIF(p.MiddleName, '') + ' ', p.LastName))) AS PatientName,
           p.Gender, p.DateOfBirth, dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(GETDATE() AS DATE)) AS AgeText, p.PhoneNumber, p.PhotoPath, p.BloodGroup,
           p.KnownAllergies, p.Address, p.GuardianName,
           a.AdmittingDoctorId, dAdm.FullName AS AdmittingDoctorName, a.ConsultantDoctorId, dCon.FullName AS ConsultantDoctorName,
           a.ReferralDoctorId, dRef.FullName AS ReferralDoctorName, a.DepartmentId, dep.DeptName AS DepartmentName,
           a.ProvisionalDiagnosis, a.DiagnosisCode, a.ReasonForAdmission, a.ExpectedDischargeAt,
           a.CurrentBedId AS BedId, b.BedNumber, r.RoomNumber, w.WardId, w.WardName, f.FloorName, bl.BuildingName, bc.CategoryName AS BedCategoryName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu,
           a.TariffCategoryId, tc.Name AS TariffCategoryName, a.PayerType,
           COALESCE(ins.Name, corp.Corporate_Name, sch.SchemeName) AS PayerName, py.PolicyNo, py.MemberId,
           a.PackageId, pk.Package_Name AS PackageName, a.IsMlc, mlc.MlcNo, a.EstimateId, est.EstimateNo,
           a.AdvanceWaived, a.AdvanceWaiveReason, a.Remarks, a.DischargeAt, a.CancelReason, a.CancelledAt,
           a.OpdServiceId, opd.OPDBillNo AS OpdBillNo,
           uc.FullName AS CreatedByName, a.CreatedDate,
           ISNULL(s.IpdDepositAlertPercent, 80) AS DepositAlertPercent
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster dAdm ON dAdm.DoctorId = a.AdmittingDoctorId
    LEFT JOIN dbo.DoctorMaster dCon ON dCon.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.DoctorMaster dRef ON dRef.DoctorId = a.ReferralDoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
    LEFT JOIN dbo.BuildingMaster bl ON bl.BuildingId = b.BuildingId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = a.TariffCategoryId
    LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1
    LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = py.CorporateId
    LEFT JOIN dbo.GovernmentSchemeMaster sch ON sch.Scheme_ID = py.SchemeId
    LEFT JOIN dbo.HospitalPackageMaster pk ON pk.HospitalPackage_ID = a.PackageId
    LEFT JOIN dbo.IpdMlc mlc ON mlc.AdmissionId = a.AdmissionId
    LEFT JOIN dbo.IpdEstimate est ON est.EstimateId = a.EstimateId
    LEFT JOIN dbo.PatientOPDService opd ON opd.OPDServiceId = a.OpdServiceId
    LEFT JOIN dbo.Users uc ON uc.Id = a.CreatedBy
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId
    WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId
);
GO

-- Consent text of the master with the patient's details filled in (Master > Consent Master placeholders).
CREATE OR ALTER FUNCTION dbo.fn_Ipd_FillConsent (@Html NVARCHAR(MAX), @AdmissionId INT, @Relation NVARCHAR(50), @Witness NVARCHAR(150), @At DATETIME)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @name NVARCHAR(250), @uhid NVARCHAR(50), @ip NVARCHAR(40), @opd NVARCHAR(50), @age NVARCHAR(30), @gender NVARCHAR(20),
            @doctor NVARCHAR(150), @dept NVARCHAR(150), @hosp NVARCHAR(250);
    SELECT @name = LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', NULLIF(p.MiddleName, '') + ' ', p.LastName))),
           @uhid = p.PatientCode, @ip = a.IpNo, @opd = o.OPDBillNo, @age = dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(a.AdmissionAt AS DATE)),
           @gender = p.Gender, @doctor = d.FullName, @dept = dep.DeptName, @hosp = s.HotelName
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.PatientOPDService o ON o.OPDServiceId = a.OpdServiceId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId
    WHERE a.AdmissionId = @AdmissionId;
    SET @Html = ISNULL(@Html, N'');
    SET @Html = REPLACE(@Html, N'{{PatientName}}', ISNULL(@name, N''));
    SET @Html = REPLACE(@Html, N'{{UHID}}', ISNULL(@uhid, N''));
    SET @Html = REPLACE(@Html, N'{{IPDNo}}', ISNULL(@ip, N''));
    SET @Html = REPLACE(@Html, N'{{OPDNo}}', ISNULL(@opd, N'—'));
    SET @Html = REPLACE(@Html, N'{{Age}}', ISNULL(@age, N''));
    SET @Html = REPLACE(@Html, N'{{Gender}}', ISNULL(@gender, N''));
    SET @Html = REPLACE(@Html, N'{{DoctorName}}', ISNULL(@doctor, N''));
    SET @Html = REPLACE(@Html, N'{{DepartmentName}}', ISNULL(@dept, N''));
    SET @Html = REPLACE(@Html, N'{{HospitalName}}', ISNULL(@hosp, N''));
    SET @Html = REPLACE(@Html, N'{{ProcedureName}}', N'');
    SET @Html = REPLACE(@Html, N'{{Relationship}}', ISNULL(@Relation, N''));
    SET @Html = REPLACE(@Html, N'{{WitnessName}}', ISNULL(@Witness, N''));
    SET @Html = REPLACE(@Html, N'{{Date}}', FORMAT(@At, 'dd-MMM-yyyy', 'en-US'));
    SET @Html = REPLACE(@Html, N'{{Time}}', FORMAT(@At, 'hh:mm tt', 'en-US'));
    RETURN @Html;
END;
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
    WHERE d.IsActive = 1 AND d.CompanyId = @CompanyId AND ISNULL(d.IsReferralDoctor, 0) = 0
      AND (EXISTS (SELECT 1 FROM dbo.DoctorBranchMap bm WHERE bm.DoctorId = d.DoctorId AND bm.BranchId = @BranchId AND bm.IsActive = 1)
           OR NOT EXISTS (SELECT 1 FROM dbo.DoctorBranchMap bm WHERE bm.DoctorId = d.DoctorId AND bm.IsActive = 1))
    ORDER BY d.FullName;
    -- 2 "Referred by": every active doctor of the company (hospital and referral doctors)
    SELECT d.DoctorId, LTRIM(RTRIM(CONCAT(NULLIF(d.NamePrefix, '') + ' ', d.FullName))) AS DoctorName,
           CAST(ISNULL(d.IsReferralDoctor, 0) AS BIT) AS IsReferralDoctor
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
    WHERE Status = 1 AND Branch_ID = @BranchId AND (ValidTo IS NULL OR ValidTo >= GETDATE()) ORDER BY Package_Name;
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

-- ── beds of the branch with their live state and today's daily rate for a tariff category ────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_Beds @CompanyId INT, @BranchId INT, @TariffCategoryId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT b.BedId, b.BedNumber, b.BedCategoryId, bc.CategoryName AS BedCategoryName, b.RoomId, r.RoomNumber, r.RoomType, r.RoomCategory,
           b.WardId, w.WardName, w.WardType, w.Gender AS WardGender, w.DepartmentId AS WardDepartmentId, r.FloorId, f.FloorName, b.BuildingId, bl.BuildingName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu, CAST(CASE WHEN b.IsIsolation = 1 OR r.IsIsolation = 1 THEN 1 ELSE 0 END AS BIT) AS IsIsolation,
           CAST(ISNULL(b.IsVentilatorCapable, 0) AS BIT) AS IsVentilator,
           CASE WHEN occ.AdmissionId IS NOT NULL THEN 'Occupied' ELSE b.BedStatus END AS BedStatus,
           occ.AdmissionId, occ.IpNo, occ.PatientName, occ.Gender AS PatientGender, occ.FromAt AS OccupiedSince,
           rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.AttendantCharge + rt.IsolationCharge AS DailyRate, rt.GstPercentage, rt.UsedFallback,
           CAST(CASE WHEN rt.BedRateId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff,
           (SELECT TOP 1 x.PatientId FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') AS ResPatientId,
           (SELECT TOP 1 x.Phone FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') AS ResPhone,
           (SELECT TOP 1 x.PatientName FROM dbo.IpdBedReservation x WHERE x.BedId = b.BedId AND x.Status = 'ACTIVE') AS ResPatientName,
           (SELECT STRING_AGG(x.Name, ', ') FROM (SELECT DISTINCT tc.Name FROM dbo.BedRoomTariffMaster t JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = t.TariffCategoryId
                     WHERE t.BranchId = @BranchId AND t.IsActive = 1 AND t.BedCategoryId = b.BedCategoryId
                       AND t.EffectiveFrom <= @today AND (t.EffectiveTo IS NULL OR t.EffectiveTo >= @today)) x) AS RatedCategories
    FROM dbo.BedMaster b
    JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.FloorMaster f ON f.FloorId = r.FloorId
    LEFT JOIN dbo.BuildingMaster bl ON bl.BuildingId = b.BuildingId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY (SELECT TOP 1 m.AdmissionId, a.IpNo, m.FromAt, p.Gender,
                        LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName
                 FROM dbo.IpdBedMovement m JOIN dbo.IpdAdmission a ON a.AdmissionId = m.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                 WHERE m.BedId = b.BedId AND m.ToAt IS NULL) occ
    OUTER APPLY dbo.fn_Ipd_BedRate(@BranchId, b.BedId, ISNULL(@TariffCategoryId, 0), @today) rt
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId AND w.IsActive = 1 AND r.IsActive = 1
    ORDER BY bl.BuildingName, f.FloorName, w.WardName, r.RoomNumber, b.BedNumber;
END;
GO

-- ── ledger: IPD advance receipts and refunds (RCT / PMT vouchers, like pharmacy receipts) ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostLedger
    @Kind   VARCHAR(10),   -- ADVRCPT (RefId = PaymentDetailId) | ADVREFUND (RefId = IpdAdvance.AdvanceId)
    @RefId  INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Patient Advance'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    IF @adv IS NULL THROW 54090, 'The ledger "IPD Patient Advance" is missing (run SQLScripts/2422).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @amt DECIMAL(18,2), @mode VARCHAR(30), @ref NVARCHAR(100), @no NVARCHAR(50), @ip NVARCHAR(40),
            @party NVARCHAR(250), @narr NVARCHAR(400), @lines NVARCHAR(MAX), @modeLedger INT, @tid BIGINT, @vno NVARCHAR(50);
    IF @Kind = 'ADVRCPT'
    BEGIN
        SELECT @co = ph.CompanyId, @br = ph.BranchId, @date = COALESCE(pd.PaymentDate, pd.CreatedDate), @amt = pd.PaidAmount, @mode = UPPER(pm.MethodCode),
               @ref = COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo), @no = pd.ReceiptNo, @ip = a.IpNo,
               @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.PaymentDetail pd
        JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND RTRIM(ph.ModuleCode) = 'IPD'
        JOIN dbo.IpdAdmission a ON a.AdmissionId = ph.ModuleRefId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1;
        IF @amt IS NULL OR @amt <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'IPD advance receipt ', @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@modeLedger, @amt, 0, N'Received by ' + @mode), (@adv, 0, @amt, N'Advance from patient')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'RCT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_ADVANCE', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'ADVREFUND'
    BEGIN
        SELECT @co = a.CompanyId, @br = a.BranchId, @date = v.CreatedDate, @amt = v.Amount, @mode = UPPER(ISNULL(pm.MethodCode, v.Mode)), @ref = v.RefNo,
               @no = v.DocNo, @ip = a.IpNo, @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.IpdAdvance v
        JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.MethodName = v.Mode OR UPPER(pm.MethodCode) = UPPER(v.Mode)
        WHERE v.AdvanceId = @RefId AND v.Kind = 'REFUND' AND v.IsActive = 1;
        IF @amt IS NULL OR @amt <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'IPD advance refund ', @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@adv, @amt, 0, N'Advance refunded'), (@modeLedger, 0, @amt, N'Paid back by ' + @mode)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_ADVREFUND', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
END;
GO

-- ── an advance receipt: PaymentHeader / PaymentDetail (module IPD, one receipt no.), IpdAdvance, ledger ─────
-- Called inside the caller's transaction; refuses with THROW 541xx.
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostAdvance
    @AdmissionId INT, @UserId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL,
    @AdvanceId INT OUTPUT, @ReceiptNo NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Pay TABLE (Seq INT IDENTITY(1,1), Method VARCHAR(20), Amount DECIMAL(18,4), Ref NVARCHAR(100), MethodId INT NULL);
    IF ISJSON(@Payments) = 1
        INSERT @Pay (Method, Amount, Ref)
        SELECT UPPER(LTRIM(RTRIM(j.Method))), j.Amount, NULLIF(LTRIM(RTRIM(j.Ref)), N'')
        FROM OPENJSON(@Payments) WITH (Method VARCHAR(20), Amount DECIMAL(18,4), Ref NVARCHAR(100)) j
        WHERE ISNULL(j.Amount, 0) <> 0;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Amount < 0) THROW 54101, 'A payment amount cannot be negative.', 1;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Amount <> ROUND(Amount, 2)) THROW 54102, 'A payment amount can have at most two decimals.', 1;
    UPDATE p SET MethodId = pm.PaymentMethodId FROM @Pay p JOIN dbo.PaymentMethodMaster pm ON UPPER(pm.MethodCode) = p.Method AND pm.IsActive = 1 AND UPPER(pm.MethodCode) <> 'POINTS';
    IF EXISTS (SELECT 1 FROM @Pay WHERE MethodId IS NULL) THROW 54103, 'Choose a valid payment mode for every amount entered.', 1;
    DECLARE @total DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM @Pay);
    IF @total <= 0 THROW 54104, 'Enter the advance amount.', 1;
    DECLARE @dupRef NVARCHAR(100) = (SELECT TOP 1 Ref FROM @Pay WHERE Ref IS NOT NULL GROUP BY Ref HAVING COUNT(*) > 1);
    IF @dupRef IS NOT NULL BEGIN DECLARE @m1 NVARCHAR(300) = N'Reference ' + @dupRef + N' is entered on more than one payment line.'; THROW 54105, @m1, 1; END;
    DECLARE @usedRef NVARCHAR(100), @usedRcpt NVARCHAR(50);
    SELECT TOP 1 @usedRef = p.Ref, @usedRcpt = pd.ReceiptNo
    FROM @Pay p JOIN dbo.PaymentDetail pd ON pd.IsActive = 1 AND p.Method <> 'CASH' AND p.Ref IS NOT NULL AND (pd.UPIRefNo = p.Ref OR pd.TransactionRef = p.Ref OR pd.ChequeNo = p.Ref);
    IF @usedRef IS NOT NULL
    BEGIN
        DECLARE @m2 NVARCHAR(400) = N'Reference ' + @usedRef + N' is already recorded on receipt ' + ISNULL(@usedRcpt, N'(no receipt no.)') + N'. The same UPI / bank transaction cannot be collected twice.';
        THROW 54106, @m2, 1;
    END;

    DECLARE @co INT, @br INT, @patient INT, @ip NVARCHAR(40), @open BIT;
    SELECT @co = CompanyId, @br = BranchId, @patient = PatientId, @ip = IpNo, @open = IsOpen FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId;
    IF @ip IS NULL THROW 54107, 'The admission was not found.', 1;
    IF @open = 0 THROW 54108, 'The admission is closed: advances can be taken only while the patient is admitted.', 1;

    INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
           NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
    VALUES ('IPD', @AdmissionId, @br, @patient, @total, 0, NULL, 0, 0, @total, @total, 0, 'P', LEFT(N'IPD advance ' + @ip + ISNULL(N' - ' + @Remarks, N''), 500),
            GETDATE(), @UserId, 1, 0, 0, 0, @co, 0);
    DECLARE @headerId INT = CAST(SCOPE_IDENTITY() AS INT);
    EXEC dbo.usp_Receipt_GetNextNo @BranchId = @br, @ReceiptNo = @ReceiptNo OUTPUT;

    DECLARE @s INT = (SELECT MIN(Seq) FROM @Pay), @pd INT;
    WHILE @s IS NOT NULL
    BEGIN
        INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
        SELECT @headerId, p.MethodId, p.Amount, CASE WHEN p.Method NOT IN ('UPI', 'CHEQUE') THEN p.Ref END, CASE WHEN p.Method = 'UPI' THEN p.Ref END,
               CASE WHEN p.Method = 'CARD' AND LEN(p.Ref) >= 4 THEN RIGHT(p.Ref, 4) END, CASE WHEN p.Method = 'CHEQUE' THEN p.Ref END,
               GETDATE(), LEFT(N'IPD advance ' + @ip, 300), GETDATE(), @UserId, 1, @ReceiptNo, @co
        FROM @Pay p WHERE p.Seq = @s;
        SET @pd = CAST(SCOPE_IDENTITY() AS INT);
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'ADVRCPT', @RefId = @pd, @UserId = @UserId;
        SET @s = (SELECT MIN(Seq) FROM @Pay WHERE Seq > @s);
    END

    INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, PaymentHeaderId, Remarks, CreatedBy)
    VALUES (@AdmissionId, 'ADVANCE', @total, @ReceiptNo, @headerId, @Remarks, @UserId);
    SET @AdvanceId = CAST(SCOPE_IDENTITY() AS INT);
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@AdmissionId, 'ADVANCE', CONCAT(N'Advance ₹', FORMAT(@total, 'N2', 'en-IN'), N' received, receipt ', @ReceiptNo), @UserId);
END;
GO

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
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1)
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
        IF @PayerType = 'CORPORATE' AND NOT EXISTS (SELECT 1 FROM @P p JOIN dbo.CorporateMaster m ON m.Corporate_ID = p.CorporateId AND m.Status = 1 WHERE p.Seq = 1)
            THROW 54018, 'Choose the corporate.', 1;
        IF @PayerType = 'SCHEME' AND NOT EXISTS (SELECT 1 FROM @P p JOIN dbo.GovernmentSchemeMaster m ON m.Scheme_ID = p.SchemeId AND m.IsActive = 1 WHERE p.Seq = 1)
            THROW 54019, 'Choose the government scheme.', 1;
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

        -- minimum advance for cash patients: N days of this bed (Hospital Settings > IPD)
        IF @minDays > 0 AND @PayerType = 'CASH'
        BEGIN
            DECLARE @daily DECIMAL(18,2) = (SELECT TOP 1 (RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge)
                                                   * (1 + CASE WHEN ISNULL((SELECT IpdRoomGstThreshold FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 5000) = 0
                                                                 OR RoomCharge + BedCharge + NursingCharge + AttendantCharge + IsolationCharge > ISNULL((SELECT IpdRoomGstThreshold FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 5000)
                                                               THEN GstPercentage ELSE 0 END / 100)
                                            FROM dbo.fn_Ipd_BedRate(@BranchId, @BedId, @TariffCategoryId, CAST(@AdmissionAt AS DATE)));
            DECLARE @need DECIMAL(18,2) = ROUND(ISNULL(@daily, 0) * @minDays, 0);
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

        INSERT dbo.IpdBedMovement (AdmissionId, BedId, WardId, RoomId, BedCategoryId, FromAt, MoveType, CreatedBy)
        VALUES (@id, @BedId, @ward, @room, @cat, @AdmissionAt, 'ADMIT', @UserId);
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @BedId, @ToStatus = N'Occupied', @Reason = N'Patient admitted', @AdmissionId = @id, @UserId = @UserId, @RefType = 'ADMIT';
        IF @resId IS NOT NULL UPDATE dbo.IpdBedReservation SET Status = 'USED', AdmissionId = @id, ModifiedBy = @UserId, ModifiedDate = @now WHERE ReservationId = @resId;

        INSERT dbo.IpdAdmissionPayer (AdmissionId, Seq, PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks)
        SELECT @id, ROW_NUMBER() OVER (ORDER BY Seq), PayerType, InsuranceTpaId, CorporateId, SchemeId, PolicyNo, MemberId, CardHolderName, RelationToHolder, PolicyValidTo, EmployeeId, CardFilePath, Remarks
        FROM @P;

        IF ISJSON(@Attendants) = 1
            INSERT dbo.IpdAttendant (AdmissionId, Name, Relation, Phone, Address, IdTypeId, IdNumber, IsPrimary, PassNo)
            SELECT @id, LEFT(LTRIM(RTRIM(j.Name)), 150), LEFT(NULLIF(j.Relation, N''), 50), LEFT(NULLIF(j.Phone, N''), 20), LEFT(NULLIF(j.Address, N''), 400),
                   NULLIF(j.IdTypeId, 0), LEFT(NULLIF(j.IdNumber, N''), 60), ISNULL(j.IsPrimary, 0), LEFT(NULLIF(j.PassNo, N''), 30)
            FROM OPENJSON(@Attendants) WITH (Name NVARCHAR(200), Relation NVARCHAR(100), Phone NVARCHAR(40), Address NVARCHAR(500), IdTypeId INT, IdNumber NVARCHAR(100), IsPrimary BIT, PassNo NVARCHAR(60)) j
            WHERE NULLIF(LTRIM(RTRIM(j.Name)), N'') IS NOT NULL;

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

-- ── one admission: banner and every block of the patient workspace ──────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Get @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    -- 1 header + live money
    SELECT h.*, lt.Net AS BillNow, lt.Days AS BedDays, lt.NoTariff, mo.AdvanceTotal, mo.RefundTotal, mo.NetAdvance,
           CAST(lt.Net - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN h.IsOpen = 1 AND h.PayerType = 'CASH' AND (lt.Net > mo.NetAdvance OR (mo.NetAdvance > 0 AND lt.Net >= mo.NetAdvance * h.DepositAlertPercent / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           DATEDIFF(DAY, h.AdmissionAt, ISNULL(h.DischargeAt, @now)) + 1 AS DayCount
    FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h
    CROSS APPLY dbo.fn_Ipd_LiveTotal(h.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(h.AdmissionId) mo;
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
           CASE WHEN v.Kind = 'ADVANCE' THEN
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

-- ── admission list (paged) ──────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_List
    @CompanyId INT, @BranchId INT, @Status VARCHAR(20) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @Search NVARCHAR(100) = NULL,
    @WardId INT = NULL, @PayerType VARCHAR(12) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @Page = CASE WHEN @Page < 1 THEN 1 ELSE @Page END;
    SET @PageSize = CASE WHEN @PageSize < 1 THEN 25 WHEN @PageSize > 200 THEN 200 ELSE @PageSize END;
    SET @Status = NULLIF(UPPER(@Status), ''); SET @PayerType = NULLIF(UPPER(@PayerType), '');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    ;WITH x AS
    (
        SELECT a.AdmissionId, a.IpNo, a.Status, a.IsOpen, a.AdmissionAt, a.AdmissionType, a.PayerType, a.DischargeAt, p.PatientId, p.PatientCode,
               LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender, p.PhoneNumber,
               dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(GETDATE() AS DATE)) AS AgeText,
               b.BedNumber, w.WardName, d.FullName AS ConsultantDoctorName, tc.Name AS TariffCategoryName,
               DATEDIFF(DAY, a.AdmissionAt, ISNULL(a.DischargeAt, GETDATE())) + 1 AS DayCount
        FROM dbo.IpdAdmission a
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
        LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
        LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
        LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = a.TariffCategoryId
        WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId
          AND (@Status IS NULL OR (@Status = 'OPEN' AND a.IsOpen = 1) OR a.Status = @Status)
          AND (@FromDate IS NULL OR a.AdmissionAt >= @FromDate) AND (@ToDate IS NULL OR a.AdmissionAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
          AND (@WardId IS NULL OR b.WardId = @WardId) AND (@PayerType IS NULL OR a.PayerType = @PayerType)
          AND (@Search IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR b.BedNumber LIKE @like
               OR CONCAT(p.FirstName, ' ', p.MiddleName, ' ', p.LastName) LIKE @like OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like)
    )
    SELECT x.*, lt.Net AS BillNow, mo.NetAdvance, CAST(lt.Net - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue
    FROM (SELECT * FROM x ORDER BY x.AdmissionAt DESC, x.AdmissionId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY) x
    OUTER APPLY (SELECT Net FROM dbo.fn_Ipd_LiveTotal(x.AdmissionId, GETDATE()) WHERE x.Status <> 'CANCELLED') lt
    CROSS APPLY dbo.fn_Ipd_Money(x.AdmissionId) mo
    ORDER BY x.AdmissionAt DESC, x.AdmissionId DESC;

    SELECT COUNT(*) AS Total
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId
      AND (@Status IS NULL OR (@Status = 'OPEN' AND a.IsOpen = 1) OR a.Status = @Status)
      AND (@FromDate IS NULL OR a.AdmissionAt >= @FromDate) AND (@ToDate IS NULL OR a.AdmissionAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
      AND (@WardId IS NULL OR b.WardId = @WardId) AND (@PayerType IS NULL OR a.PayerType = @PayerType)
      AND (@Search IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR b.BedNumber LIKE @like
           OR CONCAT(p.FirstName, ' ', p.MiddleName, ' ', p.LastName) LIKE @like OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like);
END;
GO

-- ── edit admission details (not the bed: transfers come in Phase 2) ─────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Update
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT,
    @AdmissionType VARCHAR(20), @AdmissionSource VARCHAR(20), @ReferralDoctorId INT = NULL, @AdmittingDoctorId INT, @ConsultantDoctorId INT,
    @DepartmentId INT = NULL, @ProvisionalDiagnosis NVARCHAR(500) = NULL, @DiagnosisCode NVARCHAR(20) = NULL, @ReasonForAdmission NVARCHAR(500) = NULL,
    @ExpectedDischargeAt DATETIME = NULL, @TariffCategoryId INT, @PayerType VARCHAR(12), @PackageId INT = NULL, @Remarks NVARCHAR(1000) = NULL,
    @Payers NVARCHAR(MAX) = NULL, @Attendants NVARCHAR(MAX) = NULL, @IsMlc BIT = 0, @Mlc NVARCHAR(MAX) = NULL, @CanChangeTariff BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @oldTc INT, @oldPayer VARCHAR(12), @open BIT, @admAt DATETIME, @oldTcName NVARCHAR(150), @newTcName NVARCHAR(150);
        SELECT @oldTc = TariffCategoryId, @oldPayer = PayerType, @open = IsOpen, @admAt = AdmissionAt FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54201, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 54202, 'The admission is closed and cannot be changed.', 1;
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

        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'EDIT', CONCAT(N'Admission details updated',
                CASE WHEN @TariffCategoryId <> @oldTc THEN N'; tariff category ' + ISNULL(@oldTcName, N'?') + N' → ' + ISNULL(@newTcName, N'?') END,
                CASE WHEN @PayerType <> @oldPayer THEN N'; payer ' + @oldPayer + N' → ' + @PayerType END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── cancel an admission made by mistake (no charges; any advance held is refunded in the same step) ────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdmission_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Reason NVARCHAR(300),
    @RefundMethod VARCHAR(20) = NULL, @RefundRefNo NVARCHAR(100) = NULL
AS
-- An admission made by mistake (no charges posted). An advance still held is paid back in full in the same step
-- (@RefundMethod; EMR.Web lets it only with the Refund permission): a stay that never was has nothing to bill.
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54301, 'Enter the reason for cancelling the admission.', 1;
        DECLARE @status VARCHAR(20), @bed INT;
        SELECT @status = Status, @bed = CurrentBedId FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 54302, 'The admission was not found in this branch.', 1;
        IF @status <> 'ADMITTED' THROW 54303, 'Only an admission that is still in the Admitted state can be cancelled.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdCharge WHERE AdmissionId = @AdmissionId AND Status = 'POSTED') THROW 54304, 'Charges are posted on this admission: it cannot be cancelled (discharge it instead).', 1;
        DECLARE @net DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId)), @refNo NVARCHAR(40) = NULL;
        IF @net > 0
        BEGIN
            DECLARE @modeName NVARCHAR(100) = (SELECT MethodName FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = UPPER(@RefundMethod) AND IsActive = 1 AND UPPER(MethodCode) NOT IN ('POINTS', 'WALLET'));
            IF @modeName IS NULL BEGIN SET @msg = N'An advance of ₹' + FORMAT(@net, 'N2', 'en-IN') + N' is held: choose how it is paid back (cash, UPI, NEFT, cheque or card).'; THROW 54305, @msg, 1; END;
            EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'REF', @DocDate = @now, @DocNo = @refNo OUTPUT;
            INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, Mode, RefNo, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'REFUND', @net, @refNo, @modeName, NULLIF(LTRIM(RTRIM(@RefundRefNo)), N''), LEFT(N'Admission cancelled: ' + LTRIM(RTRIM(@Reason)), 300), @UserId);
            DECLARE @advId INT = CAST(SCOPE_IDENTITY() AS INT);
            EXEC dbo.usp_Ipd_PostLedger @Kind = 'ADVREFUND', @RefId = @advId, @UserId = @UserId;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'REFUND', CONCAT(N'Advance refund ₹', FORMAT(@net, 'N2', 'en-IN'), N' by ', @modeName, N', voucher ', @refNo, N' (admission cancelled)'), @UserId);
        END;
        ELSE IF @net < 0 THROW 54306, 'More was refunded than received on this admission; check the advances before cancelling.', 1;

        UPDATE dbo.IpdBedMovement SET ToAt = @now, EndType = 'CANCEL' WHERE AdmissionId = @AdmissionId AND ToAt IS NULL;
        EXEC dbo.usp_Ipd_ReleaseBed @BedId = @bed, @AdmissionId = @AdmissionId, @Reason = 'CANCEL', @UserId = @UserId;
        UPDATE dbo.IpdAdmission SET Status = 'CANCELLED', IsOpen = 0, CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = @now, ModifiedBy = @UserId, ModifiedDate = @now
        WHERE AdmissionId = @AdmissionId;
        UPDATE dbo.IpdEstimate SET Status = 'ACTIVE', AdmissionId = NULL WHERE AdmissionId = @AdmissionId AND Status = 'CONVERTED';
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy) VALUES (@AdmissionId, 'CANCEL', @status, 'CANCELLED', LTRIM(RTRIM(@Reason)), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId, @refNo AS RefundNo,
               (SELECT TOP 1 AdvanceId FROM dbo.IpdAdvance WHERE AdmissionId = @AdmissionId AND DocNo = @refNo) AS RefundAdvanceId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── advances ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Add @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 54401, 'The admission was not found in this branch.', 1;
        DECLARE @advId INT, @rcpt NVARCHAR(50);
        EXEC dbo.usp_Ipd_PostAdvance @AdmissionId = @AdmissionId, @UserId = @UserId, @Payments = @Payments, @Remarks = @Remarks, @AdvanceId = @advId OUTPUT, @ReceiptNo = @rcpt OUTPUT;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @advId AS AdvanceId, @rcpt AS ReceiptNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- Refund of advance while admitted: at most what is left after the bill so far (the rest is settled at discharge).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Refund
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Amount DECIMAL(18,2), @Method VARCHAR(20), @RefNo NVARCHAR(100) = NULL, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54501, 'Enter the reason for the refund.', 1;
        IF ISNULL(@Amount, 0) <= 0 THROW 54502, 'Enter the refund amount.', 1;
        IF @Amount <> ROUND(@Amount, 2) THROW 54503, 'The refund amount can have at most two decimals.', 1;
        DECLARE @modeName NVARCHAR(100) = (SELECT MethodName FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = UPPER(@Method) AND IsActive = 1 AND UPPER(MethodCode) NOT IN ('POINTS', 'WALLET'));
        IF @modeName IS NULL THROW 54504, 'Choose how the refund is paid (cash, UPI, NEFT, cheque or card).', 1;
        DECLARE @status VARCHAR(20), @open BIT;
        SELECT @status = Status, @open = IsOpen FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 54505, 'The admission was not found in this branch.', 1;
        DECLARE @net DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        DECLARE @bill DECIMAL(18,2) = CASE WHEN @status = 'CANCELLED' THEN 0 ELSE (SELECT Net FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, @now)) END;
        DECLARE @max DECIMAL(18,2) = CASE WHEN @open = 1 OR @status = 'CANCELLED' THEN @net - @bill ELSE 0 END;
        IF @max < 0 SET @max = 0;
        IF @Amount > @max
        BEGIN
            SET @msg = CONCAT(N'Refundable now: ₹', FORMAT(@max, 'N2', 'en-IN'), N' (advance ₹', FORMAT(@net, 'N2', 'en-IN'), N' less the bill so far ₹', FORMAT(@bill, 'N2', 'en-IN'), N').');
            THROW 54506, @msg, 1;
        END;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'REF', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, Mode, RefNo, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'REFUND', @Amount, @no, @modeName, NULLIF(LTRIM(RTRIM(@RefNo)), N''), LTRIM(RTRIM(@Reason)), @UserId);
        DECLARE @advId INT = CAST(SCOPE_IDENTITY() AS INT);
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'ADVREFUND', @RefId = @advId, @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'REFUND', CONCAT(N'Advance refund ₹', FORMAT(@Amount, 'N2', 'en-IN'), N' by ', @modeName, N', voucher ', @no, N': ', LTRIM(RTRIM(@Reason))), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @advId AS AdvanceId, @no AS DocNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- An advance receipt / refund voucher for print.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAdvance_Get @CompanyId INT, @AdvanceId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT v.AdmissionId FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId WHERE v.AdvanceId = @AdvanceId AND a.CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.RefNo, v.Remarks, v.CreatedDate, u.FullName AS CreatedByName, mo.NetAdvance, mo.AdvanceTotal, mo.RefundTotal
    FROM dbo.IpdAdvance v LEFT JOIN dbo.Users u ON u.Id = v.CreatedBy CROSS APPLY dbo.fn_Ipd_Money(v.AdmissionId) mo WHERE v.AdvanceId = @AdvanceId;
    SELECT h.* FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h;
    SELECT pm.MethodName, pd.PaidAmount, COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) AS RefNo, pd.CardLast4
    FROM dbo.IpdAdvance v
    JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1
    JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE v.AdvanceId = @AdvanceId ORDER BY pd.PaymentDetailId;
END;
GO

-- ── consents and documents ──────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdConsent_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ConsentId INT, @SignedByName NVARCHAR(150), @SignedByRelation NVARCHAR(50) = NULL,
    @WitnessName NVARCHAR(150) = NULL, @SignaturePath NVARCHAR(400) = NULL, @WitnessSignaturePath NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status <> 'CANCELLED')
            THROW 54601, 'The admission was not found in this branch.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.ConsentMaster WHERE Consent_ID = @ConsentId AND Status = 1 AND Type = 'IPD') THROW 54602, 'Choose an active IPD consent form.', 1;
        IF NULLIF(LTRIM(RTRIM(@SignedByName)), N'') IS NULL THROW 54603, 'Enter who signed the consent (patient or relative).', 1;
        IF (SELECT WitnessRequired FROM dbo.ConsentMaster WHERE Consent_ID = @ConsentId) = 1 AND NULLIF(LTRIM(RTRIM(@WitnessName)), N'') IS NULL
            THROW 54604, 'This consent needs a witness: enter the witness name.', 1;
        INSERT dbo.IpdAdmissionConsent (AdmissionId, ConsentId, ConsentType, Language, Version, ContentHtml, SignedByName, SignedByRelation, WitnessName, SignaturePath, WitnessSignaturePath, SignedAt, CreatedBy)
        SELECT @AdmissionId, c.Consent_ID, c.ConsentType, c.Language, c.Version,
               dbo.fn_Ipd_FillConsent(c.ConsentTemplateContent, @AdmissionId, NULLIF(@SignedByRelation, N''), NULLIF(LTRIM(RTRIM(@WitnessName)), N''), @now),
               LTRIM(RTRIM(@SignedByName)), NULLIF(@SignedByRelation, N''), NULLIF(LTRIM(RTRIM(@WitnessName)), N''), NULLIF(@SignaturePath, N''), NULLIF(@WitnessSignaturePath, N''), @now, @UserId
        FROM dbo.ConsentMaster c WHERE c.Consent_ID = @ConsentId;
        DECLARE @cid INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'CONSENT', CONCAT(ConsentType, N' signed by ', SignedByName), @UserId FROM dbo.IpdAdmissionConsent WHERE AdmissionConsentId = @cid;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @cid AS AdmissionConsentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdConsent_Get @CompanyId INT, @AdmissionConsentId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT c.AdmissionId FROM dbo.IpdAdmissionConsent c JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId
                        WHERE c.AdmissionConsentId = @AdmissionConsentId AND a.CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    SELECT c.*, u.FullName AS CapturedByName FROM dbo.IpdAdmissionConsent c LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy WHERE c.AdmissionConsentId = @AdmissionConsentId;
    SELECT h.* FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDocument_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @DocType NVARCHAR(40), @Title NVARCHAR(150) = NULL, @FilePath NVARCHAR(400), @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status <> 'CANCELLED')
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The admission was not found in this branch.' AS Error; RETURN; END;
    IF NULLIF(LTRIM(RTRIM(@FilePath)), N'') IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose the file to upload.' AS Error; RETURN; END;
    INSERT dbo.IpdDocument (AdmissionId, DocType, Title, FilePath, Remarks, CreatedBy)
    VALUES (@AdmissionId, LEFT(ISNULL(NULLIF(LTRIM(RTRIM(@DocType)), N''), N'Other'), 40), NULLIF(LTRIM(RTRIM(@Title)), N''), @FilePath, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
    DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@AdmissionId, 'DOCUMENT', CONCAT(N'Document added: ', @DocType, ISNULL(N' - ' + NULLIF(@Title, N''), N'')), @UserId);
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS DocumentId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDocument_Remove @CompanyId INT, @BranchId INT, @UserId INT, @DocumentId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT d.AdmissionId FROM dbo.IpdDocument d JOIN dbo.IpdAdmission a ON a.AdmissionId = d.AdmissionId
                        WHERE d.DocumentId = @DocumentId AND d.IsActive = 1 AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId);
    IF @adm IS NULL BEGIN SELECT CAST(0 AS BIT) AS Success, N'The document was not found.' AS Error; RETURN; END;
    UPDATE dbo.IpdDocument SET IsActive = 0 WHERE DocumentId = @DocumentId;
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    SELECT @adm, 'DOCUMENT', CONCAT(N'Document removed: ', DocType, ISNULL(N' - ' + Title, N'')), @UserId FROM dbo.IpdDocument WHERE DocumentId = @DocumentId;
    SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END;
GO

-- ── IPD dashboard ───────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_Dashboard @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @now DATETIME = GETDATE();
    DECLARE @beds TABLE (BedId INT PRIMARY KEY, WardId INT, Occupied BIT, Available BIT);
    INSERT @beds
    SELECT b.BedId, b.WardId, CASE WHEN m.BedId IS NOT NULL THEN 1 ELSE 0 END,
           CASE WHEN m.BedId IS NULL AND b.BedStatus = 'Available' THEN 1 ELSE 0 END
    FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId AND w.IsActive = 1
    LEFT JOIN (SELECT DISTINCT BedId FROM dbo.IpdBedMovement WHERE ToAt IS NULL) m ON m.BedId = b.BedId
    WHERE b.IsActive = 1 AND b.BranchId = @BranchId;
    -- 1 tiles
    SELECT (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND IsOpen = 1) AS InPatients,
           (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND Status <> 'CANCELLED' AND AdmissionAt >= @today) AS AdmittedToday,
           (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND Status = 'DISCHARGED' AND DischargeAt >= @today) AS DischargedToday,
           (SELECT COUNT(*) FROM dbo.IpdAdmission WHERE BranchId = @BranchId AND CompanyId = @CompanyId AND Status = 'DISCHARGE_ADVISED') AS DischargeAdvised,
           (SELECT COUNT(*) FROM @beds) AS BedsTotal, (SELECT COUNT(*) FROM @beds WHERE Occupied = 1) AS BedsOccupied,
           (SELECT COUNT(*) FROM @beds WHERE Available = 1) AS BedsAvailable, (SELECT COUNT(*) FROM @beds WHERE Occupied = 0 AND Available = 0) AS BedsOther,
           (SELECT ISNULL(SUM(v.Amount), 0) FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
             WHERE a.BranchId = @BranchId AND v.IsActive = 1 AND v.Kind = 'ADVANCE' AND v.CreatedDate >= @today) AS AdvanceToday,
           (SELECT ISNULL(SUM(v.Amount), 0) FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
             WHERE a.BranchId = @BranchId AND v.IsActive = 1 AND v.Kind = 'REFUND' AND v.CreatedDate >= @today) AS RefundToday;
    -- 2 ward occupancy
    SELECT w.WardId, w.WardName, w.WardType, COUNT(b.BedId) AS Total, ISNULL(SUM(CAST(b.Occupied AS INT)), 0) AS Occupied,
           ISNULL(SUM(CAST(b.Available AS INT)), 0) AS Available, COUNT(b.BedId) - ISNULL(SUM(CAST(b.Occupied AS INT)), 0) - ISNULL(SUM(CAST(b.Available AS INT)), 0) AS Other
    FROM dbo.WardMaster w JOIN @beds b ON b.WardId = w.WardId
    GROUP BY w.WardId, w.WardName, w.WardType ORDER BY w.WardName;
    -- 3 patients in the hospital now
    SELECT TOP 300 a.AdmissionId, a.IpNo, a.AdmissionAt, a.PayerType, a.Status, p.PatientCode,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, @today) AS AgeText, b.BedNumber, r.RoomNumber, w.WardName, d.FullName AS ConsultantDoctorName,
           DATEDIFF(DAY, a.AdmissionAt, @now) + 1 AS DayCount, lt.Net AS BillNow, mo.NetAdvance, CAST(lt.Net - mo.NetAdvance AS DECIMAL(18,2)) AS BalanceDue
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    CROSS APPLY dbo.fn_Ipd_LiveTotal(a.AdmissionId, @now) lt
    CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    WHERE a.BranchId = @BranchId AND a.CompanyId = @CompanyId AND a.IsOpen = 1
    ORDER BY w.WardName, b.BedNumber;
END;
GO

-- ── Current Billing Estimation (real time) ──────────────────────────────────────────────────────────────────
-- What the patient would pay if discharged at @AsOf (default now), and the estimate till the expected discharge.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEstimate_Live @CompanyId INT, @AdmissionId INT, @AsOf DATETIME = NULL, @ProjectTo DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    SET @AsOf = ISNULL(@AsOf, @now);
    DECLARE @payer VARCHAR(12), @expected DATETIME, @pct INT, @status VARCHAR(20), @disch DATETIME, @admAt DATETIME;
    SELECT @payer = a.PayerType, @expected = a.ExpectedDischargeAt, @pct = ISNULL(s.IpdDepositAlertPercent, 80), @status = a.Status, @disch = a.DischargeAt, @admAt = a.AdmissionAt
    FROM dbo.IpdAdmission a LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId;
    IF @payer IS NULL RETURN;
    IF @disch IS NOT NULL AND @AsOf > @disch SET @AsOf = @disch;
    SET @ProjectTo = CASE WHEN @disch IS NOT NULL THEN NULL WHEN @ProjectTo IS NOT NULL THEN @ProjectTo ELSE @expected END;
    IF @ProjectTo IS NOT NULL AND @ProjectTo <= @AsOf SET @ProjectTo = NULL;

    DECLARE @L TABLE (Head VARCHAR(20), Gross DECIMAL(18,2), Discount DECIMAL(18,2), GstAmount DECIMAL(18,2), Net DECIMAL(18,2), Status VARCHAR(10), NoTariff BIT, UsedFallback BIT, DayNo INT);
    IF @status <> 'CANCELLED'
        INSERT @L SELECT Head, Gross, Discount, GstAmount, Net, Status, NoTariff, UsedFallback, DayNo FROM dbo.fn_Ipd_BillLines(@AdmissionId, @AsOf);
    DECLARE @projected DECIMAL(18,2) = NULL, @projDays INT = NULL;
    IF @ProjectTo IS NOT NULL AND @status <> 'CANCELLED'
        SELECT @projected = Net, @projDays = Days FROM dbo.fn_Ipd_LiveTotal(@AdmissionId, @ProjectTo);

    -- 1 header
    SELECT h.*, @AsOf AS AsOf, @ProjectTo AS ProjectTo FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @AdmissionId) h;
    -- 2 heads (every head, in bill order)
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(l.Head) AS Lines, CAST(ISNULL(SUM(l.Gross), 0) AS DECIMAL(18,2)) AS Gross,
           CAST(ISNULL(SUM(l.Discount), 0) AS DECIMAL(18,2)) AS Discount, CAST(ISNULL(SUM(l.GstAmount), 0) AS DECIMAL(18,2)) AS Gst,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS Net, CAST(ISNULL(SUM(CASE WHEN l.Status = 'ACCRUED' THEN l.Net END), 0) AS DECIMAL(18,2)) AS Accrued,
           CAST(ISNULL(SUM(CASE WHEN l.Status = 'POSTED' THEN l.Net END), 0) AS DECIMAL(18,2)) AS Posted,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS PatientShare, CAST(0 AS DECIMAL(18,2)) AS PayerShare
    FROM dbo.fn_Ipd_Heads() hd LEFT JOIN @L l ON l.Head = hd.Head
    GROUP BY hd.Head, hd.HeadName, hd.Sort ORDER BY hd.Sort;
    -- 3 totals
    DECLARE @gross DECIMAL(18,2), @disc DECIMAL(18,2), @gst DECIMAL(18,2), @net DECIMAL(18,2), @days INT;
    SELECT @gross = ISNULL(SUM(Gross), 0), @disc = ISNULL(SUM(Discount), 0), @gst = ISNULL(SUM(GstAmount), 0), @net = ISNULL(SUM(Net), 0), @days = ISNULL(MAX(DayNo), 0) FROM @L;
    SELECT @gross AS Gross, @disc AS Discount, @gst AS Gst, @net AS BillNow, @days AS BedDays,
           mo.AdvanceTotal, mo.RefundTotal, mo.NetAdvance, CAST(0 AS DECIMAL(18,2)) AS ApprovedAmount,
           @net AS PatientShare, CAST(0 AS DECIMAL(18,2)) AS PayerShare,
           CAST(CASE WHEN @net - mo.NetAdvance > 0 THEN @net - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN mo.NetAdvance - @net > 0 THEN mo.NetAdvance - @net ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           CAST(CASE WHEN @status IN ('ADMITTED', 'DISCHARGE_ADVISED') AND @payer = 'CASH'
                      AND (@net > mo.NetAdvance OR (mo.NetAdvance > 0 AND @net >= mo.NetAdvance * @pct / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert,
           @pct AS DepositAlertPercent,
           @projected AS ProjectedTotal, @projDays AS ProjectedDays,
           CAST(CASE WHEN @projected IS NULL THEN NULL ELSE @projected - @net END AS DECIMAL(18,2)) AS ProjectedExtra,
           CAST(CASE WHEN @projected IS NULL THEN NULL WHEN @projected - mo.NetAdvance > 0 THEN @projected - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS ProjectedBalance,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @L WHERE NoTariff = 1) THEN 1 ELSE 0 END AS BIT) AS NoTariff,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM @L WHERE UsedFallback = 1) THEN 1 ELSE 0 END AS BIT) AS UsedFallback
    FROM dbo.fn_Ipd_Money(@AdmissionId) mo;
    -- 4 ordered, not yet charged (LAB orders, indents, OT bookings: filled as Phases 4 and 8 arrive)
    SELECT CAST(NULL AS VARCHAR(20)) AS Head, CAST(NULL AS NVARCHAR(250)) AS ItemName, CAST(NULL AS DATETIME) AS OrderedAt,
           CAST(NULL AS NVARCHAR(50)) AS OrderNo, CAST(NULL AS NVARCHAR(30)) AS OrderStatus, CAST(NULL AS DECIMAL(18,2)) AS EstimatedAmount
    WHERE 1 = 0;
END;
GO

-- Every line of the current estimate, with filters.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEstimate_Lines @CompanyId INT, @AdmissionId INT, @AsOf DATETIME = NULL, @Head VARCHAR(20) = NULL, @Status VARCHAR(10) = NULL,
    @FromDate DATE = NULL, @ToDate DATE = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admStatus VARCHAR(20), @disch DATETIME;
    SELECT @admStatus = Status, @disch = DischargeAt FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId;
    IF @admStatus IS NULL OR @admStatus = 'CANCELLED' RETURN;
    SET @AsOf = ISNULL(@AsOf, GETDATE());
    IF @disch IS NOT NULL AND @AsOf > @disch SET @AsOf = @disch;
    SET @Head = NULLIF(@Head, ''); SET @Status = NULLIF(@Status, ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SELECT l.LineKey, l.Head, hd.HeadName, hd.Sort AS HeadSort, l.ChargeAt, l.ItemCode, l.ItemName, l.Detail, l.DoctorName, l.Qty, l.Rate, l.Gross, l.Discount,
           l.GstPercent, l.GstAmount, l.Net, l.Status, l.SourceModule, l.SourceNo, l.IsPackageItem, l.NoTariff, l.UsedFallback, l.DayNo, l.Sort
    FROM dbo.fn_Ipd_BillLines(@AdmissionId, @AsOf) l
    LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head
    WHERE (@Head IS NULL OR l.Head = @Head) AND (@Status IS NULL OR l.Status = @Status)
      AND (@FromDate IS NULL OR l.ChargeAt >= @FromDate) AND (@ToDate IS NULL OR l.ChargeAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
      AND (@Search IS NULL OR l.ItemName LIKE N'%' + @Search + N'%' OR l.Detail LIKE N'%' + @Search + N'%')
    ORDER BY l.ChargeAt, hd.Sort, l.DayNo, l.Sort, l.LineKey;
END;
GO

-- All admitted patients with their live bill, advance and balance.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEstimate_DueList @CompanyId INT, @BranchId INT, @WardId INT = NULL, @PayerType VARCHAR(12) = NULL, @Search NVARCHAR(100) = NULL,
    @OnlyAlerts BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N''); SET @PayerType = NULLIF(UPPER(@PayerType), '');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    ;WITH x AS
    (
        SELECT a.AdmissionId, a.IpNo, a.AdmissionAt, a.PayerType, a.Status, p.PatientCode, p.PhoneNumber,
               LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.Gender,
               dbo.fn_Ipd_AgeText(p.DateOfBirth, CAST(@now AS DATE)) AS AgeText, b.BedNumber, w.WardId, w.WardName, d.FullName AS ConsultantDoctorName,
               COALESCE(ins.Name, corp.Corporate_Name, sch.SchemeName) AS PayerName,
               DATEDIFF(DAY, a.AdmissionAt, @now) + 1 AS DayCount, lt.Net AS BillNow, lt.Days AS BedDays, lt.NoTariff, mo.NetAdvance,
               ISNULL(s.IpdDepositAlertPercent, 80) AS Pct
        FROM dbo.IpdAdmission a
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
        LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
        LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
        LEFT JOIN dbo.IpdAdmissionPayer py ON py.AdmissionId = a.AdmissionId AND py.Seq = 1
        LEFT JOIN dbo.InsuranceTPAMaster ins ON ins.InsuranceTPA_ID = py.InsuranceTpaId
        LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = py.CorporateId
        LEFT JOIN dbo.GovernmentSchemeMaster sch ON sch.Scheme_ID = py.SchemeId
        LEFT JOIN dbo.HospitalSettings s ON s.BranchID = a.BranchId
        CROSS APPLY dbo.fn_Ipd_LiveTotal(a.AdmissionId, @now) lt
        CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
        WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1
          AND (@WardId IS NULL OR b.WardId = @WardId) AND (@PayerType IS NULL OR a.PayerType = @PayerType)
          AND (@Search IS NULL OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR b.BedNumber LIKE @like
               OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like)
    )
    SELECT x.AdmissionId, x.IpNo, x.AdmissionAt, x.PayerType, x.PayerName, x.Status, x.PatientCode, x.PhoneNumber, x.PatientName, x.Gender, x.AgeText,
           x.BedNumber, x.WardId, x.WardName, x.ConsultantDoctorName, x.DayCount, x.BedDays, x.BillNow, x.NetAdvance, x.NoTariff,
           CAST(x.BillNow - x.NetAdvance AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN x.PayerType = 'CASH' AND (x.BillNow > x.NetAdvance OR (x.NetAdvance > 0 AND x.BillNow >= x.NetAdvance * x.Pct / 100.0)) THEN 1 ELSE 0 END AS BIT) AS DepositAlert
    FROM x
    WHERE ISNULL(@OnlyAlerts, 0) = 0 OR (x.PayerType = 'CASH' AND (x.BillNow > x.NetAdvance OR (x.NetAdvance > 0 AND x.BillNow >= x.NetAdvance * x.Pct / 100.0)))
    ORDER BY x.BillNow - x.NetAdvance DESC, x.IpNo;
END;
GO

-- ── pre-admission estimate ──────────────────────────────────────────────────────────────────────────────────
-- Suggested lines from the masters: bed category rate x ward days, ICU bed category x ICU days, package.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreEstimate_Calc @CompanyId INT, @BranchId INT, @TariffCategoryId INT, @BedCategoryId INT = NULL, @WardDays INT = 0,
    @IcuBedCategoryId INT = NULL, @IcuDays INT = 0, @PackageId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @def INT = (SELECT IpdDefaultTariffCategoryId FROM dbo.HospitalSettings WHERE BranchID = @BranchId),
            @thr DECIMAL(18,2) = ISNULL((SELECT IpdRoomGstThreshold FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 5000);
    DECLARE @R TABLE (Kind VARCHAR(5), CategoryName NVARCHAR(150), Days INT, RoomCharge DECIMAL(18,2), BedCharge DECIMAL(18,2), NursingCharge DECIMAL(18,2),
                      AttendantCharge DECIMAL(18,2), Gst DECIMAL(5,2), Found BIT);
    INSERT @R
    SELECT k.Kind, bc.CategoryName, k.Days, t.RoomCharge, t.BedCharge, t.NursingCharge, t.AttendantCharge,
           CASE WHEN k.Kind = 'ICU' OR t.BedRateId IS NULL THEN 0 WHEN @thr > 0 AND t.RoomCharge + t.BedCharge + t.NursingCharge + t.AttendantCharge <= @thr THEN 0 ELSE t.GstPercentage END,
           CASE WHEN t.BedRateId IS NULL THEN 0 ELSE 1 END
    FROM (VALUES ('WARD', @BedCategoryId, ISNULL(@WardDays, 0)), ('ICU', @IcuBedCategoryId, ISNULL(@IcuDays, 0))) k (Kind, CatId, Days)
    JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = k.CatId
    OUTER APPLY (SELECT TOP 1 x.* FROM dbo.BedRoomTariffMaster x
                 WHERE x.BranchId = @BranchId AND x.IsActive = 1 AND x.BedCategoryId = k.CatId AND x.TariffCategoryId IN (@TariffCategoryId, ISNULL(@def, @TariffCategoryId))
                   AND x.EffectiveFrom <= @today AND (x.EffectiveTo IS NULL OR x.EffectiveTo >= @today)
                 ORDER BY CASE WHEN x.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END, x.EffectiveFrom DESC, x.BedRateId) t
    WHERE k.CatId IS NOT NULL AND k.Days > 0;

    SELECT Head, ItemName, Qty, Rate, CAST(Qty * Rate AS DECIMAL(18,2)) AS Amount, Remarks
    FROM (
        SELECT CASE WHEN r.Kind = 'ICU' THEN 'ICU' ELSE 'BED' END AS Head, v.Sort + CASE WHEN r.Kind = 'ICU' THEN 10 ELSE 0 END AS Sort,
               CONCAT(v.Name, N' - ', r.CategoryName) AS ItemName, CAST(r.Days AS DECIMAL(18,3)) AS Qty,
               CAST(v.Amount * (1 + r.Gst / 100) AS DECIMAL(18,2)) AS Rate,
               CASE WHEN r.Gst > 0 THEN CONCAT(N'incl. GST ', FORMAT(r.Gst, '0.##'), N'%') END AS Remarks
        FROM @R r
        CROSS APPLY (VALUES (1, N'Room Rent', r.RoomCharge), (2, N'Bed Charge', r.BedCharge), (3, N'Nursing Charge', r.NursingCharge), (4, N'Attendant Charge', r.AttendantCharge)) v (Sort, Name, Amount)
        WHERE r.Found = 1 AND v.Amount > 0
        UNION ALL
        SELECT 'PACKAGE', 50, CONCAT(N'Package - ', Package_Name), 1, TotalPackageAmount, Package_Type
        FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1
    ) z ORDER BY Sort;
    -- categories without a rate for this tariff
    SELECT r.Kind, r.CategoryName FROM @R r WHERE r.Found = 0;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreEstimate_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @EstimateId INT = NULL, @PatientId INT = NULL, @PatientName NVARCHAR(200), @Phone NVARCHAR(20) = NULL,
    @AgeText NVARCHAR(30) = NULL, @Gender NVARCHAR(20) = NULL, @PayerType VARCHAR(12), @TariffCategoryId INT, @BedCategoryId INT = NULL, @WardDays INT = 0,
    @IcuBedCategoryId INT = NULL, @IcuDays INT = 0, @PackageId INT = NULL, @DoctorId INT = NULL, @ProcedureNote NVARCHAR(300) = NULL, @Remarks NVARCHAR(1000) = NULL,
    @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;   -- called inside another transaction: only this procedure's work is undone on a refusal
    DECLARE @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@PatientName)), N'') IS NULL THROW 54701, 'Enter the patient name.', 1;
        SET @PayerType = UPPER(ISNULL(@PayerType, 'CASH'));
        IF @PayerType NOT IN ('CASH', 'CORPORATE', 'INSURANCE', 'SCHEME') THROW 54702, 'Choose the payer.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId AND IsActive = 1 AND CompanyId = @CompanyId) THROW 54703, 'Choose the tariff category.', 1;
        IF @PatientId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId) THROW 54704, 'The patient was not found in this company.', 1;
        DECLARE @L TABLE (Seq INT IDENTITY(1,1), Head VARCHAR(20), ItemName NVARCHAR(250), Qty DECIMAL(18,3), Rate DECIMAL(18,2), Remarks NVARCHAR(300));
        IF ISJSON(@Lines) = 1
            INSERT @L (Head, ItemName, Qty, Rate, Remarks)
            SELECT LEFT(ISNULL(NULLIF(UPPER(j.Head), ''), 'SERVICE'), 20), LEFT(LTRIM(RTRIM(j.ItemName)), 250), ISNULL(j.Qty, 1), ISNULL(j.Rate, 0), LEFT(NULLIF(j.Remarks, N''), 300)
            FROM OPENJSON(@Lines) WITH (Head VARCHAR(30), ItemName NVARCHAR(400), Qty DECIMAL(18,3), Rate DECIMAL(18,2), Remarks NVARCHAR(500)) j
            WHERE NULLIF(LTRIM(RTRIM(j.ItemName)), N'') IS NOT NULL;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 54705, 'Add at least one line to the estimate.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE Qty <= 0 OR Rate < 0) THROW 54706, 'Every line needs a quantity above 0 and a rate of 0 or more.', 1;
        DECLARE @total DECIMAL(18,2) = (SELECT SUM(CAST(Qty * Rate AS DECIMAL(18,2))) FROM @L);
        DECLARE @valid INT = ISNULL((SELECT IpdEstimateValidityDays FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 7);
        DECLARE @no NVARCHAR(40);
        IF @EstimateId IS NULL
        BEGIN
            EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'EST', @DocDate = @now, @DocNo = @no OUTPUT;
            INSERT dbo.IpdEstimate (CompanyId, BranchId, EstimateNo, EstimateDate, ValidTo, PatientId, PatientName, Phone, AgeText, Gender, PayerType, TariffCategoryId, BedCategoryId,
                   WardDays, IcuBedCategoryId, IcuDays, PackageId, DoctorId, ProcedureNote, Remarks, TotalAmount, Status, CreatedBy)
            VALUES (@CompanyId, @BranchId, @no, @now, DATEADD(DAY, @valid, CAST(@now AS DATE)), @PatientId, LTRIM(RTRIM(@PatientName)), NULLIF(@Phone, N''), NULLIF(@AgeText, N''),
                   NULLIF(@Gender, N''), @PayerType, @TariffCategoryId, @BedCategoryId, ISNULL(@WardDays, 0), @IcuBedCategoryId, ISNULL(@IcuDays, 0), @PackageId, NULLIF(@DoctorId, 0),
                   NULLIF(@ProcedureNote, N''), NULLIF(@Remarks, N''), @total, 'ACTIVE', @UserId);
            SET @EstimateId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdEstimate WITH (UPDLOCK) WHERE EstimateId = @EstimateId AND BranchId = @BranchId AND Status = 'ACTIVE')
                THROW 54707, 'Only an active estimate of this branch can be changed.', 1;
            UPDATE dbo.IpdEstimate SET PatientId = @PatientId, PatientName = LTRIM(RTRIM(@PatientName)), Phone = NULLIF(@Phone, N''), AgeText = NULLIF(@AgeText, N''),
                   Gender = NULLIF(@Gender, N''), PayerType = @PayerType, TariffCategoryId = @TariffCategoryId, BedCategoryId = @BedCategoryId, WardDays = ISNULL(@WardDays, 0),
                   IcuBedCategoryId = @IcuBedCategoryId, IcuDays = ISNULL(@IcuDays, 0), PackageId = @PackageId, DoctorId = NULLIF(@DoctorId, 0), ProcedureNote = NULLIF(@ProcedureNote, N''),
                   Remarks = NULLIF(@Remarks, N''), TotalAmount = @total, ModifiedBy = @UserId, ModifiedDate = @now
            WHERE EstimateId = @EstimateId;
            DELETE dbo.IpdEstimateLine WHERE EstimateId = @EstimateId;
            SELECT @no = EstimateNo FROM dbo.IpdEstimate WHERE EstimateId = @EstimateId;
        END
        INSERT dbo.IpdEstimateLine (EstimateId, Seq, Head, ItemName, Qty, Rate, Amount, Remarks)
        SELECT @EstimateId, Seq, Head, ItemName, Qty, Rate, CAST(Qty * Rate AS DECIMAL(18,2)), Remarks FROM @L;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @EstimateId AS EstimateId, @no AS EstimateNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreEstimate_Get @CompanyId INT, @EstimateId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.*, tc.Name AS TariffCategoryName, bc.CategoryName AS BedCategoryName, ic.CategoryName AS IcuBedCategoryName, pk.Package_Name AS PackageName,
           d.FullName AS DoctorName, p.PatientCode, u.FullName AS CreatedByName, a.IpNo AS AdmissionIpNo,
           CAST(CASE WHEN e.Status = 'ACTIVE' AND e.ValidTo < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS BIT) AS IsExpired
    FROM dbo.IpdEstimate e
    LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = e.TariffCategoryId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = e.BedCategoryId
    LEFT JOIN dbo.BedCategoryMaster ic ON ic.BedCategoryId = e.IcuBedCategoryId
    LEFT JOIN dbo.HospitalPackageMaster pk ON pk.HospitalPackage_ID = e.PackageId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = e.DoctorId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = e.PatientId
    LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = e.AdmissionId
    WHERE e.EstimateId = @EstimateId AND e.CompanyId = @CompanyId;
    SELECT l.LineId, l.Seq, l.Head, hd.HeadName, l.ItemName, l.Qty, l.Rate, l.Amount, l.Remarks
    FROM dbo.IpdEstimateLine l JOIN dbo.IpdEstimate e ON e.EstimateId = l.EstimateId LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head
    WHERE l.EstimateId = @EstimateId AND e.CompanyId = @CompanyId ORDER BY l.Seq;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreEstimate_List @CompanyId INT, @BranchId INT, @Status VARCHAR(10) = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL,
    @Search NVARCHAR(100) = NULL, @PatientId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Status = NULLIF(UPPER(@Status), ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    SELECT TOP 500 e.EstimateId, e.EstimateNo, e.EstimateDate, e.ValidTo, e.PatientId, e.PatientName, e.Phone, e.PayerType, tc.Name AS TariffCategoryName,
           e.TotalAmount, e.Status, a.IpNo AS AdmissionIpNo, u.FullName AS CreatedByName,
           CAST(CASE WHEN e.Status = 'ACTIVE' AND e.ValidTo < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS BIT) AS IsExpired
    FROM dbo.IpdEstimate e
    LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = e.TariffCategoryId
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = e.AdmissionId
    LEFT JOIN dbo.Users u ON u.Id = e.CreatedBy
    WHERE e.CompanyId = @CompanyId AND e.BranchId = @BranchId AND (@Status IS NULL OR e.Status = @Status)
      AND (@PatientId IS NULL OR e.PatientId = @PatientId)
      AND (@FromDate IS NULL OR e.EstimateDate >= @FromDate) AND (@ToDate IS NULL OR e.EstimateDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)))
      AND (@Search IS NULL OR e.EstimateNo LIKE N'%' + @Search + N'%' OR e.PatientName LIKE N'%' + @Search + N'%' OR e.Phone LIKE N'%' + @Search + N'%')
    ORDER BY e.EstimateDate DESC, e.EstimateId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdPreEstimate_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @EstimateId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.IpdEstimate SET Status = 'CANCELLED', ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE EstimateId = @EstimateId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'ACTIVE';
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, N'Only an active estimate of this branch can be cancelled.' AS Error;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END;
GO

-- ── admission page helpers ──────────────────────────────────────────────────────────────────────────────────
-- Is the picked patient admitted already, and are there active pre-admission estimates to attach?
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_PatientStatus @CompanyId INT, @BranchId INT, @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 a.AdmissionId, a.IpNo, a.AdmissionAt, a.Status, a.BranchId, br.BranchName, b.BedNumber, w.WardName
    FROM dbo.IpdAdmission a
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.Branchmaster br ON br.BranchID = a.BranchId
    WHERE a.PatientId = @PatientId AND a.CompanyId = @CompanyId AND a.IsOpen = 1;
    SELECT e.EstimateId, e.EstimateNo, e.EstimateDate, e.ValidTo, e.TotalAmount, e.PayerType, e.TariffCategoryId, e.BedCategoryId, e.PackageId, e.DoctorId
    FROM dbo.IpdEstimate e
    WHERE e.PatientId = @PatientId AND e.CompanyId = @CompanyId AND e.BranchId = @BranchId AND e.Status = 'ACTIVE' AND (e.ValidTo IS NULL OR e.ValidTo >= CAST(GETDATE() AS DATE))
    ORDER BY e.EstimateDate DESC;
    SELECT TOP 5 a.AdmissionId, a.IpNo, a.AdmissionAt, a.DischargeAt, a.Status FROM dbo.IpdAdmission a
    WHERE a.PatientId = @PatientId AND a.CompanyId = @CompanyId AND a.IsOpen = 0 AND a.Status <> 'CANCELLED' ORDER BY a.AdmissionAt DESC;
END;
GO

-- The consent master text, to preview before it is signed.
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_ConsentTemplate @BranchId INT, @ConsentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.Consent_ID AS Id, c.ConsentType, c.Language, c.Version, c.WitnessRequired, c.ConsentTemplateContent AS ContentHtml, s.HotelName AS HospitalName
    FROM dbo.ConsentMaster c LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId
    WHERE c.Consent_ID = @ConsentId AND c.Status = 1 AND c.Type = 'IPD';
END;
GO

PRINT '2423 IPD procedures - done.';
GO
