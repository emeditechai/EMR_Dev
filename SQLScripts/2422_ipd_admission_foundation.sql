-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2422  IPD Phase 1 · Foundation and Admission (part 1 of 3: settings, tables, ledger, numbering, live bill)
--
--   Hospital Settings > IPD      new Ipd* columns on HospitalSettings (per branch)
--   Tables (prefix Ipd)          IpdAdmission, IpdBedMovement, IpdAdmissionPayer, IpdAttendant, IpdMlc,
--                                IpdAdmissionConsent, IpdAdvance, IpdDocument, IpdStatusLog, IpdCharge,
--                                IpdNumberCounter, IpdEstimate, IpdEstimateLine
--   Ledger                       'IPD Patient Advance' (Current Liabilities): advances Cr, refunds Dr
--   Live bill                    fn_Ipd_BedRate, fn_Ipd_BedDays, fn_Ipd_BillLines, fn_Ipd_Money
--                                (the estimate and, from Phase 5, the final bill read the same functions)
--
-- Nothing existing changes behaviour: PaymentHeader already accepts ModuleCode 'IPD'; existing day closings,
-- receipts and reports filter their own modules. Safe to re-run.
-- Run order: 2422 -> 2423 (procedures) -> 2424 (menu, pages, controls).
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. Hospital Settings > IPD (per branch) ───────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.HospitalSettings', 'IpdNumberPrefix') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD
        IpdNumberPrefix            NVARCHAR(10)  NOT NULL CONSTRAINT DF_HS_IpdNoPrefix      DEFAULT (N'IP'),
        IpdNumberResetYearly       BIT           NOT NULL CONSTRAINT DF_HS_IpdNoReset       DEFAULT (1),
        IpdBedChargeMode           VARCHAR(10)   NOT NULL CONSTRAINT DF_HS_IpdBedMode       DEFAULT ('CALENDAR'),
        IpdDischargeGraceHour      INT           NOT NULL CONSTRAINT DF_HS_IpdGraceHour     DEFAULT (12),
        IpdHourlyGraceHours        INT           NOT NULL CONSTRAINT DF_HS_IpdGraceHours    DEFAULT (2),
        IpdDefaultTariffCategoryId INT           NULL,
        IpdRoomGstThreshold        DECIMAL(18,2) NOT NULL CONSTRAINT DF_HS_IpdRoomGst       DEFAULT (5000),
        IpdMinAdvanceDays          INT           NOT NULL CONSTRAINT DF_HS_IpdMinAdvDays    DEFAULT (0),
        IpdDepositAlertPercent     INT           NOT NULL CONSTRAINT DF_HS_IpdDepositPct    DEFAULT (80),
        IpdEstimateValidityDays    INT           NOT NULL CONSTRAINT DF_HS_IpdEstValidity   DEFAULT (7),
        IpdDefaultDischargeHour    INT           NOT NULL CONSTRAINT DF_HS_IpdDischHour     DEFAULT (11),
        IpdBlockWardGenderMismatch BIT           NOT NULL CONSTRAINT DF_HS_IpdWardGender    DEFAULT (1),
        IpdConsentRequired         BIT           NOT NULL CONSTRAINT DF_HS_IpdConsentReq    DEFAULT (0);
GO

-- ── 2. Tables ───────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdAdmission', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdAdmission
    (
        AdmissionId          INT IDENTITY(1,1) CONSTRAINT PK_IpdAdmission PRIMARY KEY,
        CompanyId            INT            NOT NULL,
        BranchId             INT            NOT NULL,
        IpNo                 NVARCHAR(40)   NOT NULL,
        PatientId            INT            NOT NULL CONSTRAINT FK_IpdAdmission_Patient REFERENCES dbo.PatientMaster (PatientId),
        AdmissionAt          DATETIME       NOT NULL,
        AdmissionType        VARCHAR(20)    NOT NULL,   -- ELECTIVE EMERGENCY DAYCARE MATERNITY TRANSFERIN
        AdmissionSource      VARCHAR(20)    NOT NULL,   -- DIRECT OPD EMERGENCY REFERRAL
        OpdServiceId         INT            NULL,
        ReferralDoctorId     INT            NULL,
        AdmittingDoctorId    INT            NOT NULL,
        ConsultantDoctorId   INT            NOT NULL,
        DepartmentId         INT            NULL,
        ProvisionalDiagnosis NVARCHAR(500)  NULL,
        DiagnosisCode        NVARCHAR(20)   NULL,       -- ICD-10
        ReasonForAdmission   NVARCHAR(500)  NULL,
        ExpectedDischargeAt  DATETIME       NULL,
        CurrentBedId         INT            NULL,
        TariffCategoryId     INT            NOT NULL,
        PayerType            VARCHAR(12)    NOT NULL,   -- CASH CORPORATE INSURANCE SCHEME
        PackageId            INT            NULL,
        IsMlc                BIT            NOT NULL CONSTRAINT DF_IpdAdmission_IsMlc DEFAULT (0),
        EstimateId           INT            NULL,
        Status               VARCHAR(20)    NOT NULL CONSTRAINT DF_IpdAdmission_Status DEFAULT ('ADMITTED'),
        IsOpen               BIT            NOT NULL CONSTRAINT DF_IpdAdmission_IsOpen DEFAULT (1),
        AdvanceWaived        BIT            NOT NULL CONSTRAINT DF_IpdAdmission_AdvWaived DEFAULT (0),
        AdvanceWaiveReason   NVARCHAR(300)  NULL,
        DischargeAt          DATETIME       NULL,
        CancelReason         NVARCHAR(300)  NULL,
        CancelledBy          INT            NULL,
        CancelledAt          DATETIME       NULL,
        Remarks              NVARCHAR(1000) NULL,
        RequestKey           UNIQUEIDENTIFIER NULL,
        CreatedBy            INT            NULL,
        CreatedDate          DATETIME       NOT NULL CONSTRAINT DF_IpdAdmission_Created DEFAULT (GETDATE()),
        ModifiedBy           INT            NULL,
        ModifiedDate         DATETIME       NULL,
        CONSTRAINT CK_IpdAdmission_Status CHECK (Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL', 'DISCHARGED', 'CANCELLED')),
        CONSTRAINT CK_IpdAdmission_Payer CHECK (PayerType IN ('CASH', 'CORPORATE', 'INSURANCE', 'SCHEME')),
        CONSTRAINT CK_IpdAdmission_Type CHECK (AdmissionType IN ('ELECTIVE', 'EMERGENCY', 'DAYCARE', 'MATERNITY', 'TRANSFERIN')),
        CONSTRAINT CK_IpdAdmission_Source CHECK (AdmissionSource IN ('DIRECT', 'OPD', 'EMERGENCY', 'REFERRAL'))
    );
    CREATE UNIQUE INDEX UX_IpdAdmission_IpNo ON dbo.IpdAdmission (CompanyId, IpNo);
    -- one open admission per patient
    CREATE UNIQUE INDEX UX_IpdAdmission_OpenPatient ON dbo.IpdAdmission (PatientId) WHERE IsOpen = 1;
    -- one admission per booking form (a retried save returns the admission it created)
    CREATE UNIQUE INDEX UX_IpdAdmission_RequestKey ON dbo.IpdAdmission (RequestKey) WHERE RequestKey IS NOT NULL;
    CREATE INDEX IX_IpdAdmission_Branch ON dbo.IpdAdmission (BranchId, Status, AdmissionAt);
END
GO

IF OBJECT_ID('dbo.IpdBedMovement', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdBedMovement
    (
        MovementId     INT IDENTITY(1,1) CONSTRAINT PK_IpdBedMovement PRIMARY KEY,
        AdmissionId    INT           NOT NULL CONSTRAINT FK_IpdBedMovement_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        BedId          INT           NOT NULL CONSTRAINT FK_IpdBedMovement_Bed REFERENCES dbo.BedMaster (BedId),
        WardId         INT           NOT NULL,
        RoomId         INT           NOT NULL,
        BedCategoryId  INT           NOT NULL,
        FromAt         DATETIME      NOT NULL,
        ToAt           DATETIME      NULL,
        MoveType       VARCHAR(12)   NOT NULL,   -- ADMIT TRANSFER SWAP
        EndType        VARCHAR(12)   NULL,       -- TRANSFER SWAP DISCHARGE CANCEL
        Reason         NVARCHAR(300) NULL,
        CreatedBy      INT           NULL,
        CreatedDate    DATETIME      NOT NULL CONSTRAINT DF_IpdBedMovement_Created DEFAULT (GETDATE())
    );
    -- one patient per bed, one bed per admission at a time
    CREATE UNIQUE INDEX UX_IpdBedMovement_OpenBed ON dbo.IpdBedMovement (BedId) WHERE ToAt IS NULL;
    CREATE UNIQUE INDEX UX_IpdBedMovement_OpenAdm ON dbo.IpdBedMovement (AdmissionId) WHERE ToAt IS NULL;
    CREATE INDEX IX_IpdBedMovement_Adm ON dbo.IpdBedMovement (AdmissionId, FromAt);
END
GO

IF OBJECT_ID('dbo.IpdAdmissionPayer', 'U') IS NULL
    CREATE TABLE dbo.IpdAdmissionPayer
    (
        PayerId          INT IDENTITY(1,1) CONSTRAINT PK_IpdAdmissionPayer PRIMARY KEY,
        AdmissionId      INT           NOT NULL CONSTRAINT FK_IpdAdmissionPayer_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        Seq              TINYINT       NOT NULL,     -- 1 primary, 2 secondary
        PayerType        VARCHAR(12)   NOT NULL,
        InsuranceTpaId   INT           NULL,
        CorporateId      INT           NULL,
        SchemeId         INT           NULL,
        PolicyNo         NVARCHAR(60)  NULL,
        MemberId         NVARCHAR(60)  NULL,
        CardHolderName   NVARCHAR(150) NULL,
        RelationToHolder NVARCHAR(50)  NULL,
        PolicyValidTo    DATE          NULL,
        EmployeeId       NVARCHAR(60)  NULL,
        CardFilePath     NVARCHAR(400) NULL,
        Remarks          NVARCHAR(300) NULL
    );
GO

IF OBJECT_ID('dbo.IpdAttendant', 'U') IS NULL
    CREATE TABLE dbo.IpdAttendant
    (
        AttendantId   INT IDENTITY(1,1) CONSTRAINT PK_IpdAttendant PRIMARY KEY,
        AdmissionId   INT           NOT NULL CONSTRAINT FK_IpdAttendant_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        Name          NVARCHAR(150) NOT NULL,
        Relation      NVARCHAR(50)  NULL,
        Phone         NVARCHAR(20)  NULL,
        Address       NVARCHAR(400) NULL,
        IdTypeId      INT           NULL,
        IdNumber      NVARCHAR(60)  NULL,
        IsPrimary     BIT           NOT NULL CONSTRAINT DF_IpdAttendant_Primary DEFAULT (0),
        PassNo        NVARCHAR(30)  NULL
    );
GO

IF OBJECT_ID('dbo.IpdMlc', 'U') IS NULL
    CREATE TABLE dbo.IpdMlc
    (
        AdmissionId    INT           NOT NULL CONSTRAINT PK_IpdMlc PRIMARY KEY CONSTRAINT FK_IpdMlc_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        MlcNo          NVARCHAR(40)  NULL,
        Nature         NVARCHAR(40)  NULL,   -- Road accident, Assault, Burns, Poisoning, Fall, Other
        IncidentAt     DATETIME      NULL,
        IncidentPlace  NVARCHAR(200) NULL,
        BroughtBy      NVARCHAR(150) NULL,
        BroughtByPhone NVARCHAR(20)  NULL,
        PoliceStation  NVARCHAR(150) NULL,
        OfficerName    NVARCHAR(150) NULL,
        InformedAt     DATETIME      NULL,
        Remarks        NVARCHAR(500) NULL,
        ModifiedBy     INT           NULL,
        ModifiedDate   DATETIME      NULL
    );
GO

IF OBJECT_ID('dbo.IpdAdmissionConsent', 'U') IS NULL
    CREATE TABLE dbo.IpdAdmissionConsent
    (
        AdmissionConsentId   INT IDENTITY(1,1) CONSTRAINT PK_IpdAdmissionConsent PRIMARY KEY,
        AdmissionId          INT            NOT NULL CONSTRAINT FK_IpdAdmissionConsent_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        ConsentId            INT            NULL,
        ConsentType          NVARCHAR(100)  NOT NULL,
        Language             NVARCHAR(50)   NULL,
        Version              NVARCHAR(20)   NULL,
        ContentHtml          NVARCHAR(MAX)  NULL,   -- the master text with the patient's details filled in, as signed
        SignedByName         NVARCHAR(150)  NULL,
        SignedByRelation     NVARCHAR(50)   NULL,
        WitnessName          NVARCHAR(150)  NULL,
        SignaturePath        NVARCHAR(400)  NULL,
        WitnessSignaturePath NVARCHAR(400)  NULL,
        SignedAt             DATETIME       NOT NULL CONSTRAINT DF_IpdAdmissionConsent_Signed DEFAULT (GETDATE()),
        CreatedBy            INT            NULL,
        CreatedDate          DATETIME       NOT NULL CONSTRAINT DF_IpdAdmissionConsent_Created DEFAULT (GETDATE())
    );
GO

IF OBJECT_ID('dbo.IpdAdvance', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdAdvance
    (
        AdvanceId        INT IDENTITY(1,1) CONSTRAINT PK_IpdAdvance PRIMARY KEY,
        AdmissionId      INT           NOT NULL CONSTRAINT FK_IpdAdvance_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        Kind             VARCHAR(10)   NOT NULL,   -- ADVANCE REFUND
        Amount           DECIMAL(18,2) NOT NULL,
        DocNo            NVARCHAR(50)  NOT NULL,   -- money receipt no. / refund voucher no.
        PaymentHeaderId  INT           NULL,       -- ADVANCE: the PaymentHeader (module IPD) holding the receipt
        Mode             NVARCHAR(30)  NULL,       -- REFUND: how it was paid back
        RefNo            NVARCHAR(100) NULL,
        Remarks          NVARCHAR(300) NULL,
        IsActive         BIT           NOT NULL CONSTRAINT DF_IpdAdvance_Active DEFAULT (1),
        CreatedBy        INT           NULL,
        CreatedDate      DATETIME      NOT NULL CONSTRAINT DF_IpdAdvance_Created DEFAULT (GETDATE()),
        CONSTRAINT CK_IpdAdvance_Kind CHECK (Kind IN ('ADVANCE', 'REFUND')),
        CONSTRAINT CK_IpdAdvance_Amount CHECK (Amount > 0)
    );
    CREATE INDEX IX_IpdAdvance_Adm ON dbo.IpdAdvance (AdmissionId, IsActive);
END
GO

IF OBJECT_ID('dbo.IpdDocument', 'U') IS NULL
    CREATE TABLE dbo.IpdDocument
    (
        DocumentId   INT IDENTITY(1,1) CONSTRAINT PK_IpdDocument PRIMARY KEY,
        AdmissionId  INT           NOT NULL CONSTRAINT FK_IpdDocument_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        DocType      NVARCHAR(40)  NOT NULL,   -- ID proof, Policy card, Referral letter, Old reports, Other
        Title        NVARCHAR(150) NULL,
        FilePath     NVARCHAR(400) NOT NULL,
        Remarks      NVARCHAR(300) NULL,
        IsActive     BIT           NOT NULL CONSTRAINT DF_IpdDocument_Active DEFAULT (1),
        CreatedBy    INT           NULL,
        CreatedDate  DATETIME      NOT NULL CONSTRAINT DF_IpdDocument_Created DEFAULT (GETDATE())
    );
GO

IF OBJECT_ID('dbo.IpdStatusLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdStatusLog
    (
        LogId        BIGINT IDENTITY(1,1) CONSTRAINT PK_IpdStatusLog PRIMARY KEY,
        AdmissionId  INT            NOT NULL,
        Action       VARCHAR(30)    NOT NULL,   -- ADMIT EDIT ADVANCE REFUND CONSENT DOCUMENT CANCEL
        FromStatus   VARCHAR(20)    NULL,
        ToStatus     VARCHAR(20)    NULL,
        Remarks      NVARCHAR(1000) NULL,
        CreatedBy    INT            NULL,
        CreatedDate  DATETIME       NOT NULL CONSTRAINT DF_IpdStatusLog_Created DEFAULT (GETDATE())
    );
    CREATE INDEX IX_IpdStatusLog_Adm ON dbo.IpdStatusLog (AdmissionId, LogId);
END
GO

-- every billable item of a stay (LAB, pharmacy issue, procedures, services, OT, visits ...). Written by
-- usp_Ipd_PostCharge from Phase 4/5; the live bill already reads it, so new heads appear without changes here.
IF OBJECT_ID('dbo.IpdCharge', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdCharge
    (
        ChargeId           BIGINT IDENTITY(1,1) CONSTRAINT PK_IpdCharge PRIMARY KEY,
        AdmissionId        INT            NOT NULL CONSTRAINT FK_IpdCharge_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        ChargeAt           DATETIME       NOT NULL,
        Head               VARCHAR(20)    NOT NULL,   -- BED ICU DOCTOR LAB RADIOLOGY PHARMACY CONSUMABLE PROCEDURE OT SERVICE PACKAGE
        ItemCode           NVARCHAR(50)   NULL,
        ItemName           NVARCHAR(250)  NOT NULL,
        SourceModule       VARCHAR(10)    NULL,       -- LAB PHR IPD OT ...
        SourceId           INT            NULL,
        SourceNo           NVARCHAR(50)   NULL,
        DoctorId           INT            NULL,
        Qty                DECIMAL(18,3)  NOT NULL CONSTRAINT DF_IpdCharge_Qty DEFAULT (1),
        Rate               DECIMAL(18,2)  NOT NULL CONSTRAINT DF_IpdCharge_Rate DEFAULT (0),
        Gross              DECIMAL(18,2)  NOT NULL CONSTRAINT DF_IpdCharge_Gross DEFAULT (0),
        Discount           DECIMAL(18,2)  NOT NULL CONSTRAINT DF_IpdCharge_Disc DEFAULT (0),
        GstPercent         DECIMAL(5,2)   NOT NULL CONSTRAINT DF_IpdCharge_GstPct DEFAULT (0),
        GstAmount          DECIMAL(18,2)  NOT NULL CONSTRAINT DF_IpdCharge_Gst DEFAULT (0),
        Net                DECIMAL(18,2)  NOT NULL CONSTRAINT DF_IpdCharge_Net DEFAULT (0),
        IsPackageItem      BIT            NOT NULL CONSTRAINT DF_IpdCharge_Pkg DEFAULT (0),
        Status             VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdCharge_Status DEFAULT ('POSTED'),   -- POSTED CANCELLED
        ReversalOfChargeId BIGINT         NULL,
        Remarks            NVARCHAR(300)  NULL,
        CreatedBy          INT            NULL,
        CreatedDate        DATETIME       NOT NULL CONSTRAINT DF_IpdCharge_Created DEFAULT (GETDATE())
    );
    CREATE INDEX IX_IpdCharge_Adm ON dbo.IpdCharge (AdmissionId, Status, ChargeAt);
END
GO

IF OBJECT_ID('dbo.IpdNumberCounter', 'U') IS NULL
    CREATE TABLE dbo.IpdNumberCounter
    (
        BranchId  INT         NOT NULL,
        DocType   VARCHAR(10) NOT NULL,   -- IP (admission) EST (pre-admission estimate) REF (advance refund)
        FinYear   VARCHAR(4)  NOT NULL,   -- '2627' or '0000' when the number never resets
        LastNo    INT         NOT NULL,
        CONSTRAINT PK_IpdNumberCounter PRIMARY KEY (BranchId, DocType, FinYear)
    );
GO

IF OBJECT_ID('dbo.IpdEstimate', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdEstimate
    (
        EstimateId        INT IDENTITY(1,1) CONSTRAINT PK_IpdEstimate PRIMARY KEY,
        CompanyId         INT            NOT NULL,
        BranchId          INT            NOT NULL,
        EstimateNo        NVARCHAR(40)   NOT NULL,
        EstimateDate      DATETIME       NOT NULL CONSTRAINT DF_IpdEstimate_Date DEFAULT (GETDATE()),
        ValidTo           DATE           NULL,
        PatientId         INT            NULL,
        PatientName       NVARCHAR(200)  NOT NULL,
        Phone             NVARCHAR(20)   NULL,
        AgeText           NVARCHAR(30)   NULL,
        Gender            NVARCHAR(20)   NULL,
        PayerType         VARCHAR(12)    NOT NULL,
        TariffCategoryId  INT            NOT NULL,
        BedCategoryId     INT            NULL,
        WardDays          INT            NOT NULL CONSTRAINT DF_IpdEstimate_WardDays DEFAULT (0),
        IcuBedCategoryId  INT            NULL,
        IcuDays           INT            NOT NULL CONSTRAINT DF_IpdEstimate_IcuDays DEFAULT (0),
        PackageId         INT            NULL,
        DoctorId          INT            NULL,
        ProcedureNote     NVARCHAR(300)  NULL,
        Remarks           NVARCHAR(1000) NULL,
        TotalAmount       DECIMAL(18,2)  NOT NULL CONSTRAINT DF_IpdEstimate_Total DEFAULT (0),
        Status            VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdEstimate_Status DEFAULT ('ACTIVE'),   -- ACTIVE CONVERTED CANCELLED
        AdmissionId       INT            NULL,
        CreatedBy         INT            NULL,
        CreatedDate       DATETIME       NOT NULL CONSTRAINT DF_IpdEstimate_Created DEFAULT (GETDATE()),
        ModifiedBy        INT            NULL,
        ModifiedDate      DATETIME       NULL
    );
    CREATE UNIQUE INDEX UX_IpdEstimate_No ON dbo.IpdEstimate (CompanyId, EstimateNo);
    CREATE INDEX IX_IpdEstimate_Branch ON dbo.IpdEstimate (BranchId, EstimateDate);
END
GO

IF OBJECT_ID('dbo.IpdEstimateLine', 'U') IS NULL
    CREATE TABLE dbo.IpdEstimateLine
    (
        LineId      INT IDENTITY(1,1) CONSTRAINT PK_IpdEstimateLine PRIMARY KEY,
        EstimateId  INT            NOT NULL CONSTRAINT FK_IpdEstimateLine_Est REFERENCES dbo.IpdEstimate (EstimateId),
        Seq         INT            NOT NULL,
        Head        VARCHAR(20)    NOT NULL,
        ItemName    NVARCHAR(250)  NOT NULL,
        Qty         DECIMAL(18,3)  NOT NULL,
        Rate        DECIMAL(18,2)  NOT NULL,
        Amount      DECIMAL(18,2)  NOT NULL,
        Remarks     NVARCHAR(300)  NULL
    );
GO

-- ── 3. Ledger: patient advances are a liability until adjusted against the final bill ─────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Patient Advance')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT 'IPD Patient Advance', LedgerGroupId, 0, 'Cr', 1, GETDATE(), 'IPD_ADVANCE', 'PARTY', 1,
           'Advances / deposits received from admitted patients (IPD); adjusted against the final IPD bill or refunded.'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Liabilities';
GO

-- ── 4. Numbering: <prefix>/<branch code>/<FY>/<000001> ────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_NextNumber @BranchId INT, @DocType VARCHAR(10), @DocDate DATETIME, @DocNo NVARCHAR(40) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @prefix NVARCHAR(10), @reset BIT, @no INT, @fy VARCHAR(4);
    SELECT @prefix = NULLIF(LTRIM(RTRIM(IpdNumberPrefix)), N''), @reset = IpdNumberResetYearly FROM dbo.HospitalSettings WHERE BranchID = @BranchId;
    SET @prefix = CASE @DocType WHEN 'IP' THEN ISNULL(@prefix, N'IP') WHEN 'EST' THEN N'EST' WHEN 'REF' THEN N'IPR' ELSE @DocType END;
    SET @reset = ISNULL(@reset, 1);
    DECLARE @y INT = CASE WHEN MONTH(@DocDate) >= 4 THEN YEAR(@DocDate) ELSE YEAR(@DocDate) - 1 END;
    SET @fy = CASE WHEN @reset = 1 THEN RIGHT(CAST(@y AS VARCHAR(4)), 2) + RIGHT(CAST(@y + 1 AS VARCHAR(4)), 2) ELSE '0000' END;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdNumberCounter WITH (UPDLOCK, HOLDLOCK) WHERE BranchId = @BranchId AND DocType = @DocType AND FinYear = @fy)
        INSERT dbo.IpdNumberCounter (BranchId, DocType, FinYear, LastNo) VALUES (@BranchId, @DocType, @fy, 0);
    UPDATE dbo.IpdNumberCounter SET @no = LastNo = LastNo + 1 WHERE BranchId = @BranchId AND DocType = @DocType AND FinYear = @fy;
    DECLARE @bc NVARCHAR(20) = ISNULL((SELECT NULLIF(LTRIM(RTRIM(BranchCode)), N'') FROM dbo.Branchmaster WHERE BranchID = @BranchId), CAST(@BranchId AS NVARCHAR(10)));
    SET @DocNo = CONCAT(@prefix, N'/', @bc, N'/', CASE WHEN @reset = 1 THEN @fy + N'/' ELSE N'' END, RIGHT(REPLICATE('0', 6) + CAST(@no AS VARCHAR(12)), 6));
END;
GO

-- ── 5. Live bill ──────────────────────────────────────────────────────────────────────────────────────────────
-- Daily rate of a bed for a tariff category on a date (Master > IPD > Bed/Room Tariff). Most specific first:
-- the room, then the ward, then any ward of the bed category; the patient's tariff category before the branch's
-- default one (Hospital Settings > IPD). UsedFallback = 1 when the default category's rate was taken.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BedRate (@BranchId INT, @BedId INT, @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) t.BedRateId, t.TariffCategoryId,
           CAST(t.RoomCharge AS DECIMAL(18,2)) AS RoomCharge, CAST(t.BedCharge AS DECIMAL(18,2)) AS BedCharge,
           CAST(t.NursingCharge AS DECIMAL(18,2)) AS NursingCharge, CAST(t.AttendantCharge AS DECIMAL(18,2)) AS AttendantCharge,
           CAST(CASE WHEN b.IsIsolation = 1 OR r.IsIsolation = 1 THEN t.IsolationCharge ELSE 0 END AS DECIMAL(18,2)) AS IsolationCharge,
           CAST(t.GstPercentage AS DECIMAL(5,2)) AS GstPercentage,
           CAST(CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END AS BIT) AS UsedFallback
    FROM dbo.BedMaster b
    JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId
    JOIN dbo.BedRoomTariffMaster t ON t.BranchId = @BranchId AND t.IsActive = 1 AND t.BedCategoryId = b.BedCategoryId
         AND t.TariffCategoryId IN (@TariffCategoryId, ISNULL(s.IpdDefaultTariffCategoryId, @TariffCategoryId))
         AND t.EffectiveFrom <= @OnDate AND (t.EffectiveTo IS NULL OR t.EffectiveTo >= @OnDate)
    WHERE b.BedId = @BedId
    ORDER BY CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END,
             CASE WHEN t.RoomId = b.RoomId THEN 0 WHEN t.WardId = b.WardId THEN 1 ELSE 2 END,
             t.EffectiveFrom DESC, t.BedRateId DESC
);
GO

-- One row per chargeable bed day of a stay up to @AsOf (or the discharge, if earlier), with the bed held and its rate.
--   CALENDAR (default): every calendar day from the admission date; the discharge day is not charged when the
--                       patient leaves before the grace hour (Hospital Settings > IPD, default 12:00) - a stay
--                       within one day is always one day. The bed of a day = the bed held at the end of that day.
--   HOURLY24          : one day per started 24 hours from the admission time, after the grace hours (default 2).
--   CHECKINOUT        : hotel-style days between the branch's Check-Out times (Hospital Settings > Daily Check-In /
--                       Check-Out Time); admitted within the grace hours before check-out or discharged within them after it
--                       adds no day. Falls back to CALENDAR when the branch has no check-out time.
-- GST: the tariff's GST % on a non-ICU day whose total is above the room-rent threshold (default Rs 5,000/day);
-- 0 = always the tariff's GST %. ICU days carry no GST.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BedDays (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    WITH a AS
    (
        SELECT ad.AdmissionId, ad.BranchId, ad.TariffCategoryId, ad.AdmissionAt,
               CASE WHEN ad.DischargeAt IS NOT NULL AND ad.DischargeAt < @AsOf THEN ad.DischargeAt ELSE @AsOf END AS EndAt,
               CASE WHEN s.IpdBedChargeMode = 'CHECKINOUT' AND s.CheckOutTime IS NULL THEN 'CALENDAR' ELSE ISNULL(s.IpdBedChargeMode, 'CALENDAR') END AS Mode,
               DATEDIFF(MINUTE, CAST('00:00' AS TIME), ISNULL(s.CheckOutTime, CAST('12:00' AS TIME))) AS OutMin,
               ISNULL(s.IpdDischargeGraceHour, 12) AS GraceHour,
               ISNULL(s.IpdHourlyGraceHours, 2) AS GraceHours, ISNULL(s.IpdRoomGstThreshold, 5000) AS GstThreshold
        FROM dbo.IpdAdmission ad
        LEFT JOIN dbo.HospitalSettings s ON s.BranchID = ad.BranchId
        WHERE ad.AdmissionId = @AdmissionId AND ad.Status <> 'CANCELLED' AND ad.AdmissionAt <= @AsOf
    ),
    n AS
    (
        SELECT a.*,
               -- CHECKINOUT: the billing day of a moment = the date of the last check-out time before it; admitted within the
               -- grace hours before check-out / discharged within the grace hours after it does not add a day
               CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, a.GraceHours * 60, a.AdmissionAt)) AS DATE) AS CioStart,
               CAST(CASE WHEN a.Mode = 'CHECKINOUT'
                    THEN CASE WHEN DATEDIFF(DAY, CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, a.GraceHours * 60, a.AdmissionAt)) AS DATE),
                                                 CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, -a.GraceHours * 60, a.EndAt)) AS DATE)) + 1 < 1 THEN 1
                              ELSE DATEDIFF(DAY, CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, a.GraceHours * 60, a.AdmissionAt)) AS DATE),
                                                 CAST(DATEADD(MINUTE, -a.OutMin, DATEADD(MINUTE, -a.GraceHours * 60, a.EndAt)) AS DATE)) + 1 END
                    WHEN a.Mode = 'HOURLY24'
                    THEN CASE WHEN DATEDIFF(MINUTE, a.AdmissionAt, a.EndAt) - a.GraceHours * 60 <= 0 THEN 1
                              ELSE CEILING((DATEDIFF(MINUTE, a.AdmissionAt, a.EndAt) - a.GraceHours * 60) / 1440.0) END
                    ELSE DATEDIFF(DAY, a.AdmissionAt, a.EndAt) + 1
                         - CASE WHEN DATEDIFF(DAY, a.AdmissionAt, a.EndAt) >= 1
                                 AND DATEPART(HOUR, a.EndAt) * 60 + DATEPART(MINUTE, a.EndAt) < a.GraceHour * 60 THEN 1 ELSE 0 END
               END AS INT) AS Days
        FROM a
    ),
    d AS
    (
        SELECT n.AdmissionId, n.BranchId, n.TariffCategoryId, n.GstThreshold, k.k + 1 AS DayNo,
               CASE WHEN n.Mode = 'HOURLY24' THEN CAST(DATEADD(MINUTE, 1440 * k.k, n.AdmissionAt) AS DATE)
                    WHEN n.Mode = 'CHECKINOUT' THEN DATEADD(DAY, k.k, n.CioStart)
                    ELSE DATEADD(DAY, k.k, CAST(n.AdmissionAt AS DATE)) END AS DayDate,
               CASE WHEN n.Mode = 'CHECKINOUT'   -- the bed held at the end of that billing day (its next check-out), or at discharge / now
                    THEN CASE WHEN DATEADD(SECOND, -1, DATEADD(MINUTE, n.OutMin, CAST(DATEADD(DAY, k.k + 1, n.CioStart) AS DATETIME))) < n.EndAt
                              THEN CASE WHEN DATEADD(SECOND, -1, DATEADD(MINUTE, n.OutMin, CAST(DATEADD(DAY, k.k + 1, n.CioStart) AS DATETIME))) < n.AdmissionAt THEN n.AdmissionAt
                                        ELSE DATEADD(SECOND, -1, DATEADD(MINUTE, n.OutMin, CAST(DATEADD(DAY, k.k + 1, n.CioStart) AS DATETIME))) END
                              ELSE n.EndAt END
                    WHEN n.Mode = 'HOURLY24'
                    THEN CASE WHEN DATEADD(SECOND, -1, DATEADD(MINUTE, 1440 * (k.k + 1), n.AdmissionAt)) < n.EndAt
                              THEN DATEADD(SECOND, -1, DATEADD(MINUTE, 1440 * (k.k + 1), n.AdmissionAt)) ELSE n.EndAt END
                    ELSE CASE WHEN DATEADD(SECOND, -1, CAST(DATEADD(DAY, k.k + 1, CAST(n.AdmissionAt AS DATE)) AS DATETIME)) < n.EndAt
                              THEN DATEADD(SECOND, -1, CAST(DATEADD(DAY, k.k + 1, CAST(n.AdmissionAt AS DATE)) AS DATETIME)) ELSE n.EndAt END
               END AS PointAt
        FROM n
        CROSS APPLY (SELECT TOP (CASE WHEN n.Days < 1 THEN 1 ELSE n.Days END) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS k
                     FROM sys.all_columns c1 CROSS JOIN sys.all_columns c2) k
    )
    SELECT d.AdmissionId, d.DayNo, d.DayDate, m.BedId, b.BedNumber, w.WardName, r.RoomNumber, bc.CategoryName AS BedCategoryName,
           CAST(ISNULL(b.IsICU, 0) AS BIT) AS IsIcu,
           ISNULL(rt.RoomCharge, 0) AS RoomCharge, ISNULL(rt.BedCharge, 0) AS BedCharge, ISNULL(rt.NursingCharge, 0) AS NursingCharge,
           ISNULL(rt.AttendantCharge, 0) AS AttendantCharge, ISNULL(rt.IsolationCharge, 0) AS IsolationCharge,
           CAST(ISNULL(rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.AttendantCharge + rt.IsolationCharge, 0) AS DECIMAL(18,2)) AS DayTotal,
           CAST(CASE WHEN rt.BedRateId IS NULL OR ISNULL(b.IsICU, 0) = 1 THEN 0
                     WHEN d.GstThreshold > 0 AND rt.RoomCharge + rt.BedCharge + rt.NursingCharge + rt.AttendantCharge + rt.IsolationCharge <= d.GstThreshold THEN 0
                     ELSE rt.GstPercentage END AS DECIMAL(5,2)) AS GstPercent,
           CAST(CASE WHEN rt.BedRateId IS NULL THEN 1 ELSE 0 END AS BIT) AS NoTariff,
           CAST(ISNULL(rt.UsedFallback, 0) AS BIT) AS UsedFallback
    FROM d
    OUTER APPLY (SELECT TOP (1) mv.BedId FROM dbo.IpdBedMovement mv
                 WHERE mv.AdmissionId = d.AdmissionId AND mv.FromAt <= d.PointAt ORDER BY mv.FromAt DESC, mv.MovementId DESC) m
    LEFT JOIN dbo.BedMaster b ON b.BedId = m.BedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = b.WardId
    LEFT JOIN dbo.RoomMaster r ON r.RoomId = b.RoomId
    LEFT JOIN dbo.BedCategoryMaster bc ON bc.BedCategoryId = b.BedCategoryId
    OUTER APPLY dbo.fn_Ipd_BedRate(d.BranchId, m.BedId, d.TariffCategoryId, d.DayDate) rt
    WHERE m.BedId IS NOT NULL
);
GO

-- Every line of the bill as of @AsOf: bed days (accrued, one line per charge component) + posted charges.
-- Status ACCRUED = worked out live, not yet posted; POSTED = an IpdCharge row.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BillLines (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(CONCAT('B', bd.DayNo, '-', v.Code) AS NVARCHAR(40)) AS LineKey,
           CAST(CASE WHEN bd.IsIcu = 1 THEN 'ICU' ELSE 'BED' END AS VARCHAR(20)) AS Head,
           CAST(bd.DayDate AS DATETIME) AS ChargeAt, CAST(v.Code AS NVARCHAR(50)) AS ItemCode,
           CAST(CASE WHEN bd.NoTariff = 1 THEN N'No bed tariff for ' + ISNULL(bd.BedCategoryName, N'this bed') ELSE v.Name END AS NVARCHAR(250)) AS ItemName,
           CAST(CONCAT(N'Day ', bd.DayNo, N' · ', bd.WardName, N' / ', bd.RoomNumber, N' / ', bd.BedNumber) AS NVARCHAR(300)) AS Detail,
           CAST(NULL AS NVARCHAR(150)) AS DoctorName,
           CAST(1 AS DECIMAL(18,3)) AS Qty, v.Amount AS Rate, v.Amount AS Gross, CAST(0 AS DECIMAL(18,2)) AS Discount,
           bd.GstPercent, CAST(ROUND(v.Amount * bd.GstPercent / 100, 2) AS DECIMAL(18,2)) AS GstAmount,
           CAST(v.Amount + ROUND(v.Amount * bd.GstPercent / 100, 2) AS DECIMAL(18,2)) AS Net,
           CAST('ACCRUED' AS VARCHAR(10)) AS Status, CAST('IPD' AS VARCHAR(10)) AS SourceModule, CAST(NULL AS NVARCHAR(50)) AS SourceNo,
           CAST(0 AS BIT) AS IsPackageItem, bd.NoTariff, bd.UsedFallback, bd.DayNo, v.Sort
    FROM dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) bd
    CROSS APPLY (VALUES ('ROOM', N'Room Rent', bd.RoomCharge, 1), ('BED', N'Bed Charge', bd.BedCharge, 2),
                        ('NURSING', N'Nursing Charge', bd.NursingCharge, 3), ('ATTENDANT', N'Attendant Charge', bd.AttendantCharge, 4),
                        ('ISOLATION', N'Isolation Charge', bd.IsolationCharge, 5), ('NOTARIFF', N'', CAST(0 AS DECIMAL(18,2)), 6)) v (Code, Name, Amount, Sort)
    WHERE (bd.NoTariff = 0 AND v.Code <> 'NOTARIFF' AND v.Amount > 0) OR (bd.NoTariff = 1 AND v.Code = 'NOTARIFF')

    UNION ALL

    SELECT CAST(CONCAT('C', c.ChargeId) AS NVARCHAR(40)), c.Head, c.ChargeAt, c.ItemCode, c.ItemName,
           CAST(CASE WHEN c.SourceNo IS NOT NULL THEN CONCAT(c.SourceModule, N' ', c.SourceNo) END AS NVARCHAR(300)),
           CAST(doc.FullName AS NVARCHAR(150)),
           c.Qty, c.Rate, c.Gross, c.Discount, c.GstPercent, c.GstAmount, c.Net,
           CAST('POSTED' AS VARCHAR(10)), c.SourceModule, c.SourceNo, c.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM dbo.IpdCharge c
    LEFT JOIN dbo.DoctorMaster doc ON doc.DoctorId = c.DoctorId
    WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED' AND c.ChargeAt <= @AsOf
);
GO

-- Money received on an admission: advances, refunds and what is left.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_Money (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(SUM(CASE WHEN Kind = 'ADVANCE' THEN Amount END), 0) AS DECIMAL(18,2)) AS AdvanceTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'REFUND' THEN Amount END), 0) AS DECIMAL(18,2)) AS RefundTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'ADVANCE' THEN Amount ELSE -Amount END), 0) AS DECIMAL(18,2)) AS NetAdvance
    FROM dbo.IpdAdvance WHERE AdmissionId = @AdmissionId AND IsActive = 1
);
GO

-- Bill heads in their display order (summary rows are shown for every head, even before it has charges).
CREATE OR ALTER FUNCTION dbo.fn_Ipd_Heads ()
RETURNS TABLE
AS RETURN
(
    SELECT Head, HeadName, Sort FROM (VALUES
        ('BED', N'Bed & Nursing', 10), ('ICU', N'ICU', 20), ('DOCTOR', N'Doctor Visits', 30), ('LAB', N'Laboratory', 40),
        ('RADIOLOGY', N'Radiology / Imaging', 50), ('PHARMACY', N'Pharmacy', 60), ('CONSUMABLE', N'Consumables', 70),
        ('PROCEDURE', N'Procedures', 80), ('OT', N'Operation Theatre', 90), ('SERVICE', N'Other Services', 100), ('PACKAGE', N'Package', 110)
    ) h (Head, HeadName, Sort)
);
GO

PRINT '2422 IPD foundation: settings, tables, ledger, numbering, live bill - done.';
GO
