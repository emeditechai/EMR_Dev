-- 2572: IPD flow-gap fixes - patient safety and legal (2026-11-28). Needs 2570. Safe to re-run.
--   B1  allergy status before the first medicine order; an order matching a known allergy needs the doctor's reason
--   B2  duplicate medicine (same molecule) and drug interactions (Master > Pharmacy > Drug Interaction) on IPD orders
--   C1  MLC: nature of the case and who brought the patient at admission / edit (police intimation before the final bill, 2575)
--   C2  a death record marks the patient deceased (PatientDeceased): no new admission, booked follow-ups cancelled
--   C3  ward age range (Ward Master Min / Max age in days) on admission, transfer and swap
--   C6  readmission within IpdReadmitDays (30) of the last discharge is flagged on the admission
--   C7  an ICU shift needs the doctor who ordered it
--   B5  code status (Full / DNR / DNI / Limited) by a doctor, with whom it was discussed, logged
--   B11 isolation flag of an admission (contact / droplet / airborne / protective)
-- REPLACES usp_Api_IpdAdmission_Save, usp_Api_IpdAdmission_Update, usp_Api_IpdBed_Transfer, usp_Api_IpdBed_Swap,
-- usp_Api_IpdDischarge_Death, usp_Api_IpdOrder_Save (live definitions + the checks): re-run 2572 after 2423 / 2431 / 2476 /
-- 2493 / 2557 / 2563. Errors 59640-59699 (59650-59689 used here).
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── age text helpers ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_DaysText (@Days INT)
RETURNS NVARCHAR(40)
AS
BEGIN
    RETURN CASE WHEN @Days IS NULL THEN N'?' WHEN @Days < 60 THEN CONCAT(@Days, N' day', CASE WHEN @Days = 1 THEN N'' ELSE N's' END)
                WHEN @Days < 730 THEN CONCAT(@Days / 30, N' months') ELSE CONCAT(@Days / 365, N' years') END;
END;
GO
CREATE OR ALTER FUNCTION dbo.fn_Ipd_AgeRangeText (@MinDays INT, @MaxDays INT)
RETURNS NVARCHAR(80)
AS
BEGIN
    RETURN CASE WHEN @MinDays IS NOT NULL AND @MaxDays IS NOT NULL THEN dbo.fn_Ipd_DaysText(@MinDays) + N' to ' + dbo.fn_Ipd_DaysText(@MaxDays)
                WHEN @MaxDays IS NOT NULL THEN N'up to ' + dbo.fn_Ipd_DaysText(@MaxDays) ELSE dbo.fn_Ipd_DaysText(@MinDays) + N' and above' END;
END;
GO

-- ── B1: the patient's allergy status ─────────────────────────────────────────────────────────────────────────
-- Recorded = something is written (a list, or "No known allergies"); IsNone = written as none / NKDA.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_AllergyStatus (@PatientId INT)
RETURNS TABLE
AS RETURN
(
    SELECT x.Allergies,
           CAST(CASE WHEN x.Allergies IS NULL THEN 0 ELSE 1 END AS BIT) AS Recorded,
           CAST(CASE WHEN UPPER(x.Allergies) IN (N'NIL', N'NONE', N'NKDA', N'NKA', N'NO', N'NA', N'N/A', N'NO KNOWN ALLERGIES', N'NO KNOWN DRUG ALLERGIES') THEN 1 ELSE 0 END AS BIT) AS IsNone
    FROM (SELECT NULLIF(LTRIM(RTRIM(p.KnownAllergies)), N'') AS Allergies FROM dbo.PatientMaster p WHERE p.PatientId = @PatientId) x
);
GO

-- ── B1 / B2: alerts for a medicine about to be ordered for an admission ──────────────────────────────────────
--   ALLERGY      a word of the known allergies (4+ letters) in a molecule of the item, or in the drug / item name
--   INTERACTION  a pair of Master > Pharmacy > Drug Interaction between this item and a running medicine order
--   DUPLICATE    the same molecule in another running medicine order (another brand or route)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_MedAlerts (@CompanyId INT, @AdmissionId INT, @ItemId INT, @DrugName NVARCHAR(250), @ExcludeOrderId INT)
RETURNS TABLE
AS RETURN
(
    WITH me AS (SELECT i.ItemId, i.ItemName, i.GenericId FROM dbo.PhItem i WHERE i.ItemId = @ItemId AND i.CompanyId = @CompanyId),
         mm AS (SELECT m.Molecule FROM me CROSS APPLY dbo.fn_PhMolecules(me.GenericId) m),
         run AS (SELECT o.OrderId, o.ItemId, o.DrugName, i.GenericId FROM dbo.IpdOrder o LEFT JOIN dbo.PhItem i ON i.ItemId = o.ItemId
                 WHERE o.AdmissionId = @AdmissionId AND o.OrderType = 'MED' AND o.Status = 'ACTIVE' AND o.OrderId <> ISNULL(@ExcludeOrderId, 0)
                   AND (o.EndAt IS NULL OR o.EndAt > GETDATE())),
         rm AS (SELECT r.OrderId, r.DrugName, m.Molecule FROM run r CROSS APPLY dbo.fn_PhMolecules(r.GenericId) m),
         al AS (SELECT UPPER(LTRIM(RTRIM(value))) AS Word
                FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                CROSS APPLY STRING_SPLIT(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(p.KnownAllergies, N''), N';', N','), N'/', N','), CHAR(10), N','), N' and ', N','), ',')
                WHERE a.AdmissionId = @AdmissionId AND LEN(LTRIM(RTRIM(value))) >= 4)
    SELECT DISTINCT CAST('ALLERGY' AS VARCHAR(12)) AS Kind, CAST('MAJOR' AS VARCHAR(10)) AS Severity,
           CAST(CONCAT(N'Known allergy "', al.Word, N'" matches ', ISNULL(NULLIF(n.Hit, N''), ISNULL(@DrugName, N'this medicine')), N'.') AS NVARCHAR(400)) AS Message,
           CAST(NULL AS INT) AS OtherOrderId
    FROM al
    CROSS APPLY (SELECT TOP 1 x.Hit FROM (SELECT mm.Molecule AS Hit FROM mm WHERE mm.Molecule LIKE N'%' + al.Word + N'%' OR al.Word LIKE N'%' + mm.Molecule + N'%'
                                          UNION ALL SELECT UPPER(@DrugName) WHERE UPPER(ISNULL(@DrugName, N'')) LIKE N'%' + al.Word + N'%'
                                          UNION ALL SELECT UPPER(me.ItemName) FROM me WHERE UPPER(me.ItemName) LIKE N'%' + al.Word + N'%') x) n
    UNION ALL
    SELECT DISTINCT 'INTERACTION', x.Severity,
           CAST(CONCAT(N'Interaction (', LOWER(x.Severity), N') with ', rm.DrugName, N': ', x.Effect, ISNULL(N' Advice: ' + x.Advice, N'')) AS NVARCHAR(400)), rm.OrderId
    FROM dbo.PhDrugInteraction x
    JOIN mm ON mm.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId1)) OR mm.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId2))
    JOIN rm ON (mm.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId1)) AND rm.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId2)))
            OR (mm.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId2)) AND rm.Molecule IN (SELECT Molecule FROM dbo.fn_PhMolecules(x.GenericId1)))
    WHERE x.CompanyId = @CompanyId AND x.IsActive = 1
    UNION ALL
    SELECT DISTINCT 'DUPLICATE', 'MODERATE', CAST(CONCAT(N'Same medicine already running: ', rm.DrugName, N' also contains ', rm.Molecule, N'.') AS NVARCHAR(400)), rm.OrderId
    FROM rm JOIN mm ON mm.Molecule = rm.Molecule
);
GO

-- alerts for the order form (shown before saving; the save asks the reasons again)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_MedCheck @CompanyId INT, @BranchId INT, @AdmissionId INT, @ItemId INT = NULL, @DrugName NVARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @patient INT = (SELECT PatientId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId);
    IF @patient IS NULL RETURN;
    SELECT s.Allergies, s.Recorded AS AllergyRecorded, s.IsNone AS NoKnownAllergy, g.AllergyStatusRequired FROM dbo.fn_Ipd_AllergyStatus(@patient) s CROSS JOIN dbo.fn_Ipd_GapSettings(@BranchId) g;
    SELECT Kind, Severity, Message, OtherOrderId,
           CAST(CASE WHEN Kind = 'ALLERGY' THEN 'ALLERGY' WHEN Kind = 'DUPLICATE' OR Severity = 'MAJOR' THEN 'INTERACTION' END AS VARCHAR(12)) AS NeedsReason
    FROM dbo.fn_Ipd_MedAlerts(@CompanyId, @AdmissionId, @ItemId, NULLIF(LTRIM(RTRIM(@DrugName)), N''), NULL)
    ORDER BY CASE Kind WHEN 'ALLERGY' THEN 0 WHEN 'INTERACTION' THEN 1 ELSE 2 END;
END;
GO

-- record the allergy status from the IPD banner (writes the patient's Known Allergies)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAllergy_Save @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Allergies NVARCHAR(500) = NULL, @NoKnownAllergy BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @patient INT = (SELECT PatientId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId);
        IF @patient IS NULL THROW 59650, 'The admission was not found in this branch.', 1;
        SET @Allergies = CASE WHEN ISNULL(@NoKnownAllergy, 0) = 1 THEN N'No known allergies' ELSE NULLIF(LTRIM(RTRIM(@Allergies)), N'') END;
        IF @Allergies IS NULL THROW 59651, 'Enter the allergies (medicines, food, others), or tick "No known allergies".', 1;
        DECLARE @old NVARCHAR(500) = (SELECT KnownAllergies FROM dbo.PatientMaster WHERE PatientId = @patient);
        UPDATE dbo.PatientMaster SET KnownAllergies = LEFT(@Allergies, 500), ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE PatientId = @patient;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'ALLERGY', LEFT(CONCAT(N'Allergies: ', @Allergies, CASE WHEN NULLIF(@old, N'') IS NOT NULL THEN N' (was: ' + @old + N')' ELSE N'' END), 500), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @Allergies AS Allergies;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── B5: code status ──────────────────────────────────────────────────────────────────────────────────────────
-- The decision is the doctor's: the doctor's own login, or the doctor chosen (entered by another user). DNR / DNI / Limited
-- need with whom it was discussed (patient / relative) and the reason; Limited needs what is to be done.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCodeStatus_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @CodeStatus VARCHAR(12), @DoctorId INT = NULL,
    @DiscussedWith NVARCHAR(150) = NULL, @Relation NVARCHAR(50) = NULL, @Reason NVARCHAR(500) = NULL, @Limits NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @CodeStatus = UPPER(NULLIF(LTRIM(RTRIM(@CodeStatus)), ''));
        IF @CodeStatus NOT IN ('FULL', 'DNR', 'DNI', 'DNR_DNI', 'LIMITED') THROW 59652, 'Choose the code status.', 1;
        SET @DoctorId = ISNULL(dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId), @DoctorId);
        IF @DoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1)
            THROW 59653, 'Choose the doctor who decided the code status.', 1;
        SELECT @DiscussedWith = NULLIF(LTRIM(RTRIM(@DiscussedWith)), N''), @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N''), @Limits = NULLIF(LTRIM(RTRIM(@Limits)), N'');
        IF @CodeStatus <> 'FULL' AND @DiscussedWith IS NULL THROW 59654, 'Enter with whom the decision was discussed (the patient, or the relative with the relation).', 1;
        IF @CodeStatus <> 'FULL' AND @Reason IS NULL THROW 59655, 'Enter the clinical reason for the decision.', 1;
        IF @CodeStatus = 'LIMITED' AND @Limits IS NULL THROW 59656, 'Limited treatment: write what is and is not to be done (e.g. no intubation, no CPR, continue antibiotics).', 1;
        INSERT dbo.IpdCodeStatusLog (AdmissionId, CodeStatus, DoctorId, DiscussedWith, Relation, Reason, Limits, RecordedBy)
        VALUES (@AdmissionId, @CodeStatus, @DoctorId, @DiscussedWith, NULLIF(LTRIM(RTRIM(@Relation)), N''), @Reason, @Limits, @UserId);
        UPDATE dbo.IpdAdmission SET CodeStatus = @CodeStatus, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'CODE_STATUS', LEFT(CONCAT(N'Code status ', @CodeStatus, N' by Dr ', (SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId),
                ISNULL(N', discussed with ' + @DiscussedWith, N''), ISNULL(N': ' + @Reason, N'')), 500), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @CodeStatus AS CodeStatus;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── B11: isolation of an admission (shown on the banner and the bed board) ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIsolation_Save @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @IsolationType VARCHAR(12) = NULL, @Reason NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @IsolationType = UPPER(NULLIF(LTRIM(RTRIM(@IsolationType)), ''));
        SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
        IF @IsolationType IS NOT NULL AND @IsolationType NOT IN ('CONTACT', 'DROPLET', 'AIRBORNE', 'PROTECTIVE') THROW 59657, 'Choose contact, droplet, airborne or protective isolation.', 1;
        IF @Reason IS NULL THROW 59658, 'Enter the reason (e.g. MRSA, open TB, H1N1, neutropenia; or why isolation ends).', 1;
        UPDATE dbo.IpdAdmission SET IsolationType = @IsolationType, IsolationReason = CASE WHEN @IsolationType IS NULL THEN NULL ELSE @Reason END,
               IsolationSince = CASE WHEN @IsolationType IS NULL THEN NULL WHEN IsolationType IS NULL OR IsolationType <> @IsolationType THEN @now ELSE IsolationSince END,
               ModifiedBy = @UserId, ModifiedDate = @now
        WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'ISOLATION', CONCAT(CASE WHEN @IsolationType IS NULL THEN N'Isolation ended' ELSE N'Isolation: ' + @IsolationType END, N': ', @Reason), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── C2: patients already dead in an active death record ──────────────────────────────────────────────────────
INSERT dbo.PatientDeceased (PatientId, DeceasedAt, AdmissionId, DeathId, Source, RecordedBy)
SELECT a.PatientId, MAX(r.DeathAt), MAX(a.AdmissionId), MAX(r.DeathId), 'IPD', ISNULL(MAX(r.CreatedBy), 1)
FROM dbo.IpdDeathRecord r JOIN dbo.IpdAdmission a ON a.AdmissionId = r.AdmissionId
WHERE r.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM dbo.PatientDeceased d WHERE d.PatientId = a.PatientId)
GROUP BY a.PatientId;
GO

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

-- ── transfer (live + 2572: C3 ward age, C7 ICU order) ──
-- ── transfer: bed / ward / ICU ──────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Transfer
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ToBedId INT, @TransferAt DATETIME = NULL, @Reason NVARCHAR(300),
    @UpdateDepartment BIT = 0, @CanBackdate BIT = 0, @OrderedByDoctorId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @TransferAt = ISNULL(@TransferAt, @now);
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54801, 'Enter the reason for the transfer (e.g. needs ICU care, patient request, isolation).', 1;
        IF @TransferAt > DATEADD(MINUTE, 5, @now) THROW 54802, 'The transfer time cannot be in the future.', 1;
        IF @TransferAt < DATEADD(MINUTE, -30, @now) AND ISNULL(@CanBackdate, 0) = 0 THROW 54803, 'You are not allowed to enter an earlier transfer time (more than 30 minutes back).', 1;
        DECLARE @open BIT, @gender NVARCHAR(20), @patient INT, @fromBed INT, @mv INT, @mvFrom DATETIME;
        SELECT @open = a.IsOpen, @gender = p.Gender, @patient = a.PatientId FROM dbo.IpdAdmission a WITH (UPDLOCK) JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
        IF @open IS NULL THROW 54804, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 54805, 'The admission is closed: the patient cannot be transferred.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND Status = 'BILL_FINAL') THROW 54813, 'The final bill is made: the patient cannot be transferred (cancel the bill first).', 1;
        SELECT @mv = MovementId, @fromBed = BedId, @mvFrom = FromAt FROM dbo.IpdBedMovement WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND ToAt IS NULL;
        IF @mv IS NULL THROW 54806, 'The patient has no current bed.', 1;
        IF @fromBed = @ToBedId THROW 54807, 'Choose a different bed.', 1;
        IF @TransferAt <= @mvFrom THROW 54808, 'The transfer time must be after the patient moved into the current bed.', 1;

        DECLARE @ward INT, @room INT, @cat INT, @bStatus NVARCHAR(30), @bNo NVARCHAR(50), @wGender NVARCHAR(20), @wName NVARCHAR(150), @wDept INT, @toIcu BIT;
        SELECT @ward = b.WardId, @room = b.RoomId, @cat = b.BedCategoryId, @bStatus = b.BedStatus, @bNo = b.BedNumber, @wGender = w.Gender, @wName = w.WardName,
               @wDept = w.DepartmentId, @toIcu = ISNULL(b.IsICU, 0)
        FROM dbo.BedMaster b WITH (UPDLOCK, HOLDLOCK) JOIN dbo.WardMaster w ON w.WardId = b.WardId
        WHERE b.BedId = @ToBedId AND b.BranchId = @BranchId AND b.IsActive = 1;
        IF @ward IS NULL THROW 54809, 'Choose an active bed of this branch.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdBedMovement WITH (UPDLOCK, HOLDLOCK) WHERE BedId = @ToBedId AND ToAt IS NULL)
        BEGIN SET @msg = N'Bed ' + @bNo + N' is occupied. Use Swap to exchange the beds of two patients.'; THROW 54810, @msg, 1; END;
        DECLARE @resId INT = (SELECT ReservationId FROM dbo.IpdBedReservation WHERE BedId = @ToBedId AND Status = 'ACTIVE' AND (PatientId = @patient));
        IF @bStatus <> N'Available' AND NOT (@bStatus = N'Reserved' AND @resId IS NOT NULL)
        BEGIN SET @msg = N'Bed ' + @bNo + N' is ' + @bStatus + N'. Choose an available bed.'; THROW 54811, @msg, 1; END;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_BedRate(@BranchId, @ToBedId, a.TariffCategoryId, CAST(@TransferAt AS DATE)) r WHERE a.AdmissionId = @AdmissionId)
           AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_IcuDailyRate(@BranchId, @ToBedId, a.TariffCategoryId, CAST(@TransferAt AS DATE)) r WHERE a.AdmissionId = @AdmissionId) /* 2493 icu */
        BEGIN SET @msg = N'Bed ' + @bNo + N' has no rate for the patient''s tariff category (Master > IPD > Bed / Room Tariff): it cannot be given.'; THROW 54814, @msg, 1; END;
        IF ISNULL((SELECT IpdBlockWardGenderMismatch FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 1) = 1
           AND @wGender IN (N'Male', N'Female') AND ISNULL(@gender, N'') IN (N'Male', N'Female') AND @wGender <> @gender
        BEGIN SET @msg = @wName + N' is a ' + LOWER(@wGender) + N' ward; the patient is ' + LOWER(@gender) + N'.'; THROW 54812, @msg, 1; END;

        -- 2572 (C3): the ward's age range (Ward Master > Min / Max age in days, e.g. NICU 0-28 days)
        DECLARE @wMin INT, @wMax INT, @ageDays INT;
        SELECT @wMin = MinAgeDays, @wMax = MaxAgeDays FROM dbo.WardMaster WHERE WardId = @ward;
        SELECT @ageDays = DATEDIFF(DAY, DateOfBirth, @TransferAt) FROM dbo.PatientMaster WHERE PatientId = @patient;
        IF @ageDays IS NOT NULL AND ((@wMin IS NOT NULL AND @ageDays < @wMin) OR (@wMax IS NOT NULL AND @ageDays > @wMax))
        BEGIN SET @msg = CONCAT(@wName, N' is for patients aged ', dbo.fn_Ipd_AgeRangeText(@wMin, @wMax), N'; the patient is ', dbo.fn_Ipd_DaysText(@ageDays), N'. Choose a bed in a suitable ward.'); THROW 59662, @msg, 1; END;

        DECLARE @fromNo NVARCHAR(50), @fromWard NVARCHAR(150), @fromIcu BIT;
        SELECT @fromNo = b.BedNumber, @fromWard = w.WardName, @fromIcu = ISNULL(b.IsICU, 0) FROM dbo.BedMaster b JOIN dbo.WardMaster w ON w.WardId = b.WardId WHERE b.BedId = @fromBed;
        DECLARE @kind VARCHAR(12) = CASE WHEN @toIcu = 1 AND @fromIcu = 0 THEN 'ICU_IN' WHEN @toIcu = 0 AND @fromIcu = 1 THEN 'ICU_OUT' ELSE 'TRANSFER' END;
        -- 2572 (C7): an ICU shift is ordered by a doctor
        IF @kind = 'ICU_IN' AND (@OrderedByDoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @OrderedByDoctorId AND CompanyId = @CompanyId AND IsActive = 1))
            THROW 59663, 'An ICU shift needs the doctor who ordered it.', 1;

        UPDATE dbo.IpdBedMovement SET ToAt = @TransferAt, EndType = 'TRANSFER' WHERE MovementId = @mv;
        INSERT dbo.IpdBedMovement (AdmissionId, BedId, WardId, RoomId, BedCategoryId, FromAt, MoveType, Reason, CreatedBy, OrderedByDoctorId)
        VALUES (@AdmissionId, @ToBedId, @ward, @room, @cat, @TransferAt, @kind, LTRIM(RTRIM(@Reason)), @UserId, @OrderedByDoctorId);
        UPDATE dbo.IpdAdmission SET CurrentBedId = @ToBedId, ModifiedBy = @UserId, ModifiedDate = @now,
               DepartmentId = CASE WHEN ISNULL(@UpdateDepartment, 0) = 1 AND @wDept IS NOT NULL THEN @wDept ELSE DepartmentId END
        WHERE AdmissionId = @AdmissionId;
        IF @resId IS NOT NULL UPDATE dbo.IpdBedReservation SET Status = 'USED', AdmissionId = @AdmissionId, ModifiedBy = @UserId, ModifiedDate = @now WHERE ReservationId = @resId;
        EXEC dbo.usp_Ipd_SetBedStatus @BedId = @ToBedId, @ToStatus = N'Occupied', @Reason = N'Patient transferred in', @AdmissionId = @AdmissionId, @UserId = @UserId, @RefType = 'TRANSFER';
        EXEC dbo.usp_Ipd_ReleaseBed @BedId = @fromBed, @AdmissionId = @AdmissionId, @Reason = 'TRANSFER', @UserId = @UserId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, CASE @kind WHEN 'ICU_IN' THEN 'ICU_SHIFT' WHEN 'ICU_OUT' THEN 'ICU_OUT' ELSE 'TRANSFER' END,
                CONCAT(N'Bed ', @fromNo, N' (', @fromWard, N') → ', @bNo, N' (', @wName, N') at ', FORMAT(@TransferAt, 'dd-MMM HH:mm', 'en-US'), N': ', LTRIM(RTRIM(@Reason))), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @AdmissionId AS AdmissionId, @bNo AS BedNumber, @kind AS MoveType;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(0 AS BIT) AS Success, N'The bed was just taken by another patient. Refresh and choose again.' AS Error;
        ELSE IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── swap (live + 2572: C3 ward age) ──
-- ── swap the beds of two admitted patients ──────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBed_Swap @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @OtherAdmissionId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    DECLARE @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54821, 'Enter the reason for the swap.', 1;
        IF @AdmissionId = @OtherAdmissionId THROW 54822, 'Choose another patient to swap with.', 1;
        DECLARE @A TABLE (Seq INT, AdmissionId INT, Gender NVARCHAR(20), Mv INT, BedId INT, BedNo NVARCHAR(50), WardId INT, RoomId INT, CatId INT, WGender NVARCHAR(20), WName NVARCHAR(150), IpNo NVARCHAR(40));
        INSERT @A
        SELECT CASE WHEN a.AdmissionId = @AdmissionId THEN 1 ELSE 2 END, a.AdmissionId, p.Gender, m.MovementId, m.BedId, b.BedNumber, b.WardId, b.RoomId, b.BedCategoryId, w.Gender, w.WardName, a.IpNo
        FROM dbo.IpdAdmission a WITH (UPDLOCK) JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        JOIN dbo.IpdBedMovement m WITH (UPDLOCK) ON m.AdmissionId = a.AdmissionId AND m.ToAt IS NULL
        JOIN dbo.BedMaster b ON b.BedId = m.BedId JOIN dbo.WardMaster w ON w.WardId = b.WardId
        WHERE a.AdmissionId IN (@AdmissionId, @OtherAdmissionId) AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1 AND a.Status <> 'BILL_FINAL';
        IF (SELECT COUNT(*) FROM @A) <> 2 THROW 54823, 'Both patients must be admitted in this branch with a current bed, and neither may have a final bill.', 1;
        IF ISNULL((SELECT IpdBlockWardGenderMismatch FROM dbo.HospitalSettings WHERE BranchID = @BranchId), 1) = 1
           AND EXISTS (SELECT 1 FROM @A x JOIN @A y ON y.Seq <> x.Seq WHERE y.WGender IN (N'Male', N'Female') AND x.Gender IN (N'Male', N'Female') AND y.WGender <> x.Gender)
            THROW 54824, 'A patient would move into a ward of the other gender.', 1;
        -- 2572 (C3): each patient must fit the age range of the other's ward
        DECLARE @ageMsg NVARCHAR(400) = (SELECT TOP 1 CONCAT(w.WardName, N' is for patients aged ', dbo.fn_Ipd_AgeRangeText(w.MinAgeDays, w.MaxAgeDays), N'; ', x.IpNo, N' is ',
                                                   dbo.fn_Ipd_DaysText(DATEDIFF(DAY, p.DateOfBirth, @now)), N'.')
                                          FROM @A x JOIN @A y ON y.Seq <> x.Seq JOIN dbo.WardMaster w ON w.WardId = y.WardId
                                          JOIN dbo.IpdAdmission a ON a.AdmissionId = x.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                                          WHERE p.DateOfBirth IS NOT NULL AND ((w.MinAgeDays IS NOT NULL AND DATEDIFF(DAY, p.DateOfBirth, @now) < w.MinAgeDays)
                                                OR (w.MaxAgeDays IS NOT NULL AND DATEDIFF(DAY, p.DateOfBirth, @now) > w.MaxAgeDays)));
        IF @ageMsg IS NOT NULL THROW 59662, @ageMsg, 1;
        UPDATE m SET ToAt = @now, EndType = 'SWAP' FROM dbo.IpdBedMovement m JOIN @A x ON x.Mv = m.MovementId;
        INSERT dbo.IpdBedMovement (AdmissionId, BedId, WardId, RoomId, BedCategoryId, FromAt, MoveType, Reason, CreatedBy)
        SELECT x.AdmissionId, y.BedId, y.WardId, y.RoomId, y.CatId, @now, 'SWAP', LTRIM(RTRIM(@Reason)), @UserId FROM @A x JOIN @A y ON y.Seq <> x.Seq;
        UPDATE a SET CurrentBedId = y.BedId, ModifiedBy = @UserId, ModifiedDate = @now
        FROM dbo.IpdAdmission a JOIN @A x ON x.AdmissionId = a.AdmissionId JOIN @A y ON y.Seq <> x.Seq;
        INSERT dbo.IpdBedStatusLog (BedId, FromStatus, ToStatus, Reason, AdmissionId, RefType, CreatedBy)
        SELECT y.BedId, N'Occupied', N'Occupied', N'Beds swapped with ' + x.IpNo, x.AdmissionId, 'SWAP', @UserId FROM @A x JOIN @A y ON y.Seq <> x.Seq;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT x.AdmissionId, 'SWAP', CONCAT(N'Bed ', x.BedNo, N' (', x.WName, N') swapped with ', y.IpNo, N' → ', y.BedNo, N' (', y.WName, N'): ', LTRIM(RTRIM(@Reason))), @UserId
        FROM @A x JOIN @A y ON y.Seq <> x.Seq;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── death record (live + 2572: C2 deceased) ──
-- ── 8. death record (MCCD Form 4 / 4A data, death register no.) ──────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Death
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @DeathAt DATETIME = NULL, @FormType VARCHAR(3) = '4',
    @CauseImmediate NVARCHAR(300) = NULL, @IntervalImmediate NVARCHAR(50) = NULL, @CauseAntecedent NVARCHAR(300) = NULL, @IntervalAntecedent NVARCHAR(50) = NULL,
    @CauseUnderlying NVARCHAR(300) = NULL, @IntervalUnderlying NVARCHAR(50) = NULL, @UnderlyingIcd NVARCHAR(10) = NULL, @OtherConditions NVARCHAR(500) = NULL,
    @MannerOfDeath VARCHAR(12) = NULL, @PregnancyStatus VARCHAR(12) = NULL, @DeliveryInvolved BIT = 0, @PoliceIntimated BIT = 0, @PoliceStation NVARCHAR(150) = NULL,
    @PostMortem BIT = 0, @CertifiedByDoctorId INT = NULL, @BodyHandedTo NVARCHAR(150) = NULL, @BodyHandedRelation NVARCHAR(50) = NULL, @BodyHandedAt DATETIME = NULL,
    @Remarks NVARCHAR(500) = NULL, @VoidReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @mlc BIT, @gender NVARCHAR(20), @status VARCHAR(20);
        SELECT @admAt = a.AdmissionAt, @mlc = a.IsMlc, @gender = p.Gender, @status = a.Status FROM dbo.IpdAdmission a WITH (UPDLOCK) JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE a.AdmissionId = @AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
        IF @admAt IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        DECLARE @id INT, @type VARCHAR(12), @dstatus VARCHAR(12);
        SELECT TOP 1 @id = DischargeId, @type = DischargeType, @dstatus = Status FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status <> 'CANCELLED' ORDER BY DischargeId DESC;
        IF @id IS NULL OR @type <> 'DEATH' THROW 58480, 'Advise the discharge with the type Death first.', 1;
        DECLARE @live INT = (SELECT DeathId FROM dbo.IpdDeathRecord WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND IsActive = 1);
        IF NULLIF(LTRIM(RTRIM(@VoidReason)), N'') IS NOT NULL
        BEGIN
            IF @live IS NULL THROW 58481, 'There is no death record to void.', 1;
            IF @dstatus = 'DISCHARGED' THROW 58482, 'The body is handed over (gate pass made): the death record can be corrected, not voided.', 1;
            UPDATE dbo.IpdDeathRecord SET IsActive = 0, VoidReason = LTRIM(RTRIM(@VoidReason)), ModifiedBy = @UserId, ModifiedDate = @now WHERE DeathId = @live;
        END
        ELSE
        BEGIN
            IF @DeathAt IS NULL OR @DeathAt < @admAt OR @DeathAt > DATEADD(MINUTE, 5, @now) THROW 58483, 'Enter the date and time of death (after the admission, not in the future).', 1;
            IF NULLIF(LTRIM(RTRIM(@CauseImmediate)), N'') IS NULL THROW 58484, 'Enter the immediate cause of death (Part I a).', 1;
            SET @MannerOfDeath = UPPER(ISNULL(@MannerOfDeath, ''));
            IF @MannerOfDeath NOT IN ('NATURAL', 'ACCIDENT', 'SUICIDE', 'HOMICIDE', 'PENDING') THROW 58485, 'Choose the manner of death.', 1;
            IF (@MannerOfDeath <> 'NATURAL' OR @mlc = 1) AND ISNULL(@PoliceIntimated, 0) = 0 THROW 58486, 'A medico-legal / unnatural death must be intimated to the police: tick it and enter the police station.', 1;
            IF ISNULL(@PoliceIntimated, 0) = 1 AND NULLIF(LTRIM(RTRIM(@PoliceStation)), N'') IS NULL THROW 58487, 'Enter the police station intimated.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @CertifiedByDoctorId AND IsActive = 1) THROW 58488, 'Choose the doctor certifying the cause of death.', 1;
            IF @FormType NOT IN ('4', '4A') SET @FormType = '4';
            IF @gender LIKE N'F%' AND NULLIF(@PregnancyStatus, '') IS NULL THROW 58489, 'For a female patient, record whether the death was associated with pregnancy.', 1;
            IF @BodyHandedAt IS NOT NULL AND @BodyHandedAt < @DeathAt THROW 58490, 'The body cannot be handed over before the time of death.', 1;
            IF @live IS NULL
            BEGIN
                DECLARE @no NVARCHAR(40);
                EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'DTH', @DocDate = @DeathAt, @DocNo = @no OUTPUT;
                INSERT dbo.IpdDeathRecord (CompanyId, BranchId, AdmissionId, DischargeId, DeathRegNo, DeathAt, FormType, CauseImmediate, MannerOfDeath, CertifiedByDoctorId, CreatedBy)
                VALUES (@CompanyId, @BranchId, @AdmissionId, @id, @no, @DeathAt, @FormType, LTRIM(RTRIM(@CauseImmediate)), @MannerOfDeath, @CertifiedByDoctorId, @UserId);
                SET @live = CAST(SCOPE_IDENTITY() AS INT);
            END
            UPDATE dbo.IpdDeathRecord SET DeathAt = @DeathAt, FormType = @FormType, CauseImmediate = LTRIM(RTRIM(@CauseImmediate)), IntervalImmediate = NULLIF(LTRIM(RTRIM(@IntervalImmediate)), N''),
                   CauseAntecedent = NULLIF(LTRIM(RTRIM(@CauseAntecedent)), N''), IntervalAntecedent = NULLIF(LTRIM(RTRIM(@IntervalAntecedent)), N''),
                   CauseUnderlying = NULLIF(LTRIM(RTRIM(@CauseUnderlying)), N''), IntervalUnderlying = NULLIF(LTRIM(RTRIM(@IntervalUnderlying)), N''),
                   UnderlyingIcd = NULLIF(LTRIM(RTRIM(@UnderlyingIcd)), N''), OtherConditions = NULLIF(LTRIM(RTRIM(@OtherConditions)), N''), MannerOfDeath = @MannerOfDeath,
                   PregnancyStatus = NULLIF(@PregnancyStatus, ''), DeliveryInvolved = ISNULL(@DeliveryInvolved, 0), PoliceIntimated = ISNULL(@PoliceIntimated, 0),
                   PoliceStation = NULLIF(LTRIM(RTRIM(@PoliceStation)), N''), PostMortem = ISNULL(@PostMortem, 0), CertifiedByDoctorId = @CertifiedByDoctorId,
                   BodyHandedTo = NULLIF(LTRIM(RTRIM(@BodyHandedTo)), N''), BodyHandedRelation = NULLIF(LTRIM(RTRIM(@BodyHandedRelation)), N''), BodyHandedAt = @BodyHandedAt,
                   Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), ModifiedBy = @UserId, ModifiedDate = @now
            WHERE DeathId = @live;
        END
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'DEATH_RECORD', @status, @status, CASE WHEN NULLIF(LTRIM(RTRIM(@VoidReason)), N'') IS NOT NULL THEN N'Death record voided: ' + LTRIM(RTRIM(@VoidReason))
                ELSE CONCAT(N'Death recorded ', FORMAT(@DeathAt, 'dd-MMM-yyyy HH:mm'), N' (', (SELECT DeathRegNo FROM dbo.IpdDeathRecord WHERE DeathId = @live), N')') END, @UserId);
        -- 2572 (C2): the patient is marked deceased while an active death record exists; booked follow-ups are cancelled
        DECLARE @pdPatient INT = (SELECT PatientId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId);
        DECLARE @pdDeath INT, @pdAt DATETIME;
        SELECT TOP 1 @pdDeath = DeathId, @pdAt = DeathAt FROM dbo.IpdDeathRecord WHERE AdmissionId = @AdmissionId AND IsActive = 1 ORDER BY DeathId DESC;
        IF @pdDeath IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.PatientDeceased WHERE PatientId = @pdPatient)
                UPDATE dbo.PatientDeceased SET DeceasedAt = @pdAt, AdmissionId = @AdmissionId, DeathId = @pdDeath, RecordedBy = @UserId, RecordedAt = @now WHERE PatientId = @pdPatient;
            ELSE INSERT dbo.PatientDeceased (PatientId, DeceasedAt, AdmissionId, DeathId, Source, RecordedBy) VALUES (@pdPatient, @pdAt, @AdmissionId, @pdDeath, 'IPD', @UserId);
            UPDATE dbo.IpdFollowUp SET Status = 'CANCELLED', CancelReason = N'Patient deceased', ModifiedBy = @UserId, ModifiedDate = @now
            WHERE PatientId = @pdPatient AND Status = 'BOOKED';
        END
        ELSE DELETE dbo.PatientDeceased WHERE PatientId = @pdPatient AND AdmissionId = @AdmissionId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, (SELECT DeathRegNo FROM dbo.IpdDeathRecord WHERE DeathId = @live) AS DeathRegNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── CPOE order (live + 2572: B1 allergy, B2 duplicate / interaction) ──
-- ── CPOE: a new order ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @OrderType VARCHAR(10), @Priority VARCHAR(10) = 'ROUTINE',
    @DoctorId INT = NULL, @Source VARCHAR(10) = NULL, @ReadBack BIT = 0,
    @ItemId INT = NULL, @DrugName NVARCHAR(250) = NULL, @Dose NVARCHAR(60) = NULL, @Route VARCHAR(20) = NULL, @FrequencyCode VARCHAR(10) = NULL,
    @StartAt DATETIME = NULL, @DurationDays INT = NULL,
    @ServiceKind VARCHAR(10) = NULL, @RefId INT = NULL, @Qty DECIMAL(10,2) = NULL,
    @DietType NVARCHAR(60) = NULL, @Details NVARCHAR(1000) = NULL,
    @AllergyOverride NVARCHAR(300) = NULL, @InteractionOverride NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SELECT @OrderType = UPPER(@OrderType), @Priority = ISNULL(NULLIF(UPPER(@Priority), ''), 'ROUTINE'),
               @Details = NULLIF(LTRIM(RTRIM(@Details)), N''), @DrugName = NULLIF(LTRIM(RTRIM(@DrugName)), N''), @Dose = NULLIF(LTRIM(RTRIM(@Dose)), N'');
        IF @OrderType NOT IN ('MED', 'SERVICE', 'DIET', 'NURSING') THROW 59240, 'Choose the kind of order.', 1;
        IF @Priority NOT IN ('ROUTINE', 'URGENT', 'STAT') THROW 59241, 'Choose the priority: routine, urgent or stat.', 1;

        -- who orders: a doctor directly; anyone else a verbal / telephone order of a doctor, read back, countersigned later
        DECLARE @my INT = dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId), @due DATETIME = NULL;
        IF @my IS NOT NULL AND (@DoctorId IS NULL OR @DoctorId = @my)
            SELECT @DoctorId = @my, @Source = 'DIRECT', @ReadBack = 0;
        ELSE
        BEGIN
            SET @Source = UPPER(ISNULL(NULLIF(@Source, ''), 'VERBAL'));
            IF @Source NOT IN ('VERBAL', 'TELEPHONE') THROW 59242, 'An order for another doctor is a verbal or telephone order: choose which.', 1;
            IF @DoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1)
                THROW 59243, 'Choose the doctor who gave the order.', 1;
            IF ISNULL(@ReadBack, 0) = 0 THROW 59244, 'Read the order back to the doctor and tick "Read back and confirmed".', 1;
            SET @due = DATEADD(HOUR, ISNULL((SELECT TOP (1) IpdCountersignHours FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 24), @now);
        END

        DECLARE @serviceName NVARCHAR(250) = NULL, @high BIT = 0, @end DATETIME = NULL;
        IF @OrderType = 'MED'
        BEGIN
            IF @ItemId IS NOT NULL
            BEGIN
                SELECT @DrugName = ISNULL(@DrugName, ItemName), @high = ISNULL(IsHighAlert, 0)
                FROM dbo.PhItem WHERE ItemId = @ItemId AND CompanyId = @CompanyId AND IsActive = 1;
                IF @@ROWCOUNT = 0 THROW 59245, 'The medicine was not found in the Pharmacy Item Master.', 1;
            END
            IF @DrugName IS NULL THROW 59246, 'Choose the medicine (or type its name).', 1;
            IF @Dose IS NULL THROW 59247, 'Enter the dose (e.g. 500 mg, 1 tab, 10 units).', 1;
            SET @Route = UPPER(NULLIF(@Route, ''));
            IF @Route IS NULL OR @Route NOT IN ('PO', 'IV', 'IM', 'SC', 'SL', 'INH', 'NEB', 'TOP', 'PR', 'PV', 'RT', 'ID', 'EYE', 'EAR', 'NASAL', 'TD', 'OTHER')
                THROW 59248, 'Choose the route.', 1;
            DECLARE @fk VARCHAR(10) = (SELECT Kind FROM dbo.IpdFrequency WHERE FrequencyCode = @FrequencyCode AND IsActive = 1);
            IF @fk IS NULL THROW 59249, 'Choose the frequency.', 1;
            SET @StartAt = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @StartAt), 0), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @now), 0));
            IF @StartAt < DATEADD(HOUR, -1, @now) OR @StartAt < @admAt THROW 59250, 'The start cannot be in the past (or before the admission).', 1;
            IF @StartAt > DATEADD(DAY, 7, @now) THROW 59251, 'The start can be at most 7 days ahead.', 1;
            IF @fk = 'STAT' SELECT @Priority = 'STAT', @DurationDays = NULL;
            IF @DurationDays IS NOT NULL AND @DurationDays NOT BETWEEN 1 AND 90 THROW 59252, 'The duration must be 1 to 90 days.', 1;
            IF @DurationDays IS NOT NULL SET @end = DATEADD(DAY, @DurationDays, @StartAt);
            IF @fk <> 'STAT' AND EXISTS (SELECT 1 FROM dbo.IpdOrder WHERE AdmissionId = @AdmissionId AND OrderType = 'MED' AND Status = 'ACTIVE' AND Route = @Route
                       AND ((@ItemId IS NOT NULL AND ItemId = @ItemId) OR (@ItemId IS NULL AND DrugName = @DrugName))
                       AND (EndAt IS NULL OR EndAt > @StartAt))
            BEGIN
                SET @msg = @DrugName + N' (' + @Route + N') is already ordered and running: stop that order first to change the dose or frequency.';
                THROW 59253, @msg, 1;
            END
            -- 2572 (B1): the allergy status is recorded before the first medicine order (Hospital Settings IpdAllergyStatusRequired)
            IF (SELECT AllergyStatusRequired FROM dbo.fn_Ipd_GapSettings(@BranchId)) = 1
               AND (SELECT s.Recorded FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_AllergyStatus(a.PatientId) s WHERE a.AdmissionId = @AdmissionId) = 0
                THROW 59664, 'Record the patient''s allergy status first (banner > Allergies; tick "No known allergies" if none).', 1;
            -- 2572 (B1 / B2): a known allergy, a major interaction or the same medicine running needs the doctor's reason
            SELECT @AllergyOverride = NULLIF(LTRIM(RTRIM(@AllergyOverride)), N''), @InteractionOverride = NULLIF(LTRIM(RTRIM(@InteractionOverride)), N'');
            DECLARE @alert NVARCHAR(400) = (SELECT TOP 1 Message FROM dbo.fn_Ipd_MedAlerts(@CompanyId, @AdmissionId, @ItemId, @DrugName, NULL) WHERE Kind = 'ALLERGY');
            IF @alert IS NOT NULL AND @AllergyOverride IS NULL
            BEGIN SET @msg = @alert + N' Enter the reason to order it anyway.'; THROW 59665, @msg, 1; END
            SET @alert = (SELECT TOP 1 Message FROM dbo.fn_Ipd_MedAlerts(@CompanyId, @AdmissionId, @ItemId, @DrugName, NULL) WHERE Kind = 'DUPLICATE' OR (Kind = 'INTERACTION' AND Severity = 'MAJOR')
                          ORDER BY CASE WHEN Kind = 'INTERACTION' THEN 0 ELSE 1 END);
            IF @alert IS NOT NULL AND @InteractionOverride IS NULL
            BEGIN SET @msg = @alert + N' Enter the reason to order it anyway.'; THROW 59666, @msg, 1; END
        END
        ELSE IF @OrderType = 'SERVICE'
        BEGIN
            IF @st = 'BILL_FINAL' THROW 59254, 'The final bill is made: services cannot be ordered (cancel the bill first).', 1;
            SET @ServiceKind = UPPER(@ServiceKind);
            IF @ServiceKind = 'SERVICE'
                SELECT @serviceName = ServiceName FROM dbo.HospitalServiceMaster WHERE HospitalServiceId = @RefId AND BranchId = @BranchId AND IsActive = 1;
            ELSE IF @ServiceKind = 'PROCEDURE'
                SELECT @serviceName = ProcedureName FROM dbo.ProcedureMaster WHERE ProcedureId = @RefId AND BranchId = @BranchId AND IsActive = 1;
            IF @serviceName IS NULL THROW 59255, 'Choose the service or procedure.', 1;
            SET @Qty = ISNULL(@Qty, 1);
            IF @Qty <= 0 OR @Qty > 100 THROW 59256, 'The quantity must be 1 to 100.', 1;
        END
        ELSE IF @OrderType = 'DIET'
        BEGIN
            SET @DietType = NULLIF(LTRIM(RTRIM(@DietType)), N'');
            IF @DietType IS NULL THROW 59257, 'Choose the diet.', 1;
        END
        ELSE IF @Details IS NULL THROW 59258, 'Write the nursing instruction.', 1;

        INSERT dbo.IpdOrder (AdmissionId, OrderType, Priority, DoctorId, OrderedBy, OrderedAt, Source, ReadBack, CountersignDueAt, Status,
               ItemId, DrugName, Dose, Route, FrequencyCode, StartAt, EndAt, IsHighAlert, ServiceKind, RefId, ServiceName, Qty, DietType, Details, AllergyOverride, InteractionOverride)
        VALUES (@AdmissionId, @OrderType, @Priority, @DoctorId, @UserId, @now, @Source, ISNULL(@ReadBack, 0), @due, 'ACTIVE',
               CASE WHEN @OrderType = 'MED' THEN @ItemId END, CASE WHEN @OrderType = 'MED' THEN @DrugName END, CASE WHEN @OrderType = 'MED' THEN @Dose END,
               CASE WHEN @OrderType = 'MED' THEN @Route END, CASE WHEN @OrderType = 'MED' THEN @FrequencyCode END, CASE WHEN @OrderType = 'MED' THEN @StartAt END,
               @end, @high, CASE WHEN @OrderType = 'SERVICE' THEN @ServiceKind END, CASE WHEN @OrderType = 'SERVICE' THEN @RefId END, @serviceName,
               CASE WHEN @OrderType = 'SERVICE' THEN @Qty END, CASE WHEN @OrderType = 'DIET' THEN @DietType END, @Details,
               CASE WHEN @OrderType = 'MED' THEN @AllergyOverride END, CASE WHEN @OrderType = 'MED' THEN @InteractionOverride END);
        DECLARE @id INT = SCOPE_IDENTITY();
        -- one diet at a time: the new diet order replaces the running one
        IF @OrderType = 'DIET'
            UPDATE dbo.IpdOrder SET Status = 'COMPLETED', StoppedAt = @now, StoppedBy = @UserId, StopReason = N'Replaced by a new diet order'
            WHERE AdmissionId = @AdmissionId AND OrderType = 'DIET' AND Status = 'ACTIVE' AND OrderId <> @id;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS OrderId, @Source AS Source, @due AS CountersignDueAt, @high AS IsHighAlert;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO


PRINT '2572 IPD flow-gap safety - done.';
GO
