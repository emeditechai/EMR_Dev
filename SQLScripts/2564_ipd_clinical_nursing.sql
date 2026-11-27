-- ============================================================================================================
-- 2564  IPD Phase 3 - Clinical (nursing): Nursing tab data, eMAR, vitals with NEWS2, intake / output, nursing notes,
--       Morse / Braden risk, care plan, SBAR handover, incidents, strike-out of a wrong entry and the Nursing Station
--       worklist. After 2562, 2563.
--   eMAR: the due doses come from the medication orders and their frequency (fn_Ipd_MarDue); a dose is GIVEN, HELD or
--   REFUSED (reason), given more than the late minutes (Hospital Settings, 60) from its time needs a reason, a high-alert
--   drug needs the second nurse's name; an SOS dose needs its indication. NEWS2 risk sets how often vitals are due:
--   high (7+) and medium (5-6) or a single red parameter = hourly, 1-4 = 4-hourly, 0 = 12-hourly.
--   Writes return Success / Error rows. Errors 59400-59599. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO

-- ── how often vitals are due for a NEWS2 result (minutes) ──
CREATE OR ALTER FUNCTION dbo.fn_Ipd_VitalsEveryMinutes (@News2 INT, @Risk VARCHAR(12))
RETURNS INT
AS
BEGIN
    RETURN CASE WHEN @Risk IN ('HIGH', 'MEDIUM', 'LOW_MEDIUM') THEN 60 WHEN @News2 IS NULL THEN 240 WHEN @News2 = 0 THEN 720 ELSE 240 END;
END;
GO

-- ── the doses of a window with what was done (eMAR grid) ──
CREATE OR ALTER FUNCTION dbo.fn_Ipd_MarDoses (@AdmissionId INT, @FromAt DATETIME, @ToAt DATETIME, @LateMinutes INT)
RETURNS TABLE
AS
RETURN
    SELECT d.OrderId, d.DueAt, m.MarId, m.Outcome, m.GivenAt, m.DoseGiven, m.Reason, m.WitnessName, m.RecordedBy,
           DoseStatus = CASE WHEN m.MarId IS NOT NULL THEN m.Outcome
                             WHEN d.DueAt < DATEADD(MINUTE, -@LateMinutes, GETDATE()) THEN 'OVERDUE'
                             WHEN d.DueAt <= DATEADD(MINUTE, @LateMinutes, GETDATE()) THEN 'DUE'
                             ELSE 'UPCOMING' END
    FROM dbo.fn_Ipd_MarDue(@AdmissionId, @FromAt, @ToAt) d
    LEFT JOIN dbo.IpdMarAdmin m ON m.OrderId = d.OrderId AND m.DueAt = d.DueAt AND m.Status = 'ACTIVE'
    UNION ALL   -- SOS doses (no schedule)
    SELECT m.OrderId, NULL, m.MarId, m.Outcome, m.GivenAt, m.DoseGiven, m.Reason, m.WitnessName, m.RecordedBy, m.Outcome
    FROM dbo.IpdMarAdmin m
    WHERE m.AdmissionId = @AdmissionId AND m.DueAt IS NULL AND m.Status = 'ACTIVE' AND m.GivenAt BETWEEN @FromAt AND @ToAt;
GO

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
           o.StopReason, o.IsHighAlert, o.Priority, o.Source, o.CountersignedAt, o.AckAt, o.Details AS Instructions, d.FullName AS DoctorName
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
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS VitalId, @score AS News2, @risk AS News2Risk,
               dbo.fn_Ipd_VitalsEveryMinutes(@score, @risk) AS NextInMinutes;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── intake / output, nursing note, risk score, care plan, handover, incident: one procedure per entry ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIo_Add
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @At DATETIME = NULL, @Direction CHAR(3), @Category VARCHAR(12), @VolumeMl INT, @Notes NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @At = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @At), 0), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @now), 0));
        IF @At > DATEADD(MINUTE, 5, @now) OR @At < @admAt THROW 59410, 'The time must be after the admission and not in the future.', 1;
        SELECT @Direction = UPPER(@Direction), @Category = UPPER(@Category);
        IF @Direction NOT IN ('IN', 'OUT') THROW 59411, 'Choose intake or output.', 1;
        IF (@Direction = 'IN' AND @Category NOT IN ('ORAL', 'IV', 'RT_FEED', 'BLOOD', 'OTHER'))
           OR (@Direction = 'OUT' AND @Category NOT IN ('URINE', 'DRAIN', 'VOMIT', 'STOOL', 'ASPIRATE', 'OTHER'))
            THROW 59412, 'Choose what was taken in / given out.', 1;
        IF ISNULL(@VolumeMl, 0) NOT BETWEEN 1 AND 10000 THROW 59413, 'The volume must be 1-10,000 ml.', 1;
        INSERT dbo.IpdIntakeOutput (AdmissionId, At, Direction, Category, VolumeMl, Notes, RecordedBy)
        VALUES (@AdmissionId, @At, @Direction, @Category, @VolumeMl, NULLIF(LTRIM(RTRIM(@Notes)), N''), @UserId);
        DECLARE @id BIGINT = SCOPE_IDENTITY();
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS IoId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdNursingNote_Add
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @NoteAt DATETIME = NULL, @Shift VARCHAR(10) = NULL, @Note NVARCHAR(2000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @NoteAt = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @NoteAt), 0), DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @now), 0));
        IF @NoteAt > DATEADD(MINUTE, 5, @now) OR @NoteAt < @admAt THROW 59420, 'The time must be after the admission and not in the future.', 1;
        IF NULLIF(LTRIM(RTRIM(@Note)), N'') IS NULL THROW 59421, 'Write the note.', 1;
        SET @Shift = ISNULL(NULLIF(UPPER(@Shift), ''), CASE WHEN DATEPART(HOUR, @NoteAt) BETWEEN 8 AND 13 THEN 'MORNING' WHEN DATEPART(HOUR, @NoteAt) BETWEEN 14 AND 19 THEN 'EVENING' ELSE 'NIGHT' END);
        IF @Shift NOT IN ('MORNING', 'EVENING', 'NIGHT') THROW 59422, 'Choose the shift.', 1;
        INSERT dbo.IpdNursingNote (AdmissionId, NoteAt, Shift, Note, RecordedBy) VALUES (@AdmissionId, @NoteAt, @Shift, LTRIM(RTRIM(@Note)), @UserId);
        DECLARE @id BIGINT = SCOPE_IDENTITY();
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS NoteId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

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

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCarePlan_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @PlanId INT = NULL, @Problem NVARCHAR(300) = NULL, @Goal NVARCHAR(500) = NULL,
    @Interventions NVARCHAR(1000) = NULL, @Resolve BIT = 0, @Evaluation NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        IF @Resolve = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdCarePlan WITH (UPDLOCK) WHERE PlanId = @PlanId AND AdmissionId = @AdmissionId AND Status = 'ACTIVE')
                THROW 59440, 'Only an active problem can be closed.', 1;
            IF NULLIF(LTRIM(RTRIM(@Evaluation)), N'') IS NULL THROW 59441, 'Write the evaluation (goal met / not met and why).', 1;
            UPDATE dbo.IpdCarePlan SET Status = 'RESOLVED', Evaluation = LTRIM(RTRIM(@Evaluation)), ClosedBy = @UserId, ClosedAt = @now WHERE PlanId = @PlanId;
        END
        ELSE
        BEGIN
            SELECT @Problem = NULLIF(LTRIM(RTRIM(@Problem)), N''), @Goal = NULLIF(LTRIM(RTRIM(@Goal)), N''), @Interventions = NULLIF(LTRIM(RTRIM(@Interventions)), N'');
            IF @Problem IS NULL OR @Goal IS NULL OR @Interventions IS NULL THROW 59442, 'Enter the problem, the goal and the interventions.', 1;
            IF EXISTS (SELECT 1 FROM dbo.IpdCarePlan WHERE AdmissionId = @AdmissionId AND Status = 'ACTIVE' AND Problem = @Problem)
                THROW 59443, 'This problem is already in the care plan.', 1;
            INSERT dbo.IpdCarePlan (AdmissionId, Problem, Goal, Interventions, CreatedBy) VALUES (@AdmissionId, @Problem, @Goal, @Interventions, @UserId);
            SET @PlanId = SCOPE_IDENTITY();
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @PlanId AS PlanId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdHandover_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @HandoverId INT = NULL, @Shift VARCHAR(10) = NULL, @Situation NVARCHAR(1000) = NULL,
    @Background NVARCHAR(1000) = NULL, @AssessmentText NVARCHAR(1000) = NULL, @Recommendation NVARCHAR(1000) = NULL, @Receive BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        IF @Receive = 1
        BEGIN
            DECLARE @giver INT, @rec DATETIME;
            SELECT @giver = GivenBy, @rec = ReceivedAt FROM dbo.IpdHandover WITH (UPDLOCK) WHERE HandoverId = @HandoverId AND AdmissionId = @AdmissionId AND Status = 'ACTIVE';
            IF @giver IS NULL THROW 59450, 'The handover was not found.', 1;
            IF @rec IS NOT NULL THROW 59451, 'The handover is already taken over.', 1;
            IF @giver = @UserId THROW 59452, 'The nurse taking over (not the one handing over) acknowledges the handover.', 1;
            UPDATE dbo.IpdHandover SET ReceivedBy = @UserId, ReceivedAt = @now WHERE HandoverId = @HandoverId;
        END
        ELSE
        BEGIN
            SET @Shift = ISNULL(NULLIF(UPPER(@Shift), ''), CASE WHEN DATEPART(HOUR, @now) BETWEEN 8 AND 13 THEN 'MORNING' WHEN DATEPART(HOUR, @now) BETWEEN 14 AND 19 THEN 'EVENING' ELSE 'NIGHT' END);
            IF @Shift NOT IN ('MORNING', 'EVENING', 'NIGHT') THROW 59453, 'Choose the shift.', 1;
            SELECT @Situation = NULLIF(LTRIM(RTRIM(@Situation)), N''), @Background = NULLIF(LTRIM(RTRIM(@Background)), N''),
                   @AssessmentText = NULLIF(LTRIM(RTRIM(@AssessmentText)), N''), @Recommendation = NULLIF(LTRIM(RTRIM(@Recommendation)), N'');
            IF @Situation IS NULL OR @AssessmentText IS NULL OR @Recommendation IS NULL
                THROW 59454, 'Fill Situation, Assessment and Recommendation of the SBAR handover.', 1;
            INSERT dbo.IpdHandover (AdmissionId, HandoverAt, Shift, Situation, Background, AssessmentText, Recommendation, GivenBy)
            VALUES (@AdmissionId, @now, @Shift, @Situation, @Background, @AssessmentText, @Recommendation, @UserId);
            SET @HandoverId = SCOPE_IDENTITY();
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @HandoverId AS HandoverId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdIncident_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @IncidentId INT = NULL, @IncidentType VARCHAR(20) = NULL, @Severity VARCHAR(12) = NULL,
    @OccurredAt DATETIME = NULL, @Location NVARCHAR(100) = NULL, @Description NVARCHAR(2000) = NULL, @ImmediateAction NVARCHAR(1000) = NULL,
    @DoctorInformed BIT = 0, @Close BIT = 0, @Closure NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 59460, 'The admission was not found in this branch.', 1;
        IF @Close = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdIncident WITH (UPDLOCK) WHERE IncidentId = @IncidentId AND AdmissionId = @AdmissionId AND Status = 'OPEN')
                THROW 59461, 'Only an open incident can be closed.', 1;
            IF NULLIF(LTRIM(RTRIM(@Closure)), N'') IS NULL THROW 59462, 'Write the closure (root cause and corrective / preventive action).', 1;
            UPDATE dbo.IpdIncident SET Status = 'CLOSED', ClosedBy = @UserId, ClosedAt = @now, Closure = LTRIM(RTRIM(@Closure)) WHERE IncidentId = @IncidentId;
        END
        ELSE
        BEGIN
            DECLARE @admAt DATETIME, @st VARCHAR(20);
            EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
            SELECT @IncidentType = UPPER(@IncidentType), @Severity = UPPER(@Severity);
            IF @IncidentType NOT IN ('FALL', 'MEDICATION', 'PRESSURE_INJURY', 'NEEDLE_STICK', 'IV_SITE', 'EQUIPMENT', 'BEHAVIOUR', 'OTHER') OR @IncidentType IS NULL
                THROW 59463, 'Choose the type of incident.', 1;
            IF @Severity NOT IN ('NEAR_MISS', 'NO_HARM', 'MILD', 'MODERATE', 'SEVERE', 'DEATH') OR @Severity IS NULL THROW 59464, 'Choose the severity.', 1;
            IF @OccurredAt IS NULL OR @OccurredAt > DATEADD(MINUTE, 5, @now) OR @OccurredAt < @admAt THROW 59465, 'Enter when it happened (after the admission, not in the future).', 1;
            IF NULLIF(LTRIM(RTRIM(@Description)), N'') IS NULL THROW 59466, 'Describe what happened.', 1;
            IF @Severity NOT IN ('NEAR_MISS', 'NO_HARM') AND NULLIF(LTRIM(RTRIM(@ImmediateAction)), N'') IS NULL THROW 59467, 'Write the immediate action taken.', 1;
            INSERT dbo.IpdIncident (AdmissionId, IncidentType, Severity, OccurredAt, Location, Description, ImmediateAction, DoctorInformed, ReportedBy)
            VALUES (@AdmissionId, @IncidentType, @Severity, @OccurredAt, NULLIF(LTRIM(RTRIM(@Location)), N''), LTRIM(RTRIM(@Description)),
                    NULLIF(LTRIM(RTRIM(@ImmediateAction)), N''), ISNULL(@DoctorInformed, 0), @UserId);
            SET @IncidentId = SCOPE_IDENTITY();
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@AdmissionId, 'INCIDENT', CONCAT(N'Incident reported: ', @IncidentType, N' (', @Severity, N')'), @UserId);
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @IncidentId AS IncidentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── eMAR: record a dose ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdMar_Record
    @CompanyId INT, @BranchId INT, @UserId INT, @OrderId INT, @DueAt DATETIME = NULL, @Outcome VARCHAR(10), @GivenAt DATETIME = NULL,
    @DoseGiven NVARCHAR(60) = NULL, @Site NVARCHAR(60) = NULL, @Reason NVARCHAR(300) = NULL, @WitnessName NVARCHAR(100) = NULL
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

-- ── strike out a wrong entry (kept, shown struck through) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdClinical_Strike @CompanyId INT, @BranchId INT, @UserId INT, @Kind VARCHAR(10), @Id BIGINT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N''); SET @Kind = UPPER(@Kind);
        IF @Reason IS NULL THROW 59490, 'Enter the reason.', 1;
        DECLARE @adm INT, @st VARCHAR(12);
        IF @Kind = 'MAR' SELECT @adm = AdmissionId, @st = Status FROM dbo.IpdMarAdmin WITH (UPDLOCK) WHERE MarId = @Id;
        ELSE IF @Kind = 'VITAL' SELECT @adm = AdmissionId, @st = Status FROM dbo.IpdVital WITH (UPDLOCK) WHERE VitalId = @Id;
        ELSE IF @Kind = 'IO' SELECT @adm = AdmissionId, @st = Status FROM dbo.IpdIntakeOutput WITH (UPDLOCK) WHERE IoId = @Id;
        ELSE IF @Kind = 'NNOTE' SELECT @adm = AdmissionId, @st = Status FROM dbo.IpdNursingNote WITH (UPDLOCK) WHERE NoteId = @Id;
        ELSE IF @Kind = 'RISK' SELECT @adm = AdmissionId, @st = Status FROM dbo.IpdRiskScore WITH (UPDLOCK) WHERE RiskId = @Id;
        ELSE IF @Kind = 'PNOTE' SELECT @adm = AdmissionId, @st = CASE Status WHEN 'STRUCK' THEN 'STRUCK' ELSE 'ACTIVE' END FROM dbo.IpdProgressNote WITH (UPDLOCK) WHERE NoteId = @Id;
        ELSE IF @Kind = 'PLAN' SELECT @adm = AdmissionId, @st = CASE Status WHEN 'STRUCK' THEN 'STRUCK' ELSE 'ACTIVE' END FROM dbo.IpdCarePlan WITH (UPDLOCK) WHERE PlanId = @Id;
        ELSE THROW 59491, 'Unknown entry.', 1;
        IF @adm IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @adm AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 59492, 'The entry was not found in this branch.', 1;
        IF @st <> 'ACTIVE' THROW 59493, 'The entry is already struck out.', 1;
        DECLARE @admAt DATETIME, @ast VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @adm, @admAt OUTPUT, @ast OUTPUT;
        IF @Kind = 'MAR' UPDATE dbo.IpdMarAdmin SET Status = 'STRUCK', StruckBy = @UserId, StruckAt = @now, StruckReason = @Reason WHERE MarId = @Id;
        ELSE IF @Kind = 'VITAL' UPDATE dbo.IpdVital SET Status = 'STRUCK', StruckBy = @UserId, StruckAt = @now, StruckReason = @Reason WHERE VitalId = @Id;
        ELSE IF @Kind = 'IO' UPDATE dbo.IpdIntakeOutput SET Status = 'STRUCK', StruckBy = @UserId, StruckAt = @now, StruckReason = @Reason WHERE IoId = @Id;
        ELSE IF @Kind = 'NNOTE' UPDATE dbo.IpdNursingNote SET Status = 'STRUCK', StruckBy = @UserId, StruckAt = @now, StruckReason = @Reason WHERE NoteId = @Id;
        ELSE IF @Kind = 'RISK' UPDATE dbo.IpdRiskScore SET Status = 'STRUCK', StruckBy = @UserId, StruckAt = @now, StruckReason = @Reason WHERE RiskId = @Id;
        ELSE IF @Kind = 'PNOTE' UPDATE dbo.IpdProgressNote SET Status = 'STRUCK', StruckBy = @UserId, StruckAt = @now, StruckReason = @Reason WHERE NoteId = @Id;
        ELSE IF @Kind = 'PLAN' UPDATE dbo.IpdCarePlan SET Status = 'STRUCK', ClosedBy = @UserId, ClosedAt = @now, Evaluation = N'Struck out: ' + @Reason WHERE PlanId = @Id;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @Id AS Id;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── IPD > Nursing Station: the patients of a station (ward) with what is due ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdNursingStation_Board @CompanyId INT, @BranchId INT, @UserId INT, @StationId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    DECLARE @late INT = ISNULL((SELECT TOP (1) IpdMarLateMinutes FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 60),
            @nh INT = ISNULL((SELECT TOP (1) IpdNursingAssessHours FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 24),
            @dh INT = ISNULL((SELECT TOP (1) IpdDoctorAssessHours FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 24);
    DECLARE @ward INT = (SELECT WardId FROM dbo.NursingStationMaster WHERE NursingStationId = @StationId AND BranchId = @BranchId);

    -- 0 stations of the branch
    SELECT s.NursingStationId, s.StationName, s.WardId, w.WardName,
           (SELECT COUNT(*) FROM dbo.IpdAdmission a JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
            WHERE a.BranchId = @BranchId AND a.IsOpen = 1 AND a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL') AND b.WardId = s.WardId) AS Patients
    FROM dbo.NursingStationMaster s LEFT JOIN dbo.WardMaster w ON w.WardId = s.WardId
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 ORDER BY s.StationName;

    -- 1 patients with their tasks
    ;WITH adm AS (
        SELECT a.AdmissionId, a.IpNo, a.AdmissionAt, a.Status, a.ConsultantDoctorId, a.PatientId, b.BedNumber, b.WardId
        FROM dbo.IpdAdmission a JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
        WHERE a.CompanyId = @CompanyId AND a.BranchId = @BranchId AND a.IsOpen = 1 AND a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL')
          AND (@ward IS NULL OR b.WardId = @ward))
    SELECT x.AdmissionId, x.IpNo, x.BedNumber, w.WardName, x.Status, x.AdmissionAt,
           LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))) AS PatientName, p.PatientCode, p.Gender, p.KnownAllergies,
           d.FullName AS ConsultantName,
           v.News2, v.News2Risk, v.ObservedAt AS LastVitalsAt,
           DATEADD(MINUTE, dbo.fn_Ipd_VitalsEveryMinutes(v.News2, v.News2Risk), ISNULL(v.ObservedAt, x.AdmissionAt)) AS VitalsDueAt,
           md.DueNext, md.Overdue,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = x.AdmissionId AND o.Status = 'ACTIVE' AND o.AckAt IS NULL) AS NewOrders,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = x.AdmissionId AND o.Source <> 'DIRECT' AND o.CountersignedAt IS NULL AND o.Status <> 'CANCELLED') AS ToCountersign,
           (SELECT COUNT(*) FROM dbo.IpdOrder o WHERE o.AdmissionId = x.AdmissionId AND o.Source <> 'DIRECT' AND o.CountersignedAt IS NULL AND o.Status <> 'CANCELLED' AND o.CountersignDueAt < @now) AS CountersignOverdue,
           (SELECT COUNT(*) FROM dbo.LabOrder lo JOIN dbo.SampleCollection sc ON sc.Laborderid = lo.LabOrderId
            WHERE lo.AdmissionId = x.AdmissionId AND ISNULL(lo.IsActive, 1) = 1 AND ISNULL(sc.Is_Active, 1) = 1 AND ISNULL(sc.Iscancelled, 0) = 0 AND sc.CollectionstatusID IN (1, 3)) AS PendingSamples,
           CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.IpdAssessment WHERE AdmissionId = x.AdmissionId AND Kind = 'NURSING' AND Status = 'SIGNED')
                      AND DATEADD(HOUR, @nh, x.AdmissionAt) < @now THEN 1 ELSE 0 END AS BIT) AS NursingAssessOverdue,
           CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.IpdAssessment WHERE AdmissionId = x.AdmissionId AND Kind = 'DOCTOR' AND Status = 'SIGNED')
                      AND DATEADD(HOUR, @dh, x.AdmissionAt) < @now THEN 1 ELSE 0 END AS BIT) AS DoctorAssessOverdue,
           mf.RiskLevel AS FallRisk, br.RiskLevel AS PressureRisk,
           (SELECT COUNT(*) FROM dbo.IpdCrossConsult c WHERE c.AdmissionId = x.AdmissionId AND c.Status = 'REQUESTED') AS ConsultsWaiting,
           (SELECT COUNT(*) FROM dbo.IpdIncident i WHERE i.AdmissionId = x.AdmissionId AND i.Status = 'OPEN') AS OpenIncidents,
           (SELECT TOP (1) DietType FROM dbo.IpdOrder o WHERE o.AdmissionId = x.AdmissionId AND o.OrderType = 'DIET' AND o.Status = 'ACTIVE' ORDER BY o.OrderedAt DESC) AS Diet,
           @now AS ServerNow
    FROM adm x
    JOIN dbo.PatientMaster p ON p.PatientId = x.PatientId
    LEFT JOIN dbo.WardMaster w ON w.WardId = x.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = x.ConsultantDoctorId
    OUTER APPLY (SELECT TOP (1) ObservedAt, News2, News2Risk FROM dbo.IpdVital WHERE AdmissionId = x.AdmissionId AND Status = 'ACTIVE' ORDER BY ObservedAt DESC) v
    OUTER APPLY (SELECT TOP (1) RiskLevel FROM dbo.IpdRiskScore WHERE AdmissionId = x.AdmissionId AND Kind = 'MORSE' AND Status = 'ACTIVE' ORDER BY AssessedAt DESC) mf
    OUTER APPLY (SELECT TOP (1) RiskLevel FROM dbo.IpdRiskScore WHERE AdmissionId = x.AdmissionId AND Kind = 'BRADEN' AND Status = 'ACTIVE' ORDER BY AssessedAt DESC) br
    OUTER APPLY (SELECT SUM(CASE WHEN m.DoseStatus = 'DUE' OR (m.DoseStatus = 'UPCOMING' AND m.DueAt <= DATEADD(HOUR, 2, @now)) THEN 1 ELSE 0 END) AS DueNext,
                        SUM(CASE WHEN m.DoseStatus = 'OVERDUE' THEN 1 ELSE 0 END) AS Overdue
                 FROM dbo.fn_Ipd_MarDoses(x.AdmissionId, DATEADD(HOUR, -24, @now), DATEADD(HOUR, 2, @now), @late) m WHERE m.DueAt IS NOT NULL) md
    ORDER BY CASE v.News2Risk WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW_MEDIUM' THEN 2 ELSE 3 END, w.WardName, x.BedNumber;
END;
GO

PRINT 'Script 2564 applied: IPD Phase 3 nursing procedures.';
GO
