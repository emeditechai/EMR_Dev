-- 2570: IPD flow-gap fixes (2026-11-28) - schema for every gap closed in 2571-2576. Safe to re-run.
--   Settings (HospitalSettings, NULL = default):
--     IpdFinalBillNeedsAdvice (1)   final bill only after the discharge advice (an interim bill before it)
--     IpdDiscountLimitPercent (10)  bill / settlement discount above this % needs IPD Patient > High discount
--     IpdPreAuthAlertPercent (90)   insurance alert when the running bill reaches this % of the approved amount
--     IpdReopenHours (24)           a gate pass can be reopened within these hours
--     IpdAllergyStatusRequired (1)  allergy status (or "No known allergies") before the first medicine order
--     IpdMarNeedsVerify (1)         a medicine order is verified by the pharmacist before routine doses are charted
--     IpdMarScanRequired (0)        wristband scan (UHID / IP no.) before a dose is charted
--     IpdReadmitDays (30)           readmission flag window
--     IpdDaycareMaxHours (24)       a day-care stay longer than this is flagged
--   Tables: IpdBillAdjustment / Line (supplementary bill, credit note after discharge), IpdDischargeReopen,
--           PatientDeceased, IpdCodeStatusLog, IpdEscalation, IpdMedRecon, IpdTransfusion,
--           IpdRestraint / Check, IpdNewborn.
--   Columns: IpdAdmission CodeStatus / ReadmitOf / Isolation / MotherAdmissionId; IpdOrder pharmacist verify +
--            overrides; IpdMarAdmin ScanVerified; WardMaster MinAgeDays / MaxAgeDays; IpdBedMovement OrderedByDoctorId;
--            IpdPreAuth RoomRentLimit / IcuRentLimit; IpdBill ProportionateDeduction; IpdRiskScore kind PADUA.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── settings ─────────────────────────────────────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.HospitalSettings', 'IpdFinalBillNeedsAdvice') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdFinalBillNeedsAdvice BIT NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdDiscountLimitPercent') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdDiscountLimitPercent DECIMAL(5,2) NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdPreAuthAlertPercent') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdPreAuthAlertPercent DECIMAL(5,2) NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdReopenHours') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdReopenHours INT NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdAllergyStatusRequired') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdAllergyStatusRequired BIT NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdMarNeedsVerify') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdMarNeedsVerify BIT NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdMarScanRequired') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdMarScanRequired BIT NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdReadmitDays') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdReadmitDays INT NULL;
IF COL_LENGTH('dbo.HospitalSettings', 'IpdDaycareMaxHours') IS NULL ALTER TABLE dbo.HospitalSettings ADD IpdDaycareMaxHours INT NULL;
GO

-- one row of the gap settings of a branch, defaults applied
CREATE OR ALTER FUNCTION dbo.fn_Ipd_GapSettings (@BranchId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(s.IpdFinalBillNeedsAdvice, 1) AS BIT) AS FinalBillNeedsAdvice,
           CAST(ISNULL(s.IpdDiscountLimitPercent, 10) AS DECIMAL(5,2)) AS DiscountLimitPercent,
           CAST(ISNULL(s.IpdPreAuthAlertPercent, 90) AS DECIMAL(5,2)) AS PreAuthAlertPercent,
           ISNULL(s.IpdReopenHours, 24) AS ReopenHours,
           CAST(ISNULL(s.IpdAllergyStatusRequired, 1) AS BIT) AS AllergyStatusRequired,
           CAST(ISNULL(s.IpdMarNeedsVerify, 1) AS BIT) AS MarNeedsVerify,
           CAST(ISNULL(s.IpdMarScanRequired, 0) AS BIT) AS MarScanRequired,
           ISNULL(s.IpdReadmitDays, 30) AS ReadmitDays,
           ISNULL(s.IpdDaycareMaxHours, 24) AS DaycareMaxHours
    FROM (SELECT 1 AS One) o
    OUTER APPLY (SELECT TOP (1) * FROM dbo.HospitalSettings h WHERE h.BranchID = @BranchId ORDER BY h.Id DESC) s
);
GO

-- ── A6: supplementary bill / credit note after the final bill ────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdBillAdjustment', 'U') IS NULL
    CREATE TABLE dbo.IpdBillAdjustment
    (
        AdjId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdBillAdjustment PRIMARY KEY,
        CompanyId     INT            NOT NULL,
        BranchId      INT            NOT NULL,
        AdmissionId   INT            NOT NULL CONSTRAINT FK_IpdBillAdj_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        BillId        INT            NOT NULL CONSTRAINT FK_IpdBillAdj_Bill REFERENCES dbo.IpdBill (BillId),
        Kind          CHAR(4)        NOT NULL CONSTRAINT CK_IpdBillAdj_Kind CHECK (Kind IN ('SUPP', 'CRED')),   -- supplementary bill / credit note
        DocNo         NVARCHAR(40)   NOT NULL,
        DocAt         DATETIME       NOT NULL,
        Gross         DECIMAL(18,2)  NOT NULL,
        Gst           DECIMAL(18,2)  NOT NULL,
        Net           DECIMAL(18,2)  NOT NULL,
        Reason        NVARCHAR(300)  NOT NULL,
        Status        VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdBillAdj_Status DEFAULT ('ACTIVE') CONSTRAINT CK_IpdBillAdj_Status CHECK (Status IN ('ACTIVE', 'CANCELLED')),
        LedgerTxnId   BIGINT         NULL,
        CancelTxnId   BIGINT         NULL,
        CancelReason  NVARCHAR(300)  NULL,
        CancelledBy   INT            NULL,
        CancelledAt   DATETIME       NULL,
        CreatedBy     INT            NOT NULL,
        CreatedDate   DATETIME       NOT NULL CONSTRAINT DF_IpdBillAdj_Created DEFAULT (GETDATE())
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdBillAdjustment_Adm' AND object_id = OBJECT_ID('dbo.IpdBillAdjustment'))
    CREATE INDEX IX_IpdBillAdjustment_Adm ON dbo.IpdBillAdjustment (AdmissionId) INCLUDE (Kind, Net, Status);
IF OBJECT_ID('dbo.IpdBillAdjustmentLine', 'U') IS NULL
    CREATE TABLE dbo.IpdBillAdjustmentLine
    (
        LineId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdBillAdjustmentLine PRIMARY KEY,
        AdjId       INT            NOT NULL CONSTRAINT FK_IpdBillAdjLine_Adj REFERENCES dbo.IpdBillAdjustment (AdjId),
        Head        VARCHAR(20)    NOT NULL,
        ItemName    NVARCHAR(250)  NOT NULL,
        Qty         DECIMAL(18,3)  NOT NULL,
        Rate        DECIMAL(18,2)  NOT NULL,
        Gross       DECIMAL(18,2)  NOT NULL,
        GstPercent  DECIMAL(5,2)   NOT NULL,
        GstAmount   DECIMAL(18,2)  NOT NULL,
        Net         DECIMAL(18,2)  NOT NULL,
        BillLineId  INT            NULL      -- a credit note line may point at the bill line it corrects
    );
GO

-- ── C8: a gate pass reopened (with the reason) ───────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdDischargeReopen', 'U') IS NULL
    CREATE TABLE dbo.IpdDischargeReopen
    (
        ReopenId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdDischargeReopen PRIMARY KEY,
        AdmissionId  INT            NOT NULL,
        DischargeId  INT            NOT NULL,
        GatePassNo   NVARCHAR(40)   NULL,
        GatePassAt   DATETIME       NULL,
        Reason       NVARCHAR(300)  NOT NULL,
        ReopenedBy   INT            NOT NULL,
        ReopenedAt   DATETIME       NOT NULL CONSTRAINT DF_IpdDischargeReopen_At DEFAULT (GETDATE())
    );
GO

-- ── C2: patient deceased (kept outside PatientMaster) ────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PatientDeceased', 'U') IS NULL
    CREATE TABLE dbo.PatientDeceased
    (
        PatientId    INT            NOT NULL CONSTRAINT PK_PatientDeceased PRIMARY KEY,
        DeceasedAt   DATETIME       NOT NULL,
        AdmissionId  INT            NULL,
        DeathId      INT            NULL,
        Source       VARCHAR(10)    NOT NULL CONSTRAINT DF_PatientDeceased_Source DEFAULT ('IPD'),
        RecordedBy   INT            NOT NULL,
        RecordedAt   DATETIME       NOT NULL CONSTRAINT DF_PatientDeceased_At DEFAULT (GETDATE())
    );
GO

-- ── admission columns: B5 code status, C6 readmission, B11 isolation, C4 mother ──────────────────────────────
IF COL_LENGTH('dbo.IpdAdmission', 'CodeStatus') IS NULL ALTER TABLE dbo.IpdAdmission ADD CodeStatus VARCHAR(12) NULL;   -- NULL = not decided (full resuscitation)
IF COL_LENGTH('dbo.IpdAdmission', 'ReadmitOfAdmissionId') IS NULL ALTER TABLE dbo.IpdAdmission ADD ReadmitOfAdmissionId INT NULL;
IF COL_LENGTH('dbo.IpdAdmission', 'ReadmitDays') IS NULL ALTER TABLE dbo.IpdAdmission ADD ReadmitDays INT NULL;
IF COL_LENGTH('dbo.IpdAdmission', 'IsolationType') IS NULL ALTER TABLE dbo.IpdAdmission ADD IsolationType VARCHAR(12) NULL;   -- CONTACT / DROPLET / AIRBORNE / PROTECTIVE
IF COL_LENGTH('dbo.IpdAdmission', 'IsolationReason') IS NULL ALTER TABLE dbo.IpdAdmission ADD IsolationReason NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.IpdAdmission', 'IsolationSince') IS NULL ALTER TABLE dbo.IpdAdmission ADD IsolationSince DATETIME NULL;
IF COL_LENGTH('dbo.IpdAdmission', 'MotherAdmissionId') IS NULL ALTER TABLE dbo.IpdAdmission ADD MotherAdmissionId INT NULL;
GO

IF OBJECT_ID('dbo.IpdCodeStatusLog', 'U') IS NULL
    CREATE TABLE dbo.IpdCodeStatusLog
    (
        LogId           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdCodeStatusLog PRIMARY KEY,
        AdmissionId     INT            NOT NULL,
        CodeStatus      VARCHAR(12)    NOT NULL CONSTRAINT CK_IpdCodeStatusLog_Code CHECK (CodeStatus IN ('FULL', 'DNR', 'DNI', 'DNR_DNI', 'LIMITED')),
        DoctorId        INT            NOT NULL,
        DiscussedWith   NVARCHAR(150)  NULL,
        Relation        NVARCHAR(50)   NULL,
        Reason          NVARCHAR(500)  NULL,
        Limits          NVARCHAR(500)  NULL,     -- LIMITED: what is / is not to be done
        RecordedBy      INT            NOT NULL,
        RecordedAt      DATETIME       NOT NULL CONSTRAINT DF_IpdCodeStatusLog_At DEFAULT (GETDATE())
    );
GO

-- B2 uses the pharmacy Drug Interaction master (PhDrugInteraction, 2406) and fn_PhMolecules.

-- ── order columns: B3 pharmacist verification, B1 / B2 overrides ─────────────────────────────────────────────
IF COL_LENGTH('dbo.IpdOrder', 'VerifiedBy') IS NULL ALTER TABLE dbo.IpdOrder ADD VerifiedBy INT NULL;
IF COL_LENGTH('dbo.IpdOrder', 'VerifiedAt') IS NULL ALTER TABLE dbo.IpdOrder ADD VerifiedAt DATETIME NULL;
IF COL_LENGTH('dbo.IpdOrder', 'VerifyNote') IS NULL ALTER TABLE dbo.IpdOrder ADD VerifyNote NVARCHAR(300) NULL;
IF COL_LENGTH('dbo.IpdOrder', 'VerifyStatus') IS NULL ALTER TABLE dbo.IpdOrder ADD VerifyStatus VARCHAR(10) NULL;   -- VERIFIED / QUERY
IF COL_LENGTH('dbo.IpdOrder', 'AllergyOverride') IS NULL ALTER TABLE dbo.IpdOrder ADD AllergyOverride NVARCHAR(300) NULL;
IF COL_LENGTH('dbo.IpdOrder', 'InteractionOverride') IS NULL ALTER TABLE dbo.IpdOrder ADD InteractionOverride NVARCHAR(300) NULL;
IF COL_LENGTH('dbo.IpdMarAdmin', 'ScanVerified') IS NULL ALTER TABLE dbo.IpdMarAdmin ADD ScanVerified BIT NULL;
GO

-- ── C3: age range of a ward; C7: who ordered a transfer ──────────────────────────────────────────────────────
IF COL_LENGTH('dbo.WardMaster', 'MinAgeDays') IS NULL ALTER TABLE dbo.WardMaster ADD MinAgeDays INT NULL;
IF COL_LENGTH('dbo.WardMaster', 'MaxAgeDays') IS NULL ALTER TABLE dbo.WardMaster ADD MaxAgeDays INT NULL;
IF COL_LENGTH('dbo.IpdBedMovement', 'OrderedByDoctorId') IS NULL ALTER TABLE dbo.IpdBedMovement ADD OrderedByDoctorId INT NULL;
GO

-- ── A9: room-rent eligibility of the approval; the deduction on the bill ─────────────────────────────────────
IF COL_LENGTH('dbo.IpdPreAuth', 'RoomRentLimit') IS NULL ALTER TABLE dbo.IpdPreAuth ADD RoomRentLimit DECIMAL(18,2) NULL;   -- per day, ward / room
IF COL_LENGTH('dbo.IpdPreAuth', 'IcuRentLimit') IS NULL ALTER TABLE dbo.IpdPreAuth ADD IcuRentLimit DECIMAL(18,2) NULL;     -- per day, ICU
IF COL_LENGTH('dbo.IpdBill', 'ProportionateDeduction') IS NULL ALTER TABLE dbo.IpdBill ADD ProportionateDeduction DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_PropDed DEFAULT (0);
GO

-- ── B6: NEWS2 escalation to the doctor ───────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdEscalation', 'U') IS NULL
    CREATE TABLE dbo.IpdEscalation
    (
        EscalationId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdEscalation PRIMARY KEY,
        AdmissionId   INT            NOT NULL,
        Source        VARCHAR(10)    NOT NULL CONSTRAINT CK_IpdEscalation_Source CHECK (Source IN ('NEWS2', 'ICU', 'MANUAL')),
        RefId         BIGINT         NULL,     -- IpdVital.VitalId / IpdIcuObservation id
        Score         INT            NULL,
        RiskLevel     VARCHAR(12)    NULL,
        Details       NVARCHAR(500)  NULL,
        DoctorId      INT            NULL,     -- the consultant called
        RaisedAt      DATETIME       NOT NULL,
        RaisedBy      INT            NOT NULL,
        Status        VARCHAR(8)     NOT NULL CONSTRAINT DF_IpdEscalation_Status DEFAULT ('OPEN') CONSTRAINT CK_IpdEscalation_Status CHECK (Status IN ('OPEN', 'ACK', 'CLOSED')),
        AckBy         INT            NULL,
        AckAt         DATETIME       NULL,
        Response      NVARCHAR(500)  NULL,
        ClosedBy      INT            NULL,
        ClosedAt      DATETIME       NULL,
        CloseNote     NVARCHAR(300)  NULL
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdEscalation_Open' AND object_id = OBJECT_ID('dbo.IpdEscalation'))
    CREATE INDEX IX_IpdEscalation_Open ON dbo.IpdEscalation (AdmissionId, Status);
GO

-- ── B7: medication reconciliation (admission / discharge) ────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdMedRecon', 'U') IS NULL
    CREATE TABLE dbo.IpdMedRecon
    (
        ReconId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdMedRecon PRIMARY KEY,
        AdmissionId   INT            NOT NULL,
        Stage         VARCHAR(10)    NOT NULL CONSTRAINT CK_IpdMedRecon_Stage CHECK (Stage IN ('ADMISSION', 'DISCHARGE')),
        NoHomeMeds    BIT            NOT NULL CONSTRAINT DF_IpdMedRecon_None DEFAULT (0),
        Lines         NVARCHAR(MAX)  NULL,     -- JSON [{drug, dose, frequency, action CONTINUE/STOP/CHANGE/HOLD, note}]
        Source        NVARCHAR(100)  NULL,     -- patient, attendant, old prescription
        Notes         NVARCHAR(500)  NULL,
        DoctorId      INT            NULL,
        DoneBy        INT            NOT NULL,
        DoneAt        DATETIME       NOT NULL,
        Status        VARCHAR(8)     NOT NULL CONSTRAINT DF_IpdMedRecon_Status DEFAULT ('ACTIVE') CONSTRAINT CK_IpdMedRecon_Status CHECK (Status IN ('ACTIVE', 'STRUCK')),
        StruckReason  NVARCHAR(300)  NULL,
        StruckBy      INT            NULL,
        StruckAt      DATETIME       NULL
    );
GO

-- ── B10: Padua VTE score next to Morse / Braden ──────────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_IpdRiskScore_Kind' AND definition NOT LIKE '%PADUA%')
BEGIN
    ALTER TABLE dbo.IpdRiskScore DROP CONSTRAINT CK_IpdRiskScore_Kind;
    ALTER TABLE dbo.IpdRiskScore ADD CONSTRAINT CK_IpdRiskScore_Kind CHECK (Kind IN ('MORSE', 'BRADEN', 'PADUA'));
END
GO

-- ── B11: blood transfusion ───────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdTransfusion', 'U') IS NULL
    CREATE TABLE dbo.IpdTransfusion
    (
        TransfusionId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdTransfusion PRIMARY KEY,
        AdmissionId       INT            NOT NULL,
        Component         VARCHAR(10)    NOT NULL CONSTRAINT CK_IpdTransfusion_Comp CHECK (Component IN ('WB', 'PRBC', 'FFP', 'PLT', 'SDP', 'CRYO')),
        Units             INT            NOT NULL CONSTRAINT DF_IpdTransfusion_Units DEFAULT (1),
        Indication        NVARCHAR(300)  NOT NULL,
        OrderedByDoctorId INT            NOT NULL,
        OrderedAt         DATETIME       NOT NULL,
        ConsentBy         NVARCHAR(150)  NULL,     -- transfusion consent signed by (patient / relative)
        ConsentRelation   NVARCHAR(50)   NULL,
        ConsentAt         DATETIME       NULL,
        PatientBloodGroup VARCHAR(5)     NULL,
        BagNo             NVARCHAR(40)   NULL,
        BagBloodGroup     VARCHAR(5)     NULL,
        BagExpiry         DATE           NULL,
        CrossmatchNo      NVARCHAR(40)   NULL,
        CheckedBy1        INT            NULL,     -- the nurse / doctor at the bedside (login)
        CheckedBy2Name    NVARCHAR(150)  NULL,     -- the second checker
        CheckedAt         DATETIME       NULL,
        StartAt           DATETIME       NULL,
        PreVitals         NVARCHAR(200)  NULL,
        Vitals15          NVARCHAR(200)  NULL,     -- 15 minutes after the start
        EndAt             DATETIME       NULL,
        PostVitals        NVARCHAR(200)  NULL,
        VolumeMl          INT            NULL,
        Reaction          BIT            NOT NULL CONSTRAINT DF_IpdTransfusion_Reaction DEFAULT (0),
        ReactionType      NVARCHAR(100)  NULL,
        ReactionAction    NVARCHAR(500)  NULL,
        Status            VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdTransfusion_Status DEFAULT ('ORDERED')
                          CONSTRAINT CK_IpdTransfusion_Status CHECK (Status IN ('ORDERED', 'CHECKED', 'STARTED', 'COMPLETED', 'STOPPED', 'CANCELLED')),
        CancelReason      NVARCHAR(300)  NULL,
        CreatedBy         INT            NOT NULL,
        CreatedDate       DATETIME       NOT NULL CONSTRAINT DF_IpdTransfusion_Created DEFAULT (GETDATE()),
        ModifiedBy        INT            NULL,
        ModifiedDate      DATETIME       NULL
    );
GO

-- ── B11: restraint (order, 2-hourly checks, release) ─────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdRestraint', 'U') IS NULL
    CREATE TABLE dbo.IpdRestraint
    (
        RestraintId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdRestraint PRIMARY KEY,
        AdmissionId       INT            NOT NULL,
        Kind              VARCHAR(10)    NOT NULL CONSTRAINT CK_IpdRestraint_Kind CHECK (Kind IN ('PHYSICAL', 'CHEMICAL')),
        Device            NVARCHAR(100)  NULL,     -- wrist / ankle / vest / mittens; or the drug for a chemical restraint
        Reason            NVARCHAR(300)  NOT NULL,
        AlternativesTried NVARCHAR(300)  NOT NULL,
        OrderedByDoctorId INT            NOT NULL,
        StartAt           DATETIME       NOT NULL,
        ReviewEveryHours  INT            NOT NULL CONSTRAINT DF_IpdRestraint_Review DEFAULT (2),
        OrderValidHours   INT            NOT NULL CONSTRAINT DF_IpdRestraint_Valid DEFAULT (24),
        FamilyInformed    NVARCHAR(150)  NULL,
        EndAt             DATETIME       NULL,
        EndReason         NVARCHAR(300)  NULL,
        Status            VARCHAR(8)     NOT NULL CONSTRAINT DF_IpdRestraint_Status DEFAULT ('ACTIVE') CONSTRAINT CK_IpdRestraint_Status CHECK (Status IN ('ACTIVE', 'ENDED')),
        CreatedBy         INT            NOT NULL,
        CreatedDate       DATETIME       NOT NULL CONSTRAINT DF_IpdRestraint_Created DEFAULT (GETDATE()),
        EndedBy           INT            NULL
    );
IF OBJECT_ID('dbo.IpdRestraintCheck', 'U') IS NULL
    CREATE TABLE dbo.IpdRestraintCheck
    (
        CheckId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdRestraintCheck PRIMARY KEY,
        RestraintId    INT            NOT NULL CONSTRAINT FK_IpdRestraintCheck_R REFERENCES dbo.IpdRestraint (RestraintId),
        CheckedAt      DATETIME       NOT NULL,
        CirculationOk  BIT            NOT NULL,
        SkinOk         BIT            NOT NULL,
        NeedsMet       BIT            NOT NULL,   -- fluids, toilet, position change
        StillNeeded    BIT            NOT NULL,
        Notes          NVARCHAR(300)  NULL,
        CheckedBy      INT            NOT NULL
    );
GO

-- ── C4: newborn of a mother's admission ──────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdNewborn', 'U') IS NULL
    CREATE TABLE dbo.IpdNewborn
    (
        NewbornId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdNewborn PRIMARY KEY,
        AdmissionId       INT            NOT NULL CONSTRAINT UX_IpdNewborn_Adm UNIQUE,   -- the baby's admission
        MotherAdmissionId INT            NOT NULL,
        BirthAt           DATETIME       NOT NULL,
        BirthWeightKg     DECIMAL(4,2)   NOT NULL,
        DeliveryType      VARCHAR(12)    NOT NULL CONSTRAINT CK_IpdNewborn_Delivery CHECK (DeliveryType IN ('NORMAL', 'ASSISTED', 'LSCS')),
        GestationWeeks    INT            NULL,
        Apgar1            TINYINT        NULL,
        Apgar5            TINYINT        NULL,
        BabyOrder         TINYINT        NOT NULL CONSTRAINT DF_IpdNewborn_Order DEFAULT (1),   -- twins: 1, 2
        Remarks           NVARCHAR(300)  NULL,
        CreatedBy         INT            NOT NULL,
        CreatedDate       DATETIME       NOT NULL CONSTRAINT DF_IpdNewborn_Created DEFAULT (GETDATE())
    );
GO

PRINT '2570 IPD flow-gap schema - done.';
GO
