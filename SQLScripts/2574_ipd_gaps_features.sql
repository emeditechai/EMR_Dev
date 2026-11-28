-- 2574: IPD flow-gap fixes - transfusion, restraint, newborn (2026-11-28). Needs 2570, 2573. Safe to re-run.
--   B11 blood transfusion: order (indication, consent) -> bedside check by two people (bag no., group, expiry, crossmatch,
--       ABO / Rh compatibility) -> start (pre vitals) -> 15-minute vitals -> complete (post vitals, volume) or stop on a reaction
--       (escalated to the doctor)
--   B11 restraint: doctor's order (reason, alternatives tried), checks every 2 hours, renewal after 24 hours, release
--   C4  newborn: the baby's admission linked to the mother's (birth time, weight, delivery, Apgar)
-- Errors 59800-59899.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── ABO / Rh compatibility of a component (red cells: the donor's cells; plasma: the donor's antibodies) ──────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BloodCompatible (@Component VARCHAR(10), @Patient VARCHAR(5), @Bag VARCHAR(5))
RETURNS BIT
AS
BEGIN
    DECLARE @pa VARCHAR(3) = REPLACE(REPLACE(UPPER(@Patient), '+', ''), '-', ''), @ba VARCHAR(3) = REPLACE(REPLACE(UPPER(@Bag), '+', ''), '-', ''),
            @pneg BIT = CASE WHEN @Patient LIKE '%-' THEN 1 ELSE 0 END, @bneg BIT = CASE WHEN @Bag LIKE '%-' THEN 1 ELSE 0 END;
    IF @pa NOT IN ('O', 'A', 'B', 'AB') OR @ba NOT IN ('O', 'A', 'B', 'AB') RETURN 0;
    IF @Component = 'WB' RETURN CASE WHEN @pa = @ba AND (@pneg = 0 OR @bneg = 1) THEN 1 ELSE 0 END;
    IF @Component = 'PRBC'
        RETURN CASE WHEN (@pa = 'AB' OR @ba = 'O' OR @pa = @ba) AND (@pneg = 0 OR @bneg = 1) THEN 1 ELSE 0 END;
    IF @Component IN ('FFP', 'CRYO')
        RETURN CASE WHEN @ba = 'AB' OR @pa = 'O' OR @pa = @ba THEN 1 ELSE 0 END;
    RETURN 1;   -- platelets: ABO-matched preferred, not refused
END;
GO

-- ── transfusion: one procedure, one step per call ────────────────────────────────────────────────────────────
-- @Action ORDER | CHECK | START | VITALS15 | COMPLETE | REACTION | CANCEL
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdTransfusion_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Action VARCHAR(10), @TransfusionId INT = NULL,
    @Component VARCHAR(10) = NULL, @Units INT = NULL, @Indication NVARCHAR(300) = NULL, @DoctorId INT = NULL,
    @ConsentBy NVARCHAR(150) = NULL, @ConsentRelation NVARCHAR(50) = NULL, @PatientBloodGroup VARCHAR(5) = NULL,
    @BagNo NVARCHAR(40) = NULL, @BagBloodGroup VARCHAR(5) = NULL, @BagExpiry DATE = NULL, @CrossmatchNo NVARCHAR(40) = NULL, @CheckedBy2Name NVARCHAR(150) = NULL,
    @Vitals NVARCHAR(200) = NULL, @VolumeMl INT = NULL, @ReactionType NVARCHAR(100) = NULL, @ReactionAction NVARCHAR(500) = NULL, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @Action = UPPER(@Action);
        SELECT @Indication = NULLIF(LTRIM(RTRIM(@Indication)), N''), @ConsentBy = NULLIF(LTRIM(RTRIM(@ConsentBy)), N''), @BagNo = NULLIF(LTRIM(RTRIM(@BagNo)), N''),
               @CheckedBy2Name = NULLIF(LTRIM(RTRIM(@CheckedBy2Name)), N''), @Vitals = NULLIF(LTRIM(RTRIM(@Vitals)), N''), @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N''),
               @PatientBloodGroup = UPPER(NULLIF(LTRIM(RTRIM(@PatientBloodGroup)), '')), @BagBloodGroup = UPPER(NULLIF(LTRIM(RTRIM(@BagBloodGroup)), ''));
        IF @Action = 'ORDER'
        BEGIN
            SET @Component = UPPER(@Component);
            IF @Component NOT IN ('WB', 'PRBC', 'FFP', 'PLT', 'SDP', 'CRYO') THROW 59800, 'Choose the blood component.', 1;
            IF ISNULL(@Units, 0) NOT BETWEEN 1 AND 20 THROW 59801, 'The units must be 1 to 20.', 1;
            IF @Indication IS NULL THROW 59802, 'Enter the indication (e.g. Hb 6.2 g/dL with symptoms, active bleeding, INR 3.5 before surgery).', 1;
            SET @DoctorId = ISNULL(dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId), @DoctorId);
            IF @DoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1)
                THROW 59803, 'Choose the doctor who ordered the transfusion.', 1;
            IF @ConsentBy IS NULL THROW 59804, 'Record who signed the transfusion consent (patient or relative).', 1;
            SET @PatientBloodGroup = ISNULL(@PatientBloodGroup, (SELECT p.BloodGroup FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId WHERE a.AdmissionId = @AdmissionId));
            IF @PatientBloodGroup IS NULL OR @PatientBloodGroup NOT IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')
                THROW 59805, 'Enter the patient''s blood group (as grouped by the blood bank).', 1;
            INSERT dbo.IpdTransfusion (AdmissionId, Component, Units, Indication, OrderedByDoctorId, OrderedAt, ConsentBy, ConsentRelation, ConsentAt, PatientBloodGroup, CreatedBy)
            VALUES (@AdmissionId, @Component, @Units, @Indication, @DoctorId, @now, @ConsentBy, NULLIF(LTRIM(RTRIM(@ConsentRelation)), N''), @now, @PatientBloodGroup, @UserId);
            SET @TransfusionId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            DECLARE @ts VARCHAR(10), @comp VARCHAR(10), @pg VARCHAR(5), @startAt DATETIME;
            SELECT @ts = Status, @comp = Component, @pg = PatientBloodGroup, @startAt = StartAt FROM dbo.IpdTransfusion WITH (UPDLOCK)
            WHERE TransfusionId = @TransfusionId AND AdmissionId = @AdmissionId;
            IF @ts IS NULL THROW 59806, 'The transfusion was not found.', 1;
            IF @Action = 'CHECK'
            BEGIN
                IF @ts <> 'ORDERED' THROW 59807, 'Only an ordered transfusion is checked at the bedside.', 1;
                IF @BagNo IS NULL OR @CrossmatchNo IS NULL THROW 59808, 'Enter the bag number and the crossmatch / compatibility report number.', 1;
                IF @BagBloodGroup IS NULL OR @BagBloodGroup NOT IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-') THROW 59809, 'Enter the blood group on the bag.', 1;
                IF @BagExpiry IS NULL OR @BagExpiry < CAST(@now AS DATE) THROW 59810, 'The bag is expired (or the expiry is missing): do not transfuse; return it to the blood bank.', 1;
                IF dbo.fn_Ipd_BloodCompatible(@comp, @pg, @BagBloodGroup) = 0
                BEGIN SET @msg = CONCAT(N'INCOMPATIBLE: a ', @BagBloodGroup, N' ', @comp, N' bag for a ', @pg, N' patient. Do not transfuse; return the bag to the blood bank.'); THROW 59811, @msg, 1; END
                IF @CheckedBy2Name IS NULL THROW 59812, 'Enter the second person who checked the bag with you at the bedside.', 1;
                UPDATE dbo.IpdTransfusion SET BagNo = @BagNo, BagBloodGroup = @BagBloodGroup, BagExpiry = @BagExpiry, CrossmatchNo = LTRIM(RTRIM(@CrossmatchNo)), CheckedBy1 = @UserId,
                       CheckedBy2Name = @CheckedBy2Name, CheckedAt = @now, Status = 'CHECKED', ModifiedBy = @UserId, ModifiedDate = @now WHERE TransfusionId = @TransfusionId;
            END
            ELSE IF @Action = 'START'
            BEGIN
                IF @ts <> 'CHECKED' THROW 59813, 'Check the bag at the bedside (two people) before starting.', 1;
                IF @Vitals IS NULL THROW 59814, 'Enter the vitals before the start (BP, pulse, temperature, RR, SpO2).', 1;
                UPDATE dbo.IpdTransfusion SET StartAt = @now, PreVitals = @Vitals, Status = 'STARTED', ModifiedBy = @UserId, ModifiedDate = @now WHERE TransfusionId = @TransfusionId;
            END
            ELSE IF @Action = 'VITALS15'
            BEGIN
                IF @ts <> 'STARTED' THROW 59815, 'The transfusion is not running.', 1;
                IF @Vitals IS NULL THROW 59816, 'Enter the vitals 15 minutes after the start.', 1;
                UPDATE dbo.IpdTransfusion SET Vitals15 = @Vitals, ModifiedBy = @UserId, ModifiedDate = @now WHERE TransfusionId = @TransfusionId;
            END
            ELSE IF @Action = 'COMPLETE'
            BEGIN
                IF @ts <> 'STARTED' THROW 59815, 'The transfusion is not running.', 1;
                IF (SELECT Vitals15 FROM dbo.IpdTransfusion WHERE TransfusionId = @TransfusionId) IS NULL THROW 59817, 'Record the 15-minute vitals first.', 1;
                IF @Vitals IS NULL THROW 59818, 'Enter the vitals at the end.', 1;
                IF ISNULL(@VolumeMl, 0) NOT BETWEEN 1 AND 2000 THROW 59819, 'Enter the volume transfused (ml).', 1;
                UPDATE dbo.IpdTransfusion SET EndAt = @now, PostVitals = @Vitals, VolumeMl = @VolumeMl, Status = 'COMPLETED', ModifiedBy = @UserId, ModifiedDate = @now WHERE TransfusionId = @TransfusionId;
            END
            ELSE IF @Action = 'REACTION'
            BEGIN
                IF @ts <> 'STARTED' THROW 59815, 'The transfusion is not running.', 1;
                SET @ReactionType = NULLIF(LTRIM(RTRIM(@ReactionType)), N''); SET @ReactionAction = NULLIF(LTRIM(RTRIM(@ReactionAction)), N'');
                IF @ReactionType IS NULL OR @ReactionAction IS NULL THROW 59820, 'Enter the reaction (e.g. fever, rash, breathlessness) and what was done (stopped, line kept open with NS, doctor informed, bag sent back).', 1;
                UPDATE dbo.IpdTransfusion SET EndAt = @now, PostVitals = @Vitals, VolumeMl = @VolumeMl, Reaction = 1, ReactionType = @ReactionType, ReactionAction = @ReactionAction,
                       Status = 'STOPPED', ModifiedBy = @UserId, ModifiedDate = @now WHERE TransfusionId = @TransfusionId;
                DECLARE @esc INT, @et NVARCHAR(300) = CONCAT(N'Transfusion reaction (', @comp, N'): ', @ReactionType, N'. ', @ReactionAction);
                EXEC dbo.usp_Ipd_RaiseEscalation @AdmissionId = @AdmissionId, @Source = 'MANUAL', @Details = @et, @UserId = @UserId, @EscalationId = @esc OUTPUT;
            END
            ELSE IF @Action = 'CANCEL'
            BEGIN
                IF @ts NOT IN ('ORDERED', 'CHECKED') THROW 59821, 'A transfusion already started is stopped (reaction) or completed, not cancelled.', 1;
                IF @Reason IS NULL THROW 59822, 'Enter the reason for cancelling.', 1;
                UPDATE dbo.IpdTransfusion SET Status = 'CANCELLED', CancelReason = @Reason, ModifiedBy = @UserId, ModifiedDate = @now WHERE TransfusionId = @TransfusionId;
            END
            ELSE THROW 59823, 'Unknown transfusion step.', 1;
        END
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'TRANSFUSION', LEFT(CONCAT(t.Component, N' x', t.Units, N' ', LOWER(@Action), ISNULL(N' bag ' + t.BagNo, N''), CASE WHEN @Action = 'REACTION' THEN N' - REACTION: ' + t.ReactionType ELSE N'' END), 500), @UserId
        FROM dbo.IpdTransfusion t WHERE t.TransfusionId = @TransfusionId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @TransfusionId AS TransfusionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── restraint ────────────────────────────────────────────────────────────────────────────────────────────────
-- @Action START (doctor's order) | CHECK (every ReviewEveryHours) | RENEW (doctor, after OrderValidHours) | END
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdRestraint_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Action VARCHAR(10), @RestraintId INT = NULL,
    @Kind VARCHAR(10) = NULL, @Device NVARCHAR(100) = NULL, @Reason NVARCHAR(300) = NULL, @AlternativesTried NVARCHAR(300) = NULL, @DoctorId INT = NULL,
    @FamilyInformed NVARCHAR(150) = NULL, @CirculationOk BIT = NULL, @SkinOk BIT = NULL, @NeedsMet BIT = NULL, @StillNeeded BIT = NULL, @Notes NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @Action = UPPER(@Action);
        SELECT @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N''), @AlternativesTried = NULLIF(LTRIM(RTRIM(@AlternativesTried)), N''), @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');
        IF @Action IN ('START', 'RENEW')
        BEGIN
            SET @DoctorId = ISNULL(dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId), @DoctorId);
            IF @DoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1)
                THROW 59830, 'A restraint is ordered by a doctor: choose the doctor.', 1;
        END
        IF @Action = 'START'
        BEGIN
            SET @Kind = UPPER(@Kind);
            IF @Kind NOT IN ('PHYSICAL', 'CHEMICAL') THROW 59831, 'Choose physical or chemical restraint.', 1;
            IF @Reason IS NULL THROW 59832, 'Enter why the restraint is needed (risk to self / others, pulling lines...).', 1;
            IF @AlternativesTried IS NULL THROW 59833, 'Enter the alternatives tried first (attendant, reorientation, sitter, bed alarm...).', 1;
            IF EXISTS (SELECT 1 FROM dbo.IpdRestraint WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE') THROW 59834, 'A restraint is already applied: end it or record its check.', 1;
            INSERT dbo.IpdRestraint (AdmissionId, Kind, Device, Reason, AlternativesTried, OrderedByDoctorId, StartAt, FamilyInformed, CreatedBy)
            VALUES (@AdmissionId, @Kind, NULLIF(LTRIM(RTRIM(@Device)), N''), @Reason, @AlternativesTried, @DoctorId, @now, NULLIF(LTRIM(RTRIM(@FamilyInformed)), N''), @UserId);
            SET @RestraintId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
        BEGIN
            DECLARE @rs VARCHAR(8), @start DATETIME, @valid INT;
            SELECT @rs = Status, @start = StartAt, @valid = OrderValidHours FROM dbo.IpdRestraint WITH (UPDLOCK) WHERE RestraintId = @RestraintId AND AdmissionId = @AdmissionId;
            IF @rs IS NULL THROW 59835, 'The restraint was not found.', 1;
            IF @rs <> 'ACTIVE' THROW 59836, 'The restraint is already ended.', 1;
            IF @Action = 'CHECK'
            BEGIN
                IF DATEADD(HOUR, @valid, @start) < @now THROW 59837, 'The restraint order has expired: the doctor renews it (or the restraint is ended).', 1;
                IF @CirculationOk IS NULL OR @SkinOk IS NULL OR @NeedsMet IS NULL OR @StillNeeded IS NULL THROW 59838, 'Answer every item of the check.', 1;
                IF (@CirculationOk = 0 OR @SkinOk = 0) AND @Notes IS NULL THROW 59839, 'Circulation or skin is not fine: write what was done.', 1;
                INSERT dbo.IpdRestraintCheck (RestraintId, CheckedAt, CirculationOk, SkinOk, NeedsMet, StillNeeded, Notes, CheckedBy)
                VALUES (@RestraintId, @now, @CirculationOk, @SkinOk, @NeedsMet, @StillNeeded, @Notes, @UserId);
            END
            ELSE IF @Action = 'RENEW'
            BEGIN
                IF @Reason IS NULL THROW 59840, 'Enter why the restraint is still needed.', 1;
                UPDATE dbo.IpdRestraint SET OrderValidHours = DATEDIFF(HOUR, StartAt, @now) + 24 WHERE RestraintId = @RestraintId;
            END
            ELSE IF @Action = 'END'
            BEGIN
                IF @Reason IS NULL THROW 59841, 'Enter why the restraint is removed (calm, oriented, no longer needed).', 1;
                UPDATE dbo.IpdRestraint SET Status = 'ENDED', EndAt = @now, EndReason = @Reason, EndedBy = @UserId WHERE RestraintId = @RestraintId;
            END
            ELSE THROW 59842, 'Unknown restraint step.', 1;
        END
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'RESTRAINT_' + @Action, LEFT(CONCAT(ISNULL(@Reason, @Notes), N''), 500), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @RestraintId AS RestraintId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- transfusions, restraints (+ checks) and the newborn link of an admission (the Nursing tab)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdSafety_Data @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId) RETURN;
    -- 1 transfusions
    SELECT t.*, d.FullName AS DoctorName, u.FullName AS CheckedBy1Name, ISNULL(DATEDIFF(MINUTE, t.StartAt, ISNULL(t.EndAt, GETDATE())), 0) AS RunMinutes,
           CAST(CASE WHEN t.Status = 'STARTED' AND t.Vitals15 IS NULL AND DATEDIFF(MINUTE, t.StartAt, GETDATE()) >= 15 THEN 1 ELSE 0 END AS BIT) AS Vitals15Due
    FROM dbo.IpdTransfusion t LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = t.OrderedByDoctorId LEFT JOIN dbo.Users u ON u.Id = t.CheckedBy1
    WHERE t.AdmissionId = @AdmissionId ORDER BY t.TransfusionId DESC;
    -- 2 restraints
    SELECT r.*, d.FullName AS DoctorName, DATEADD(HOUR, r.OrderValidHours, r.StartAt) AS OrderValidTo,
           lc.LastCheckAt, DATEADD(HOUR, r.ReviewEveryHours, ISNULL(lc.LastCheckAt, r.StartAt)) AS NextCheckDue,
           CAST(CASE WHEN r.Status = 'ACTIVE' AND DATEADD(HOUR, r.ReviewEveryHours, ISNULL(lc.LastCheckAt, r.StartAt)) < GETDATE() THEN 1 ELSE 0 END AS BIT) AS CheckOverdue,
           CAST(CASE WHEN r.Status = 'ACTIVE' AND DATEADD(HOUR, r.OrderValidHours, r.StartAt) < GETDATE() THEN 1 ELSE 0 END AS BIT) AS OrderExpired
    FROM dbo.IpdRestraint r LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.OrderedByDoctorId
    OUTER APPLY (SELECT MAX(c.CheckedAt) AS LastCheckAt FROM dbo.IpdRestraintCheck c WHERE c.RestraintId = r.RestraintId) lc
    WHERE r.AdmissionId = @AdmissionId ORDER BY r.RestraintId DESC;
    -- 3 restraint checks
    SELECT c.*, u.FullName AS CheckedByName FROM dbo.IpdRestraintCheck c JOIN dbo.IpdRestraint r ON r.RestraintId = c.RestraintId LEFT JOIN dbo.Users u ON u.Id = c.CheckedBy
    WHERE r.AdmissionId = @AdmissionId ORDER BY c.CheckedAt DESC;
    -- 4 this admission as a newborn (its mother) and 5 the babies of this admission (as the mother)
    SELECT n.*, m.IpNo AS MotherIpNo, LTRIM(RTRIM(CONCAT(mp.FirstName, ' ', mp.LastName))) AS MotherName
    FROM dbo.IpdNewborn n JOIN dbo.IpdAdmission m ON m.AdmissionId = n.MotherAdmissionId JOIN dbo.PatientMaster mp ON mp.PatientId = m.PatientId
    WHERE n.AdmissionId = @AdmissionId;
    SELECT n.*, b.IpNo AS BabyIpNo, LTRIM(RTRIM(CONCAT(bp.FirstName, ' ', bp.LastName))) AS BabyName, bp.Gender AS BabyGender, b.Status AS BabyStatus
    FROM dbo.IpdNewborn n JOIN dbo.IpdAdmission b ON b.AdmissionId = n.AdmissionId JOIN dbo.PatientMaster bp ON bp.PatientId = b.PatientId
    WHERE n.MotherAdmissionId = @AdmissionId ORDER BY n.BabyOrder;
END;
GO

-- ── C4: link a newborn's admission to the mother's ───────────────────────────────────────────────────────────
-- The baby is registered as a patient (normal registration) and admitted (cradle beside the mother, or NICU); then linked here.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdNewborn_Link
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @MotherIpNo NVARCHAR(40), @BirthAt DATETIME, @BirthWeightKg DECIMAL(4,2),
    @DeliveryType VARCHAR(12), @GestationWeeks INT = NULL, @Apgar1 TINYINT = NULL, @Apgar5 TINYINT = NULL, @BabyOrder TINYINT = 1, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        DECLARE @mother INT, @mGender NVARCHAR(20), @mPatient INT, @bPatient INT, @bDob DATE;
        SELECT @mother = a.AdmissionId, @mGender = p.Gender, @mPatient = a.PatientId FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE a.IpNo = LTRIM(RTRIM(@MotherIpNo)) AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.Status <> 'CANCELLED';
        IF @mother IS NULL THROW 59850, 'The mother''s IP number was not found in this branch.', 1;
        IF @mother = @AdmissionId THROW 59851, 'Choose the mother''s admission, not the baby''s.', 1;
        IF ISNULL(@mGender, N'') <> N'Female' THROW 59852, 'The mother''s admission is not of a female patient.', 1;
        SELECT @bPatient = a.PatientId, @bDob = p.DateOfBirth FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId WHERE a.AdmissionId = @AdmissionId;
        IF @bPatient = @mPatient THROW 59853, 'The baby must be registered as a separate patient.', 1;
        IF @BirthAt IS NULL OR @BirthAt > DATEADD(MINUTE, 5, @now) THROW 59854, 'Enter the time of birth (not in the future).', 1;
        IF @BirthAt < DATEADD(DAY, -28, @now) THROW 59855, 'A newborn is linked within 28 days of birth.', 1;
        IF @bDob IS NOT NULL AND @bDob <> CAST(@BirthAt AS DATE) THROW 59856, 'The baby''s date of birth in the patient record differs from the time of birth: correct one of them.', 1;
        IF ISNULL(@BirthWeightKg, 0) NOT BETWEEN 0.3 AND 7 THROW 59857, 'The birth weight must be 0.3-7 kg.', 1;
        SET @DeliveryType = UPPER(@DeliveryType);
        IF @DeliveryType NOT IN ('NORMAL', 'ASSISTED', 'LSCS') THROW 59858, 'Choose normal, assisted or LSCS delivery.', 1;
        IF (@Apgar1 IS NOT NULL AND @Apgar1 > 10) OR (@Apgar5 IS NOT NULL AND @Apgar5 > 10) THROW 59859, 'Apgar is 0 to 10.', 1;
        IF @GestationWeeks IS NOT NULL AND @GestationWeeks NOT BETWEEN 20 AND 45 THROW 59860, 'Gestation must be 20-45 weeks.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdNewborn WHERE AdmissionId = @AdmissionId)
            UPDATE dbo.IpdNewborn SET MotherAdmissionId = @mother, BirthAt = @BirthAt, BirthWeightKg = @BirthWeightKg, DeliveryType = @DeliveryType, GestationWeeks = @GestationWeeks,
                   Apgar1 = @Apgar1, Apgar5 = @Apgar5, BabyOrder = ISNULL(@BabyOrder, 1), Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'') WHERE AdmissionId = @AdmissionId;
        ELSE
            INSERT dbo.IpdNewborn (AdmissionId, MotherAdmissionId, BirthAt, BirthWeightKg, DeliveryType, GestationWeeks, Apgar1, Apgar5, BabyOrder, Remarks, CreatedBy)
            VALUES (@AdmissionId, @mother, @BirthAt, @BirthWeightKg, @DeliveryType, @GestationWeeks, @Apgar1, @Apgar5, ISNULL(@BabyOrder, 1), NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        IF @bDob IS NULL UPDATE dbo.PatientMaster SET DateOfBirth = CAST(@BirthAt AS DATE), ModifiedBy = @UserId, ModifiedDate = @now WHERE PatientId = @bPatient;
        UPDATE dbo.IpdAdmission SET MotherAdmissionId = @mother, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'NEWBORN', CONCAT(N'Linked to the mother ', LTRIM(RTRIM(@MotherIpNo)), N': born ', FORMAT(@BirthAt, 'dd-MMM-yyyy HH:mm'), N', ', @BirthWeightKg, N' kg, ', @DeliveryType), @UserId),
               (@mother, 'NEWBORN', CONCAT(N'Baby admission linked: ', (SELECT IpNo FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId)), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @mother AS MotherAdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

PRINT '2574 IPD flow-gap features - done.';
GO
