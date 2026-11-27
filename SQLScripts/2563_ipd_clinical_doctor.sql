-- ============================================================================================================
-- 2563  IPD Phase 3 - Clinical (doctor): data of the Clinical tab, initial assessment (doctor and nursing),
--       rounds / progress notes with the automatic visit charge, CPOE orders with verbal-order countersign,
--       order actions (acknowledge, countersign, stop, cancel, done), cross-consultation. After 2562.
--   Who is a doctor: the login linked to a doctor in Doctor Master (Linked User). A doctor's order is DIRECT; any other
--   user enters a VERBAL / TELEPHONE order of a chosen doctor with read-back, countersigned by that doctor within
--   the countersign hours (Hospital Settings, 24). A signed round / cross-consultation note charges the doctor's IPD
--   visit charge once per doctor per day (Hospital Settings > automatic visit charge); a missing rate never blocks the note.
--   Writes return Success / Error rows. Errors 59200-59399. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO

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
           o.ServiceKind, o.RefId, o.ServiceName, o.Qty, o.DoneAt, o.ChargeId, o.DietType, o.Details,
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

-- ── shared check: the admission is in this branch and still in hospital ──
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ClinicalCheck @CompanyId INT, @BranchId INT, @AdmissionId INT, @AdmissionAt DATETIME OUTPUT, @Status VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Status = Status, @AdmissionAt = AdmissionAt FROM dbo.IpdAdmission WITH (UPDLOCK)
    WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @Status IS NULL THROW 59200, 'The admission was not found in this branch.', 1;
    IF @Status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL') THROW 59201, 'The patient is not in hospital any more (discharged or cancelled): clinical entries are closed.', 1;
END;
GO

-- ── doctor / nursing initial assessment ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdAssessment_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Kind VARCHAR(10), @Data NVARCHAR(MAX), @Sign BIT = 0, @AmendReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @Kind = UPPER(@Kind);
        IF @Kind NOT IN ('DOCTOR', 'NURSING') THROW 59210, 'Unknown assessment.', 1;
        IF ISJSON(@Data) <> 1 THROW 59211, 'The assessment could not be read.', 1;
        DECLARE @doc INT = CASE WHEN @Kind = 'DOCTOR' THEN dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId) END;
        IF @Kind = 'DOCTOR' AND @Sign = 1 AND @doc IS NULL
            THROW 59212, 'Only a doctor can sign the doctor''s assessment (your login is not linked to a doctor in Doctor Master).', 1;
        -- required to sign (NABH AAC: the initial assessment documents these)
        IF @Sign = 1
        BEGIN
            DECLARE @miss NVARCHAR(400) = N'';
            IF @Kind = 'DOCTOR'
                SELECT @miss = CONCAT(
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.chiefComplaints')), N'') IS NULL THEN N', chief complaints' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.historyOfIllness')), N'') IS NULL THEN N', history of present illness' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.examination')), N'') IS NULL THEN N', examination' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.provisionalDiagnosis')), N'') IS NULL THEN N', provisional diagnosis' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.plan')), N'') IS NULL THEN N', plan of care' END);
            ELSE
                SELECT @miss = CONCAT(
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.generalCondition')), N'') IS NULL THEN N', general condition' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.consciousness')), N'') IS NULL THEN N', consciousness' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.allergies')), N'') IS NULL THEN N', allergies (write "None known" if none)' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.mobility')), N'') IS NULL THEN N', mobility' END,
                    CASE WHEN NULLIF(LTRIM(JSON_VALUE(@Data, '$.skin')), N'') IS NULL THEN N', skin condition' END);
            IF LEN(@miss) > 0 BEGIN SET @msg = N'Enter before signing: ' + STUFF(@miss, 1, 2, N'') + N'.'; THROW 59213, @msg, 1; END
        END

        DECLARE @cur INT, @curSt VARCHAR(12), @ver INT;
        SELECT @cur = AssessmentId, @curSt = Status, @ver = Version FROM dbo.IpdAssessment WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND Kind = @Kind AND Status <> 'SUPERSEDED';
        SET @AmendReason = NULLIF(LTRIM(RTRIM(@AmendReason)), N'');

        IF @cur IS NOT NULL AND @curSt = 'SIGNED'
        BEGIN
            -- a signed assessment changes only as a new version, with the reason; the signed one is kept
            IF @AmendReason IS NULL THROW 59214, 'The assessment is signed: enter the reason for the amendment.', 1;
            IF @Kind = 'DOCTOR' AND @doc IS NULL THROW 59215, 'Only a doctor can amend the doctor''s assessment.', 1;
            UPDATE dbo.IpdAssessment SET Status = 'SUPERSEDED', ModifiedBy = @UserId, ModifiedDate = @now WHERE AssessmentId = @cur;
            INSERT dbo.IpdAssessment (AdmissionId, Kind, Data, Status, Version, DoctorId, SignedBy, SignedAt, AmendReason, CreatedBy)
            VALUES (@AdmissionId, @Kind, @Data, CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END, @ver + 1, @doc,
                    CASE WHEN @Sign = 1 THEN @UserId END, CASE WHEN @Sign = 1 THEN @now END, @AmendReason, @UserId);
            SET @cur = SCOPE_IDENTITY();
        END
        ELSE IF @cur IS NOT NULL
            UPDATE dbo.IpdAssessment
               SET Data = @Data, Status = CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END, DoctorId = ISNULL(@doc, DoctorId),
                   SignedBy = CASE WHEN @Sign = 1 THEN @UserId END, SignedAt = CASE WHEN @Sign = 1 THEN @now END, ModifiedBy = @UserId, ModifiedDate = @now
             WHERE AssessmentId = @cur;
        ELSE
        BEGIN
            INSERT dbo.IpdAssessment (AdmissionId, Kind, Data, Status, DoctorId, SignedBy, SignedAt, CreatedBy)
            VALUES (@AdmissionId, @Kind, @Data, CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END, @doc,
                    CASE WHEN @Sign = 1 THEN @UserId END, CASE WHEN @Sign = 1 THEN @now END, @UserId);
            SET @cur = SCOPE_IDENTITY();
        END
        IF @Sign = 1
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'ASSESSMENT', CONCAT(CASE @Kind WHEN 'DOCTOR' THEN N'Doctor' ELSE N'Nursing' END, N' initial assessment signed', CASE WHEN @AmendReason IS NOT NULL THEN N' (amended: ' + @AmendReason + N')' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @cur AS AssessmentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── the automatic doctor visit charge of a signed round / cross-consultation note (never throws) ──
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_AutoVisitCharge
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @DoctorId INT, @VisitType VARCHAR(12), @At DATETIME, @NoteId INT,
    @ChargeId BIGINT OUTPUT, @Note NVARCHAR(300) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ChargeId = NULL; SET @Note = NULL;
    DECLARE @auto BIT = ISNULL((SELECT TOP (1) IpdAutoVisitCharge FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 1);
    IF @auto = 0 BEGIN SET @Note = N'Automatic visit charge is off (Hospital Settings > IPD).'; RETURN; END
    DECLARE @st VARCHAR(20), @bill INT, @tcat INT, @admAt DATETIME;
    SELECT @st = Status, @bill = BillId, @tcat = TariffCategoryId, @admAt = AdmissionAt FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId;
    IF @st NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') OR @bill IS NOT NULL BEGIN SET @Note = N'Not charged: the final bill is made.'; RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.IpdCharge WHERE AdmissionId = @AdmissionId AND Head = 'DOCTOR' AND DoctorId = @DoctorId AND Status = 'POSTED'
               AND CAST(ChargeAt AS DATE) = CAST(@At AS DATE))
    BEGIN SET @Note = N'The doctor''s visit is already charged for this day.'; RETURN; END
    DECLARE @rate DECIMAL(18,2) = (SELECT TOP (1) Rate FROM dbo.fn_Ipd_DoctorFee(@BranchId, @DoctorId, @VisitType, @tcat, CAST(@At AS DATE)));
    IF ISNULL(@rate, 0) <= 0
    BEGIN SET @Note = N'Not charged: the doctor has no IPD visit charge (Master > IPD Master > IPD Doctor Visit Charges).'; RETURN; END
    DECLARE @name NVARCHAR(250) = CASE @VisitType WHEN 'CROSS' THEN N'Cross consultation' ELSE N'Routine round' END + N' - ' + (SELECT FullName FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId);
    IF @At < @admAt SET @At = @admAt;
    IF @At > GETDATE() SET @At = GETDATE();
    BEGIN TRY
        EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @AdmissionId, @UserId = @UserId, @Head = 'DOCTOR', @ItemCode = @VisitType, @ItemName = @name,
             @SourceModule = 'IPD', @SourceId = @NoteId, @SourceNo = NULL, @DoctorId = @DoctorId, @ChargeAt = @At, @Qty = 1, @Rate = @rate,
             @Remarks = N'Charged on signing the note', @MasterRate = @rate, @RefKind = 'DOCTOR', @RefId = @DoctorId, @ChargeId = @ChargeId OUTPUT;
        SET @Note = N'Visit charged.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 THROW;
        SET @ChargeId = NULL; SET @Note = N'Not charged: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

-- ── rounds / progress notes (SOAP); a cross-consultation reply closes the request ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdNote_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @NoteId INT = NULL, @NoteType VARCHAR(10), @DoctorId INT = NULL, @NoteAt DATETIME = NULL,
    @Subjective NVARCHAR(2000) = NULL, @Objective NVARCHAR(2000) = NULL, @Assessment NVARCHAR(2000) = NULL, @PlanText NVARCHAR(2000) = NULL,
    @Sign BIT = 0, @CrossConsultId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        SET @NoteType = UPPER(ISNULL(@NoteType, 'PROGRESS'));
        IF @NoteType NOT IN ('ROUND', 'PROGRESS', 'CROSS') THROW 59220, 'Choose the kind of note.', 1;
        DECLARE @my INT = dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId);
        SET @DoctorId = COALESCE(@DoctorId, @my);
        IF @DoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1)
            THROW 59221, 'Choose the doctor of the note.', 1;
        IF @Sign = 1 AND (@my IS NULL OR @my <> @DoctorId)
            THROW 59222, 'Only the doctor of the note can sign it (with the login linked to that doctor in Doctor Master). Save it as a draft for the doctor to sign.', 1;
        SET @NoteAt = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @NoteAt), 0), @now);
        IF @NoteAt > DATEADD(MINUTE, 5, @now) THROW 59223, 'The note time cannot be in the future.', 1;
        IF @NoteAt < @admAt THROW 59224, 'The note time cannot be before the admission.', 1;
        SELECT @Subjective = NULLIF(LTRIM(RTRIM(@Subjective)), N''), @Objective = NULLIF(LTRIM(RTRIM(@Objective)), N''),
               @Assessment = NULLIF(LTRIM(RTRIM(@Assessment)), N''), @PlanText = NULLIF(LTRIM(RTRIM(@PlanText)), N'');
        IF COALESCE(@Subjective, @Objective, @Assessment, @PlanText) IS NULL THROW 59225, 'Write the note (subjective, objective, assessment or plan).', 1;
        IF @Sign = 1 AND (@Assessment IS NULL OR @PlanText IS NULL) THROW 59226, 'Enter the assessment and the plan before signing.', 1;

        IF @NoteType = 'CROSS'
        BEGIN
            DECLARE @cxTo INT, @cxSt VARCHAR(10);
            SELECT @cxTo = ToDoctorId, @cxSt = Status FROM dbo.IpdCrossConsult WITH (UPDLOCK) WHERE ConsultId = @CrossConsultId AND AdmissionId = @AdmissionId;
            IF @cxTo IS NULL THROW 59227, 'Choose the cross-consultation request this note answers.', 1;
            IF @cxSt <> 'REQUESTED' AND @NoteId IS NULL THROW 59228, 'The cross-consultation is already answered or cancelled.', 1;
            IF @cxTo <> @DoctorId THROW 59229, 'Only the doctor asked for the cross-consultation can answer it.', 1;
        END
        ELSE SET @CrossConsultId = NULL;

        IF @NoteId IS NOT NULL
        BEGIN
            DECLARE @nSt VARCHAR(10), @nAdm INT;
            SELECT @nSt = Status, @nAdm = AdmissionId FROM dbo.IpdProgressNote WITH (UPDLOCK) WHERE NoteId = @NoteId;
            IF @nAdm IS NULL OR @nAdm <> @AdmissionId THROW 59230, 'The note was not found.', 1;
            IF @nSt <> 'DRAFT' THROW 59231, 'A signed note cannot be changed: write a new note (or strike it out with a reason).', 1;
            UPDATE dbo.IpdProgressNote
               SET NoteType = @NoteType, DoctorId = @DoctorId, NoteAt = @NoteAt, Subjective = @Subjective, Objective = @Objective, Assessment = @Assessment,
                   PlanText = @PlanText, CrossConsultId = @CrossConsultId, Status = CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END,
                   SignedBy = CASE WHEN @Sign = 1 THEN @UserId END, SignedAt = CASE WHEN @Sign = 1 THEN @now END, ModifiedBy = @UserId, ModifiedDate = @now
             WHERE NoteId = @NoteId;
        END
        ELSE
        BEGIN
            INSERT dbo.IpdProgressNote (AdmissionId, NoteType, DoctorId, NoteAt, Subjective, Objective, Assessment, PlanText, Status, SignedBy, SignedAt, CrossConsultId, CreatedBy)
            VALUES (@AdmissionId, @NoteType, @DoctorId, @NoteAt, @Subjective, @Objective, @Assessment, @PlanText, CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END,
                    CASE WHEN @Sign = 1 THEN @UserId END, CASE WHEN @Sign = 1 THEN @now END, @CrossConsultId, @UserId);
            SET @NoteId = SCOPE_IDENTITY();
        END

        DECLARE @chg BIGINT = NULL, @chgNote NVARCHAR(300) = NULL;
        IF @Sign = 1
        BEGIN
            IF @NoteType IN ('ROUND', 'CROSS')
            BEGIN
                DECLARE @vt VARCHAR(12) = CASE WHEN @NoteType = 'CROSS' THEN 'CROSS' ELSE 'ROUTINE' END;
                EXEC dbo.usp_Ipd_AutoVisitCharge @CompanyId, @BranchId, @UserId, @AdmissionId, @DoctorId, @vt, @NoteAt, @NoteId, @chg OUTPUT, @chgNote OUTPUT;
                UPDATE dbo.IpdProgressNote SET ChargeId = @chg, ChargeNote = @chgNote WHERE NoteId = @NoteId;
            END
            IF @NoteType = 'CROSS'
                UPDATE dbo.IpdCrossConsult SET Status = 'SEEN', SeenAt = @now, NoteId = @NoteId WHERE ConsultId = @CrossConsultId;
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @NoteId AS NoteId, @chg AS ChargeId, @chgNote AS ChargeNote;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── CPOE: a new order ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @OrderType VARCHAR(10), @Priority VARCHAR(10) = 'ROUTINE',
    @DoctorId INT = NULL, @Source VARCHAR(10) = NULL, @ReadBack BIT = 0,
    @ItemId INT = NULL, @DrugName NVARCHAR(250) = NULL, @Dose NVARCHAR(60) = NULL, @Route VARCHAR(20) = NULL, @FrequencyCode VARCHAR(10) = NULL,
    @StartAt DATETIME = NULL, @DurationDays INT = NULL,
    @ServiceKind VARCHAR(10) = NULL, @RefId INT = NULL, @Qty DECIMAL(10,2) = NULL,
    @DietType NVARCHAR(60) = NULL, @Details NVARCHAR(1000) = NULL
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
               ItemId, DrugName, Dose, Route, FrequencyCode, StartAt, EndAt, IsHighAlert, ServiceKind, RefId, ServiceName, Qty, DietType, Details)
        VALUES (@AdmissionId, @OrderType, @Priority, @DoctorId, @UserId, @now, @Source, ISNULL(@ReadBack, 0), @due, 'ACTIVE',
               CASE WHEN @OrderType = 'MED' THEN @ItemId END, CASE WHEN @OrderType = 'MED' THEN @DrugName END, CASE WHEN @OrderType = 'MED' THEN @Dose END,
               CASE WHEN @OrderType = 'MED' THEN @Route END, CASE WHEN @OrderType = 'MED' THEN @FrequencyCode END, CASE WHEN @OrderType = 'MED' THEN @StartAt END,
               @end, @high, CASE WHEN @OrderType = 'SERVICE' THEN @ServiceKind END, CASE WHEN @OrderType = 'SERVICE' THEN @RefId END, @serviceName,
               CASE WHEN @OrderType = 'SERVICE' THEN @Qty END, CASE WHEN @OrderType = 'DIET' THEN @DietType END, @Details);
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

-- ── order actions: ACK (nurse seen), COUNTERSIGN (doctor), STOP, CANCEL (entered in error), DONE (service performed: charged),
--    INDENT (the indent raised for a medication order is linked) ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_Action
    @CompanyId INT, @BranchId INT, @UserId INT, @OrderId INT, @Action VARCHAR(12), @Reason NVARCHAR(300) = NULL, @At DATETIME = NULL, @IndentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @type VARCHAR(10), @status VARCHAR(10), @src VARCHAR(10), @doc INT, @csAt DATETIME, @ack DATETIME, @kind VARCHAR(10), @ref INT,
                @qty DECIMAL(10,2), @name NVARCHAR(250), @startAt DATETIME;
        SELECT @adm = AdmissionId, @type = OrderType, @status = Status, @src = Source, @doc = DoctorId, @csAt = CountersignedAt, @ack = AckAt,
               @kind = ServiceKind, @ref = RefId, @qty = Qty, @name = ServiceName, @startAt = StartAt
        FROM dbo.IpdOrder WITH (UPDLOCK) WHERE OrderId = @OrderId;
        IF @adm IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @adm AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 59260, 'The order was not found in this branch.', 1;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @adm, @admAt OUTPUT, @st OUTPUT;
        SET @Action = UPPER(@Action); SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
        DECLARE @my INT = dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId);

        IF @Action = 'ACK'
        BEGIN
            IF @status <> 'ACTIVE' THROW 59261, 'The order is not active.', 1;
            IF @ack IS NOT NULL THROW 59262, 'The order is already acknowledged.', 1;
            UPDATE dbo.IpdOrder SET AckBy = @UserId, AckAt = @now WHERE OrderId = @OrderId;
        END
        ELSE IF @Action = 'COUNTERSIGN'
        BEGIN
            IF @src = 'DIRECT' THROW 59263, 'Only a verbal / telephone order needs a countersign.', 1;
            IF @csAt IS NOT NULL THROW 59264, 'The order is already countersigned.', 1;
            IF @status = 'CANCELLED' THROW 59265, 'The order is cancelled.', 1;
            IF @my IS NULL OR @my <> @doc THROW 59266, 'Only the doctor who gave the order can countersign it (with the login linked to that doctor).', 1;
            UPDATE dbo.IpdOrder SET CountersignedBy = @UserId, CountersignedAt = @now WHERE OrderId = @OrderId;
        END
        ELSE IF @Action IN ('STOP', 'CANCEL')
        BEGIN
            IF @status <> 'ACTIVE' THROW 59267, 'Only an active order can be stopped or cancelled.', 1;
            IF @Reason IS NULL THROW 59268, 'Enter the reason.', 1;
            IF @Action = 'CANCEL' AND (EXISTS (SELECT 1 FROM dbo.IpdMarAdmin WHERE OrderId = @OrderId AND Status = 'ACTIVE')
                                       OR EXISTS (SELECT 1 FROM dbo.IpdOrder WHERE OrderId = @OrderId AND DoneAt IS NOT NULL))
                THROW 59269, 'Something was already given / done on this order: stop it instead of cancelling.', 1;
            UPDATE dbo.IpdOrder SET Status = CASE WHEN @Action = 'STOP' THEN 'STOPPED' ELSE 'CANCELLED' END, StoppedBy = @UserId,
                   StoppedAt = CASE WHEN @Action = 'STOP' AND @type = 'MED' AND @startAt > @now THEN @startAt ELSE @now END, StopReason = @Reason
            WHERE OrderId = @OrderId;
        END
        ELSE IF @Action = 'DONE'
        BEGIN
            IF @type <> 'SERVICE' THROW 59270, 'Only a service / procedure order is marked done.', 1;
            IF @status <> 'ACTIVE' THROW 59271, 'The order is not active.', 1;
            SET @At = ISNULL(DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @At), 0), @now);
            IF @At > DATEADD(MINUTE, 5, @now) OR @At < @admAt THROW 59272, 'The time it was done must be after the admission and not in the future.', 1;
            DECLARE @tcat INT = (SELECT TariffCategoryId FROM dbo.IpdAdmission WHERE AdmissionId = @adm), @rate DECIMAL(18,2), @code NVARCHAR(50), @gst DECIMAL(5,2) = 0,
                    @head VARCHAR(20), @chg BIGINT;
            IF @kind = 'SERVICE'
                SELECT @rate = r.Rate, @code = s.ServiceCode, @gst = ISNULL(s.TaxPercentage, 0),
                       @head = CASE WHEN s.ServiceType LIKE N'OT%' THEN 'OT' WHEN s.ServiceType LIKE N'%Consumable%' THEN 'CONSUMABLE'
                                    WHEN s.ServiceType LIKE N'%Radiolog%' OR s.ServiceType LIKE N'%Imaging%' THEN 'RADIOLOGY' ELSE 'SERVICE' END
                FROM dbo.HospitalServiceMaster s OUTER APPLY dbo.fn_Ipd_ServiceRate(@BranchId, s.HospitalServiceId, @tcat, CAST(@At AS DATE)) r
                WHERE s.HospitalServiceId = @ref;
            ELSE
                SELECT @rate = r.Rate, @code = p.ProcedureCode, @head = 'PROCEDURE'
                FROM dbo.ProcedureMaster p OUTER APPLY dbo.fn_Ipd_ProcedureRate(@BranchId, p.ProcedureId, @tcat, CAST(@At AS DATE)) r
                WHERE p.ProcedureId = @ref;
            IF ISNULL(@rate, 0) <= 0
            BEGIN
                SET @msg = N'"' + @name + N'" has no rate for this patient''s tariff category: add the rate in the master tariff first, then mark it done.';
                THROW 59273, @msg, 1;
            END
            EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @adm, @UserId = @UserId, @Head = @head, @ItemCode = @code, @ItemName = @name, @SourceModule = 'IPD',
                 @SourceId = @OrderId, @DoctorId = @doc, @ChargeAt = @At, @Qty = @qty, @Rate = @rate, @GstPercent = @gst,
                 @Remarks = N'Doctor order done', @MasterRate = @rate, @RefKind = @kind, @RefId = @ref, @ChargeId = @chg OUTPUT;
            UPDATE dbo.IpdOrder SET Status = 'COMPLETED', DoneAt = @At, DoneBy = @UserId, ChargeId = @chg, AckBy = ISNULL(AckBy, @UserId), AckAt = ISNULL(AckAt, @now)
            WHERE OrderId = @OrderId;
        END
        ELSE IF @Action = 'INDENT'
        BEGIN
            IF @type <> 'MED' THROW 59274, 'Only a medication order goes to the pharmacy.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdPhIndent WHERE IndentId = @IndentId AND AdmissionId = @adm) THROW 59275, 'The indent was not found for this patient.', 1;
            UPDATE dbo.IpdOrder SET IndentId = @IndentId WHERE OrderId = @OrderId;
        END
        ELSE THROW 59276, 'Unknown order action.', 1;

        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @OrderId AS OrderId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── cross-consultation request / cancel ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCrossConsult_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ConsultId INT = NULL, @ToDoctorId INT = NULL, @Urgency VARCHAR(10) = 'ROUTINE',
    @Reason NVARCHAR(1000) = NULL, @Cancel BIT = 0, @CancelReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @admAt DATETIME, @st VARCHAR(20);
        EXEC dbo.usp_Ipd_ClinicalCheck @CompanyId, @BranchId, @AdmissionId, @admAt OUTPUT, @st OUTPUT;
        IF @Cancel = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdCrossConsult WITH (UPDLOCK) WHERE ConsultId = @ConsultId AND AdmissionId = @AdmissionId AND Status = 'REQUESTED')
                THROW 59280, 'Only a request not yet seen can be cancelled.', 1;
            IF NULLIF(LTRIM(RTRIM(@CancelReason)), N'') IS NULL THROW 59281, 'Enter the reason.', 1;
            UPDATE dbo.IpdCrossConsult SET Status = 'CANCELLED', CancelledBy = @UserId, CancelReason = LTRIM(RTRIM(@CancelReason)) WHERE ConsultId = @ConsultId;
        END
        ELSE
        BEGIN
            DECLARE @from INT = COALESCE(dbo.fn_Ipd_UserDoctor(@CompanyId, @UserId), (SELECT ConsultantDoctorId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId));
            IF @ToDoctorId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @ToDoctorId AND CompanyId = @CompanyId AND IsActive = 1)
                THROW 59282, 'Choose the doctor to consult.', 1;
            IF @ToDoctorId = @from THROW 59283, 'Choose another doctor than the one asking.', 1;
            SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'');
            IF @Reason IS NULL THROW 59284, 'Write the reason for the consultation (the question to the doctor).', 1;
            SET @Urgency = ISNULL(NULLIF(UPPER(@Urgency), ''), 'ROUTINE');
            IF @Urgency NOT IN ('ROUTINE', 'URGENT') THROW 59285, 'Choose routine or urgent.', 1;
            IF EXISTS (SELECT 1 FROM dbo.IpdCrossConsult WHERE AdmissionId = @AdmissionId AND ToDoctorId = @ToDoctorId AND Status = 'REQUESTED')
                THROW 59286, 'A request to this doctor is already waiting.', 1;
            INSERT dbo.IpdCrossConsult (AdmissionId, FromDoctorId, ToDoctorId, Urgency, Reason, RequestedBy) VALUES (@AdmissionId, @from, @ToDoctorId, @Urgency, @Reason, @UserId);
            SET @ConsultId = SCOPE_IDENTITY();
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @ConsultId AS ConsultId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── pickers: services / procedures of the branch for a service order ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOrder_Services @CompanyId INT, @BranchId INT, @Q NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Q + N'%';
    SELECT TOP (30) x.Kind, x.RefId, x.Code, x.Name FROM (
        SELECT 'SERVICE' AS Kind, HospitalServiceId AS RefId, ServiceCode AS Code, ServiceName AS Name FROM dbo.HospitalServiceMaster
        WHERE BranchId = @BranchId AND IsActive = 1 AND (@Q IS NULL OR ServiceName LIKE @like OR ServiceCode LIKE @like)
        UNION ALL
        SELECT 'PROCEDURE', ProcedureId, ProcedureCode, ProcedureName FROM dbo.ProcedureMaster
        WHERE BranchId = @BranchId AND IsActive = 1 AND (@Q IS NULL OR ProcedureName LIKE @like OR ProcedureCode LIKE @like)) x
    ORDER BY x.Name;
END;
GO

PRINT 'Script 2563 applied: IPD Phase 3 doctor procedures.';
GO
