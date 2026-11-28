-- 2573: IPD flow-gap fixes - clinical (2026-11-28). Needs 2570, 2572. Safe to re-run.
--   B3  a medicine order is verified by the pharmacist before routine doses are charted (STAT exempt; IpdMarNeedsVerify)
--   B4  wristband scan (UHID / IP no.) checked on the MAR; required when IpdMarScanRequired = 1
--   B1  MAR safety net: an allergy recorded after the order stops the dose until the doctor gives a reason
--   B6  NEWS2 medium / high (or a single red score) raises an escalation to the consultant; acknowledged with the response
--   B7  medication reconciliation at admission / discharge
--   B8  record gaps (fn_Ipd_RecordGaps): the discharge summary is signed and the nursing clearance done only when complete
--   B10 Padua VTE risk score next to Morse / Braden
-- REPLACES usp_Api_IpdMar_Record, usp_Api_IpdVital_Add, usp_Api_IpdRisk_Add, usp_Api_IpdDischargeSummary_Save,
-- usp_Api_IpdDischarge_Clear, usp_Api_IpdClinical_Data, usp_Api_IpdNursing_Data (live + the checks): re-run 2573 after 2557 / 2563 / 2564. Errors 59700-59799.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── B3: pharmacist verification ──────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_Verify @CompanyId INT, @BranchId INT, @UserId INT, @OrderId INT, @Action VARCHAR(10) = 'VERIFY', @Note NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @type VARCHAR(10), @st VARCHAR(10), @drug NVARCHAR(250), @vs VARCHAR(10);
        SELECT @adm = o.AdmissionId, @type = o.OrderType, @st = o.Status, @drug = o.DrugName, @vs = o.VerifyStatus FROM dbo.IpdOrder o WITH (UPDLOCK)
        JOIN dbo.IpdAdmission a ON a.AdmissionId = o.AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId WHERE o.OrderId = @OrderId;
        IF @adm IS NULL OR @type <> 'MED' THROW 59700, 'The medicine order was not found in this branch.', 1;
        IF @st <> 'ACTIVE' THROW 59701, 'The order is not active.', 1;
        SET @Action = UPPER(ISNULL(@Action, 'VERIFY')); SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'');
        IF @Action NOT IN ('VERIFY', 'QUERY') THROW 59702, 'Choose verify or query.', 1;
        IF @Action = 'QUERY' AND @Note IS NULL THROW 59703, 'Write the query to the doctor (dose, route, interaction, allergy...).', 1;
        IF @Action = 'VERIFY' AND @vs = 'VERIFIED' THROW 59704, 'The order is already verified.', 1;
        UPDATE dbo.IpdOrder SET VerifyStatus = CASE WHEN @Action = 'VERIFY' THEN 'VERIFIED' ELSE 'QUERY' END,
               VerifiedBy = CASE WHEN @Action = 'VERIFY' THEN @UserId END, VerifiedAt = CASE WHEN @Action = 'VERIFY' THEN @now END, VerifyNote = @Note
        WHERE OrderId = @OrderId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, CASE WHEN @Action = 'VERIFY' THEN 'ORDER_VERIFY' ELSE 'ORDER_QUERY' END, LEFT(CONCAT(@drug, CASE WHEN @Action = 'VERIFY' THEN N' verified by the pharmacist' ELSE N' - pharmacist query' END, ISNULL(N': ' + @Note, N'')), 500), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- the pharmacist's queue: running medicine orders of the branch not yet verified (oldest first, STAT / urgent on top)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_VerifyQueue @CompanyId INT, @BranchId INT, @AdmissionId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.OrderId, o.AdmissionId, a.IpNo, LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, p.KnownAllergies,
           b.BedNumber, w.WardName, o.DrugName, o.Dose, o.Route, o.FrequencyCode, o.Priority, o.StartAt, o.EndAt, o.IsHighAlert, o.Source, o.OrderedAt,
           d.FullName AS DoctorName, o.VerifyStatus, o.VerifyNote, o.AllergyOverride, o.InteractionOverride,
           (SELECT TOP 1 x.Message FROM dbo.fn_Ipd_MedAlerts(@CompanyId, o.AdmissionId, o.ItemId, o.DrugName, o.OrderId) x ORDER BY CASE x.Kind WHEN 'ALLERGY' THEN 0 WHEN 'INTERACTION' THEN 1 ELSE 2 END) AS Alert
    FROM dbo.IpdOrder o
    JOIN dbo.IpdAdmission a ON a.AdmissionId = o.AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    WHERE o.OrderType = 'MED' AND o.Status = 'ACTIVE' AND ISNULL(o.VerifyStatus, '') <> 'VERIFIED' AND (@AdmissionId IS NULL OR o.AdmissionId = @AdmissionId)
    ORDER BY CASE o.Priority WHEN 'STAT' THEN 0 WHEN 'URGENT' THEN 1 ELSE 2 END, o.OrderedAt;
END;
GO

-- ── B6: escalations (NEWS2 / ICU / raised by hand) ───────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_RaiseEscalation @AdmissionId INT, @Source VARCHAR(10), @RefId BIGINT = NULL, @Score INT = NULL, @RiskLevel VARCHAR(12) = NULL,
    @Details NVARCHAR(500) = NULL, @UserId INT, @EscalationId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    -- one open escalation at a time: a worse reading updates it
    SELECT TOP 1 @EscalationId = EscalationId FROM dbo.IpdEscalation WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'OPEN' ORDER BY EscalationId DESC;
    IF @EscalationId IS NOT NULL
    BEGIN
        UPDATE dbo.IpdEscalation SET Score = CASE WHEN ISNULL(@Score, 0) > ISNULL(Score, 0) THEN @Score ELSE Score END,
               RiskLevel = CASE WHEN ISNULL(@Score, 0) > ISNULL(Score, 0) THEN @RiskLevel ELSE RiskLevel END,
               Details = LEFT(CONCAT(Details, N' | ', FORMAT(GETDATE(), 'HH:mm'), N' ', @Details), 500)
        WHERE EscalationId = @EscalationId;
        RETURN;
    END
    INSERT dbo.IpdEscalation (AdmissionId, Source, RefId, Score, RiskLevel, Details, DoctorId, RaisedAt, RaisedBy)
    SELECT @AdmissionId, @Source, @RefId, @Score, @RiskLevel, LEFT(@Details, 500), a.ConsultantDoctorId, GETDATE(), @UserId FROM dbo.IpdAdmission a WHERE a.AdmissionId = @AdmissionId;
    SET @EscalationId = CAST(SCOPE_IDENTITY() AS INT);
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@AdmissionId, 'ESCALATION', LEFT(CONCAT(N'Escalated to the consultant (', @Source, ISNULL(N' ' + CAST(@Score AS NVARCHAR(10)), N''), ISNULL(N', ' + @RiskLevel, N''), N'): ', @Details), 500), @UserId);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEscalation_Action
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Action VARCHAR(10), @EscalationId INT = NULL, @Text NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @Action = UPPER(@Action); SET @Text = NULLIF(LTRIM(RTRIM(@Text)), N'');
        IF @Action = 'RAISE'
        BEGIN
            IF @Text IS NULL THROW 59710, 'Describe why the doctor is called (what you see, the vitals).', 1;
            DECLARE @new INT;
            EXEC dbo.usp_Ipd_RaiseEscalation @AdmissionId = @AdmissionId, @Source = 'MANUAL', @Details = @Text, @UserId = @UserId, @EscalationId = @new OUTPUT;
            SET @EscalationId = @new;
        END
        ELSE
        BEGIN
            DECLARE @es VARCHAR(8);
            SELECT @es = Status FROM dbo.IpdEscalation WITH (UPDLOCK) WHERE EscalationId = @EscalationId AND AdmissionId = @AdmissionId;
            IF @es IS NULL THROW 59711, 'The escalation was not found.', 1;
            IF @Action = 'ACK'
            BEGIN
                IF @es <> 'OPEN' THROW 59712, 'The escalation is already acknowledged.', 1;
                IF @Text IS NULL THROW 59713, 'Write the response (seen / advice / plan, e.g. "Seen, start O2, repeat NEWS2 in 30 min").', 1;
                UPDATE dbo.IpdEscalation SET Status = 'ACK', AckBy = @UserId, AckAt = @now, Response = @Text WHERE EscalationId = @EscalationId;
            END
            ELSE IF @Action = 'CLOSE'
            BEGIN
                IF @es = 'CLOSED' THROW 59714, 'The escalation is already closed.', 1;
                IF @es = 'OPEN' THROW 59715, 'The doctor acknowledges the escalation (with the response) before it is closed.', 1;
                UPDATE dbo.IpdEscalation SET Status = 'CLOSED', ClosedBy = @UserId, ClosedAt = @now, CloseNote = LEFT(@Text, 300) WHERE EscalationId = @EscalationId;
            END
            ELSE THROW 59716, 'Unknown escalation action.', 1;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'ESCALATION_' + @Action, LEFT(ISNULL(@Text, N''), 500), @UserId);
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @EscalationId AS EscalationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- escalations of an admission (@AdmissionId) or open ones of the branch (nursing station / doctors)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdEscalation_List @CompanyId INT, @BranchId INT, @AdmissionId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EscalationId, e.AdmissionId, a.IpNo, LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, b.BedNumber, w.WardName,
           e.Source, e.Score, e.RiskLevel, e.Details, e.RaisedAt, ur.FullName AS RaisedByName, d.FullName AS DoctorName, e.Status, e.AckAt, ua.FullName AS AckByName, e.Response,
           e.ClosedAt, e.CloseNote, DATEDIFF(MINUTE, e.RaisedAt, ISNULL(e.AckAt, GETDATE())) AS MinutesToAck
    FROM dbo.IpdEscalation e
    JOIN dbo.IpdAdmission a ON a.AdmissionId = e.AdmissionId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = e.DoctorId LEFT JOIN dbo.Users ur ON ur.Id = e.RaisedBy LEFT JOIN dbo.Users ua ON ua.Id = e.AckBy
    WHERE (@AdmissionId IS NOT NULL AND e.AdmissionId = @AdmissionId) OR (@AdmissionId IS NULL AND e.Status <> 'CLOSED' AND a.IsOpen = 1)
    ORDER BY CASE e.Status WHEN 'OPEN' THEN 0 WHEN 'ACK' THEN 1 ELSE 2 END, e.RaisedAt DESC;
END;
GO

-- ── B7: medication reconciliation ────────────────────────────────────────────────────────────────────────────
-- @Lines: [{drug, dose, frequency, action (CONTINUE / STOP / CHANGE / HOLD), note}]; a new one of the same stage replaces the old.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdMedRecon_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Stage VARCHAR(10), @NoHomeMeds BIT = 0, @Lines NVARCHAR(MAX) = NULL,
    @Source NVARCHAR(100) = NULL, @Notes NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @Stage = UPPER(@Stage);
        IF @Stage NOT IN ('ADMISSION', 'DISCHARGE') THROW 59720, 'Choose admission or discharge reconciliation.', 1;
        DECLARE @L TABLE (drug NVARCHAR(200), dose NVARCHAR(60), frequency NVARCHAR(40), action VARCHAR(10), note NVARCHAR(200));
        IF ISJSON(@Lines) = 1
            INSERT @L SELECT NULLIF(LTRIM(RTRIM(drug)), N''), NULLIF(LTRIM(RTRIM(dose)), N''), NULLIF(LTRIM(RTRIM(frequency)), N''), UPPER(NULLIF(LTRIM(RTRIM(action)), '')), NULLIF(LTRIM(RTRIM(note)), N'')
            FROM OPENJSON(@Lines) WITH (drug NVARCHAR(200), dose NVARCHAR(60), frequency NVARCHAR(40), action VARCHAR(10), note NVARCHAR(200));
        DELETE @L WHERE drug IS NULL;
        IF ISNULL(@NoHomeMeds, 0) = 0 AND NOT EXISTS (SELECT 1 FROM @L)
            THROW 59721, 'Add the medicines the patient takes at home, or tick "No regular medicines".', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE ISNULL(action, '') NOT IN ('CONTINUE', 'STOP', 'CHANGE', 'HOLD'))
            THROW 59722, 'Choose continue, stop, change or hold for every medicine.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE action IN ('STOP', 'CHANGE', 'HOLD') AND note IS NULL)
            THROW 59723, 'Write why a medicine is stopped, changed or held.', 1;
        UPDATE dbo.IpdMedRecon SET Status = 'STRUCK', StruckReason = N'Replaced by a new reconciliation', StruckBy = @UserId, StruckAt = @now
        WHERE AdmissionId = @AdmissionId AND Stage = @Stage AND Status = 'ACTIVE';
        INSERT dbo.IpdMedRecon (AdmissionId, Stage, NoHomeMeds, Lines, Source, Notes, DoctorId, DoneBy, DoneAt)
        VALUES (@AdmissionId, @Stage, CASE WHEN EXISTS (SELECT 1 FROM @L) THEN 0 ELSE 1 END, CASE WHEN EXISTS (SELECT 1 FROM @L) THEN (SELECT * FROM @L FOR JSON PATH) END,
                NULLIF(LTRIM(RTRIM(@Source)), N''), NULLIF(LTRIM(RTRIM(@Notes)), N''), dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId), @UserId, @now);
        DECLARE @id INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'MED_RECON', CONCAT(LOWER(@Stage), N' medication reconciliation: ', CASE WHEN EXISTS (SELECT 1 FROM @L) THEN CONCAT((SELECT COUNT(*) FROM @L), N' medicine(s)') ELSE N'no regular medicines' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS ReconId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdMedRecon_List @CompanyId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.ReconId, r.Stage, r.NoHomeMeds, r.Lines, r.Source, r.Notes, r.DoneAt, u.FullName AS DoneByName, d.FullName AS DoctorName, r.Status
    FROM dbo.IpdMedRecon r JOIN dbo.IpdAdmission a ON a.AdmissionId = r.AdmissionId AND a.CompanyId = @CompanyId
    LEFT JOIN dbo.Users u ON u.Id = r.DoneBy LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.DoctorId
    WHERE r.AdmissionId = @AdmissionId AND r.Status = 'ACTIVE' ORDER BY r.Stage, r.DoneAt DESC;
END;
GO

-- ── B8: what is missing in the record of an admission ────────────────────────────────────────────────────────
--   Owner DOCTOR (checked when the discharge summary is signed) / NURSING (checked at the nursing clearance)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_RecordGaps (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT 10 AS Sort, 'DOCTOR' AS Owner, CAST(N'The doctor''s initial assessment is not signed (Clinical tab).' AS NVARCHAR(300)) AS Message
    WHERE NOT EXISTS (SELECT 1 FROM dbo.IpdAssessment x WHERE x.AdmissionId = @AdmissionId AND x.Kind = 'DOCTOR' AND x.Status = 'SIGNED')
    UNION ALL
    SELECT 20, 'DOCTOR', CAST(CONCAT(COUNT(*), N' verbal / telephone order(s) are not countersigned by the doctor (Clinical tab).') AS NVARCHAR(300))
    FROM dbo.IpdOrder o WHERE o.AdmissionId = @AdmissionId AND o.Source IN ('VERBAL', 'TELEPHONE') AND o.CountersignedAt IS NULL AND o.Status <> 'CANCELLED'
    HAVING COUNT(*) > 0
    UNION ALL
    SELECT 30, 'DOCTOR', CAST(CONCAT(COUNT(*), N' progress note(s) are saved as draft and not signed (Clinical tab).') AS NVARCHAR(300))
    FROM dbo.IpdProgressNote n WHERE n.AdmissionId = @AdmissionId AND n.Status = 'DRAFT' HAVING COUNT(*) > 0
    UNION ALL
    SELECT 40, 'DOCTOR', CAST(N'The admission medication reconciliation is not recorded (Clinical tab).' AS NVARCHAR(300))
    WHERE NOT EXISTS (SELECT 1 FROM dbo.IpdMedRecon r WHERE r.AdmissionId = @AdmissionId AND r.Stage = 'ADMISSION' AND r.Status = 'ACTIVE')
    UNION ALL
    SELECT 50, 'DOCTOR', CAST(CONCAT(COUNT(*), N' escalation(s) are not acknowledged by the doctor.') AS NVARCHAR(300))
    FROM dbo.IpdEscalation e WHERE e.AdmissionId = @AdmissionId AND e.Status = 'OPEN' HAVING COUNT(*) > 0
    UNION ALL
    SELECT 110, 'NURSING', CAST(N'The nursing initial assessment is not signed (Nursing tab).' AS NVARCHAR(300))
    WHERE NOT EXISTS (SELECT 1 FROM dbo.IpdAssessment x WHERE x.AdmissionId = @AdmissionId AND x.Kind = 'NURSING' AND x.Status = 'SIGNED')
    UNION ALL
    SELECT 120, 'NURSING', CAST(CONCAT(COUNT(*), N' infusion(s) are still running (ICU tab): stop them.') AS NVARCHAR(300))
    FROM dbo.IpdIcuInfusion i WHERE i.AdmissionId = @AdmissionId AND i.Status = 'RUNNING' HAVING COUNT(*) > 0
    UNION ALL
    SELECT 130, 'NURSING', CAST(N'A restraint is still applied: release it (Nursing tab).' AS NVARCHAR(300))
    WHERE EXISTS (SELECT 1 FROM dbo.IpdRestraint r WHERE r.AdmissionId = @AdmissionId AND r.Status = 'ACTIVE')
    UNION ALL
    SELECT 140, 'NURSING', CAST(N'A blood transfusion is ordered or running: complete, stop or cancel it (Nursing tab).' AS NVARCHAR(300))
    WHERE EXISTS (SELECT 1 FROM dbo.IpdTransfusion t WHERE t.AdmissionId = @AdmissionId AND t.Status IN ('ORDERED', 'CHECKED', 'STARTED'))
);
GO

-- ── eMAR (live + 2573: B1 allergy, B3 verification, B4 wristband) ──
-- ── eMAR: record a dose ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdMar_Record
    @CompanyId INT, @BranchId INT, @UserId INT, @OrderId INT, @DueAt DATETIME = NULL, @Outcome VARCHAR(10), @GivenAt DATETIME = NULL,
    @DoseGiven NVARCHAR(60) = NULL, @Site NVARCHAR(60) = NULL, @Reason NVARCHAR(300) = NULL, @WitnessName NVARCHAR(100) = NULL, @ScanValue NVARCHAR(60) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @type VARCHAR(10), @ost VARCHAR(10), @fk VARCHAR(10), @high BIT, @dose NVARCHAR(60), @route VARCHAR(20), @start DATETIME, @drug NVARCHAR(250);
        SELECT @adm = o.AdmissionId, @type = o.OrderType, @ost = o.Status, @fk = f.Kind, @high = o.IsHighAlert, @dose = o.Dose, @route = o.Route, @start = o.StartAt, @drug = o.DrugName
        FROM dbo.IpdOrder o LEFT JOIN dbo.IpdFrequency f ON f.FrequencyCode = o.FrequencyCode WHERE o.OrderId = @OrderId;
        IF @adm IS NULL OR @type <> 'MED' OR NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @adm AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 59470, 'The medication order was not found in this branch.', 1;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @adm, @admAt OUTPUT, @st OUTPUT;
        SET @Outcome = UPPER(@Outcome);
        IF @Outcome NOT IN ('GIVEN', 'HELD', 'REFUSED') THROW 59471, 'Choose given, held or refused.', 1;
        -- 2573: checks before a dose is given
        DECLARE @scanOk BIT = NULL;
        IF @Outcome = 'GIVEN'
        BEGIN
            DECLARE @oItem INT, @oPri VARCHAR(10), @oVer VARCHAR(10), @oAllergyOk NVARCHAR(300);
            SELECT @oItem = ItemId, @oPri = Priority, @oVer = VerifyStatus, @oAllergyOk = AllergyOverride FROM dbo.IpdOrder WHERE OrderId = @OrderId;
            -- B1: an allergy recorded after the order was written
            IF @oAllergyOk IS NULL AND EXISTS (SELECT 1 FROM dbo.fn_Ipd_MedAlerts(@CompanyId, @adm, @oItem, @drug, @OrderId) WHERE Kind = 'ALLERGY')
                THROW 59730, 'The patient''s recorded allergy matches this medicine and the order has no doctor''s reason: hold the dose and ask the doctor to review the order.', 1;
            -- B3: pharmacist verification before routine doses (a STAT order or an SOS dose in an emergency is given first)
            IF (SELECT MarNeedsVerify FROM dbo.fn_Ipd_GapSettings(@BranchId)) = 1 AND ISNULL(@oVer, '') <> 'VERIFIED' AND @fk NOT IN ('STAT') AND ISNULL(@oPri, '') <> 'STAT'
                THROW 59731, 'The pharmacist has not verified this order yet (Medicines > Verify): routine doses are charted after the verification. A STAT order can be given first.', 1;
            -- B4: positive patient identification by the wristband
            SET @ScanValue = UPPER(NULLIF(LTRIM(RTRIM(@ScanValue)), N''));
            IF @ScanValue IS NULL AND (SELECT MarScanRequired FROM dbo.fn_Ipd_GapSettings(@BranchId)) = 1
                THROW 59732, 'Scan the patient''s wristband (UHID / IP no.) before giving the dose.', 1;
            IF @ScanValue IS NOT NULL
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission a JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
                               WHERE a.AdmissionId = @adm AND (UPPER(p.PatientCode) = @ScanValue OR UPPER(a.IpNo) = @ScanValue))
                    THROW 59733, 'WRONG PATIENT: the wristband scanned is not this patient''s. Do not give the dose; check the patient.', 1;
                SET @scanOk = 1;
            END
        END
        SELECT @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N''), @WitnessName = NULLIF(LTRIM(RTRIM(@WitnessName)), N'');
        SET @GivenAt = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @GivenAt), 0), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @now), 0));
        IF @GivenAt > DATEADD(MINUTE, 5, @now) THROW 59472, 'The time cannot be in the future.', 1;
        IF @GivenAt < @admAt THROW 59473, 'The time cannot be before the admission.', 1;
        DECLARE @late INT = ISNULL((SELECT TOP (1) IpdMarLateMinutes FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 60);

        IF @fk = 'PRN'
        BEGIN
            IF @DueAt IS NOT NULL SET @DueAt = NULL;
            IF @ost <> 'ACTIVE' THROW 59474, 'The order is not active: an SOS dose cannot be given.', 1;
            IF @Reason IS NULL THROW 59475, 'Enter why the SOS dose was given (the indication).', 1;
            IF @GivenAt < @start THROW 59476, 'The dose cannot be before the order starts.', 1;
        END
        ELSE
        BEGIN
            IF @DueAt IS NULL THROW 59477, 'Choose the dose (its scheduled time).', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_MarDue(@adm, DATEADD(MINUTE, -1, @DueAt), DATEADD(MINUTE, 1, @DueAt)) WHERE OrderId = @OrderId AND DueAt = @DueAt)
                THROW 59478, 'This order has no dose at that time.', 1;
            IF @DueAt > DATEADD(MINUTE, @late, @now) THROW 59479, 'This dose is not due yet.', 1;
            IF @Outcome = 'GIVEN' AND ABS(DATEDIFF(MINUTE, @DueAt, @GivenAt)) > @late AND @Reason IS NULL
            BEGIN
                SET @msg = CONCAT(N'The dose is charted more than ', @late, N' minutes from its time: enter the reason (late / early).');
                THROW 59480, @msg, 1;
            END
            IF EXISTS (SELECT 1 FROM dbo.IpdMarAdmin WITH (UPDLOCK, HOLDLOCK) WHERE OrderId = @OrderId AND DueAt = @DueAt AND Status = 'ACTIVE')
                THROW 59481, 'This dose is already charted: strike it out first to correct it.', 1;
        END
        IF @Outcome IN ('HELD', 'REFUSED') AND @Reason IS NULL THROW 59482, 'Enter why the dose was held / refused.', 1;
        IF @Outcome = 'GIVEN' AND @high = 1 AND @WitnessName IS NULL THROW 59483, 'High-alert medicine: enter the second nurse who double-checked it.', 1;

        INSERT dbo.IpdMarAdmin (OrderId, AdmissionId, DueAt, Outcome, GivenAt, DoseGiven, Route, Site, Reason, WitnessName, RecordedBy)
        VALUES (@OrderId, @adm, @DueAt, @Outcome, @GivenAt, CASE WHEN @Outcome = 'GIVEN' THEN ISNULL(NULLIF(LTRIM(RTRIM(@DoseGiven)), N''), @dose) END,
                CASE WHEN @Outcome = 'GIVEN' THEN @route END, NULLIF(LTRIM(RTRIM(@Site)), N''), @Reason, @WitnessName, @UserId);
        DECLARE @id BIGINT = SCOPE_IDENTITY();
        IF @scanOk = 1 UPDATE dbo.IpdMarAdmin SET ScanVerified = 1 WHERE MarId = @id;
        -- the nurse has seen the order
        UPDATE dbo.IpdOrder SET AckBy = ISNULL(AckBy, @UserId), AckAt = ISNULL(AckAt, @now) WHERE OrderId = @OrderId;
        -- a STAT order is done once given
        IF @fk = 'STAT' AND @Outcome = 'GIVEN' UPDATE dbo.IpdOrder SET Status = 'COMPLETED' WHERE OrderId = @OrderId AND Status = 'ACTIVE';
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS MarId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── vitals (live + 2573: B6 escalation) ──
-- ── vitals with NEWS2 ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdVital_Add
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ObservedAt DATETIME = NULL, @Rr SMALLINT = NULL, @SpO2 DECIMAL(4,1) = NULL,
    @OnOxygen BIT = NULL, @O2Device NVARCHAR(40) = NULL, @O2FlowLpm DECIMAL(4,1) = NULL, @Sbp SMALLINT = NULL, @Dbp SMALLINT = NULL, @Pulse SMALLINT = NULL,
    @Consciousness CHAR(1) = NULL, @TempC DECIMAL(4,1) = NULL, @PainScore TINYINT = NULL, @Glucose DECIMAL(6,1) = NULL, @WeightKg DECIMAL(5,1) = NULL,
    @Notes NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @ObservedAt = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @ObservedAt), 0), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @now), 0));
        IF @ObservedAt > DATEADD(MINUTE, 5, @now) THROW 59400, 'The time cannot be in the future.', 1;
        IF @ObservedAt < @admAt THROW 59401, 'The time cannot be before the admission.', 1;
        SET @Consciousness = UPPER(NULLIF(@Consciousness, ''));
        IF COALESCE(@Rr, @Sbp, @Pulse, @PainScore) IS NULL AND @SpO2 IS NULL AND @TempC IS NULL AND @Glucose IS NULL AND @WeightKg IS NULL AND @Consciousness IS NULL
            THROW 59402, 'Enter at least one reading.', 1;
        SELECT @msg = CASE
            WHEN @Rr NOT BETWEEN 0 AND 80 THEN N'Respiratory rate must be 0-80 /min.'
            WHEN @SpO2 NOT BETWEEN 0 AND 100 THEN N'SpO2 must be 0-100 %.'
            WHEN @Sbp NOT BETWEEN 0 AND 300 THEN N'Systolic BP must be 0-300 mmHg.'
            WHEN @Dbp NOT BETWEEN 0 AND 200 THEN N'Diastolic BP must be 0-200 mmHg.'
            WHEN @Sbp IS NOT NULL AND @Dbp IS NOT NULL AND @Dbp > @Sbp THEN N'Diastolic BP cannot be above systolic.'
            WHEN (@Sbp IS NULL AND @Dbp IS NOT NULL) OR (@Sbp IS NOT NULL AND @Dbp IS NULL) THEN N'Enter both systolic and diastolic BP.'
            WHEN @Pulse NOT BETWEEN 0 AND 300 THEN N'Pulse must be 0-300 /min.'
            WHEN @Consciousness IS NOT NULL AND @Consciousness NOT IN ('A', 'C', 'V', 'P', 'U') THEN N'Consciousness: A, C, V, P or U.'
            WHEN @TempC NOT BETWEEN 25 AND 45 THEN N'Temperature must be 25-45 °C.'
            WHEN @PainScore > 10 THEN N'Pain score must be 0-10.'
            WHEN @Glucose NOT BETWEEN 0 AND 1500 THEN N'Glucose must be 0-1500 mg/dl.'
            WHEN @WeightKg NOT BETWEEN 0.3 AND 400 THEN N'Weight must be 0.3-400 kg.'
            WHEN @OnOxygen = 1 AND NULLIF(LTRIM(RTRIM(@O2Device)), N'') IS NULL THEN N'Choose the oxygen device.'
            WHEN @O2FlowLpm NOT BETWEEN 0 AND 60 THEN N'Oxygen flow must be 0-60 l/min.'
            END;
        IF @msg IS NOT NULL THROW 59403, @msg, 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdVital WITH (UPDLOCK, HOLDLOCK) WHERE AdmissionId = @AdmissionId AND ObservedAt = @ObservedAt AND Status = 'ACTIVE')
            THROW 59404, 'Vitals are already charted at this time: strike them out first to correct them.', 1;
        DECLARE @score TINYINT, @risk VARCHAR(12);
        SELECT @score = Score, @risk = Risk FROM dbo.fn_Ipd_News2(@Rr, @SpO2, @OnOxygen, @Sbp, @Pulse, @Consciousness, @TempC);
        INSERT dbo.IpdVital (AdmissionId, ObservedAt, Rr, SpO2, OnOxygen, O2Device, O2FlowLpm, Sbp, Dbp, Pulse, Consciousness, TempC, PainScore, Glucose, WeightKg,
               News2, News2Risk, Notes, RecordedBy)
        VALUES (@AdmissionId, @ObservedAt, @Rr, @SpO2, @OnOxygen, CASE WHEN @OnOxygen = 1 THEN NULLIF(LTRIM(RTRIM(@O2Device)), N'') END,
               CASE WHEN @OnOxygen = 1 THEN @O2FlowLpm END, @Sbp, @Dbp, @Pulse, @Consciousness, @TempC, @PainScore, @Glucose, @WeightKg,
               @score, @risk, NULLIF(LTRIM(RTRIM(@Notes)), N''), @UserId);
        DECLARE @id BIGINT = SCOPE_IDENTITY();
        -- 2573 (B6): NEWS2 medium / high or a single red parameter calls the consultant
        IF @risk IN ('HIGH', 'MEDIUM', 'LOW_MEDIUM')
        BEGIN
            DECLARE @esc INT, @escTxt NVARCHAR(300) = CONCAT(N'NEWS2 ', @score, N' (', LOWER(REPLACE(@risk, '_', ' ')), N')', ISNULL(N' RR ' + CAST(@Rr AS NVARCHAR(5)), N''),
                    ISNULL(N' SpO2 ' + CAST(@SpO2 AS NVARCHAR(6)), N''), ISNULL(N' BP ' + CAST(@Sbp AS NVARCHAR(5)), N''), ISNULL(N' P ' + CAST(@Pulse AS NVARCHAR(5)), N''),
                    ISNULL(N' T ' + CAST(@TempC AS NVARCHAR(6)), N''), CASE WHEN @Consciousness IS NOT NULL AND @Consciousness <> 'A' THEN N' consciousness ' + @Consciousness ELSE N'' END);
            EXEC dbo.usp_Ipd_RaiseEscalation @AdmissionId = @AdmissionId, @Source = 'NEWS2', @RefId = @id, @Score = @score, @RiskLevel = @risk, @Details = @escTxt, @UserId = @UserId, @EscalationId = @esc OUTPUT;
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS VitalId, @score AS News2, @risk AS News2Risk,
               dbo.fn_Ipd_VitalsEveryMinutes(@score, @risk) AS NextInMinutes,
               CAST(CASE WHEN @risk IN ('HIGH', 'MEDIUM', 'LOW_MEDIUM') THEN 1 ELSE 0 END AS BIT) AS Escalated;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── risk scores (live + 2573: B10 Padua) ──
-- Morse fall scale (history 0/25, secondary diagnosis 0/15, ambulatory aid 0/15/30, IV / heparin lock 0/20, gait 0/10/20, mental status 0/15):
--   0-24 low, 25-44 moderate, 45+ high. Braden (sensory, moisture, activity, mobility, nutrition 1-4; friction / shear 1-3):
--   19-23 no risk, 15-18 mild, 13-14 moderate, 10-12 high, 9 or less very high. The score is worked out here from the answers.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdRisk_Add
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Kind VARCHAR(10), @Answers NVARCHAR(1000), @AssessedAt DATETIME = NULL, @Interventions NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @Kind = UPPER(@Kind);
        SET @AssessedAt = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @AssessedAt), 0), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @now), 0));
        IF @AssessedAt > DATEADD(MINUTE, 5, @now) OR @AssessedAt < @admAt THROW 59430, 'The time must be after the admission and not in the future.', 1;
        IF ISJSON(@Answers) <> 1 THROW 59431, 'Answer every item.', 1;
        DECLARE @score INT, @level VARCHAR(12);
        IF @Kind = 'MORSE'
        BEGIN
            DECLARE @m1 INT = TRY_CAST(JSON_VALUE(@Answers, '$.history') AS INT), @m2 INT = TRY_CAST(JSON_VALUE(@Answers, '$.secondary') AS INT),
                    @m3 INT = TRY_CAST(JSON_VALUE(@Answers, '$.aid') AS INT), @m4 INT = TRY_CAST(JSON_VALUE(@Answers, '$.iv') AS INT),
                    @m5 INT = TRY_CAST(JSON_VALUE(@Answers, '$.gait') AS INT), @m6 INT = TRY_CAST(JSON_VALUE(@Answers, '$.mental') AS INT);
            IF ISNULL(@m1, -1) NOT IN (0, 25) OR ISNULL(@m2, -1) NOT IN (0, 15) OR ISNULL(@m3, -1) NOT IN (0, 15, 30) OR ISNULL(@m4, -1) NOT IN (0, 20)
               OR ISNULL(@m5, -1) NOT IN (0, 10, 20) OR ISNULL(@m6, -1) NOT IN (0, 15)
                THROW 59432, 'Answer every item of the Morse fall scale.', 1;
            SET @score = @m1 + @m2 + @m3 + @m4 + @m5 + @m6;
            SET @level = CASE WHEN @score >= 45 THEN 'HIGH' WHEN @score >= 25 THEN 'MODERATE' ELSE 'LOW' END;
        END
        ELSE IF @Kind = 'BRADEN'
        BEGIN
            DECLARE @b1 INT = TRY_CAST(JSON_VALUE(@Answers, '$.sensory') AS INT), @b2 INT = TRY_CAST(JSON_VALUE(@Answers, '$.moisture') AS INT),
                    @b3 INT = TRY_CAST(JSON_VALUE(@Answers, '$.activity') AS INT), @b4 INT = TRY_CAST(JSON_VALUE(@Answers, '$.mobility') AS INT),
                    @b5 INT = TRY_CAST(JSON_VALUE(@Answers, '$.nutrition') AS INT), @b6 INT = TRY_CAST(JSON_VALUE(@Answers, '$.friction') AS INT);
            IF ISNULL(@b1, 0) NOT BETWEEN 1 AND 4 OR ISNULL(@b2, 0) NOT BETWEEN 1 AND 4 OR ISNULL(@b3, 0) NOT BETWEEN 1 AND 4 OR ISNULL(@b4, 0) NOT BETWEEN 1 AND 4
               OR ISNULL(@b5, 0) NOT BETWEEN 1 AND 4 OR ISNULL(@b6, 0) NOT BETWEEN 1 AND 3
                THROW 59433, 'Answer every item of the Braden scale.', 1;
            SET @score = @b1 + @b2 + @b3 + @b4 + @b5 + @b6;
            SET @level = CASE WHEN @score <= 9 THEN 'VERY_HIGH' WHEN @score <= 12 THEN 'HIGH' WHEN @score <= 14 THEN 'MODERATE' WHEN @score <= 18 THEN 'MILD' ELSE 'NONE' END;
        END
        ELSE IF @Kind = 'PADUA'
        BEGIN
            -- 2573 (B10) Padua prediction score: cancer 3, previous VTE 3, reduced mobility 3, thrombophilia 3, recent trauma / surgery 2,
            -- age 70+ 1, heart / respiratory failure 1, MI / stroke 1, infection / rheumatic disorder 1, obesity 1, hormonal treatment 1; 4+ = high risk
            DECLARE @pv TABLE (K NVARCHAR(20), W INT);
            INSERT @pv VALUES (N'cancer', 3), (N'previousVte', 3), (N'mobility', 3), (N'thrombophilia', 3), (N'trauma', 2), (N'age70', 1), (N'failure', 1),
                              (N'miStroke', 1), (N'infection', 1), (N'obesity', 1), (N'hormonal', 1);
            IF EXISTS (SELECT 1 FROM @pv v WHERE ISNULL(TRY_CAST(JSON_VALUE(@Answers, '$.' + v.K) AS INT), -1) NOT IN (0, 1))
                THROW 59740, 'Answer every item of the Padua score (yes / no).', 1;
            SET @score = (SELECT SUM(v.W * TRY_CAST(JSON_VALUE(@Answers, '$.' + v.K) AS INT)) FROM @pv v);
            SET @level = CASE WHEN @score >= 4 THEN 'HIGH' ELSE 'LOW' END;
        END
        ELSE THROW 59434, 'Choose the risk scale.', 1;
        INSERT dbo.IpdRiskScore (AdmissionId, Kind, AssessedAt, Answers, Score, RiskLevel, Interventions, RecordedBy)
        VALUES (@AdmissionId, @Kind, @AssessedAt, @Answers, @score, @level, NULLIF(LTRIM(RTRIM(@Interventions)), N''), @UserId);
        DECLARE @id BIGINT = SCOPE_IDENTITY();
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS RiskId, @score AS Score, @level AS RiskLevel;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── discharge summary (live + 2573: B8 record complete) ──
-- ── 6. discharge summary (draft -> signed; a signed summary is amended with a reason as a new version) ─────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischargeSummary_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT,
    @Diagnoses NVARCHAR(MAX) = NULL, @PresentingComplaints NVARCHAR(MAX) = NULL, @HistoryOfIllness NVARCHAR(MAX) = NULL, @PastHistory NVARCHAR(MAX) = NULL,
    @Allergies NVARCHAR(500) = NULL, @Examination NVARCHAR(MAX) = NULL, @Investigations NVARCHAR(MAX) = NULL, @Procedures NVARCHAR(MAX) = NULL,
    @CourseInHospital NVARCHAR(MAX) = NULL, @ConditionAtDischarge VARCHAR(15) = NULL, @ConditionNotes NVARCHAR(MAX) = NULL, @Medicines NVARCHAR(MAX) = NULL,
    @Diet NVARCHAR(500) = NULL, @Activity NVARCHAR(500) = NULL, @Advice NVARCHAR(MAX) = NULL, @WarningSigns NVARCHAR(MAX) = NULL, @FollowUp NVARCHAR(500) = NULL,
    @EmergencyContact NVARCHAR(300) = NULL, @Sign BIT = 0, @CanSign BIT = 0, @SignedByDoctorId INT = NULL, @AmendReason NVARCHAR(300) = NULL,
    @CanSignOnBehalf BIT = 0, @OnBehalfReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @status VARCHAR(20);
        SELECT @status = Status FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        IF @status = 'CANCELLED' THROW 58440, 'The admission is cancelled.', 1;
        IF @Diagnoses IS NOT NULL AND ISJSON(@Diagnoses) = 0 THROW 58441, 'The diagnoses could not be read.', 1;
        IF @Medicines IS NOT NULL AND ISJSON(@Medicines) = 0 THROW 58442, 'The medicines could not be read.', 1;
        DECLARE @type VARCHAR(12) = ISNULL((SELECT TOP 1 DischargeType FROM dbo.IpdDischarge WHERE AdmissionId = @AdmissionId AND Status <> 'CANCELLED' ORDER BY DischargeId DESC), 'NORMAL');
        DECLARE @draft INT = (SELECT SummaryId FROM dbo.IpdDischargeSummary WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'DRAFT');
        DECLARE @signed INT = (SELECT SummaryId FROM dbo.IpdDischargeSummary WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'SIGNED');
        SET @AmendReason = NULLIF(LTRIM(RTRIM(@AmendReason)), N'');
        IF @draft IS NULL
        BEGIN
            IF @signed IS NOT NULL AND ISNULL(@CanSign, 0) = 0 AND ISNULL(@CanSignOnBehalf, 0) = 0 THROW 58443, 'The summary is signed: only a user allowed to sign it can amend it.', 1;
            IF @signed IS NOT NULL AND @AmendReason IS NULL THROW 58444, 'The summary is signed: enter the reason for the amendment.', 1;
            INSERT dbo.IpdDischargeSummary (AdmissionId, Version, Status, SummaryType, AmendReason, CreatedBy)
            VALUES (@AdmissionId, ISNULL((SELECT MAX(Version) FROM dbo.IpdDischargeSummary WHERE AdmissionId = @AdmissionId), 0) + 1, 'DRAFT', @type,
                    CASE WHEN @signed IS NOT NULL THEN @AmendReason END, @UserId);
            SET @draft = CAST(SCOPE_IDENTITY() AS INT);
        END
        UPDATE dbo.IpdDischargeSummary SET SummaryType = @type, Diagnoses = @Diagnoses, PresentingComplaints = @PresentingComplaints, HistoryOfIllness = @HistoryOfIllness,
               PastHistory = @PastHistory, Allergies = @Allergies, Examination = @Examination, Investigations = @Investigations, Procedures = @Procedures,
               CourseInHospital = @CourseInHospital, ConditionAtDischarge = NULLIF(@ConditionAtDischarge, ''), ConditionNotes = @ConditionNotes, Medicines = @Medicines,
               Diet = @Diet, Activity = @Activity, Advice = @Advice, WarningSigns = @WarningSigns, FollowUp = @FollowUp, EmergencyContact = @EmergencyContact,
               AmendReason = ISNULL(@AmendReason, AmendReason), ModifiedBy = @UserId, ModifiedDate = @now
        WHERE SummaryId = @draft;
        IF ISNULL(@Sign, 0) = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @SignedByDoctorId AND IsActive = 1) THROW 58446, 'Choose the consultant signing the summary.', 1;
            -- own signature: the doctor linked to this login; anything else is a signature on behalf (bypass, with a reason)
            DECLARE @own BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @SignedByDoctorId AND LinkedUserId = @UserId) THEN 1 ELSE 0 END;
            SET @OnBehalfReason = NULLIF(LTRIM(RTRIM(@OnBehalfReason)), N'');
            IF @own = 1 AND ISNULL(@CanSign, 0) = 0 THROW 58445, 'You are not allowed to sign the discharge summary.', 1;
            IF @own = 0 AND ISNULL(@CanSignOnBehalf, 0) = 0
                THROW 58451, 'Only the consultant can sign with their own login: you are not allowed to sign on behalf of a doctor.', 1;
            IF @own = 0 AND @OnBehalfReason IS NULL THROW 58452, 'Enter why you are signing on behalf of the consultant.', 1;
            IF @Diagnoses IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@Diagnoses) WITH (title NVARCHAR(300) '$.title') WHERE NULLIF(LTRIM(RTRIM(title)), N'') IS NOT NULL)
                THROW 58447, 'Enter the final diagnosis before signing.', 1;
            IF NULLIF(LTRIM(RTRIM(@CourseInHospital)), N'') IS NULL THROW 58448, 'Enter the course in hospital before signing.', 1;
            IF NULLIF(@ConditionAtDischarge, '') IS NULL THROW 58449, 'Choose the condition at discharge before signing.', 1;
            IF @type NOT IN ('DEATH', 'ABSCONDED') AND NULLIF(LTRIM(RTRIM(@EmergencyContact)), N'') IS NULL THROW 58450, 'Enter the emergency contact (NABH) before signing.', 1;
            -- 2573 (B8): the doctor's part of the record is complete before the summary is signed (reconciliation not for a death / absconded)
            DECLARE @gap NVARCHAR(300) = (SELECT TOP 1 g.Message FROM dbo.fn_Ipd_RecordGaps(@AdmissionId) g
                                          WHERE g.Owner = 'DOCTOR' AND NOT (g.Sort = 40 AND @type IN ('DEATH', 'ABSCONDED')) ORDER BY g.Sort);
            IF @gap IS NOT NULL BEGIN SET @gap = N'Before signing: ' + @gap; THROW 59750, @gap, 1; END
            IF @signed IS NOT NULL UPDATE dbo.IpdDischargeSummary SET Status = 'SUPERSEDED' WHERE SummaryId = @signed;
            UPDATE dbo.IpdDischargeSummary SET Status = 'SIGNED', SignedByDoctorId = @SignedByDoctorId, SignedByUserId = @UserId, SignedAt = @now,
                   SignedOnBehalf = CASE WHEN @own = 1 THEN 0 ELSE 1 END, OnBehalfReason = CASE WHEN @own = 1 THEN NULL ELSE @OnBehalfReason END
            WHERE SummaryId = @draft;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
            SELECT @AdmissionId, 'SUMMARY_SIGNED', @status, @status,
                   CONCAT(CASE WHEN @type = 'DEATH' THEN N'Death summary' ELSE N'Discharge summary' END, N' version ', Version, N' signed', CASE WHEN SignedOnBehalf = 1 THEN N' on behalf of the consultant (' + OnBehalfReason + N')' ELSE N'' END, CASE WHEN AmendReason IS NOT NULL THEN N' (amended: ' + AmendReason + N')' ELSE N'' END), @UserId
            FROM dbo.IpdDischargeSummary WHERE SummaryId = @draft;
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @draft AS SummaryId, (SELECT Version FROM dbo.IpdDischargeSummary WHERE SummaryId = @draft) AS Version,
               (SELECT Status FROM dbo.IpdDischargeSummary WHERE SummaryId = @draft) AS SummaryStatus;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── discharge clearances (live + 2573: B8 nursing record) ──
-- ── 5. clearances ────────────────────────────────────────────────────────────────────────────────────────────
-- @Action CLEAR (checklist JSON: every item answered DONE or NA) | REOPEN. Checks:
--   PHARMACY  no open indent when Hospital Settings > Pharmacy "block discharge on pending indent" is on (default), else a remark
--   LAB       no test still waiting for its sample (cancel it or collect it); reports awaited need a remark (handed over later)
--   TPA       nothing waiting for the TPA (request, query, enhancement, final authorisation)
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Clear
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Dept VARCHAR(10), @Action VARCHAR(6) = 'CLEAR',
    @Checklist NVARCHAR(MAX) = NULL, @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @id INT, @cid INT, @cstatus VARCHAR(10);
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 58400, 'The admission was not found in this branch.', 1;
        SELECT @id = DischargeId FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'ADVISED';
        IF @id IS NULL THROW 58420, 'Advise the discharge first.', 1;
        SET @Dept = UPPER(@Dept);
        SELECT @cid = ClearanceId, @cstatus = Status FROM dbo.IpdDischargeClearance WITH (UPDLOCK) WHERE DischargeId = @id AND Dept = @Dept;
        IF @cid IS NULL THROW 58421, 'Unknown clearance.', 1;
        SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N'');
        IF @Action = 'REOPEN'
        BEGIN
            IF @cstatus = 'PENDING' THROW 58422, 'The clearance is still pending.', 1;
            IF @Remarks IS NULL THROW 58423, 'Enter the reason for reopening.', 1;
            UPDATE dbo.IpdDischargeClearance SET Status = 'PENDING', Remarks = @Remarks, ClearedBy = NULL, ClearedAt = NULL, ModifiedDate = @now WHERE ClearanceId = @cid;
            UPDATE dbo.IpdDischarge SET ClearedAt = NULL WHERE DischargeId = @id;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
            SELECT @AdmissionId, 'CLEARANCE_REOPEN', Status, Status, CONCAT(@Dept, N' clearance reopened: ', @Remarks), @UserId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId;
        END
        ELSE
        BEGIN
            IF @cstatus <> 'PENDING' THROW 58424, 'The clearance is already done.', 1;
            DECLARE @st TABLE (OpenIndents INT, LabNotCollected INT, LabPending INT, TpaWaiting VARCHAR(20));
            INSERT @st SELECT OpenIndents, ISNULL(LabNotCollected, 0), ISNULL(LabPending, 0), TpaWaiting FROM dbo.fn_Ipd_DischargeState(@AdmissionId);
            IF @Dept = 'PHARMACY'
            BEGIN
                DECLARE @block BIT = ISNULL((SELECT TOP 1 PharmacyBlockDischargeOnPendingIndent FROM dbo.HospitalSettings WHERE BranchID = @BranchId ORDER BY Id DESC), 1);
                IF (SELECT OpenIndents FROM @st) > 0 AND @block = 1 THROW 58425, 'Medicine indents are still open: issue or cancel them (Medicines tab) before the pharmacy clearance.', 1;
                IF (SELECT OpenIndents FROM @st) > 0 AND @Remarks IS NULL THROW 58426, 'Medicine indents are still open: enter a remark.', 1;
            END
            IF @Dept = 'LAB'
            BEGIN
                IF (SELECT LabNotCollected FROM @st) > 0 THROW 58427, 'Some LAB / radiology tests are still waiting for the sample: collect them or cancel them (LAB tab) first.', 1;
                IF (SELECT LabPending FROM @st) > 0 AND @Remarks IS NULL THROW 58428, 'Some reports are not ready: enter how they will reach the patient (e.g. collected at follow-up, sent on WhatsApp).', 1;
            END
            IF @Dept = 'TPA' AND (SELECT TpaWaiting FROM @st) IS NOT NULL
                THROW 58429, 'The pre-authorisation still waits for the TPA: record the TPA''s answer (Insurance / TPA tab) before the TPA clearance.', 1;
            -- 2573 (B8): the nursing part of the record is complete before the nursing clearance
            IF @Dept = 'NURSING'
            BEGIN
                DECLARE @ngap NVARCHAR(300) = (SELECT TOP 1 g.Message FROM dbo.fn_Ipd_RecordGaps(@AdmissionId) g WHERE g.Owner = 'NURSING' ORDER BY g.Sort);
                IF @ngap IS NOT NULL BEGIN SET @ngap = N'Before the nursing clearance: ' + @ngap; THROW 59751, @ngap, 1; END
            END
            IF @Checklist IS NOT NULL AND ISJSON(@Checklist) = 0 THROW 58430, 'The checklist could not be read.', 1;
            IF @Checklist IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@Checklist) WITH (answer NVARCHAR(10) '$.answer') WHERE ISNULL(answer, N'') NOT IN (N'DONE', N'NA'))
                THROW 58431, 'Answer every item of the checklist (Done or N/A).', 1;
            UPDATE dbo.IpdDischargeClearance SET Status = 'CLEARED', Checklist = @Checklist, Remarks = @Remarks, ClearedBy = @UserId, ClearedAt = @now, ModifiedDate = @now WHERE ClearanceId = @cid;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdDischargeClearance WHERE DischargeId = @id AND Status = 'PENDING')
                UPDATE dbo.IpdDischarge SET ClearedAt = @now WHERE DischargeId = @id;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
            SELECT @AdmissionId, 'CLEARANCE', Status, Status, CONCAT(@Dept, N' clearance done', CASE WHEN @Remarks IS NOT NULL THEN N': ' + @Remarks ELSE N'' END), @UserId
            FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId;
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── Clinical tab data (live + 2573: verification columns) ──
-- ── Clinical tab ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClinical_Data @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
    BEGIN
        SELECT TOP (0) CAST(NULL AS INT) AS AdmissionId; RETURN;
    END
    DECLARE @dh INT, @nh INT, @ch INT, @auto BIT;
    SELECT TOP (1) @dh = IpdDoctorAssessHours, @nh = IpdNursingAssessHours, @ch = IpdCountersignHours, @auto = IpdAutoVisitCharge
    FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;

    -- 0 state
    SELECT a.AdmissionId, a.Status, a.AdmissionAt, a.ConsultantDoctorId, cd.FullName AS ConsultantName, p.KnownAllergies,
           dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId) AS MyDoctorId,
           (SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId)) AS MyDoctorName,
           DATEADD(HOUR, ISNULL(@dh, 24), a.AdmissionAt) AS DoctorAssessDueAt,
           DATEADD(HOUR, ISNULL(@nh, 24), a.AdmissionAt) AS NursingAssessDueAt,
           ISNULL(@ch, 24) AS CountersignHours, ISNULL(@auto, 1) AS AutoVisitCharge,
           CAST(CASE WHEN a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL') THEN 1 ELSE 0 END AS BIT) AS ClinicalOpen,
           CAST(CASE WHEN a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED') AND a.BillId IS NULL THEN 1 ELSE 0 END AS BIT) AS BillOpen,
           @now AS ServerNow
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    WHERE a.AdmissionId = @AdmissionId;

    -- 1 assessments (current and earlier versions)
    SELECT s.AssessmentId, s.Kind, s.Status, s.Version, s.Data, s.DoctorId, d.FullName AS DoctorName, s.SignedAt,
           ISNULL(NULLIF(LTRIM(RTRIM(su.FullName)), N''), su.Username) AS SignedByName, s.AmendReason, s.CreatedDate, s.ModifiedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), N''), cu.Username) AS CreatedByName
    FROM dbo.IpdAssessment s
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.DoctorId
    LEFT JOIN dbo.Users su ON su.Id = s.SignedBy
    LEFT JOIN dbo.Users cu ON cu.Id = s.CreatedBy
    WHERE s.AdmissionId = @AdmissionId
    ORDER BY s.Kind, s.Version DESC;

    -- 2 rounds / progress notes
    SELECT n.NoteId, n.NoteType, n.DoctorId, d.FullName AS DoctorName, n.NoteAt, n.Subjective, n.Objective, n.Assessment, n.PlanText, n.Status,
           n.SignedAt, n.ChargeId, c.Net AS ChargeAmount, n.ChargeNote, n.CrossConsultId, n.StruckReason,
           ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), N''), cu.Username) AS CreatedByName, n.CreatedBy
    FROM dbo.IpdProgressNote n
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = n.DoctorId
    LEFT JOIN dbo.IpdCharge c ON c.ChargeId = n.ChargeId
    LEFT JOIN dbo.Users cu ON cu.Id = n.CreatedBy
    WHERE n.AdmissionId = @AdmissionId
    ORDER BY n.NoteAt DESC, n.NoteId DESC;

    -- 3 orders
    SELECT o.OrderId, o.OrderType, o.Priority, o.DoctorId, d.FullName AS DoctorName, o.OrderedAt, o.Source, o.ReadBack, o.CountersignDueAt,
           o.CountersignedAt, ISNULL(NULLIF(LTRIM(RTRIM(csu.FullName)), N''), csu.Username) AS CountersignedByName,
           CAST(CASE WHEN o.Source <> 'DIRECT' AND o.CountersignedAt IS NULL AND o.Status <> 'CANCELLED' AND o.CountersignDueAt < @now THEN 1 ELSE 0 END AS BIT) AS CountersignOverdue,
           o.Status, o.AckAt, ISNULL(NULLIF(LTRIM(RTRIM(au.FullName)), N''), au.Username) AS AckByName, o.StoppedAt, o.StopReason,
           o.ItemId, o.DrugName, o.Dose, o.Route, o.FrequencyCode, f.FrequencyName, f.Kind AS FrequencyKind, o.StartAt, o.EndAt, o.IsHighAlert, o.IndentId,
           o.ServiceKind, o.RefId, o.ServiceName, o.Qty, o.DoneAt, o.ChargeId, o.DietType, o.Details, o.VerifyStatus, o.VerifyNote, o.VerifiedAt, o.AllergyOverride, o.InteractionOverride,
           ISNULL(NULLIF(LTRIM(RTRIM(ou.FullName)), N''), ou.Username) AS OrderedByName
    FROM dbo.IpdOrder o
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    LEFT JOIN dbo.IpdFrequency f ON f.FrequencyCode = o.FrequencyCode
    LEFT JOIN dbo.Users ou ON ou.Id = o.OrderedBy
    LEFT JOIN dbo.Users au ON au.Id = o.AckBy
    LEFT JOIN dbo.Users csu ON csu.Id = o.CountersignedBy
    WHERE o.AdmissionId = @AdmissionId
    ORDER BY CASE o.Status WHEN 'ACTIVE' THEN 0 ELSE 1 END, o.OrderedAt DESC, o.OrderId DESC;

    -- 4 cross-consultations
    SELECT x.ConsultId, x.FromDoctorId, fd.FullName AS FromDoctorName, x.ToDoctorId, td.FullName AS ToDoctorName, x.Urgency, x.Reason,
           x.RequestedAt, x.Status, x.SeenAt, x.NoteId, x.CancelReason,
           ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), N''), ru.Username) AS RequestedByName
    FROM dbo.IpdCrossConsult x
    LEFT JOIN dbo.DoctorMaster fd ON fd.DoctorId = x.FromDoctorId
    LEFT JOIN dbo.DoctorMaster td ON td.DoctorId = x.ToDoctorId
    LEFT JOIN dbo.Users ru ON ru.Id = x.RequestedBy
    WHERE x.AdmissionId = @AdmissionId
    ORDER BY CASE x.Status WHEN 'REQUESTED' THEN 0 ELSE 1 END, x.RequestedAt DESC;

    -- 5 frequencies
    SELECT FrequencyCode, FrequencyName, Kind, TimesCsv FROM dbo.IpdFrequency WHERE IsActive = 1 ORDER BY SortOrder;

    -- 6 doctors of the company (pickers)
    SELECT DoctorId, FullName FROM dbo.DoctorMaster WHERE CompanyId = @CompanyId AND IsActive = 1 ORDER BY FullName;
END;
GO

-- ── Nursing tab data (live + 2573: verification columns) ──
-- ── Nursing tab ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdNursing_Data @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @FromAt DATETIME = NULL, @ToAt DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
    BEGIN SELECT TOP (0) CAST(NULL AS INT) AS AdmissionId; RETURN; END
    DECLARE @now DATETIME = GETDATE();
    SET @FromAt = ISNULL(@FromAt, CAST(CAST(@now AS DATE) AS DATETIME));
    SET @ToAt = ISNULL(@ToAt, DATEADD(MINUTE, -1, DATEADD(DAY, 1, @FromAt)));
    IF DATEDIFF(DAY, @FromAt, @ToAt) > 7 SET @ToAt = DATEADD(DAY, 7, @FromAt);
    DECLARE @late INT = ISNULL((SELECT TOP (1) IpdMarLateMinutes FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 60),
            @nh INT = ISNULL((SELECT TOP (1) IpdNursingAssessHours FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 24);

    -- 0 state
    SELECT a.AdmissionId, a.Status, a.AdmissionAt, p.KnownAllergies, @late AS LateMinutes, @FromAt AS FromAt, @ToAt AS ToAt, @now AS ServerNow,
           CAST(CASE WHEN a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL') THEN 1 ELSE 0 END AS BIT) AS ClinicalOpen,
           DATEADD(HOUR, @nh, a.AdmissionAt) AS NursingAssessDueAt,
           (SELECT TOP (1) Status FROM dbo.IpdAssessment WHERE AdmissionId = a.AdmissionId AND Kind = 'NURSING' AND Status <> 'SUPERSEDED') AS NursingAssessStatus,
           v.ObservedAt AS LastVitalsAt, v.News2 AS LastNews2, v.News2Risk AS LastNews2Risk,
           DATEADD(MINUTE, dbo.fn_Ipd_VitalsEveryMinutes(v.News2, v.News2Risk), ISNULL(v.ObservedAt, a.AdmissionAt)) AS VitalsDueAt,
           mf.Score AS MorseScore, mf.RiskLevel AS MorseRisk, mf.AssessedAt AS MorseAt,
           br.Score AS BradenScore, br.RiskLevel AS BradenRisk, br.AssessedAt AS BradenAt,
           dt.DietType AS CurrentDiet, dt.Details AS DietDetails
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    OUTER APPLY (SELECT TOP (1) ObservedAt, News2, News2Risk FROM dbo.IpdVital WHERE AdmissionId = a.AdmissionId AND Status = 'ACTIVE' ORDER BY ObservedAt DESC) v
    OUTER APPLY (SELECT TOP (1) Score, RiskLevel, AssessedAt FROM dbo.IpdRiskScore WHERE AdmissionId = a.AdmissionId AND Kind = 'MORSE' AND Status = 'ACTIVE' ORDER BY AssessedAt DESC) mf
    OUTER APPLY (SELECT TOP (1) Score, RiskLevel, AssessedAt FROM dbo.IpdRiskScore WHERE AdmissionId = a.AdmissionId AND Kind = 'BRADEN' AND Status = 'ACTIVE' ORDER BY AssessedAt DESC) br
    OUTER APPLY (SELECT TOP (1) DietType, Details FROM dbo.IpdOrder WHERE AdmissionId = a.AdmissionId AND OrderType = 'DIET' AND Status = 'ACTIVE' ORDER BY OrderedAt DESC) dt
    WHERE a.AdmissionId = @AdmissionId;

    -- 1 medication orders of the window (eMAR rows)
    SELECT o.OrderId, o.DrugName, o.Dose, o.Route, o.FrequencyCode, f.FrequencyName, f.Kind AS FrequencyKind, o.StartAt, o.EndAt, o.Status, o.StoppedAt,
           o.StopReason, o.IsHighAlert, o.Priority, o.Source, o.CountersignedAt, o.AckAt, o.Details AS Instructions, d.FullName AS DoctorName, o.VerifyStatus, o.VerifyNote
    FROM dbo.IpdOrder o
    LEFT JOIN dbo.IpdFrequency f ON f.FrequencyCode = o.FrequencyCode
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    WHERE o.AdmissionId = @AdmissionId AND o.OrderType = 'MED' AND o.Status <> 'CANCELLED'
      AND o.StartAt <= @ToAt AND COALESCE(o.StoppedAt, o.EndAt, '9999-12-31') >= @FromAt
    ORDER BY CASE o.Status WHEN 'ACTIVE' THEN 0 ELSE 1 END, o.StartAt;

    -- 2 doses of the window
    SELECT x.OrderId, x.DueAt, x.MarId, x.Outcome, x.GivenAt, x.DoseGiven, x.Reason, x.WitnessName, x.DoseStatus,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS RecordedByName
    FROM dbo.fn_Ipd_MarDoses(@AdmissionId, @FromAt, @ToAt, @late) x
    LEFT JOIN dbo.Users u ON u.Id = x.RecordedBy
    ORDER BY x.OrderId, ISNULL(x.DueAt, x.GivenAt);

    -- 3 vitals of the window
    SELECT v.VitalId, v.ObservedAt, v.Rr, v.SpO2, v.OnOxygen, v.O2Device, v.O2FlowLpm, v.Sbp, v.Dbp, v.Pulse, v.Consciousness, v.TempC, v.PainScore,
           v.Glucose, v.WeightKg, v.News2, v.News2Risk, v.Notes, v.Status, v.StruckReason,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS RecordedByName
    FROM dbo.IpdVital v LEFT JOIN dbo.Users u ON u.Id = v.RecordedBy
    WHERE v.AdmissionId = @AdmissionId AND v.ObservedAt BETWEEN DATEADD(DAY, -2, @FromAt) AND @ToAt
    ORDER BY v.ObservedAt DESC;

    -- 4 intake / output of the window
    SELECT i.IoId, i.At, i.Direction, i.Category, i.VolumeMl, i.Notes, i.Status, i.StruckReason,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS RecordedByName
    FROM dbo.IpdIntakeOutput i LEFT JOIN dbo.Users u ON u.Id = i.RecordedBy
    WHERE i.AdmissionId = @AdmissionId AND i.At BETWEEN @FromAt AND @ToAt
    ORDER BY i.At DESC;

    -- 5 nursing notes (last 3 days of the window)
    SELECT n.NoteId, n.NoteAt, n.Shift, n.Note, n.Status, n.StruckReason, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS RecordedByName
    FROM dbo.IpdNursingNote n LEFT JOIN dbo.Users u ON u.Id = n.RecordedBy
    WHERE n.AdmissionId = @AdmissionId AND n.NoteAt BETWEEN DATEADD(DAY, -2, @FromAt) AND @ToAt
    ORDER BY n.NoteAt DESC;

    -- 6 risk scores (all)
    SELECT r.RiskId, r.Kind, r.AssessedAt, r.Answers, r.Score, r.RiskLevel, r.Interventions, r.Status, r.StruckReason,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS RecordedByName
    FROM dbo.IpdRiskScore r LEFT JOIN dbo.Users u ON u.Id = r.RecordedBy
    WHERE r.AdmissionId = @AdmissionId ORDER BY r.AssessedAt DESC;

    -- 7 care plan
    SELECT c.PlanId, c.Problem, c.Goal, c.Interventions, c.Status, c.Evaluation, c.CreatedDate, c.ClosedAt,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS CreatedByName
    FROM dbo.IpdCarePlan c LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    WHERE c.AdmissionId = @AdmissionId AND c.Status <> 'STRUCK'
    ORDER BY CASE c.Status WHEN 'ACTIVE' THEN 0 ELSE 1 END, c.CreatedDate DESC;

    -- 8 handovers (latest 20)
    SELECT TOP (20) h.HandoverId, h.HandoverAt, h.Shift, h.Situation, h.Background, h.AssessmentText, h.Recommendation, h.ReceivedAt,
           ISNULL(NULLIF(LTRIM(RTRIM(g.FullName)), N''), g.Username) AS GivenByName, ISNULL(NULLIF(LTRIM(RTRIM(r.FullName)), N''), r.Username) AS ReceivedByName, h.GivenBy
    FROM dbo.IpdHandover h LEFT JOIN dbo.Users g ON g.Id = h.GivenBy LEFT JOIN dbo.Users r ON r.Id = h.ReceivedBy
    WHERE h.AdmissionId = @AdmissionId AND h.Status = 'ACTIVE' ORDER BY h.HandoverAt DESC;

    -- 9 incidents
    SELECT i.IncidentId, i.IncidentType, i.Severity, i.OccurredAt, i.Location, i.Description, i.ImmediateAction, i.DoctorInformed, i.Status, i.ClosedAt, i.Closure,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS ReportedByName
    FROM dbo.IpdIncident i LEFT JOIN dbo.Users u ON u.Id = i.ReportedBy
    WHERE i.AdmissionId = @AdmissionId ORDER BY i.OccurredAt DESC;

    -- 10 active doctor instructions for the nurse (diet, nursing, services) with acknowledgement
    SELECT o.OrderId, o.OrderType, o.Priority, o.DietType, o.Details, o.ServiceName, o.Qty, o.OrderedAt, o.AckAt, o.Source, o.CountersignedAt, d.FullName AS DoctorName
    FROM dbo.IpdOrder o LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    WHERE o.AdmissionId = @AdmissionId AND o.Status = 'ACTIVE' AND o.OrderType IN ('DIET', 'NURSING', 'SERVICE')
    ORDER BY CASE o.Priority WHEN 'STAT' THEN 0 WHEN 'URGENT' THEN 1 ELSE 2 END, o.OrderedAt DESC;
END;
GO


PRINT '2573 IPD flow-gap clinical - done.';
GO
