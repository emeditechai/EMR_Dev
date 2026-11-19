-- 2492: IPD Phase 8 - Operation Theatre (OT) for admitted patients.
--   * IpdOtBooking: OT slot on an OT of the branch (OT Master), procedure (Procedure Master or free text), surgeon, assistant,
--     anaesthetist, anaesthesia type, nurses; no overlap in the same OT, for the same surgeon / anaesthetist or patient.
--   * Checklists: ward pre-op checklist and the WHO Surgical Safety Checklist (Sign In, Time Out, Sign Out); each gates the
--     next step (patient in OT needs PRE-OP, anaesthesia start needs SIGN IN, incision needs TIME OUT, out of OT needs SIGN OUT).
--   * Surgical (and, with an anaesthetist, anaesthesia) consent linked to the booking (IpdAdmissionConsent.OtBookingId).
--   * Anaesthesia record (pre-anaesthetic check, ASA, airway, drugs, intra-op monitoring, fluids, recovery / Aldrete), signed.
--   * Surgery note (procedure, findings, details, specimens, drains, complications, post-op plan); signed by the surgeon,
--     a later change needs a reason and keeps the earlier version (IpdSurgeryNoteVersion).
--   * Implants, surgical items and consumables issued from pharmacy stock (Implants / Surgical / Consumables categories, FEFO batch,
--     price from the batch and Price Rule) through the IPD pharmacy issue (head OT); removal returns them to the store.
--   * OT charges: surgeon, assistant and anaesthetist fees and OT charges from Procedure Tariff, Anaesthesia Rate and
--     OT Tariff of the patient's tariff category (else the branch's default category), posted through usp_Ipd_PostCharge
--     (head OT, source OT) and reversed from the OT tab only.
--   * Unplanned return to OT (NABH) recorded on the booking.
-- Needs 2422-2479. Safe to re-run. Replaces usp_Api_IpdConsent_Save of 2423 (adds the OT booking) and patches usp_Api_IpdPh_Issue
-- (head OT): re-run this after 2423, 2437 or 2475.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ── 1. tables ─────────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdOtBooking') IS NULL
CREATE TABLE dbo.IpdOtBooking
(
    OtBookingId        INT IDENTITY(1,1) CONSTRAINT PK_IpdOtBooking PRIMARY KEY,
    CompanyId          INT NOT NULL,
    BranchId           INT NOT NULL,
    AdmissionId        INT NOT NULL CONSTRAINT FK_IpdOtBooking_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
    BookingNo          NVARCHAR(40) NOT NULL,
    OtId               INT NOT NULL CONSTRAINT FK_IpdOtBooking_Ot REFERENCES dbo.OtMaster (OtId),
    ProcedureId        INT NULL CONSTRAINT FK_IpdOtBooking_Proc REFERENCES dbo.ProcedureMaster (ProcedureId),
    ProcedureName      NVARCHAR(250) NOT NULL,
    Laterality         VARCHAR(10) NULL CONSTRAINT CK_IpdOtBooking_Side CHECK (Laterality IN ('LEFT', 'RIGHT', 'BILATERAL', 'NA')),
    SurgeryType        VARCHAR(10) NOT NULL CONSTRAINT CK_IpdOtBooking_Type CHECK (SurgeryType IN ('ELECTIVE', 'EMERGENCY')),
    SurgeonId          INT NOT NULL CONSTRAINT FK_IpdOtBooking_Surgeon REFERENCES dbo.DoctorMaster (DoctorId),
    AssistantSurgeonId INT NULL CONSTRAINT FK_IpdOtBooking_Asst REFERENCES dbo.DoctorMaster (DoctorId),
    AnaesthetistId     INT NULL CONSTRAINT FK_IpdOtBooking_Anaes REFERENCES dbo.DoctorMaster (DoctorId),
    AnaesthesiaTypeId  INT NULL CONSTRAINT FK_IpdOtBooking_AnaesType REFERENCES dbo.AnaesthesiaTypeMaster (AnaesthesiaTypeId),
    ScrubNurse         NVARCHAR(150) NULL,
    CirculatingNurse   NVARCHAR(150) NULL,
    ScheduledStart     DATETIME NOT NULL,
    ScheduledEnd       DATETIME NOT NULL,
    PreOpDiagnosis     NVARCHAR(500) NULL,
    Remarks            NVARCHAR(500) NULL,
    Status             VARCHAR(10) NOT NULL CONSTRAINT DF_IpdOtBooking_Status DEFAULT ('SCHEDULED')
                       CONSTRAINT CK_IpdOtBooking_Status CHECK (Status IN ('SCHEDULED', 'IN_OT', 'COMPLETED', 'CANCELLED')),
    InOtAt             DATETIME NULL,
    AnaesStartAt       DATETIME NULL,
    IncisionAt         DATETIME NULL,
    ClosureAt          DATETIME NULL,
    AnaesEndAt         DATETIME NULL,
    OutOtAt            DATETIME NULL,
    RecoveryOutAt      DATETIME NULL,
    IsUnplannedReturn  BIT NOT NULL CONSTRAINT DF_IpdOtBooking_Return DEFAULT (0),
    ReturnReason       NVARCHAR(300) NULL,
    CompletedBy        INT NULL,
    CompletedAt        DATETIME NULL,
    CancelReason       NVARCHAR(300) NULL,
    CancelledBy        INT NULL,
    CancelledAt        DATETIME NULL,
    CreatedBy          INT NOT NULL,
    CreatedDate        DATETIME NOT NULL CONSTRAINT DF_IpdOtBooking_Created DEFAULT (GETDATE()),
    ModifiedBy         INT NULL,
    ModifiedDate       DATETIME NULL,
    CONSTRAINT CK_IpdOtBooking_Slot CHECK (ScheduledEnd > ScheduledStart)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdOtBooking_Ot' AND object_id = OBJECT_ID('dbo.IpdOtBooking'))
    CREATE INDEX IX_IpdOtBooking_Ot ON dbo.IpdOtBooking (OtId, ScheduledStart) INCLUDE (ScheduledEnd, Status);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdOtBooking_Adm' AND object_id = OBJECT_ID('dbo.IpdOtBooking'))
    CREATE INDEX IX_IpdOtBooking_Adm ON dbo.IpdOtBooking (AdmissionId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdOtBooking_Day' AND object_id = OBJECT_ID('dbo.IpdOtBooking'))
    CREATE INDEX IX_IpdOtBooking_Day ON dbo.IpdOtBooking (BranchId, ScheduledStart);
GO

IF OBJECT_ID('dbo.IpdOtChecklist') IS NULL
CREATE TABLE dbo.IpdOtChecklist
(
    ChecklistId  INT IDENTITY(1,1) CONSTRAINT PK_IpdOtChecklist PRIMARY KEY,
    OtBookingId  INT NOT NULL CONSTRAINT FK_IpdOtChecklist_Booking REFERENCES dbo.IpdOtBooking (OtBookingId),
    Phase        VARCHAR(10) NOT NULL CONSTRAINT CK_IpdOtChecklist_Phase CHECK (Phase IN ('PREOP', 'SIGNIN', 'TIMEOUT', 'SIGNOUT')),
    Answers      NVARCHAR(MAX) NOT NULL,      -- [{ "code": "...", "answer": "YES|NO|NA", "note": "..." }]
    Remarks      NVARCHAR(500) NULL,
    CompletedBy  INT NOT NULL,
    CompletedAt  DATETIME NOT NULL CONSTRAINT DF_IpdOtChecklist_At DEFAULT (GETDATE()),
    CONSTRAINT UQ_IpdOtChecklist UNIQUE (OtBookingId, Phase)
);
GO

IF OBJECT_ID('dbo.IpdAnaesthesiaRecord') IS NULL
CREATE TABLE dbo.IpdAnaesthesiaRecord
(
    OtBookingId       INT NOT NULL CONSTRAINT PK_IpdAnaesthesiaRecord PRIMARY KEY CONSTRAINT FK_IpdAnaesRec_Booking REFERENCES dbo.IpdOtBooking (OtBookingId),
    AnaesthesiaTypeId INT NULL CONSTRAINT FK_IpdAnaesRec_Type REFERENCES dbo.AnaesthesiaTypeMaster (AnaesthesiaTypeId),
    AsaGrade          VARCHAR(4) NULL CONSTRAINT CK_IpdAnaesRec_Asa CHECK (AsaGrade IN ('I', 'II', 'III', 'IV', 'V', 'VI', 'IE', 'IIE', 'IIIE', 'IVE', 'VE')),
    Mallampati        TINYINT NULL CONSTRAINT CK_IpdAnaesRec_Mp CHECK (Mallampati BETWEEN 1 AND 4),
    NpoSince          DATETIME NULL,
    Airway            NVARCHAR(300) NULL,
    Comorbidities     NVARCHAR(500) NULL,
    PreAnaesNotes     NVARCHAR(1000) NULL,
    Technique         NVARCHAR(500) NULL,
    AirwayDevice      NVARCHAR(150) NULL,
    Drugs             NVARCHAR(MAX) NULL,     -- [{ "at": "HH:mm", "drug": "", "dose": "", "route": "" }]
    Monitoring        NVARCHAR(MAX) NULL,     -- [{ "at": "HH:mm", "hr": , "sbp": , "dbp": , "spo2": , "etco2": , "temp": }]
    FluidsMl          INT NULL,
    BloodGivenMl      INT NULL,
    UrineMl           INT NULL,
    BloodLossMl       INT NULL,
    Complications     NVARCHAR(1000) NULL,
    AldreteScore      TINYINT NULL CONSTRAINT CK_IpdAnaesRec_Aldrete CHECK (AldreteScore BETWEEN 0 AND 10),
    RecoveryNotes     NVARCHAR(1000) NULL,
    SignedBy          INT NULL,
    SignedAt          DATETIME NULL,
    CreatedBy         INT NOT NULL,
    CreatedDate       DATETIME NOT NULL CONSTRAINT DF_IpdAnaesRec_Created DEFAULT (GETDATE()),
    ModifiedBy        INT NULL,
    ModifiedDate      DATETIME NULL
);
GO

IF OBJECT_ID('dbo.IpdSurgeryNote') IS NULL
CREATE TABLE dbo.IpdSurgeryNote
(
    OtBookingId         INT NOT NULL CONSTRAINT PK_IpdSurgeryNote PRIMARY KEY CONSTRAINT FK_IpdSurgeryNote_Booking REFERENCES dbo.IpdOtBooking (OtBookingId),
    ProcedurePerformed  NVARCHAR(500) NOT NULL,
    PostOpDiagnosis     NVARCHAR(500) NULL,
    Indication          NVARCHAR(1000) NULL,
    Findings            NVARCHAR(MAX) NULL,
    ProcedureDetails    NVARCHAR(MAX) NULL,
    Specimens           NVARCHAR(500) NULL,
    SpecimenToHistopath BIT NOT NULL CONSTRAINT DF_IpdSurgeryNote_Histo DEFAULT (0),
    Drains              NVARCHAR(300) NULL,
    BloodLossMl         INT NULL,
    Complications       NVARCHAR(1000) NULL,
    Closure             NVARCHAR(300) NULL,
    PostOpPlan          NVARCHAR(MAX) NULL,
    PatientCondition    NVARCHAR(100) NULL,
    Status              VARCHAR(10) NOT NULL CONSTRAINT DF_IpdSurgeryNote_Status DEFAULT ('DRAFT') CONSTRAINT CK_IpdSurgeryNote_Status CHECK (Status IN ('DRAFT', 'SIGNED')),
    Version             INT NOT NULL CONSTRAINT DF_IpdSurgeryNote_Ver DEFAULT (1),
    SignedBy            INT NULL,
    SignedAt            DATETIME NULL,
    CreatedBy           INT NOT NULL,
    CreatedDate         DATETIME NOT NULL CONSTRAINT DF_IpdSurgeryNote_Created DEFAULT (GETDATE()),
    ModifiedBy          INT NULL,
    ModifiedDate        DATETIME NULL
);
GO
IF OBJECT_ID('dbo.IpdSurgeryNoteVersion') IS NULL
CREATE TABLE dbo.IpdSurgeryNoteVersion
(
    NoteVersionId INT IDENTITY(1,1) CONSTRAINT PK_IpdSurgeryNoteVersion PRIMARY KEY,
    OtBookingId   INT NOT NULL CONSTRAINT FK_IpdSurgeryNoteVer_Booking REFERENCES dbo.IpdOtBooking (OtBookingId),
    Version       INT NOT NULL,
    NoteJson      NVARCHAR(MAX) NOT NULL,     -- the signed note as it was
    SignedBy      INT NULL,
    SignedAt      DATETIME NULL,
    AmendReason   NVARCHAR(300) NOT NULL,
    AmendedBy     INT NOT NULL,
    AmendedAt     DATETIME NOT NULL CONSTRAINT DF_IpdSurgeryNoteVer_At DEFAULT (GETDATE())
);
GO

IF OBJECT_ID('dbo.IpdOtImplant') IS NULL
CREATE TABLE dbo.IpdOtImplant
(
    ImplantId     INT IDENTITY(1,1) CONSTRAINT PK_IpdOtImplant PRIMARY KEY,
    OtBookingId   INT NOT NULL CONSTRAINT FK_IpdOtImplant_Booking REFERENCES dbo.IpdOtBooking (OtBookingId),
    AdmissionId   INT NOT NULL,
    ItemType      VARCHAR(10) NOT NULL CONSTRAINT CK_IpdOtImplant_Type CHECK (ItemType IN ('IMPLANT', 'SURGICAL', 'CONSUMABLE')),
    ItemName      NVARCHAR(200) NOT NULL,
    Manufacturer  NVARCHAR(150) NULL,
    CatalogueNo   NVARCHAR(80) NULL,
    BatchNo       NVARCHAR(80) NULL,
    SerialNo      NVARCHAR(80) NULL,
    ExpiryDate    DATE NULL,
    Qty           DECIMAL(18,3) NOT NULL,
    Rate          DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdOtImplant_Rate DEFAULT (0),
    GstPercent    DECIMAL(5,2) NOT NULL CONSTRAINT DF_IpdOtImplant_Gst DEFAULT (0),
    ChargeId      BIGINT NULL,
    Remarks       NVARCHAR(300) NULL,
    Status        VARCHAR(10) NOT NULL CONSTRAINT DF_IpdOtImplant_Status DEFAULT ('ACTIVE') CONSTRAINT CK_IpdOtImplant_Status CHECK (Status IN ('ACTIVE', 'REMOVED')),
    RemoveReason  NVARCHAR(300) NULL,
    RemovedBy     INT NULL,
    RemovedAt     DATETIME NULL,
    CreatedBy     INT NOT NULL,
    CreatedDate   DATETIME NOT NULL CONSTRAINT DF_IpdOtImplant_Created DEFAULT (GETDATE())
);
GO
-- item type Surgical (sutures, staplers, clips, instruments) added after the first build: widen the check on an existing table
IF OBJECT_ID('dbo.CK_IpdOtImplant_Type') IS NOT NULL AND OBJECT_DEFINITION(OBJECT_ID('dbo.CK_IpdOtImplant_Type')) NOT LIKE '%SURGICAL%'
BEGIN
    ALTER TABLE dbo.IpdOtImplant DROP CONSTRAINT CK_IpdOtImplant_Type;
    ALTER TABLE dbo.IpdOtImplant ADD CONSTRAINT CK_IpdOtImplant_Type CHECK (ItemType IN ('IMPLANT', 'SURGICAL', 'CONSUMABLE'));
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdOtImplant_Booking' AND object_id = OBJECT_ID('dbo.IpdOtImplant'))
    CREATE INDEX IX_IpdOtImplant_Booking ON dbo.IpdOtImplant (OtBookingId);
GO

-- an OT item is issued from pharmacy stock (item, batch, store, IPD issue line): added after the first build
IF COL_LENGTH('dbo.IpdOtImplant', 'ItemId') IS NULL
    ALTER TABLE dbo.IpdOtImplant ADD ItemId INT NULL, BatchId INT NULL, StoreId INT NULL, IssueId INT NULL, IssueLineId INT NULL;
GO
-- the IPD pharmacy issue gets head OT (items issued to a surgery)
IF OBJECT_ID('dbo.CK_IpdPhIssue_Head') IS NOT NULL AND OBJECT_DEFINITION(OBJECT_ID('dbo.CK_IpdPhIssue_Head')) NOT LIKE '%''OT''%'
BEGIN
    ALTER TABLE dbo.IpdPhIssue DROP CONSTRAINT CK_IpdPhIssue_Head;
    ALTER TABLE dbo.IpdPhIssue ADD CONSTRAINT CK_IpdPhIssue_Head CHECK (Head IN ('PHARMACY', 'CONSUMABLE', 'OT'));
END
GO
CREATE OR ALTER PROCEDURE #Patch @Proc SYSNAME, @Marker NVARCHAR(200), @Old1 NVARCHAR(MAX), @New1 NVARCHAR(MAX), @Old2 NVARCHAR(MAX) = NULL, @New2 NVARCHAR(MAX) = NULL
AS
BEGIN
    DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@Proc)), @m NVARCHAR(400);
    IF @d IS NULL BEGIN SET @m = @Proc + N' is missing.'; THROW 51470, @m, 1; END;
    IF CHARINDEX(@Marker, @d) > 0 BEGIN PRINT @Proc + N': already patched'; RETURN; END;
    IF CHARINDEX(@Old1, @d) = 0 OR (@Old2 IS NOT NULL AND CHARINDEX(@Old2, @d) = 0) BEGIN SET @m = @Proc + N': the expected code was not found - not patched.'; THROW 51471, @m, 1; END;
    SET @d = REPLACE(@d, @Old1, @New1);
    IF @Old2 IS NOT NULL SET @d = REPLACE(@d, @Old2, @New2);
    DECLARE @p INT = PATINDEX(N'%CREATE[ ' + NCHAR(9) + NCHAR(10) + NCHAR(13) + N']%PROC%', @d);
    SET @d = STUFF(@d, @p, CHARINDEX(N'PROC', @d, @p) - @p, N'CREATE OR ALTER ');
    BEGIN TRY EXEC sp_executesql @d; END TRY BEGIN CATCH THROW; END CATCH;
    PRINT @Proc + N': patched';
END;
GO
EXEC #Patch N'dbo.usp_Api_IpdPh_Issue', N'/* 2492 OT */',
    N'IF @Head NOT IN (''PHARMACY'', ''CONSUMABLE'') THROW 55103, ''Choose medicine or consumable.'', 1;',
    N'IF @Head NOT IN (''PHARMACY'', ''CONSUMABLE'', ''OT'') /* 2492 OT */ THROW 55103, ''Choose medicine or consumable.'', 1;',
    N'CASE WHEN @Head = ''CONSUMABLE'' THEN N''Consumables issued '' ELSE N''Medicines issued '' END',
    N'CASE WHEN @Head = ''CONSUMABLE'' THEN N''Consumables issued '' WHEN @Head = ''OT'' THEN N''OT items issued '' ELSE N''Medicines issued '' END';
GO
DROP PROCEDURE IF EXISTS #Patch;
GO

-- consents signed for an OT booking
IF COL_LENGTH('dbo.IpdAdmissionConsent', 'OtBookingId') IS NULL
    ALTER TABLE dbo.IpdAdmissionConsent ADD OtBookingId INT NULL CONSTRAINT FK_IpdAdmissionConsent_Ot REFERENCES dbo.IpdOtBooking (OtBookingId);
GO

-- a standard anaesthesia consent form (IPD) for each branch that has a surgical consent and no anaesthesia consent yet;
-- the hospital can edit it in Master > Consent Master
INSERT dbo.ConsentMaster (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedBy, CreatedDate)
SELECT DISTINCT s.CompanyId, s.Branch_ID, N'Anaesthesia Consent', 'IPD', NULL, N'English',
       N'<h3>INFORMED CONSENT FOR ANAESTHESIA</h3>'
     + N'<p>I, the undersigned ({{Relationship}} of the patient), consent to the administration of anaesthesia to <strong>{{PatientName}}</strong> '
     + N'(UHID {{UHID}}, IP No. {{IPDNo}}, Age {{Age}}, {{Gender}}) for <strong>{{ProcedureName}}</strong> at <strong>{{HospitalName}}</strong>.</p>'
     + N'<p>The anaesthetist has explained to me in a language I understand the type of anaesthesia planned (general, spinal / epidural, regional, '
     + N'local with sedation), the alternatives, and that the plan may change during the procedure if the patient''s safety requires it.</p>'
     + N'<p>I understand the common and the rare but serious risks: sore throat, nausea and vomiting, headache, dental injury, awareness, allergic '
     + N'reaction to drugs, nerve injury, breathing or heart problems, and very rarely brain damage or death. I have disclosed the patient''s '
     + N'illnesses, medicines, allergies and last food and drink truthfully.</p>'
     + N'<p>I consent to blood or blood products, invasive monitoring and post-operative care (including ICU or ventilation) if the '
     + N'anaesthetist considers them necessary. I have had the opportunity to ask questions and they were answered to my satisfaction.</p>'
     + N'<p>Date: {{Date}} &nbsp; Time: {{Time}} &nbsp; Witness: {{WitnessName}}</p>',
       N'1.0', N'Single Procedure', 1, 1, 1, GETDATE()
FROM dbo.ConsentMaster s
WHERE s.Type = 'IPD' AND s.Status = 1 AND (s.ConsentType LIKE N'%urg%' OR s.ConsentType LIKE N'%perat%')
  AND NOT EXISTS (SELECT 1 FROM dbo.ConsentMaster x WHERE x.Type = 'IPD' AND ISNULL(x.Branch_ID, 0) = ISNULL(s.Branch_ID, 0)
                  AND (x.ConsentType LIKE N'%naesth%' OR x.ConsentType LIKE N'%nesth%'));
GO

-- ── 2. checklist template (pre-op + WHO Surgical Safety Checklist) ──────────────────────────────────────────────────
-- Kind CHECK = must be YES (or NA where AllowNa = 1); INFO = YES or NO is recorded (e.g. known allergy).
-- Auto = answered from the record: SURG_CONSENT / ANAES_CONSENT from the consents of the booking.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_OtChecklistItems ()
RETURNS TABLE
AS RETURN
(
    SELECT Phase, Code, ItemText, Kind, CAST(AllowNa AS BIT) AS AllowNa, Sort FROM (VALUES
        ('PREOP', 'ID_BAND',       N'Identity band checked: name, UHID / IP no. match the booking', 'CHECK', 0, 10),
        ('PREOP', 'SURG_CONSENT',  N'Surgical consent signed and on file', 'CHECK', 0, 20),
        ('PREOP', 'ANAES_CONSENT', N'Anaesthesia consent signed and on file', 'CHECK', 1, 30),
        ('PREOP', 'SITE_MARK',     N'Operative site marked by the surgeon', 'CHECK', 1, 40),
        ('PREOP', 'NPO',           N'Nil by mouth status confirmed (time noted)', 'CHECK', 1, 50),
        ('PREOP', 'PAC',           N'Pre-anaesthetic check-up done and fit for surgery', 'CHECK', 1, 60),
        ('PREOP', 'INVESTIGATION', N'Investigations reviewed (Hb, blood group, coagulation, viral markers as needed)', 'CHECK', 0, 70),
        ('PREOP', 'BLOOD',         N'Blood / components arranged and cross-matched', 'CHECK', 1, 80),
        ('PREOP', 'PREMED',        N'Pre-medication / prophylactic antibiotic given as ordered', 'CHECK', 1, 90),
        ('PREOP', 'ALLERGY',       N'Known allergy?', 'INFO', 0, 100),
        ('PREOP', 'REMOVALS',      N'Jewellery, dentures, prosthesis, make-up and nail polish removed', 'CHECK', 1, 110),
        ('PREOP', 'VOID',          N'Bladder voided / catheterised', 'CHECK', 1, 120),
        ('PREOP', 'SKIN_PREP',     N'Skin preparation done; OT gown worn', 'CHECK', 0, 130),
        ('PREOP', 'IMPLANTS_READY', N'Implants / special equipment needed are available', 'CHECK', 1, 140),

        ('SIGNIN', 'SI_IDENTITY',  N'Patient has confirmed identity, site, procedure and consent', 'CHECK', 0, 10),
        ('SIGNIN', 'SI_SITE',      N'Site marked', 'CHECK', 1, 20),
        ('SIGNIN', 'SI_MACHINE',   N'Anaesthesia machine and medication check complete', 'CHECK', 1, 30),
        ('SIGNIN', 'SI_OXIMETER',  N'Pulse oximeter on the patient and functioning', 'CHECK', 0, 40),
        ('SIGNIN', 'SI_ALLERGY',   N'Does the patient have a known allergy?', 'INFO', 0, 50),
        ('SIGNIN', 'SI_AIRWAY',    N'Difficult airway / aspiration risk?', 'INFO', 0, 60),
        ('SIGNIN', 'SI_AIRWAY_EQ', N'If difficult airway: equipment and assistance available', 'CHECK', 1, 70),
        ('SIGNIN', 'SI_BLOODLOSS', N'Risk of more than 500 ml blood loss (7 ml/kg in children)?', 'INFO', 0, 80),
        ('SIGNIN', 'SI_IV',        N'If risk of blood loss: two IVs / central access and fluids planned', 'CHECK', 1, 90),

        ('TIMEOUT', 'TO_TEAM',     N'All team members have introduced themselves by name and role', 'CHECK', 0, 10),
        ('TIMEOUT', 'TO_CONFIRM',  N'Surgeon, anaesthetist and nurse confirm patient, site and procedure', 'CHECK', 0, 20),
        ('TIMEOUT', 'TO_ANTIBIOTIC', N'Antibiotic prophylaxis given within the last 60 minutes', 'CHECK', 1, 30),
        ('TIMEOUT', 'TO_SURGEON',  N'Surgeon: critical or non-routine steps, duration, anticipated blood loss reviewed', 'CHECK', 0, 40),
        ('TIMEOUT', 'TO_ANAES',    N'Anaesthetist: patient-specific concerns reviewed', 'CHECK', 1, 50),
        ('TIMEOUT', 'TO_STERILE',  N'Nursing: sterility (indicator results) confirmed; equipment issues addressed', 'CHECK', 0, 60),
        ('TIMEOUT', 'TO_IMAGING',  N'Essential imaging displayed', 'CHECK', 1, 70),

        ('SIGNOUT', 'SO_NAME',     N'Name of the procedure recorded', 'CHECK', 0, 10),
        ('SIGNOUT', 'SO_COUNTS',   N'Instrument, sponge and needle counts correct', 'CHECK', 0, 20),
        ('SIGNOUT', 'SO_SPECIMEN', N'Specimen labelled (patient name, site)', 'CHECK', 1, 30),
        ('SIGNOUT', 'SO_EQUIP',    N'Equipment problems to be addressed noted', 'CHECK', 1, 40),
        ('SIGNOUT', 'SO_RECOVERY', N'Key concerns for recovery and management reviewed', 'CHECK', 0, 50)
    ) v (Phase, Code, ItemText, Kind, AllowNa, Sort)
);
GO

-- ── 3. rates (patient's tariff category first, else the branch's default category) ─────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_OtRate (@BranchId INT, @OtId INT, @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) t.OtTariffId, CAST(t.OtUsageRate AS DECIMAL(18,2)) AS OtUsageRate, CAST(t.NursingCharges AS DECIMAL(18,2)) AS NursingCharges,
           CAST(t.EquipmentCharges AS DECIMAL(18,2)) AS EquipmentCharges, CAST(t.RecoveryCharges AS DECIMAL(18,2)) AS RecoveryCharges,
           CAST(t.ConsumableCharges AS DECIMAL(18,2)) AS ConsumableCharges, CAST(t.SpecialEquipmentCharges AS DECIMAL(18,2)) AS SpecialEquipmentCharges,
           CAST(CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END AS BIT) AS UsedFallback
    FROM dbo.OtTariffMaster t
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId
    WHERE t.BranchId = @BranchId AND t.OtId = @OtId AND t.IsActive = 1
      AND t.TariffCategoryId IN (@TariffCategoryId, ISNULL(s.IpdDefaultTariffCategoryId, @TariffCategoryId))
      AND CAST(t.EffectiveFrom AS DATE) <= @OnDate AND (t.EffectiveTo IS NULL OR CAST(t.EffectiveTo AS DATE) >= @OnDate)
    ORDER BY CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END, t.EffectiveFrom DESC, t.OtTariffId DESC
);
GO
CREATE OR ALTER FUNCTION dbo.fn_Ipd_AnaesRate (@BranchId INT, @ProcedureId INT, @AnaesthesiaTypeId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) r.AnaesthesiaRateId, CAST(r.AnaesthetistFee AS DECIMAL(18,2)) AS AnaesthetistFee, CAST(r.ConsumableCharge AS DECIMAL(18,2)) AS ConsumableCharge
    FROM dbo.AnaesthesiaRateMaster r
    WHERE r.BranchId = @BranchId AND r.ProcedureId = @ProcedureId AND r.AnaesthesiaTypeId = @AnaesthesiaTypeId AND r.IsActive = 1
      AND CAST(r.EffectiveFrom AS DATE) <= @OnDate AND (r.EffectiveTo IS NULL OR CAST(r.EffectiveTo AS DATE) >= @OnDate)
    ORDER BY r.EffectiveFrom DESC, r.AnaesthesiaRateId DESC
);
GO

-- The OT charge lines of a booking as the masters price them (Code, Name, DoctorId, Rate, Source). Zero lines are kept so the
-- screen can show what has no rate; only lines with a rate are posted.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_OtChargeLines (@OtBookingId INT)
RETURNS TABLE
AS RETURN
(
    WITH b AS
    (
        SELECT ob.OtBookingId, ob.BranchId, ob.OtId, ob.ProcedureId, ob.AnaesthesiaTypeId, ob.SurgeonId, ob.AssistantSurgeonId, ob.AnaesthetistId,
               a.TariffCategoryId, CAST(ISNULL(ob.OutOtAt, ob.ScheduledStart) AS DATE) AS OnDate
        FROM dbo.IpdOtBooking ob JOIN dbo.IpdAdmission a ON a.AdmissionId = ob.AdmissionId
        WHERE ob.OtBookingId = @OtBookingId
    )
    SELECT v.Code, v.Name, v.DoctorId, CAST(ISNULL(v.Rate, 0) AS DECIMAL(18,2)) AS Rate, v.Source, v.Sort,
           CAST(CASE WHEN v.Code IN ('SURGEON', 'ASSISTANT') THEN ISNULL(pr.UsedFallback, 0)
                     WHEN v.Code LIKE 'ANAES%' THEN 0
                     WHEN v.Source = 'Procedure Tariff' THEN ISNULL(pr.UsedFallback, 0) ELSE ISNULL(otr.UsedFallback, 0) END AS BIT) AS UsedFallback
    FROM b
    OUTER APPLY dbo.fn_Ipd_ProcedureRate(b.BranchId, b.ProcedureId, b.TariffCategoryId, b.OnDate) pr
    OUTER APPLY dbo.fn_Ipd_OtRate(b.BranchId, b.OtId, b.TariffCategoryId, b.OnDate) otr
    OUTER APPLY dbo.fn_Ipd_AnaesRate(b.BranchId, b.ProcedureId, b.AnaesthesiaTypeId, b.OnDate) ar
    CROSS APPLY (VALUES
        ('SURGEON',     N'Surgeon fee', b.SurgeonId, pr.SurgeonFee, N'Procedure Tariff', 10),
        ('ASSISTANT',   N'Assistant surgeon fee', b.AssistantSurgeonId, CASE WHEN b.AssistantSurgeonId IS NOT NULL THEN pr.AssistantFee END, N'Procedure Tariff', 20),
        ('ANAESTHETIST', N'Anaesthetist fee', b.AnaesthetistId,
                         CASE WHEN b.AnaesthetistId IS NOT NULL THEN COALESCE(ar.AnaesthetistFee, pr.AnaesthetistFee) END,
                         CASE WHEN ar.AnaesthesiaRateId IS NOT NULL THEN N'Anaesthesia Rate' ELSE N'Procedure Tariff' END, 30),
        ('ANAES_CONS',  N'Anaesthesia consumables', NULL, ar.ConsumableCharge, N'Anaesthesia Rate', 40),
        ('OT_USE',      N'OT charges', NULL, CASE WHEN ISNULL(pr.OtCharges, 0) > 0 THEN pr.OtCharges ELSE otr.OtUsageRate END,
                         CASE WHEN ISNULL(pr.OtCharges, 0) > 0 THEN N'Procedure Tariff' ELSE N'OT Tariff' END, 50),
        ('OT_NURSING',  N'OT nursing charges', NULL, CASE WHEN ISNULL(pr.NursingCharges, 0) > 0 THEN pr.NursingCharges ELSE otr.NursingCharges END,
                         CASE WHEN ISNULL(pr.NursingCharges, 0) > 0 THEN N'Procedure Tariff' ELSE N'OT Tariff' END, 60),
        ('OT_EQUIP',    N'OT equipment charges', NULL, CASE WHEN ISNULL(pr.EquipmentCharges, 0) > 0 THEN pr.EquipmentCharges ELSE otr.EquipmentCharges END,
                         CASE WHEN ISNULL(pr.EquipmentCharges, 0) > 0 THEN N'Procedure Tariff' ELSE N'OT Tariff' END, 70),
        ('OT_SPECIAL',  N'Special equipment charges', NULL, otr.SpecialEquipmentCharges, N'OT Tariff', 80),
        ('OT_CONS',     N'OT consumables', NULL, CASE WHEN ISNULL(pr.ConsumableCharges, 0) > 0 THEN pr.ConsumableCharges ELSE otr.ConsumableCharges END,
                         CASE WHEN ISNULL(pr.ConsumableCharges, 0) > 0 THEN N'Procedure Tariff' ELSE N'OT Tariff' END, 90),
        ('OT_RECOVERY', N'Recovery room charges', NULL, otr.RecoveryCharges, N'OT Tariff', 100)
    ) v (Code, Name, DoctorId, Rate, Source, Sort)
    WHERE (v.Code <> 'ASSISTANT' OR b.AssistantSurgeonId IS NOT NULL) AND (v.Code NOT LIKE 'ANAES%' OR b.AnaesthetistId IS NOT NULL OR b.AnaesthesiaTypeId IS NOT NULL)
);
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
    WHERE d.IsActive = 1 AND ISNULL(d.IsSuspended, 0) = 0 AND ISNULL(d.IsReferralDoctor, 0) = 0 AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
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

-- OT schedule of a day: every OT of the branch and its bookings
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_Schedule @CompanyId INT, @BranchId INT, @Date DATE, @OtId INT = NULL, @IncludeCancelled BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @from DATETIME = @Date, @to DATETIME = DATEADD(DAY, 1, CAST(@Date AS DATETIME));
    SELECT o.OtId, o.OtCode, o.OtName, o.OtType, CAST(ISNULL(o.EmergencyAvailable, 0) AS BIT) AS EmergencyAvailable
    FROM dbo.OtMaster o WHERE o.BranchId = @BranchId AND o.IsActive = 1 AND (@OtId IS NULL OR o.OtId = @OtId) ORDER BY o.OtName;
    SELECT ob.OtBookingId, ob.BookingNo, ob.OtId, ob.AdmissionId, a.IpNo, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           dbo.fn_Ipd_AgeText(p.DateOfBirth, GETDATE()) AS AgeText, p.Gender,
           ob.ProcedureName, ob.Laterality, ob.SurgeryType, ob.ScheduledStart, ob.ScheduledEnd, ob.Status, ob.InOtAt, ob.IncisionAt, ob.OutOtAt,
           LTRIM(RTRIM(ISNULL(s.NamePrefix + ' ', '') + s.FullName)) AS SurgeonName, LTRIM(RTRIM(ISNULL(an.NamePrefix + ' ', '') + an.FullName)) AS AnaesthetistName,
           at.TypeName AS AnaesthesiaType, ob.IsUnplannedReturn,
           w.WardName, b.BedNumber,
           (SELECT COUNT(*) FROM dbo.IpdOtChecklist c WHERE c.OtBookingId = ob.OtBookingId) AS ChecklistsDone
    FROM dbo.IpdOtBooking ob
    JOIN dbo.IpdAdmission a ON a.AdmissionId = ob.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    JOIN dbo.DoctorMaster s ON s.DoctorId = ob.SurgeonId
    LEFT JOIN dbo.DoctorMaster an ON an.DoctorId = ob.AnaesthetistId
    LEFT JOIN dbo.AnaesthesiaTypeMaster at ON at.AnaesthesiaTypeId = ob.AnaesthesiaTypeId
    LEFT JOIN dbo.BedMaster b ON b.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    WHERE ob.BranchId = @BranchId AND ob.CompanyId = @CompanyId AND ob.ScheduledStart < @to AND ob.ScheduledEnd > @from
      AND (@OtId IS NULL OR ob.OtId = @OtId) AND (@IncludeCancelled = 1 OR ob.Status <> 'CANCELLED')
    ORDER BY ob.ScheduledStart;
END;
GO

-- Everything the OT tab shows for one admission: bookings, checklists, consents, anaesthesia records, notes, implants, charges
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_Data @CompanyId INT, @BranchId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT AdmissionId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId);
    -- 1 bookings
    SELECT ob.OtBookingId, ob.BookingNo, ob.OtId, o.OtName, ob.ProcedureId, ob.ProcedureName, ob.Laterality, ob.SurgeryType,
           ob.SurgeonId, LTRIM(RTRIM(ISNULL(s.NamePrefix + ' ', '') + s.FullName)) AS SurgeonName,
           ob.AssistantSurgeonId, LTRIM(RTRIM(ISNULL(asx.NamePrefix + ' ', '') + asx.FullName)) AS AssistantName,
           ob.AnaesthetistId, LTRIM(RTRIM(ISNULL(an.NamePrefix + ' ', '') + an.FullName)) AS AnaesthetistName,
           ob.AnaesthesiaTypeId, at.TypeName AS AnaesthesiaType, ob.ScrubNurse, ob.CirculatingNurse,
           ob.ScheduledStart, ob.ScheduledEnd, ob.PreOpDiagnosis, ob.Remarks, ob.Status,
           ob.InOtAt, ob.AnaesStartAt, ob.IncisionAt, ob.ClosureAt, ob.AnaesEndAt, ob.OutOtAt, ob.RecoveryOutAt,
           ob.IsUnplannedReturn, ob.ReturnReason, ob.CompletedAt, ob.CancelReason, ob.CancelledAt, ob.CreatedDate, uc.FullName AS CreatedByName,
           DATEDIFF(MINUTE, ob.IncisionAt, ob.ClosureAt) AS SurgeryMinutes, DATEDIFF(MINUTE, ob.InOtAt, ob.OutOtAt) AS OtMinutes,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdCharge c WHERE c.RefKind = 'OTB' AND c.RefId = ob.OtBookingId AND c.Status = 'POSTED') THEN 1 ELSE 0 END AS BIT) AS ChargesPosted,
           (SELECT ISNULL(SUM(c.Net), 0) FROM dbo.IpdCharge c WHERE c.RefKind IN ('OTB', 'OTI') AND c.SourceId = ob.OtBookingId AND c.SourceModule = 'OT' AND c.Status = 'POSTED')
           + (SELECT ISNULL(SUM(pl.Amount), 0) FROM dbo.IpdOtImplant i JOIN dbo.IpdPhIssueLine pl ON pl.LineId = i.IssueLineId WHERE i.OtBookingId = ob.OtBookingId AND i.Status = 'ACTIVE') AS ChargedNet,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdAdmissionConsent k JOIN dbo.ConsentMaster cm ON cm.Consent_ID = k.ConsentId
                                  WHERE k.OtBookingId = ob.OtBookingId AND (cm.ConsentType LIKE N'%urg%' OR cm.ConsentType LIKE N'%perat%')) THEN 1 ELSE 0 END AS BIT) AS HasSurgicalConsent,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdAdmissionConsent k JOIN dbo.ConsentMaster cm ON cm.Consent_ID = k.ConsentId
                                  WHERE k.OtBookingId = ob.OtBookingId AND (cm.ConsentType LIKE N'%naesth%' OR cm.ConsentType LIKE N'%nesth%')) THEN 1 ELSE 0 END AS BIT) AS HasAnaesConsent
    FROM dbo.IpdOtBooking ob
    JOIN dbo.OtMaster o ON o.OtId = ob.OtId
    JOIN dbo.DoctorMaster s ON s.DoctorId = ob.SurgeonId
    LEFT JOIN dbo.DoctorMaster asx ON asx.DoctorId = ob.AssistantSurgeonId
    LEFT JOIN dbo.DoctorMaster an ON an.DoctorId = ob.AnaesthetistId
    LEFT JOIN dbo.AnaesthesiaTypeMaster at ON at.AnaesthesiaTypeId = ob.AnaesthesiaTypeId
    LEFT JOIN dbo.Users uc ON uc.Id = ob.CreatedBy
    WHERE ob.AdmissionId = @adm
    ORDER BY CASE ob.Status WHEN 'IN_OT' THEN 0 WHEN 'SCHEDULED' THEN 1 WHEN 'COMPLETED' THEN 2 ELSE 3 END, ob.ScheduledStart DESC;
    -- 2 checklists
    SELECT c.OtBookingId, c.Phase, c.Answers, c.Remarks, c.CompletedAt, u.FullName AS CompletedByName
    FROM dbo.IpdOtChecklist c JOIN dbo.IpdOtBooking ob ON ob.OtBookingId = c.OtBookingId LEFT JOIN dbo.Users u ON u.Id = c.CompletedBy
    WHERE ob.AdmissionId = @adm;
    -- 3 consents of the bookings
    SELECT k.AdmissionConsentId, k.OtBookingId, k.ConsentType, k.SignedByName, k.SignedByRelation, k.SignedAt
    FROM dbo.IpdAdmissionConsent k WHERE k.AdmissionId = @adm AND k.OtBookingId IS NOT NULL ORDER BY k.SignedAt;
    -- 4 anaesthesia records
    SELECT r.*, at.TypeName AS AnaesthesiaType, us.FullName AS SignedByName, um.FullName AS ModifiedByName
    FROM dbo.IpdAnaesthesiaRecord r JOIN dbo.IpdOtBooking ob ON ob.OtBookingId = r.OtBookingId
    LEFT JOIN dbo.AnaesthesiaTypeMaster at ON at.AnaesthesiaTypeId = r.AnaesthesiaTypeId
    LEFT JOIN dbo.Users us ON us.Id = r.SignedBy LEFT JOIN dbo.Users um ON um.Id = ISNULL(r.ModifiedBy, r.CreatedBy)
    WHERE ob.AdmissionId = @adm;
    -- 5 surgery notes
    SELECT n.*, us.FullName AS SignedByName, um.FullName AS ModifiedByName,
           (SELECT COUNT(*) FROM dbo.IpdSurgeryNoteVersion v WHERE v.OtBookingId = n.OtBookingId) AS Amendments
    FROM dbo.IpdSurgeryNote n JOIN dbo.IpdOtBooking ob ON ob.OtBookingId = n.OtBookingId
    LEFT JOIN dbo.Users us ON us.Id = n.SignedBy LEFT JOIN dbo.Users um ON um.Id = ISNULL(n.ModifiedBy, n.CreatedBy)
    WHERE ob.AdmissionId = @adm;
    -- 6 implants and consumables
    SELECT i.ImplantId, i.OtBookingId, i.ItemType, i.ItemName, i.Manufacturer, i.CatalogueNo, i.BatchNo, i.SerialNo, i.ExpiryDate, i.Qty, i.Rate, i.GstPercent,
           i.ChargeId, CASE WHEN i.IssueLineId IS NOT NULL THEN CASE WHEN i.Status = 'ACTIVE' THEN pl.Amount END ELSE ch.Net END AS ChargeNet,
           i.Remarks, i.Status, i.RemoveReason, i.CreatedDate, u.FullName AS CreatedByName, i.ItemId, i.IssueId, pi.IssueNo, st.StoreName
    FROM dbo.IpdOtImplant i LEFT JOIN dbo.IpdCharge ch ON ch.ChargeId = i.ChargeId LEFT JOIN dbo.Users u ON u.Id = i.CreatedBy
    LEFT JOIN dbo.IpdPhIssueLine pl ON pl.LineId = i.IssueLineId LEFT JOIN dbo.IpdPhIssue pi ON pi.IssueId = i.IssueId LEFT JOIN dbo.PhStore st ON st.StoreId = i.StoreId
    WHERE i.AdmissionId = @adm ORDER BY i.CreatedDate;
    -- 7 OT charges posted
    SELECT c.ChargeId, c.SourceId AS OtBookingId, c.ChargeAt, c.ItemCode, c.ItemName, d.FullName AS DoctorName, c.Qty, c.Rate, c.Gross, c.Discount, c.GstAmount, c.Net,
           c.IsPackageItem, c.Status, c.CancelReason, c.RefKind
    FROM dbo.IpdCharge c LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    WHERE c.AdmissionId = @adm AND c.SourceModule = 'OT' ORDER BY c.ChargeId;
END;
GO

-- ── 5. book / edit / cancel ────────────────────────────────────────────────────────────────────────────────────────
-- @OtBookingId NULL = new booking; an existing one can be changed while SCHEDULED.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @OtBookingId INT = NULL, @OtId INT, @ProcedureId INT = NULL,
    @ProcedureName NVARCHAR(250) = NULL, @Laterality VARCHAR(10) = NULL, @SurgeryType VARCHAR(10), @SurgeonId INT, @AssistantSurgeonId INT = NULL,
    @AnaesthetistId INT = NULL, @AnaesthesiaTypeId INT = NULL, @ScrubNurse NVARCHAR(150) = NULL, @CirculatingNurse NVARCHAR(150) = NULL,
    @ScheduledStart DATETIME, @DurationMinutes INT, @PreOpDiagnosis NVARCHAR(500) = NULL, @Remarks NVARCHAR(500) = NULL,
    @IsUnplannedReturn BIT = 0, @ReturnReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @st VARCHAR(20), @open BIT, @bill INT, @admAt DATETIME, @pat INT;
        SELECT @st = Status, @open = IsOpen, @bill = BillId, @admAt = AdmissionAt, @pat = PatientId
        FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @st IS NULL THROW 57101, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @st NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') OR @bill IS NOT NULL
            THROW 57102, 'An OT can be booked only for an admitted patient before the final bill.', 1;
        IF @OtBookingId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtBooking WITH (UPDLOCK) WHERE OtBookingId = @OtBookingId AND AdmissionId = @AdmissionId)
            THROW 57103, 'The OT booking was not found.', 1;
        IF @OtBookingId IS NOT NULL AND (SELECT Status FROM dbo.IpdOtBooking WHERE OtBookingId = @OtBookingId) <> 'SCHEDULED'
            THROW 57104, 'Only a scheduled booking can be changed (the patient is already in OT or the booking is closed).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.OtMaster WHERE OtId = @OtId AND BranchId = @BranchId AND IsActive = 1) THROW 57105, 'Choose an active OT of this branch.', 1;
        IF @ProcedureId IS NOT NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.ProcedureMaster WHERE ProcedureId = @ProcedureId AND BranchId = @BranchId AND IsActive = 1) THROW 57106, 'Choose an active procedure.', 1;
            SET @ProcedureName = ISNULL(NULLIF(LTRIM(RTRIM(@ProcedureName)), N''), (SELECT ProcedureName FROM dbo.ProcedureMaster WHERE ProcedureId = @ProcedureId));
        END
        SET @ProcedureName = NULLIF(LTRIM(RTRIM(@ProcedureName)), N'');
        IF @ProcedureName IS NULL THROW 57107, 'Choose the procedure or enter the planned surgery.', 1;
        IF @SurgeryType NOT IN ('ELECTIVE', 'EMERGENCY') THROW 57108, 'Choose elective or emergency.', 1;
        IF @Laterality IS NOT NULL AND @Laterality NOT IN ('LEFT', 'RIGHT', 'BILATERAL', 'NA') THROW 57109, 'Choose the side (left, right, bilateral or not applicable).', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @SurgeonId AND IsActive = 1 AND ISNULL(IsSuspended, 0) = 0) THROW 57110, 'Choose an active surgeon.', 1;
        IF @AssistantSurgeonId IS NOT NULL AND (@AssistantSurgeonId = @SurgeonId OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AssistantSurgeonId AND IsActive = 1 AND ISNULL(IsSuspended, 0) = 0))
            THROW 57111, 'The assistant surgeon must be another active doctor.', 1;
        IF @AnaesthetistId IS NOT NULL AND (@AnaesthetistId = @SurgeonId OR NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AnaesthetistId AND IsActive = 1 AND ISNULL(IsSuspended, 0) = 0))
            THROW 57112, 'The anaesthetist must be another active doctor.', 1;
        IF @AnaesthesiaTypeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE AnaesthesiaTypeId = @AnaesthesiaTypeId AND IsActive = 1)
            THROW 57113, 'Choose an active anaesthesia type.', 1;
        IF @AnaesthesiaTypeId IS NOT NULL AND @AnaesthetistId IS NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.AnaesthesiaTypeMaster WHERE AnaesthesiaTypeId = @AnaesthesiaTypeId AND (TypeCode = 'LOC' OR TypeName LIKE N'Local%'))
            THROW 57114, 'Choose the anaesthetist for this anaesthesia (only local anaesthesia can be given without one).', 1;
        IF @ProcedureId IS NOT NULL AND @AnaesthesiaTypeId IS NULL AND (SELECT AnaesthesiaRequired FROM dbo.ProcedureMaster WHERE ProcedureId = @ProcedureId) = 1
            THROW 57115, 'This procedure needs anaesthesia: choose the anaesthesia type.', 1;
        IF @DurationMinutes IS NULL OR @DurationMinutes < 10 OR @DurationMinutes > 1440 THROW 57116, 'The expected duration must be between 10 minutes and 24 hours.', 1;
        IF @ScheduledStart IS NULL THROW 57117, 'Enter the OT start time.', 1;
        IF @ScheduledStart < @admAt THROW 57118, 'The OT cannot be booked before the admission time.', 1;
        IF @OtBookingId IS NULL AND @ScheduledStart < DATEADD(MINUTE, -30, @now) AND @SurgeryType = 'ELECTIVE'
            THROW 57119, 'An elective OT cannot be booked in the past (an emergency case already under way can be).', 1;
        IF ISNULL(@IsUnplannedReturn, 0) = 1 AND NULLIF(LTRIM(RTRIM(@ReturnReason)), N'') IS NULL
            THROW 57120, 'Enter the reason for the unplanned return to OT.', 1;
        DECLARE @end DATETIME = DATEADD(MINUTE, @DurationMinutes, @ScheduledStart), @clash NVARCHAR(300);
        -- one booking at a time in an OT, for a surgeon, an anaesthetist and a patient
        SELECT TOP (1) @clash = CONCAT(N'the OT is booked ', FORMAT(ob.ScheduledStart, 'dd-MMM HH:mm'), N' - ', FORMAT(ob.ScheduledEnd, 'HH:mm'), N' (', ob.BookingNo, N')')
        FROM dbo.IpdOtBooking ob WITH (UPDLOCK, HOLDLOCK)
        WHERE ob.OtId = @OtId AND ob.Status IN ('SCHEDULED', 'IN_OT') AND ob.OtBookingId <> ISNULL(@OtBookingId, 0) AND ob.ScheduledStart < @end AND ob.ScheduledEnd > @ScheduledStart;
        IF @clash IS NULL
            SELECT TOP (1) @clash = CONCAT(N'the surgeon / anaesthetist is in another OT ', FORMAT(ob.ScheduledStart, 'dd-MMM HH:mm'), N' - ', FORMAT(ob.ScheduledEnd, 'HH:mm'), N' (', ob.BookingNo, N')')
            FROM dbo.IpdOtBooking ob WITH (UPDLOCK, HOLDLOCK)
            WHERE ob.Status IN ('SCHEDULED', 'IN_OT') AND ob.OtBookingId <> ISNULL(@OtBookingId, 0) AND ob.ScheduledStart < @end AND ob.ScheduledEnd > @ScheduledStart
              AND (ob.SurgeonId IN (@SurgeonId, ISNULL(@AnaesthetistId, -1)) OR ob.AnaesthetistId IN (@SurgeonId, ISNULL(@AnaesthetistId, -1)));
        IF @clash IS NULL
            SELECT TOP (1) @clash = CONCAT(N'the patient already has an OT ', FORMAT(ob.ScheduledStart, 'dd-MMM HH:mm'), N' (', ob.BookingNo, N')')
            FROM dbo.IpdOtBooking ob WITH (UPDLOCK, HOLDLOCK)
            WHERE ob.AdmissionId = @AdmissionId AND ob.Status IN ('SCHEDULED', 'IN_OT') AND ob.OtBookingId <> ISNULL(@OtBookingId, 0)
              AND ob.ScheduledStart < @end AND ob.ScheduledEnd > @ScheduledStart;
        IF @clash IS NOT NULL BEGIN SET @msg = N'This slot is not free: ' + @clash + N'.'; THROW 57121, @msg, 1; END;

        DECLARE @no NVARCHAR(40);
        IF @OtBookingId IS NULL
        BEGIN
            EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'OTB', @DocDate = @ScheduledStart, @DocNo = @no OUTPUT;
            INSERT dbo.IpdOtBooking (CompanyId, BranchId, AdmissionId, BookingNo, OtId, ProcedureId, ProcedureName, Laterality, SurgeryType, SurgeonId, AssistantSurgeonId,
                   AnaesthetistId, AnaesthesiaTypeId, ScrubNurse, CirculatingNurse, ScheduledStart, ScheduledEnd, PreOpDiagnosis, Remarks, IsUnplannedReturn, ReturnReason, CreatedBy)
            VALUES (@CompanyId, @BranchId, @AdmissionId, @no, @OtId, @ProcedureId, @ProcedureName, @Laterality, @SurgeryType, @SurgeonId, @AssistantSurgeonId,
                   @AnaesthetistId, @AnaesthesiaTypeId, NULLIF(LTRIM(RTRIM(@ScrubNurse)), N''), NULLIF(LTRIM(RTRIM(@CirculatingNurse)), N''), @ScheduledStart, @end,
                   NULLIF(LTRIM(RTRIM(@PreOpDiagnosis)), N''), NULLIF(LTRIM(RTRIM(@Remarks)), N''), ISNULL(@IsUnplannedReturn, 0),
                   CASE WHEN @IsUnplannedReturn = 1 THEN LTRIM(RTRIM(@ReturnReason)) END, @UserId);
            SET @OtBookingId = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'OT_BOOK', LEFT(CONCAT(N'OT booked ', @no, N': ', @ProcedureName, N' on ', FORMAT(@ScheduledStart, 'dd-MMM-yyyy HH:mm'),
                    CASE WHEN @IsUnplannedReturn = 1 THEN N' (unplanned return to OT)' ELSE N'' END), 1000), @UserId);
        END
        ELSE
        BEGIN
            SET @no = (SELECT BookingNo FROM dbo.IpdOtBooking WHERE OtBookingId = @OtBookingId);
            UPDATE dbo.IpdOtBooking SET OtId = @OtId, ProcedureId = @ProcedureId, ProcedureName = @ProcedureName, Laterality = @Laterality, SurgeryType = @SurgeryType,
                   SurgeonId = @SurgeonId, AssistantSurgeonId = @AssistantSurgeonId, AnaesthetistId = @AnaesthetistId, AnaesthesiaTypeId = @AnaesthesiaTypeId,
                   ScrubNurse = NULLIF(LTRIM(RTRIM(@ScrubNurse)), N''), CirculatingNurse = NULLIF(LTRIM(RTRIM(@CirculatingNurse)), N''),
                   ScheduledStart = @ScheduledStart, ScheduledEnd = @end, PreOpDiagnosis = NULLIF(LTRIM(RTRIM(@PreOpDiagnosis)), N''),
                   Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), IsUnplannedReturn = ISNULL(@IsUnplannedReturn, 0),
                   ReturnReason = CASE WHEN @IsUnplannedReturn = 1 THEN LTRIM(RTRIM(@ReturnReason)) END, ModifiedBy = @UserId, ModifiedDate = @now
            WHERE OtBookingId = @OtBookingId;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'OT_EDIT', LEFT(CONCAT(N'OT booking ', @no, N' changed: ', @ProcedureName, N' on ', FORMAT(@ScheduledStart, 'dd-MMM-yyyy HH:mm')), 1000), @UserId);
        END
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @OtBookingId AS OtBookingId, @no AS BookingNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40);
        SELECT @adm = AdmissionId, @st = Status, @no = BookingNo FROM dbo.IpdOtBooking WITH (UPDLOCK)
        WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 57131, 'The OT booking was not found in this branch.', 1;
        IF @st <> 'SCHEDULED' THROW 57132, 'Only a scheduled booking can be cancelled (the patient has gone into OT or it is already closed).', 1;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 57133, 'Enter the reason for cancelling the OT booking.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdOtImplant WHERE OtBookingId = @OtBookingId AND Status = 'ACTIVE')
            THROW 57134, 'Remove the implants / consumables recorded on this booking first.', 1;
        UPDATE dbo.IpdOtBooking SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = GETDATE() WHERE OtBookingId = @OtBookingId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@adm, 'OT_CANCEL', LEFT(CONCAT(N'OT booking ', @no, N' cancelled: ', LTRIM(RTRIM(@Reason))), 1000), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 6. checklists ──────────────────────────────────────────────────────────────────────────────────────────────────
-- A phase is saved once, complete: every item answered, CHECK items YES (or NA where allowed); the consent items are checked
-- against the consents of the booking. Phases go in order: PREOP, SIGNIN, TIMEOUT, SIGNOUT.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_SaveChecklist
    @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @Phase VARCHAR(10), @Answers NVARCHAR(MAX), @Remarks NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40), @anaes INT;
        SELECT @adm = AdmissionId, @st = Status, @no = BookingNo, @anaes = AnaesthetistId FROM dbo.IpdOtBooking WITH (UPDLOCK)
        WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 57141, 'The OT booking was not found in this branch.', 1;
        IF @st IN ('COMPLETED', 'CANCELLED') THROW 57142, 'The OT booking is closed.', 1;
        IF @Phase NOT IN ('PREOP', 'SIGNIN', 'TIMEOUT', 'SIGNOUT') THROW 57143, 'Unknown checklist.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdOtChecklist WHERE OtBookingId = @OtBookingId AND Phase = @Phase) THROW 57144, 'This checklist is already completed.', 1;
        DECLARE @prev VARCHAR(10) = CASE @Phase WHEN 'SIGNIN' THEN 'PREOP' WHEN 'TIMEOUT' THEN 'SIGNIN' WHEN 'SIGNOUT' THEN 'TIMEOUT' END;
        IF @prev IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtChecklist WHERE OtBookingId = @OtBookingId AND Phase = @prev)
        BEGIN SET @msg = N'Complete the ' + CASE @prev WHEN 'PREOP' THEN N'pre-op checklist' WHEN 'SIGNIN' THEN N'Sign In' ELSE N'Time Out' END + N' first.'; THROW 57145, @msg, 1; END;
        IF @Phase IN ('SIGNIN', 'TIMEOUT', 'SIGNOUT') AND @st <> 'IN_OT' THROW 57146, 'Record the time the patient entered the OT first.', 1;
        IF ISJSON(@Answers) <> 1 THROW 57147, 'The checklist answers are not readable.', 1;
        DECLARE @a TABLE (Code VARCHAR(20) PRIMARY KEY, Answer VARCHAR(3), Note NVARCHAR(300));
        INSERT @a (Code, Answer, Note)
        SELECT LEFT(j.code, 20), UPPER(LEFT(j.answer, 3)), LEFT(NULLIF(LTRIM(RTRIM(j.note)), N''), 300)
        FROM OPENJSON(@Answers) WITH (code NVARCHAR(40) '$.code', answer NVARCHAR(10) '$.answer', note NVARCHAR(400) '$.note') j;
        DECLARE @bad NVARCHAR(300);
        SELECT TOP (1) @bad = t.ItemText FROM dbo.fn_Ipd_OtChecklistItems() t LEFT JOIN @a a ON a.Code = t.Code
        WHERE t.Phase = @Phase AND (a.Code IS NULL OR a.Answer NOT IN ('YES', 'NO', 'NA')
              OR (t.Kind = 'CHECK' AND a.Answer = 'NO') OR (t.Kind = 'CHECK' AND a.Answer = 'NA' AND t.AllowNa = 0) OR (t.Kind = 'INFO' AND a.Answer = 'NA'))
        ORDER BY t.Sort;
        IF @bad IS NOT NULL BEGIN SET @msg = N'Not ready: "' + @bad + N'". Every item must be confirmed before this checklist can be completed.'; THROW 57148, @msg, 1; END;
        IF @Phase = 'PREOP'
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmissionConsent k JOIN dbo.ConsentMaster cm ON cm.Consent_ID = k.ConsentId
                           WHERE k.OtBookingId = @OtBookingId AND (cm.ConsentType LIKE N'%urg%' OR cm.ConsentType LIKE N'%perat%'))
                THROW 57149, 'Record the surgical consent for this OT booking first (Record consent).', 1;
            IF @anaes IS NOT NULL AND (SELECT Answer FROM @a WHERE Code = 'ANAES_CONSENT') = 'NA' THROW 57150, 'An anaesthetist is on this booking: the anaesthesia consent cannot be "not applicable".', 1;
            IF (SELECT Answer FROM @a WHERE Code = 'ANAES_CONSENT') = 'YES'
               AND NOT EXISTS (SELECT 1 FROM dbo.IpdAdmissionConsent k JOIN dbo.ConsentMaster cm ON cm.Consent_ID = k.ConsentId
                               WHERE k.OtBookingId = @OtBookingId AND (cm.ConsentType LIKE N'%naesth%' OR cm.ConsentType LIKE N'%nesth%'))
                THROW 57151, 'Record the anaesthesia consent for this OT booking first (Record consent).', 1;
        END
        INSERT dbo.IpdOtChecklist (OtBookingId, Phase, Answers, Remarks, CompletedBy)
        VALUES (@OtBookingId, @Phase, (SELECT Code AS code, Answer AS answer, Note AS note FROM @a FOR JSON PATH), NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'OT_CHECKLIST', CONCAT(CASE @Phase WHEN 'PREOP' THEN N'Pre-op checklist' WHEN 'SIGNIN' THEN N'WHO Sign In' WHEN 'TIMEOUT' THEN N'WHO Time Out' ELSE N'WHO Sign Out' END,
                N' completed for ', @no), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 7. OT times and completion ─────────────────────────────────────────────────────────────────────────────────────
-- Times in order: in OT <= anaesthesia start <= incision <= closure <= anaesthesia end <= out of OT <= out of recovery.
-- Gates: in OT needs the pre-op checklist; anaesthesia start needs Sign In; incision needs Time Out; out of OT needs Sign Out.
-- A time already recorded can be corrected while the booking is open. Complete needs out-of-OT and the surgery note.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_SaveTimes
    @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @InOtAt DATETIME = NULL, @AnaesStartAt DATETIME = NULL, @IncisionAt DATETIME = NULL,
    @ClosureAt DATETIME = NULL, @AnaesEndAt DATETIME = NULL, @OutOtAt DATETIME = NULL, @RecoveryOutAt DATETIME = NULL, @Complete BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40), @admAt DATETIME, @anaesType INT;
        SELECT @adm = ob.AdmissionId, @st = ob.Status, @no = ob.BookingNo, @admAt = a.AdmissionAt, @anaesType = ob.AnaesthesiaTypeId
        FROM dbo.IpdOtBooking ob WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = ob.AdmissionId
        WHERE ob.OtBookingId = @OtBookingId AND ob.CompanyId = @CompanyId AND ob.BranchId = @BranchId;
        IF @adm IS NULL THROW 57161, 'The OT booking was not found in this branch.', 1;
        IF @st IN ('COMPLETED', 'CANCELLED') THROW 57162, 'The OT booking is closed.', 1;
        DECLARE @t TABLE (Seq INT, Name NVARCHAR(40), At DATETIME);
        INSERT @t VALUES (1, N'In OT', @InOtAt), (2, N'Anaesthesia start', @AnaesStartAt), (3, N'Incision', @IncisionAt), (4, N'Closure', @ClosureAt),
                         (5, N'Anaesthesia end', @AnaesEndAt), (6, N'Out of OT', @OutOtAt), (7, N'Out of recovery', @RecoveryOutAt);
        IF EXISTS (SELECT 1 FROM @t WHERE At > DATEADD(MINUTE, 5, @now)) THROW 57163, 'A time cannot be in the future.', 1;
        IF EXISTS (SELECT 1 FROM @t WHERE At < @admAt) THROW 57164, 'A time cannot be before the admission.', 1;
        DECLARE @bad NVARCHAR(200);
        SELECT TOP (1) @bad = CONCAT(b.Name, N' cannot be before ', a.Name) FROM @t a JOIN @t b ON b.Seq > a.Seq
        WHERE a.At IS NOT NULL AND b.At IS NOT NULL AND b.At < a.At ORDER BY a.Seq, b.Seq;
        IF @bad IS NOT NULL BEGIN SET @bad = @bad + N'.'; THROW 57165, @bad, 1; END;
        IF @InOtAt IS NULL AND EXISTS (SELECT 1 FROM @t WHERE Seq > 1 AND At IS NOT NULL) THROW 57166, 'Enter the time the patient entered the OT first.', 1;
        IF @InOtAt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtChecklist WHERE OtBookingId = @OtBookingId AND Phase = 'PREOP')
            THROW 57167, 'Complete the pre-op checklist before the patient enters the OT.', 1;
        IF @AnaesStartAt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtChecklist WHERE OtBookingId = @OtBookingId AND Phase = 'SIGNIN')
            THROW 57168, 'Complete the WHO Sign In before anaesthesia starts.', 1;
        IF @IncisionAt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtChecklist WHERE OtBookingId = @OtBookingId AND Phase = 'TIMEOUT')
            THROW 57169, 'Complete the WHO Time Out before the incision.', 1;
        IF @OutOtAt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtChecklist WHERE OtBookingId = @OtBookingId AND Phase = 'SIGNOUT')
            THROW 57170, 'Complete the WHO Sign Out before the patient leaves the OT.', 1;
        IF @Complete = 1
        BEGIN
            IF @OutOtAt IS NULL THROW 57171, 'Enter the time the patient left the OT before completing the surgery.', 1;
            IF @IncisionAt IS NULL OR @ClosureAt IS NULL THROW 57172, 'Enter the incision and closure times before completing the surgery.', 1;
            IF @anaesType IS NOT NULL AND (@AnaesStartAt IS NULL OR @AnaesEndAt IS NULL) THROW 57173, 'Enter the anaesthesia start and end times before completing the surgery.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.IpdSurgeryNote WHERE OtBookingId = @OtBookingId AND Status = 'SIGNED')
                THROW 57174, 'The surgeon must sign the surgery note before the surgery is completed.', 1;
        END
        UPDATE dbo.IpdOtBooking SET InOtAt = @InOtAt, AnaesStartAt = @AnaesStartAt, IncisionAt = @IncisionAt, ClosureAt = @ClosureAt, AnaesEndAt = @AnaesEndAt,
               OutOtAt = @OutOtAt, RecoveryOutAt = @RecoveryOutAt,
               Status = CASE WHEN @Complete = 1 THEN 'COMPLETED' WHEN @InOtAt IS NOT NULL THEN 'IN_OT' ELSE 'SCHEDULED' END,
               CompletedBy = CASE WHEN @Complete = 1 THEN @UserId END, CompletedAt = CASE WHEN @Complete = 1 THEN @now END,
               ModifiedBy = @UserId, ModifiedDate = @now
        WHERE OtBookingId = @OtBookingId;
        IF @Complete = 1 OR (@st = 'SCHEDULED' AND @InOtAt IS NOT NULL)
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@adm, CASE WHEN @Complete = 1 THEN 'OT_DONE' ELSE 'OT_IN' END,
                    CASE WHEN @Complete = 1 THEN CONCAT(N'Surgery completed (', @no, N'), out of OT ', FORMAT(@OutOtAt, 'dd-MMM HH:mm'))
                         ELSE CONCAT(N'Patient in OT (', @no, N') at ', FORMAT(@InOtAt, 'dd-MMM HH:mm')) END, @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 8. anaesthesia record ──────────────────────────────────────────────────────────────────────────────────────────
-- Saved as often as needed; @Sign = 1 signs it (the anaesthetist), after which it cannot be changed.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_SaveAnaesthesia
    @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @AnaesthesiaTypeId INT = NULL, @AsaGrade VARCHAR(4) = NULL, @Mallampati TINYINT = NULL,
    @NpoSince DATETIME = NULL, @Airway NVARCHAR(300) = NULL, @Comorbidities NVARCHAR(500) = NULL, @PreAnaesNotes NVARCHAR(1000) = NULL,
    @Technique NVARCHAR(500) = NULL, @AirwayDevice NVARCHAR(150) = NULL, @Drugs NVARCHAR(MAX) = NULL, @Monitoring NVARCHAR(MAX) = NULL,
    @FluidsMl INT = NULL, @BloodGivenMl INT = NULL, @UrineMl INT = NULL, @BloodLossMl INT = NULL, @Complications NVARCHAR(1000) = NULL,
    @AldreteScore TINYINT = NULL, @RecoveryNotes NVARCHAR(1000) = NULL, @Sign BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40);
        SELECT @adm = AdmissionId, @st = Status, @no = BookingNo FROM dbo.IpdOtBooking WITH (UPDLOCK)
        WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 57181, 'The OT booking was not found in this branch.', 1;
        IF @st = 'CANCELLED' THROW 57182, 'The OT booking is cancelled.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdAnaesthesiaRecord WHERE OtBookingId = @OtBookingId AND SignedAt IS NOT NULL) THROW 57183, 'The anaesthesia record is signed and cannot be changed.', 1;
        IF @AsaGrade IS NOT NULL AND @AsaGrade NOT IN ('I', 'II', 'III', 'IV', 'V', 'VI', 'IE', 'IIE', 'IIIE', 'IVE', 'VE') THROW 57184, 'Choose a valid ASA grade.', 1;
        IF @Mallampati IS NOT NULL AND @Mallampati NOT BETWEEN 1 AND 4 THROW 57185, 'The Mallampati class is 1 to 4.', 1;
        IF @AldreteScore IS NOT NULL AND @AldreteScore > 10 THROW 57186, 'The Aldrete score is 0 to 10.', 1;
        IF (@Drugs IS NOT NULL AND ISJSON(@Drugs) <> 1) OR (@Monitoring IS NOT NULL AND ISJSON(@Monitoring) <> 1) THROW 57187, 'The drug or monitoring rows are not readable.', 1;
        IF EXISTS (SELECT 1 FROM (VALUES (@FluidsMl), (@BloodGivenMl), (@UrineMl), (@BloodLossMl)) v (x) WHERE x < 0 OR x > 50000) THROW 57188, 'Volumes must be between 0 and 50,000 ml.', 1;
        IF @NpoSince > @now THROW 57189, 'Nil by mouth cannot start in the future.', 1;
        IF @Sign = 1 AND (@AsaGrade IS NULL OR @AnaesthesiaTypeId IS NULL) THROW 57190, 'Enter the ASA grade and the anaesthesia given before signing.', 1;
        IF @Sign = 1 AND @st <> 'COMPLETED' AND NOT EXISTS (SELECT 1 FROM dbo.IpdOtBooking WHERE OtBookingId = @OtBookingId AND OutOtAt IS NOT NULL)
            THROW 57191, 'The anaesthesia record is signed after the patient leaves the OT.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdAnaesthesiaRecord WHERE OtBookingId = @OtBookingId)
            UPDATE dbo.IpdAnaesthesiaRecord SET AnaesthesiaTypeId = @AnaesthesiaTypeId, AsaGrade = @AsaGrade, Mallampati = @Mallampati, NpoSince = @NpoSince,
                   Airway = NULLIF(LTRIM(RTRIM(@Airway)), N''), Comorbidities = NULLIF(LTRIM(RTRIM(@Comorbidities)), N''), PreAnaesNotes = NULLIF(LTRIM(RTRIM(@PreAnaesNotes)), N''),
                   Technique = NULLIF(LTRIM(RTRIM(@Technique)), N''), AirwayDevice = NULLIF(LTRIM(RTRIM(@AirwayDevice)), N''), Drugs = NULLIF(@Drugs, N'[]'), Monitoring = NULLIF(@Monitoring, N'[]'),
                   FluidsMl = @FluidsMl, BloodGivenMl = @BloodGivenMl, UrineMl = @UrineMl, BloodLossMl = @BloodLossMl, Complications = NULLIF(LTRIM(RTRIM(@Complications)), N''),
                   AldreteScore = @AldreteScore, RecoveryNotes = NULLIF(LTRIM(RTRIM(@RecoveryNotes)), N''),
                   SignedBy = CASE WHEN @Sign = 1 THEN @UserId END, SignedAt = CASE WHEN @Sign = 1 THEN @now END, ModifiedBy = @UserId, ModifiedDate = @now
            WHERE OtBookingId = @OtBookingId;
        ELSE
            INSERT dbo.IpdAnaesthesiaRecord (OtBookingId, AnaesthesiaTypeId, AsaGrade, Mallampati, NpoSince, Airway, Comorbidities, PreAnaesNotes, Technique, AirwayDevice, Drugs,
                   Monitoring, FluidsMl, BloodGivenMl, UrineMl, BloodLossMl, Complications, AldreteScore, RecoveryNotes, SignedBy, SignedAt, CreatedBy)
            VALUES (@OtBookingId, @AnaesthesiaTypeId, @AsaGrade, @Mallampati, @NpoSince, NULLIF(LTRIM(RTRIM(@Airway)), N''), NULLIF(LTRIM(RTRIM(@Comorbidities)), N''),
                   NULLIF(LTRIM(RTRIM(@PreAnaesNotes)), N''), NULLIF(LTRIM(RTRIM(@Technique)), N''), NULLIF(LTRIM(RTRIM(@AirwayDevice)), N''), NULLIF(@Drugs, N'[]'), NULLIF(@Monitoring, N'[]'),
                   @FluidsMl, @BloodGivenMl, @UrineMl, @BloodLossMl, NULLIF(LTRIM(RTRIM(@Complications)), N''), @AldreteScore, NULLIF(LTRIM(RTRIM(@RecoveryNotes)), N''),
                   CASE WHEN @Sign = 1 THEN @UserId END, CASE WHEN @Sign = 1 THEN @now END, @UserId);
        IF @Sign = 1
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@adm, 'OT_ANAES', CONCAT(N'Anaesthesia record signed for ', @no), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 9. surgery note ────────────────────────────────────────────────────────────────────────────────────────────────
-- Draft saved as often as needed; @Sign = 1 signs it. Changing a signed note (@CanAmend) needs a reason: the signed text is
-- kept in IpdSurgeryNoteVersion, the version goes up and the note must be signed again.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_SaveNote
    @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @ProcedurePerformed NVARCHAR(500), @PostOpDiagnosis NVARCHAR(500) = NULL,
    @Indication NVARCHAR(1000) = NULL, @Findings NVARCHAR(MAX) = NULL, @ProcedureDetails NVARCHAR(MAX) = NULL, @Specimens NVARCHAR(500) = NULL,
    @SpecimenToHistopath BIT = 0, @Drains NVARCHAR(300) = NULL, @BloodLossMl INT = NULL, @Complications NVARCHAR(1000) = NULL, @Closure NVARCHAR(300) = NULL,
    @PostOpPlan NVARCHAR(MAX) = NULL, @PatientCondition NVARCHAR(100) = NULL, @Sign BIT = 0, @CanSign BIT = 0, @AmendReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40), @incision DATETIME;
        SELECT @adm = AdmissionId, @st = Status, @no = BookingNo, @incision = IncisionAt FROM dbo.IpdOtBooking WITH (UPDLOCK)
        WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 57201, 'The OT booking was not found in this branch.', 1;
        IF @st IN ('SCHEDULED', 'CANCELLED') THROW 57202, 'The surgery note is written once the patient is in the OT.', 1;
        IF @incision IS NULL THROW 57203, 'Enter the incision time before writing the surgery note.', 1;
        IF NULLIF(LTRIM(RTRIM(@ProcedurePerformed)), N'') IS NULL THROW 57204, 'Enter the procedure performed.', 1;
        IF @BloodLossMl < 0 OR @BloodLossMl > 50000 THROW 57205, 'The blood loss must be between 0 and 50,000 ml.', 1;
        IF @Sign = 1 AND ISNULL(@CanSign, 0) = 0 THROW 57206, 'Signing the surgery note needs the IPD Patient > Sign surgery note permission.', 1;
        IF @Sign = 1 AND (NULLIF(LTRIM(RTRIM(@ProcedureDetails)), N'') IS NULL OR NULLIF(LTRIM(RTRIM(@PostOpPlan)), N'') IS NULL)
            THROW 57207, 'Enter the procedure details and the post-op plan before signing.', 1;
        DECLARE @signed BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdSurgeryNote WHERE OtBookingId = @OtBookingId AND Status = 'SIGNED') THEN 1 ELSE 0 END;
        IF @signed = 1
        BEGIN
            IF ISNULL(@CanSign, 0) = 0 THROW 57208, 'The note is signed: changing it needs the IPD Patient > Sign surgery note permission.', 1;
            IF NULLIF(LTRIM(RTRIM(@AmendReason)), N'') IS NULL THROW 57209, 'The note is signed: enter the reason for the change.', 1;
            INSERT dbo.IpdSurgeryNoteVersion (OtBookingId, Version, NoteJson, SignedBy, SignedAt, AmendReason, AmendedBy)
            SELECT n.OtBookingId, n.Version,
                   (SELECT n.ProcedurePerformed, n.PostOpDiagnosis, n.Indication, n.Findings, n.ProcedureDetails, n.Specimens, n.SpecimenToHistopath, n.Drains,
                           n.BloodLossMl, n.Complications, n.Closure, n.PostOpPlan, n.PatientCondition FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   n.SignedBy, n.SignedAt, LTRIM(RTRIM(@AmendReason)), @UserId
            FROM dbo.IpdSurgeryNote n WHERE n.OtBookingId = @OtBookingId;
        END
        IF EXISTS (SELECT 1 FROM dbo.IpdSurgeryNote WHERE OtBookingId = @OtBookingId)
            UPDATE dbo.IpdSurgeryNote SET ProcedurePerformed = LTRIM(RTRIM(@ProcedurePerformed)), PostOpDiagnosis = NULLIF(LTRIM(RTRIM(@PostOpDiagnosis)), N''),
                   Indication = NULLIF(LTRIM(RTRIM(@Indication)), N''), Findings = NULLIF(LTRIM(RTRIM(@Findings)), N''), ProcedureDetails = NULLIF(LTRIM(RTRIM(@ProcedureDetails)), N''),
                   Specimens = NULLIF(LTRIM(RTRIM(@Specimens)), N''), SpecimenToHistopath = ISNULL(@SpecimenToHistopath, 0), Drains = NULLIF(LTRIM(RTRIM(@Drains)), N''),
                   BloodLossMl = @BloodLossMl, Complications = NULLIF(LTRIM(RTRIM(@Complications)), N''), Closure = NULLIF(LTRIM(RTRIM(@Closure)), N''),
                   PostOpPlan = NULLIF(LTRIM(RTRIM(@PostOpPlan)), N''), PatientCondition = NULLIF(LTRIM(RTRIM(@PatientCondition)), N''),
                   Version = Version + @signed,
                   Status = CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END, SignedBy = CASE WHEN @Sign = 1 THEN @UserId END, SignedAt = CASE WHEN @Sign = 1 THEN @now END,
                   ModifiedBy = @UserId, ModifiedDate = @now
            WHERE OtBookingId = @OtBookingId;
        ELSE
            INSERT dbo.IpdSurgeryNote (OtBookingId, ProcedurePerformed, PostOpDiagnosis, Indication, Findings, ProcedureDetails, Specimens, SpecimenToHistopath, Drains,
                   BloodLossMl, Complications, Closure, PostOpPlan, PatientCondition, Status, SignedBy, SignedAt, CreatedBy)
            VALUES (@OtBookingId, LTRIM(RTRIM(@ProcedurePerformed)), NULLIF(LTRIM(RTRIM(@PostOpDiagnosis)), N''), NULLIF(LTRIM(RTRIM(@Indication)), N''),
                   NULLIF(LTRIM(RTRIM(@Findings)), N''), NULLIF(LTRIM(RTRIM(@ProcedureDetails)), N''), NULLIF(LTRIM(RTRIM(@Specimens)), N''), ISNULL(@SpecimenToHistopath, 0),
                   NULLIF(LTRIM(RTRIM(@Drains)), N''), @BloodLossMl, NULLIF(LTRIM(RTRIM(@Complications)), N''), NULLIF(LTRIM(RTRIM(@Closure)), N''),
                   NULLIF(LTRIM(RTRIM(@PostOpPlan)), N''), NULLIF(LTRIM(RTRIM(@PatientCondition)), N''),
                   CASE WHEN @Sign = 1 THEN 'SIGNED' ELSE 'DRAFT' END, CASE WHEN @Sign = 1 THEN @UserId END, CASE WHEN @Sign = 1 THEN @now END, @UserId);
        IF @Sign = 1 OR @signed = 1
            INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
            VALUES (@adm, 'OT_NOTE', LEFT(CONCAT(N'Surgery note ', CASE WHEN @signed = 1 THEN N'amended' ELSE N'signed' END, N' for ', @no,
                    CASE WHEN @signed = 1 THEN N': ' + LTRIM(RTRIM(@AmendReason)) ELSE N'' END), 1000), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 10. implants, surgical items and consumables: issued from pharmacy stock ─────────────────────────────────────────
-- The pharmacy categories of an OT item type (the category and its sub-categories): Implants / Surgical / Consumables.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_OtItemCategories (@CompanyId INT, @ItemType VARCHAR(10))
RETURNS TABLE
AS RETURN
(
    WITH top_ AS
    (
        SELECT c.CategoryId FROM dbo.PhCategory c
        WHERE c.CompanyId = @CompanyId AND c.IsActive = 1
          AND ((@ItemType = 'IMPLANT' AND c.CategoryName LIKE N'%mplant%') OR (@ItemType = 'SURGICAL' AND c.CategoryName LIKE N'%urgical%')
               OR (@ItemType = 'CONSUMABLE' AND c.CategoryName LIKE N'%onsumable%'))
    )
    SELECT CategoryId FROM top_
    UNION SELECT c.CategoryId FROM dbo.PhCategory c JOIN top_ t ON t.CategoryId = c.ParentCategoryId WHERE c.IsActive = 1
);
GO

-- Items of the type's categories with saleable stock in the store (search as you type); 2nd set: the selling stores.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_StockItems @CompanyId INT, @BranchId INT, @ItemType VARCHAR(10), @Q NVARCHAR(100) = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Q + N'%';
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SELECT TOP (40) i.ItemId, i.ItemCode, i.ItemName, c.CategoryName, m.ManufacturerName, SUM(s.QtyOnHand) AS Stock, MIN(b.ExpiryDate) AS NearestExpiry, @StoreId AS StoreId
    FROM dbo.PhItem i
    JOIN dbo.fn_Ipd_OtItemCategories(@CompanyId, @ItemType) k ON k.CategoryId = i.CategoryId
    JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
    LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
    JOIN dbo.PhStoreStock s ON s.ItemId = i.ItemId AND s.StoreId = @StoreId AND s.QtyOnHand > 0
    JOIN dbo.PhBatch b ON b.BatchId = s.BatchId AND b.IsBlocked = 0 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE))
    WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND (@Q IS NULL OR i.ItemName LIKE @like OR i.ItemCode LIKE @like OR i.Barcode = @Q)
    GROUP BY i.ItemId, i.ItemCode, i.ItemName, c.CategoryName, m.ManufacturerName
    ORDER BY CASE WHEN i.ItemName LIKE @Q + N'%' THEN 0 ELSE 1 END, i.ItemName;
    SELECT StoreId, StoreName, CAST(CASE WHEN StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL') THEN 1 ELSE 0 END AS BIT) AS IsDefault
    FROM dbo.PhStore WHERE BranchId = @BranchId AND dbo.fn_PhStoreOk(@BranchId, StoreId, 'SELL') = 1 ORDER BY StoreName;
    -- does the category exist at all (to tell "no such category" from "no stock")?
    SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.fn_Ipd_OtItemCategories(@CompanyId, @ItemType)) THEN 1 ELSE 0 END AS BIT) AS HasCategory;
END;
GO

-- Records an OT item by issuing it from pharmacy stock (usp_Api_IpdPh_Issue, head OT): stock goes down, the price comes from the
-- batch and the Price Rule of the payer, the IP bill is charged, the cost voucher is posted. Only an item of the type's
-- pharmacy category with enough saleable stock in the store can be chosen. The answer is the issue's row (IssueNo).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_AddImplant
    @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @ItemType VARCHAR(10), @ItemId INT = NULL, @BatchId INT = NULL, @StoreId INT = NULL,
    @Qty DECIMAL(18,3), @SerialNo NVARCHAR(80) = NULL, @Remarks NVARCHAR(300) = NULL,
    -- kept for older callers; the item, price and GST now come from the pharmacy master
    @ItemName NVARCHAR(200) = NULL, @Manufacturer NVARCHAR(150) = NULL, @CatalogueNo NVARCHAR(80) = NULL, @BatchNo NVARCHAR(80) = NULL,
    @ExpiryDate DATE = NULL, @Rate DECIMAL(18,2) = NULL, @GstPercent DECIMAL(5,2) = NULL, @CanCharge BIT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ot_item;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40), @day DATE, @surgeon INT;
        SELECT @adm = AdmissionId, @st = Status, @no = BookingNo, @day = CAST(ISNULL(IncisionAt, ScheduledStart) AS DATE), @surgeon = SurgeonId
        FROM dbo.IpdOtBooking WITH (UPDLOCK) WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 57221, 'The OT booking was not found in this branch.', 1;
        IF @st NOT IN ('IN_OT', 'COMPLETED') THROW 57222, 'Implants, surgical items and consumables are recorded once the patient is in the OT.', 1;
        IF @ItemType NOT IN ('IMPLANT', 'SURGICAL', 'CONSUMABLE') THROW 57223, 'Choose implant, surgical item or consumable.', 1;
        IF @ItemId IS NULL THROW 57224, 'Choose the item from the list (items with stock in the store).', 1;
        IF ISNULL(@Qty, 0) <= 0 THROW 57225, 'The quantity must be more than zero.', 1;
        IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
        IF @StoreId IS NULL THROW 57233, 'This branch has no selling pharmacy store (Master > Pharmacy Master > Store / Godown).', 1;
        DECLARE @iname NVARCHAR(250), @cat INT;
        SELECT @iname = ItemName, @cat = CategoryId FROM dbo.PhItem WHERE ItemId = @ItemId AND CompanyId = @CompanyId AND IsActive = 1;
        IF @iname IS NULL THROW 57234, 'The item was not found in the pharmacy item master.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.fn_Ipd_OtItemCategories(@CompanyId, @ItemType) WHERE CategoryId = @cat)
        BEGIN SET @msg = @iname + N' is not in the ' + CASE @ItemType WHEN 'IMPLANT' THEN N'Implants' WHEN 'SURGICAL' THEN N'Surgical' ELSE N'Consumables' END + N' category of the pharmacy.'; THROW 57235, @msg, 1; END;
        -- the batch: the one chosen, else the nearest expiry with enough stock (FEFO)
        DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
        IF @BatchId IS NULL
            SELECT TOP (1) @BatchId = b.BatchId FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
            WHERE s.StoreId = @StoreId AND s.ItemId = @ItemId AND s.QtyOnHand >= @Qty AND b.IsBlocked = 0 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE))
            ORDER BY b.ExpiryDate, b.BatchId;
        DECLARE @have DECIMAL(18,3) = (SELECT SUM(s.QtyOnHand) FROM dbo.PhStoreStock s WITH (UPDLOCK) WHERE s.StoreId = @StoreId AND s.ItemId = @ItemId AND (@BatchId IS NULL OR s.BatchId = @BatchId));
        IF @BatchId IS NULL OR ISNULL(@have, 0) < @Qty
        BEGIN
            SET @msg = CONCAT(N'Not enough stock of ', @iname, N': ', FORMAT(ISNULL(@have, 0), '0.###'), N' available', CASE WHEN @BatchId IS NOT NULL THEN N' in this batch' ELSE N' in one batch' END,
                              N', ', FORMAT(@Qty, '0.###'), N' asked.');
            THROW 57236, @msg, 1;
        END
        DECLARE @bno NVARCHAR(80), @exp DATE;
        SELECT @bno = BatchNo, @exp = ExpiryDate FROM dbo.PhBatch WHERE BatchId = @BatchId AND ItemId = @ItemId;
        IF @bno IS NULL THROW 57237, 'The batch does not belong to this item.', 1;
        IF @exp < @day THROW 57228, 'This batch had expired on the day of surgery: it cannot be used.', 1;
        IF NULLIF(LTRIM(RTRIM(@SerialNo)), N'') IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.IpdOtImplant WHERE Status = 'ACTIVE' AND ItemType = 'IMPLANT'
               AND SerialNo = LTRIM(RTRIM(@SerialNo)) AND ISNULL(ItemId, 0) = @ItemId)
            THROW 57231, 'An implant of this item with this serial number is already recorded.', 1;

        -- issue from the store (stock, price, charge, cost voucher); its result row is the answer
        DECLARE @ok BIT, @lines NVARCHAR(200) = CONCAT(N'[{"ItemId":', @ItemId, N',"BatchId":', @BatchId, N',"Qty":', @Qty, N'}]'),
                @rem NVARCHAR(300) = LEFT(CONCAT(N'OT ', @no, CASE WHEN NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NOT NULL THEN N' - ' + LTRIM(RTRIM(@Remarks)) END), 300);
        EXEC dbo.usp_Api_IpdPh_Issue @CompanyId = @CompanyId, @BranchId = @BranchId, @UserId = @UserId, @AdmissionId = @adm, @Lines = @lines, @Head = 'OT',
             @StoreId = @StoreId, @DoctorId = @surgeon, @Remarks = @rem, @Ok = @ok OUTPUT;
        IF ISNULL(@ok, 0) = 0
        BEGIN
            IF @tc = 0 AND XACT_STATE() <> 0 ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ot_item;
            RETURN;
        END
        DECLARE @issue INT = (SELECT TOP (1) IssueId FROM dbo.IpdPhIssue WHERE AdmissionId = @adm AND Kind = 'ISSUE' AND Head = 'OT' AND CreatedBy = @UserId ORDER BY IssueId DESC);
        DECLARE @line INT, @price DECIMAL(12,4), @gst DECIMAL(5,2), @chg BIGINT;
        SELECT TOP (1) @line = LineId, @price = UnitPrice, @gst = GstPercent, @chg = ChargeId FROM dbo.IpdPhIssueLine WHERE IssueId = @issue ORDER BY LineId;
        INSERT dbo.IpdOtImplant (OtBookingId, AdmissionId, ItemType, ItemName, Manufacturer, CatalogueNo, BatchNo, SerialNo, ExpiryDate, Qty, Rate, GstPercent, ChargeId, Remarks,
               CreatedBy, ItemId, BatchId, StoreId, IssueId, IssueLineId)
        SELECT @OtBookingId, @adm, @ItemType, i.ItemName, m.ManufacturerName, i.ItemCode, @bno, NULLIF(LTRIM(RTRIM(@SerialNo)), N''), @exp, @Qty, @price, @gst, @chg,
               NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId, @ItemId, @BatchId, @StoreId, @issue, @line
        FROM dbo.PhItem i LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId WHERE i.ItemId = @ItemId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'OT_IMPLANT', LEFT(CONCAT(CASE @ItemType WHEN 'IMPLANT' THEN N'Implant ' WHEN 'SURGICAL' THEN N'Surgical item ' ELSE N'OT consumable ' END, @iname,
                N', batch ', @bno, N' x ', FORMAT(@Qty, '0.###'), N' issued for ', @no), 1000), @UserId);
        IF @tc = 0 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ot_item;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- Removes an OT item: one issued from stock goes back to the store (IPD pharmacy return, the charge follows); an older
-- manual row only has its charge cancelled.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_RemoveImplant @CompanyId INT, @BranchId INT, @UserId INT, @ImplantId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ot_item;
        DECLARE @adm INT, @st VARCHAR(10), @chg BIGINT, @name NVARCHAR(200), @bill INT, @line INT, @qty DECIMAL(18,3);
        SELECT @adm = i.AdmissionId, @st = i.Status, @chg = i.ChargeId, @name = i.ItemName, @bill = a.BillId, @line = i.IssueLineId, @qty = i.Qty
        FROM dbo.IpdOtImplant i WITH (UPDLOCK) JOIN dbo.IpdOtBooking ob ON ob.OtBookingId = i.OtBookingId JOIN dbo.IpdAdmission a ON a.AdmissionId = i.AdmissionId
        WHERE i.ImplantId = @ImplantId AND ob.CompanyId = @CompanyId AND ob.BranchId = @BranchId;
        IF @adm IS NULL THROW 57241, 'The item was not found in this branch.', 1;
        IF @st <> 'ACTIVE' THROW 57242, 'The item is already removed.', 1;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 57243, 'Enter the reason (e.g. entered by mistake, not used).', 1;
        IF @bill IS NOT NULL THROW 57244, 'The final bill is made: cancel the bill first.', 1;
        UPDATE dbo.IpdOtImplant SET Status = 'REMOVED', RemoveReason = LTRIM(RTRIM(@Reason)), RemovedBy = @UserId, RemovedAt = GETDATE() WHERE ImplantId = @ImplantId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@adm, 'OT_IMPLANT', LEFT(CONCAT(N'OT item removed: ', @name, N' - ', LTRIM(RTRIM(@Reason))), 1000), @UserId);
        IF @line IS NOT NULL
        BEGIN
            DECLARE @left DECIMAL(18,3) = (SELECT Qty - ReturnedQty FROM dbo.IpdPhIssueLine WHERE LineId = @line), @ok BIT;
            IF ISNULL(@left, 0) > 0
            BEGIN
                DECLARE @lines NVARCHAR(200) = CONCAT(N'[{"LineId":', @line, N',"Qty":', @left, N'}]'), @why NVARCHAR(300) = LEFT(N'OT item removed: ' + LTRIM(RTRIM(@Reason)), 300);
                EXEC dbo.usp_Api_IpdPh_Return @CompanyId = @CompanyId, @BranchId = @BranchId, @UserId = @UserId, @AdmissionId = @adm, @Lines = @lines, @Reason = @why,
                     @IgnoreReturnable = 1, @Ok = @ok OUTPUT;
                IF ISNULL(@ok, 0) = 0
                BEGIN
                    IF @tc = 0 AND XACT_STATE() <> 0 ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ot_item;
                    RETURN;
                END
                IF @tc = 0 COMMIT;
                RETURN;   -- the return's row is the answer
            END
        END
        ELSE IF @chg IS NOT NULL
            UPDATE dbo.IpdCharge SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = GETDATE()
            WHERE ChargeId = @chg AND Status = 'POSTED';
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ot_item;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 11. OT charges ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_ChargePreview @CompanyId INT, @BranchId INT, @OtBookingId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT l.Code, l.Name, l.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName, l.Rate, l.Source, l.UsedFallback, l.Sort,
           CAST(CASE WHEN dbo.fn_Ipd_InPackage(ob.AdmissionId, 'OT') = 1 THEN 1 ELSE 0 END AS BIT) AS InPackage
    FROM dbo.IpdOtBooking ob
    CROSS APPLY dbo.fn_Ipd_OtChargeLines(ob.OtBookingId) l
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = l.DoctorId
    WHERE ob.OtBookingId = @OtBookingId AND ob.CompanyId = @CompanyId AND ob.BranchId = @BranchId
    ORDER BY l.Sort;
END;
GO

-- Posts the OT charges of a completed surgery once (again only after they were reversed). @Lines = [{ "code": "SURGEON", "rate": 15000 }]:
-- the lines to post with their rates; a rate other than the master's needs @CanEditRate.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_PostCharges
    @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @Lines NVARCHAR(MAX), @CanEditRate BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE(), @msg NVARCHAR(600);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @st VARCHAR(10), @no NVARCHAR(40), @at DATETIME, @proc NVARCHAR(250);
        SELECT @adm = AdmissionId, @st = Status, @no = BookingNo, @at = OutOtAt, @proc = ProcedureName FROM dbo.IpdOtBooking WITH (UPDLOCK)
        WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @adm IS NULL THROW 57251, 'The OT booking was not found in this branch.', 1;
        IF @st <> 'COMPLETED' THROW 57252, 'OT charges are posted after the surgery is completed.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdCharge WHERE RefKind = 'OTB' AND RefId = @OtBookingId AND Status = 'POSTED')
            THROW 57253, 'The OT charges of this surgery are already posted (reverse them first to post again).', 1;
        IF ISJSON(@Lines) <> 1 THROW 57254, 'The charge lines are not readable.', 1;
        DECLARE @l TABLE (Code VARCHAR(20) PRIMARY KEY, Rate DECIMAL(18,2));
        INSERT @l SELECT LEFT(j.code, 20), j.rate FROM OPENJSON(@Lines) WITH (code NVARCHAR(40) '$.code', rate DECIMAL(18,2) '$.rate') j WHERE j.rate > 0;
        IF NOT EXISTS (SELECT 1 FROM @l) THROW 57255, 'There is no OT charge with a rate to post.', 1;
        IF EXISTS (SELECT 1 FROM @l l LEFT JOIN dbo.fn_Ipd_OtChargeLines(@OtBookingId) m ON m.Code = l.Code WHERE m.Code IS NULL) THROW 57256, 'Unknown OT charge line.', 1;
        IF ISNULL(@CanEditRate, 0) = 0 AND EXISTS (SELECT 1 FROM @l l JOIN dbo.fn_Ipd_OtChargeLines(@OtBookingId) m ON m.Code = l.Code WHERE l.Rate <> m.Rate)
            THROW 57257, 'Changing an OT rate needs the IPD Patient > Change rate permission.', 1;
        SET @at = CASE WHEN @at IS NULL OR @at > @now THEN @now ELSE @at END;
        DECLARE @code VARCHAR(20), @name NVARCHAR(250), @doc INT, @rate DECIMAL(18,2), @mrate DECIMAL(18,2), @chg BIGINT, @n INT = 0, @total DECIMAL(18,2) = 0;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT m.Code, LEFT(CONCAT(m.Name, N' - ', @proc, CASE WHEN d.FullName IS NOT NULL THEN N' (' + LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) + N')' ELSE N'' END), 250),
                   m.DoctorId, l.Rate, m.Rate
            FROM @l l JOIN dbo.fn_Ipd_OtChargeLines(@OtBookingId) m ON m.Code = l.Code LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = m.DoctorId ORDER BY m.Sort;
        OPEN c; FETCH NEXT FROM c INTO @code, @name, @doc, @rate, @mrate;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @chg = NULL;
            EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @adm, @UserId = @UserId, @Head = 'OT', @ItemCode = @code, @ItemName = @name, @SourceModule = 'OT',
                 @SourceId = @OtBookingId, @SourceNo = @no, @DoctorId = @doc, @ChargeAt = @at, @Qty = 1, @Rate = @rate, @Discount = 0, @GstPercent = 0,
                 @Remarks = NULL, @MasterRate = @mrate, @RefKind = 'OTB', @RefId = @OtBookingId, @ChargeId = @chg OUTPUT;
            SELECT @n += 1, @total += Net FROM dbo.IpdCharge WHERE ChargeId = @chg;
            FETCH NEXT FROM c INTO @code, @name, @doc, @rate, @mrate;
        END
        CLOSE c; DEALLOCATE c;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'OT_CHARGE', CONCAT(N'OT charges posted for ', @no, N': ', @n, N' line(s), ₹', FORMAT(@total, 'N2', 'en-IN')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId, @n AS Lines, @total AS Total;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'c') >= -1 BEGIN CLOSE c; DEALLOCATE c; END;
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- Reverses every posted OT charge of a surgery (not the implant rows: remove those one by one).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_ReverseCharges @CompanyId INT, @BranchId INT, @UserId INT, @OtBookingId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @adm INT, @no NVARCHAR(40), @bill INT;
        SELECT @adm = ob.AdmissionId, @no = ob.BookingNo, @bill = a.BillId FROM dbo.IpdOtBooking ob WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = ob.AdmissionId
        WHERE ob.OtBookingId = @OtBookingId AND ob.CompanyId = @CompanyId AND ob.BranchId = @BranchId;
        IF @adm IS NULL THROW 57261, 'The OT booking was not found in this branch.', 1;
        IF @bill IS NOT NULL THROW 57262, 'The final bill is made: cancel the bill first.', 1;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 57263, 'Enter the reason for reversing the OT charges.', 1;
        UPDATE dbo.IpdCharge SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = GETDATE()
        WHERE RefKind = 'OTB' AND RefId = @OtBookingId AND Status = 'POSTED';
        IF @@ROWCOUNT = 0 THROW 57264, 'There are no posted OT charges on this surgery.', 1;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy) VALUES (@adm, 'OT_CHARGE', LEFT(CONCAT(N'OT charges reversed for ', @no, N': ', LTRIM(RTRIM(@Reason))), 1000), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- OT record print: the booking with team, times, checklists, consents, anaesthesia record, surgery note, implants and charges
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdOt_Print @CompanyId INT, @BranchId INT, @OtBookingId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT AdmissionId FROM dbo.IpdOtBooking WHERE OtBookingId = @OtBookingId AND CompanyId = @CompanyId AND BranchId = @BranchId);
    SELECT h.* FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h;
    -- the rest is the OT tab's data; the page keeps the rows of this booking
    EXEC dbo.usp_Api_IpdOt_Data @CompanyId = @CompanyId, @BranchId = @BranchId, @AdmissionId = @adm;
END;
GO

-- ── 12. consent with the OT booking (replaces 2423) ────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdConsent_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @ConsentId INT, @SignedByName NVARCHAR(150), @SignedByRelation NVARCHAR(50) = NULL,
    @WitnessName NVARCHAR(150) = NULL, @SignaturePath NVARCHAR(400) = NULL, @WitnessSignaturePath NVARCHAR(400) = NULL, @OtBookingId INT = NULL
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
        DECLARE @proc NVARCHAR(250);
        IF @OtBookingId IS NOT NULL
        BEGIN
            SELECT @proc = ProcedureName FROM dbo.IpdOtBooking WHERE OtBookingId = @OtBookingId AND AdmissionId = @AdmissionId AND Status <> 'CANCELLED';
            IF @proc IS NULL THROW 54605, 'The OT booking of this consent was not found.', 1;
        END
        INSERT dbo.IpdAdmissionConsent (AdmissionId, ConsentId, ConsentType, Language, Version, ContentHtml, SignedByName, SignedByRelation, WitnessName, SignaturePath,
               WitnessSignaturePath, SignedAt, CreatedBy, OtBookingId)
        SELECT @AdmissionId, c.Consent_ID, c.ConsentType, c.Language, c.Version,
               REPLACE(dbo.fn_Ipd_FillConsent(c.ConsentTemplateContent, @AdmissionId, NULLIF(@SignedByRelation, N''), NULLIF(LTRIM(RTRIM(@WitnessName)), N''), @now),
                       N'{{ProcedureName}}', ISNULL(@proc, N'')),
               LTRIM(RTRIM(@SignedByName)), NULLIF(@SignedByRelation, N''), NULLIF(LTRIM(RTRIM(@WitnessName)), N''), NULLIF(@SignaturePath, N''), NULLIF(@WitnessSignaturePath, N''),
               @now, @UserId, @OtBookingId
        FROM dbo.ConsentMaster c WHERE c.Consent_ID = @ConsentId;
        DECLARE @cid INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'CONSENT', CONCAT(ConsentType, N' signed by ', SignedByName, CASE WHEN @proc IS NOT NULL THEN N' for ' + @proc ELSE N'' END), @UserId
        FROM dbo.IpdAdmissionConsent WHERE AdmissionConsentId = @cid;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @cid AS AdmissionConsentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

PRINT '2492 IPD OT - done.';
GO
