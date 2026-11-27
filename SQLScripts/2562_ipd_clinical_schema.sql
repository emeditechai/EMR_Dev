-- ============================================================================================================
-- 2562  IPD Phase 3 - Clinical: doctor and nursing - tables and functions (application database)
--   Doctor : initial assessment (24 h timer), daily rounds / progress notes (signed round = doctor visit charge),
--            CPOE orders (medication, service / procedure, diet, nursing instruction; LAB stays on the LAB tab),
--            verbal / telephone orders countersigned within 24 h, cross-consultation requests.
--   Nursing: nursing assessment, care plan, eMAR (due / given / held / refused with reason), vitals with NEWS2,
--            intake / output, nursing notes, Morse fall risk, Braden pressure-ulcer risk, SBAR handover, incidents.
--   Every clinical entry is kept: a wrong one is struck out with a reason (never edited or deleted); signed
--   assessments are amended as a new version with a reason.
--   Settings (Hospital Settings, per branch): doctor / nursing assessment hours (24), countersign hours (24),
--   automatic visit charge on a signed round (on), eMAR late minutes (60).
--   Decisions taken with the plan's recommendations: D4 visit charge from each signed round (once per doctor per day),
--   D7 full CPOE + eMAR, D10 nurses may enter orders as verbal / telephone orders for the doctor to countersign.
--   Errors 59200-59599. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO

-- ── settings ──
IF COL_LENGTH('dbo.HospitalSettings', 'IpdDoctorAssessHours') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD
        IpdDoctorAssessHours  INT NOT NULL CONSTRAINT DF_HS_IpdDoctorAssessHours DEFAULT (24),
        IpdNursingAssessHours INT NOT NULL CONSTRAINT DF_HS_IpdNursingAssessHours DEFAULT (24),
        IpdCountersignHours   INT NOT NULL CONSTRAINT DF_HS_IpdCountersignHours DEFAULT (24),
        IpdAutoVisitCharge    BIT NOT NULL CONSTRAINT DF_HS_IpdAutoVisitCharge DEFAULT (1),
        IpdMarLateMinutes     INT NOT NULL CONSTRAINT DF_HS_IpdMarLateMinutes DEFAULT (60);
GO

-- ── medication frequencies (times of the day the doses fall due) ──
IF OBJECT_ID('dbo.IpdFrequency', 'U') IS NULL
    CREATE TABLE dbo.IpdFrequency
    (
        FrequencyCode VARCHAR(10)   NOT NULL CONSTRAINT PK_IpdFrequency PRIMARY KEY,
        FrequencyName NVARCHAR(60)  NOT NULL,
        Kind          VARCHAR(10)   NOT NULL,   -- SCHEDULED (times below), STAT (one dose now), PRN (when needed)
        TimesCsv      VARCHAR(100)  NULL,       -- HH:mm,HH:mm (SCHEDULED)
        SortOrder     INT           NOT NULL CONSTRAINT DF_IpdFrequency_Sort DEFAULT (0),
        IsActive      BIT           NOT NULL CONSTRAINT DF_IpdFrequency_Active DEFAULT (1),
        CONSTRAINT CK_IpdFrequency_Kind CHECK (Kind IN ('SCHEDULED', 'STAT', 'PRN'))
    );
GO
MERGE dbo.IpdFrequency AS t
USING (VALUES
    ('OD',   N'Once a day (OD)',              'SCHEDULED', '09:00', 10),
    ('BD',   N'Twice a day (BD)',             'SCHEDULED', '09:00,21:00', 20),
    ('TDS',  N'Three times a day (TDS)',      'SCHEDULED', '08:00,14:00,20:00', 30),
    ('QID',  N'Four times a day (QID)',       'SCHEDULED', '06:00,12:00,18:00,22:00', 40),
    ('Q4H',  N'Every 4 hours',                'SCHEDULED', '02:00,06:00,10:00,14:00,18:00,22:00', 50),
    ('Q6H',  N'Every 6 hours',                'SCHEDULED', '00:00,06:00,12:00,18:00', 60),
    ('Q8H',  N'Every 8 hours',                'SCHEDULED', '06:00,14:00,22:00', 70),
    ('Q12H', N'Every 12 hours',               'SCHEDULED', '08:00,20:00', 80),
    ('HS',   N'At bedtime (HS)',              'SCHEDULED', '21:00', 90),
    ('AC',   N'Before meals (AC)',            'SCHEDULED', '07:30,12:30,19:30', 100),
    ('PC',   N'After meals (PC)',             'SCHEDULED', '08:30,13:30,20:30', 110),
    ('STAT', N'Immediately, once (STAT)',     'STAT',      NULL, 120),
    ('SOS',  N'When needed (SOS / PRN)',      'PRN',       NULL, 130)
) s (FrequencyCode, FrequencyName, Kind, TimesCsv, SortOrder)
ON t.FrequencyCode = s.FrequencyCode
WHEN NOT MATCHED THEN INSERT (FrequencyCode, FrequencyName, Kind, TimesCsv, SortOrder) VALUES (s.FrequencyCode, s.FrequencyName, s.Kind, s.TimesCsv, s.SortOrder);
GO

-- ── doctor / nursing initial assessment (one current version per kind; amendments keep the old version) ──
IF OBJECT_ID('dbo.IpdAssessment', 'U') IS NULL
    CREATE TABLE dbo.IpdAssessment
    (
        AssessmentId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdAssessment PRIMARY KEY,
        AdmissionId   INT            NOT NULL,
        Kind          VARCHAR(10)    NOT NULL,          -- DOCTOR / NURSING
        Data          NVARCHAR(MAX)  NOT NULL,          -- the form (JSON)
        Status        VARCHAR(12)    NOT NULL CONSTRAINT DF_IpdAssessment_Status DEFAULT ('DRAFT'),   -- DRAFT / SIGNED / SUPERSEDED
        Version       INT            NOT NULL CONSTRAINT DF_IpdAssessment_Version DEFAULT (1),
        DoctorId      INT            NULL,              -- doctor assessment: the signing doctor
        SignedBy      INT            NULL,
        SignedAt      DATETIME       NULL,
        AmendReason   NVARCHAR(300)  NULL,
        CreatedBy     INT            NOT NULL,
        CreatedDate   DATETIME       NOT NULL CONSTRAINT DF_IpdAssessment_Created DEFAULT (GETDATE()),
        ModifiedBy    INT            NULL,
        ModifiedDate  DATETIME       NULL,
        CONSTRAINT CK_IpdAssessment_Kind CHECK (Kind IN ('DOCTOR', 'NURSING')),
        CONSTRAINT CK_IpdAssessment_Status CHECK (Status IN ('DRAFT', 'SIGNED', 'SUPERSEDED'))
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_IpdAssessment_Current')
    CREATE UNIQUE INDEX UX_IpdAssessment_Current ON dbo.IpdAssessment (AdmissionId, Kind) WHERE Status <> 'SUPERSEDED';
GO

-- ── rounds and progress notes (SOAP) ──
IF OBJECT_ID('dbo.IpdProgressNote', 'U') IS NULL
    CREATE TABLE dbo.IpdProgressNote
    (
        NoteId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdProgressNote PRIMARY KEY,
        AdmissionId     INT            NOT NULL,
        NoteType        VARCHAR(10)    NOT NULL,        -- ROUND (daily round) / PROGRESS / CROSS (cross-consultation reply)
        DoctorId        INT            NOT NULL,
        NoteAt          DATETIME       NOT NULL,
        Subjective      NVARCHAR(2000) NULL,
        Objective       NVARCHAR(2000) NULL,
        Assessment      NVARCHAR(2000) NULL,
        PlanText        NVARCHAR(2000) NULL,
        Status          VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdProgressNote_Status DEFAULT ('DRAFT'),   -- DRAFT / SIGNED / STRUCK
        SignedBy        INT            NULL,
        SignedAt        DATETIME       NULL,
        ChargeId        BIGINT         NULL,            -- the doctor visit charged when the round was signed
        ChargeNote      NVARCHAR(300)  NULL,            -- why no visit was charged
        CrossConsultId  INT            NULL,
        StruckBy        INT            NULL,
        StruckAt        DATETIME       NULL,
        StruckReason    NVARCHAR(300)  NULL,
        CreatedBy       INT            NOT NULL,
        CreatedDate     DATETIME       NOT NULL CONSTRAINT DF_IpdProgressNote_Created DEFAULT (GETDATE()),
        ModifiedBy      INT            NULL,
        ModifiedDate    DATETIME       NULL,
        CONSTRAINT CK_IpdProgressNote_Type CHECK (NoteType IN ('ROUND', 'PROGRESS', 'CROSS')),
        CONSTRAINT CK_IpdProgressNote_Status CHECK (Status IN ('DRAFT', 'SIGNED', 'STRUCK'))
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdProgressNote_Adm')
    CREATE INDEX IX_IpdProgressNote_Adm ON dbo.IpdProgressNote (AdmissionId, NoteAt DESC);
GO

-- ── doctor orders (CPOE) ──
IF OBJECT_ID('dbo.IpdOrder', 'U') IS NULL
    CREATE TABLE dbo.IpdOrder
    (
        OrderId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdOrder PRIMARY KEY,
        AdmissionId      INT            NOT NULL,
        OrderType        VARCHAR(10)    NOT NULL,        -- MED / SERVICE / DIET / NURSING
        Priority         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdOrder_Priority DEFAULT ('ROUTINE'),   -- ROUTINE / URGENT / STAT
        DoctorId         INT            NOT NULL,        -- the ordering doctor
        OrderedBy        INT            NOT NULL,        -- the user who entered it
        OrderedAt        DATETIME       NOT NULL,
        Source           VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdOrder_Source DEFAULT ('DIRECT'),     -- DIRECT / VERBAL / TELEPHONE
        ReadBack         BIT            NOT NULL CONSTRAINT DF_IpdOrder_ReadBack DEFAULT (0),
        CountersignDueAt DATETIME       NULL,
        CountersignedBy  INT            NULL,
        CountersignedAt  DATETIME       NULL,
        Status           VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdOrder_Status DEFAULT ('ACTIVE'),     -- ACTIVE / COMPLETED / STOPPED / CANCELLED
        AckBy            INT            NULL,            -- nurse acknowledgement
        AckAt            DATETIME       NULL,
        StoppedBy        INT            NULL,
        StoppedAt        DATETIME       NULL,
        StopReason       NVARCHAR(300)  NULL,
        -- medication
        ItemId           INT            NULL,            -- Pharmacy Item Master (or a free-text drug)
        DrugName         NVARCHAR(250)  NULL,
        Dose             NVARCHAR(60)   NULL,
        Route            VARCHAR(20)    NULL,
        FrequencyCode    VARCHAR(10)    NULL,
        StartAt          DATETIME       NULL,
        EndAt            DATETIME       NULL,
        IsHighAlert      BIT            NOT NULL CONSTRAINT DF_IpdOrder_HighAlert DEFAULT (0),
        IndentId         INT            NULL,            -- sent to the pharmacy as an indent
        -- service / procedure
        ServiceKind      VARCHAR(10)    NULL,            -- SERVICE / PROCEDURE
        RefId            INT            NULL,
        ServiceName      NVARCHAR(250)  NULL,
        Qty              DECIMAL(10,2)  NULL,
        DoneAt           DATETIME       NULL,
        DoneBy           INT            NULL,
        ChargeId         BIGINT         NULL,
        -- diet / nursing instruction / medication instructions
        DietType         NVARCHAR(60)   NULL,
        Details          NVARCHAR(1000) NULL,
        CONSTRAINT CK_IpdOrder_Type CHECK (OrderType IN ('MED', 'SERVICE', 'DIET', 'NURSING')),
        CONSTRAINT CK_IpdOrder_Status CHECK (Status IN ('ACTIVE', 'COMPLETED', 'STOPPED', 'CANCELLED')),
        CONSTRAINT CK_IpdOrder_Source CHECK (Source IN ('DIRECT', 'VERBAL', 'TELEPHONE')),
        CONSTRAINT CK_IpdOrder_Priority CHECK (Priority IN ('ROUTINE', 'URGENT', 'STAT'))
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdOrder_Adm')
    CREATE INDEX IX_IpdOrder_Adm ON dbo.IpdOrder (AdmissionId, Status, OrderType);
GO

-- ── medication administration record (one row per dose given / held / refused) ──
IF OBJECT_ID('dbo.IpdMarAdmin', 'U') IS NULL
    CREATE TABLE dbo.IpdMarAdmin
    (
        MarId          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdMarAdmin PRIMARY KEY,
        OrderId        INT            NOT NULL,
        AdmissionId    INT            NOT NULL,
        DueAt          DATETIME       NULL,             -- the scheduled dose; NULL = an SOS / PRN dose
        Outcome        VARCHAR(10)    NOT NULL,         -- GIVEN / HELD / REFUSED
        GivenAt        DATETIME       NOT NULL,         -- when it was given (or held / refused)
        DoseGiven      NVARCHAR(60)   NULL,
        Route          VARCHAR(20)    NULL,
        Site           NVARCHAR(60)   NULL,
        Reason         NVARCHAR(300)  NULL,             -- held / refused / late / SOS indication
        WitnessName    NVARCHAR(100)  NULL,             -- second check of a high-alert drug
        RecordedBy     INT            NOT NULL,
        RecordedAt     DATETIME       NOT NULL CONSTRAINT DF_IpdMarAdmin_Rec DEFAULT (GETDATE()),
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdMarAdmin_Status DEFAULT ('ACTIVE'),   -- ACTIVE / STRUCK
        StruckBy       INT            NULL,
        StruckAt       DATETIME       NULL,
        StruckReason   NVARCHAR(300)  NULL,
        CONSTRAINT CK_IpdMarAdmin_Outcome CHECK (Outcome IN ('GIVEN', 'HELD', 'REFUSED'))
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_IpdMarAdmin_Dose')
    CREATE UNIQUE INDEX UX_IpdMarAdmin_Dose ON dbo.IpdMarAdmin (OrderId, DueAt) WHERE Status = 'ACTIVE' AND DueAt IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdMarAdmin_Adm')
    CREATE INDEX IX_IpdMarAdmin_Adm ON dbo.IpdMarAdmin (AdmissionId, GivenAt);
GO

-- ── cross-consultation requests ──
IF OBJECT_ID('dbo.IpdCrossConsult', 'U') IS NULL
    CREATE TABLE dbo.IpdCrossConsult
    (
        ConsultId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdCrossConsult PRIMARY KEY,
        AdmissionId   INT            NOT NULL,
        FromDoctorId  INT            NOT NULL,
        ToDoctorId    INT            NOT NULL,
        Urgency       VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdCrossConsult_Urg DEFAULT ('ROUTINE'),   -- ROUTINE / URGENT
        Reason        NVARCHAR(1000) NOT NULL,
        RequestedBy   INT            NOT NULL,
        RequestedAt   DATETIME       NOT NULL CONSTRAINT DF_IpdCrossConsult_Req DEFAULT (GETDATE()),
        Status        VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdCrossConsult_Status DEFAULT ('REQUESTED'),   -- REQUESTED / SEEN / CANCELLED
        SeenAt        DATETIME       NULL,
        NoteId        INT            NULL,
        CancelledBy   INT            NULL,
        CancelReason  NVARCHAR(300)  NULL,
        CONSTRAINT CK_IpdCrossConsult_Status CHECK (Status IN ('REQUESTED', 'SEEN', 'CANCELLED'))
    );
GO

-- ── nursing charting ──
IF OBJECT_ID('dbo.IpdVital', 'U') IS NULL
    CREATE TABLE dbo.IpdVital
    (
        VitalId        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdVital PRIMARY KEY,
        AdmissionId    INT            NOT NULL,
        ObservedAt     DATETIME       NOT NULL,
        Rr             SMALLINT       NULL,
        SpO2           DECIMAL(4,1)   NULL,
        OnOxygen       BIT            NULL,
        O2Device       NVARCHAR(40)   NULL,
        O2FlowLpm      DECIMAL(4,1)   NULL,
        Sbp            SMALLINT       NULL,
        Dbp            SMALLINT       NULL,
        Pulse          SMALLINT       NULL,
        Consciousness  CHAR(1)        NULL,             -- A / C / V / P / U (ACVPU)
        TempC          DECIMAL(4,1)   NULL,
        PainScore      TINYINT        NULL,
        Glucose        DECIMAL(6,1)   NULL,
        WeightKg       DECIMAL(5,1)   NULL,
        News2          TINYINT        NULL,             -- NULL = not all seven parameters recorded
        News2Risk      VARCHAR(12)    NULL,             -- LOW / LOW_MEDIUM / MEDIUM / HIGH
        Notes          NVARCHAR(500)  NULL,
        RecordedBy     INT            NOT NULL,
        RecordedAt     DATETIME       NOT NULL CONSTRAINT DF_IpdVital_Rec DEFAULT (GETDATE()),
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdVital_Status DEFAULT ('ACTIVE'),
        StruckBy       INT            NULL,
        StruckAt       DATETIME       NULL,
        StruckReason   NVARCHAR(300)  NULL
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdVital_Adm')
    CREATE INDEX IX_IpdVital_Adm ON dbo.IpdVital (AdmissionId, ObservedAt DESC);
GO
IF OBJECT_ID('dbo.IpdIntakeOutput', 'U') IS NULL
    CREATE TABLE dbo.IpdIntakeOutput
    (
        IoId           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdIntakeOutput PRIMARY KEY,
        AdmissionId    INT            NOT NULL,
        At             DATETIME       NOT NULL,
        Direction      CHAR(3)        NOT NULL,         -- IN / OUT
        Category       VARCHAR(12)    NOT NULL,         -- IN: ORAL, IV, RT_FEED, BLOOD, OTHER · OUT: URINE, DRAIN, VOMIT, STOOL, ASPIRATE, OTHER
        VolumeMl       INT            NOT NULL,
        Notes          NVARCHAR(300)  NULL,
        RecordedBy     INT            NOT NULL,
        RecordedAt     DATETIME       NOT NULL CONSTRAINT DF_IpdIo_Rec DEFAULT (GETDATE()),
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdIo_Status DEFAULT ('ACTIVE'),
        StruckBy       INT            NULL,
        StruckAt       DATETIME       NULL,
        StruckReason   NVARCHAR(300)  NULL,
        CONSTRAINT CK_IpdIo_Dir CHECK (Direction IN ('IN', 'OUT'))
    );
GO
IF OBJECT_ID('dbo.IpdNursingNote', 'U') IS NULL
    CREATE TABLE dbo.IpdNursingNote
    (
        NoteId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdNursingNote PRIMARY KEY,
        AdmissionId    INT            NOT NULL,
        NoteAt         DATETIME       NOT NULL,
        Shift          VARCHAR(10)    NULL,             -- MORNING / EVENING / NIGHT
        Note           NVARCHAR(2000) NOT NULL,
        RecordedBy     INT            NOT NULL,
        RecordedAt     DATETIME       NOT NULL CONSTRAINT DF_IpdNursingNote_Rec DEFAULT (GETDATE()),
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdNursingNote_Status DEFAULT ('ACTIVE'),
        StruckBy       INT            NULL,
        StruckAt       DATETIME       NULL,
        StruckReason   NVARCHAR(300)  NULL
    );
GO
IF OBJECT_ID('dbo.IpdRiskScore', 'U') IS NULL
    CREATE TABLE dbo.IpdRiskScore
    (
        RiskId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdRiskScore PRIMARY KEY,
        AdmissionId    INT            NOT NULL,
        Kind           VARCHAR(10)    NOT NULL,         -- MORSE (fall) / BRADEN (pressure ulcer)
        AssessedAt     DATETIME       NOT NULL,
        Answers        NVARCHAR(1000) NOT NULL,         -- item -> points (JSON)
        Score          TINYINT        NOT NULL,
        RiskLevel      VARCHAR(12)    NOT NULL,
        Interventions  NVARCHAR(500)  NULL,
        RecordedBy     INT            NOT NULL,
        RecordedAt     DATETIME       NOT NULL CONSTRAINT DF_IpdRiskScore_Rec DEFAULT (GETDATE()),
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdRiskScore_Status DEFAULT ('ACTIVE'),
        StruckBy       INT            NULL,
        StruckAt       DATETIME       NULL,
        StruckReason   NVARCHAR(300)  NULL,
        CONSTRAINT CK_IpdRiskScore_Kind CHECK (Kind IN ('MORSE', 'BRADEN'))
    );
GO
IF OBJECT_ID('dbo.IpdCarePlan', 'U') IS NULL
    CREATE TABLE dbo.IpdCarePlan
    (
        PlanId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdCarePlan PRIMARY KEY,
        AdmissionId    INT            NOT NULL,
        Problem        NVARCHAR(300)  NOT NULL,         -- nursing diagnosis / problem
        Goal           NVARCHAR(500)  NOT NULL,
        Interventions  NVARCHAR(1000) NOT NULL,
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdCarePlan_Status DEFAULT ('ACTIVE'),   -- ACTIVE / RESOLVED / STRUCK
        Evaluation     NVARCHAR(500)  NULL,
        CreatedBy      INT            NOT NULL,
        CreatedDate    DATETIME       NOT NULL CONSTRAINT DF_IpdCarePlan_Created DEFAULT (GETDATE()),
        ClosedBy       INT            NULL,
        ClosedAt       DATETIME       NULL
    );
GO
IF OBJECT_ID('dbo.IpdHandover', 'U') IS NULL
    CREATE TABLE dbo.IpdHandover
    (
        HandoverId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdHandover PRIMARY KEY,
        AdmissionId    INT            NOT NULL,
        HandoverAt     DATETIME       NOT NULL,
        Shift          VARCHAR(10)    NOT NULL,         -- the shift handing over: MORNING / EVENING / NIGHT
        Situation      NVARCHAR(1000) NOT NULL,
        Background     NVARCHAR(1000) NULL,
        AssessmentText NVARCHAR(1000) NULL,
        Recommendation NVARCHAR(1000) NULL,
        GivenBy        INT            NOT NULL,
        ReceivedBy     INT            NULL,             -- the nurse taking over acknowledges
        ReceivedAt     DATETIME       NULL,
        Status         VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdHandover_Status DEFAULT ('ACTIVE')
    );
GO
IF OBJECT_ID('dbo.IpdIncident', 'U') IS NULL
    CREATE TABLE dbo.IpdIncident
    (
        IncidentId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IpdIncident PRIMARY KEY,
        AdmissionId     INT            NOT NULL,
        IncidentType    VARCHAR(20)    NOT NULL,        -- FALL / MEDICATION / PRESSURE_INJURY / NEEDLE_STICK / IV_SITE / EQUIPMENT / BEHAVIOUR / OTHER
        Severity        VARCHAR(12)    NOT NULL,        -- NEAR_MISS / NO_HARM / MILD / MODERATE / SEVERE / DEATH
        OccurredAt      DATETIME       NOT NULL,
        Location        NVARCHAR(100)  NULL,
        Description     NVARCHAR(2000) NOT NULL,
        ImmediateAction NVARCHAR(1000) NULL,
        DoctorInformed  BIT            NOT NULL CONSTRAINT DF_IpdIncident_Doc DEFAULT (0),
        ReportedBy      INT            NOT NULL,
        ReportedAt      DATETIME       NOT NULL CONSTRAINT DF_IpdIncident_Rep DEFAULT (GETDATE()),
        Status          VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdIncident_Status DEFAULT ('OPEN'),   -- OPEN / CLOSED
        ClosedBy        INT            NULL,
        ClosedAt        DATETIME       NULL,
        Closure         NVARCHAR(1000) NULL
    );
GO

-- ── the doctor of a login (Doctor Master > Linked User) ──
CREATE OR ALTER FUNCTION dbo.fn_Ipd_UserDoctor (@CompanyId INT, @UserId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT TOP (1) DoctorId FROM dbo.DoctorMaster WHERE LinkedUserId = @UserId AND IsActive = 1 AND CompanyId = @CompanyId AND @UserId IS NOT NULL ORDER BY DoctorId);
END;
GO

-- ── NEWS2 (Royal College of Physicians 2017, SpO2 scale 1): score only when all seven parameters are there ──
CREATE OR ALTER FUNCTION dbo.fn_Ipd_News2 (@Rr SMALLINT, @SpO2 DECIMAL(4,1), @OnO2 BIT, @Sbp SMALLINT, @Pulse SMALLINT, @Cons CHAR(1), @TempC DECIMAL(4,1))
RETURNS TABLE
AS
RETURN
    SELECT Score = CASE WHEN p.Complete = 1 THEN p.Total END,
           Risk  = CASE WHEN p.Complete = 0 THEN NULL
                        WHEN p.Total >= 7 THEN 'HIGH'
                        WHEN p.Total >= 5 THEN 'MEDIUM'
                        WHEN p.Any3 = 1 THEN 'LOW_MEDIUM'
                        ELSE 'LOW' END,
           p.Any3
    FROM (SELECT
            Complete = CASE WHEN @Rr IS NULL OR @SpO2 IS NULL OR @OnO2 IS NULL OR @Sbp IS NULL OR @Pulse IS NULL OR @Cons IS NULL OR @TempC IS NULL THEN 0 ELSE 1 END,
            Total = s.Rr + s.Sp + s.O2 + s.Bp + s.Hr + s.Cn + s.Tp,
            Any3 = CASE WHEN 3 IN (s.Rr, s.Sp, s.Bp, s.Hr, s.Cn, s.Tp) THEN 1 ELSE 0 END
          FROM (SELECT
                Rr = CASE WHEN @Rr IS NULL THEN 0 WHEN @Rr <= 8 THEN 3 WHEN @Rr <= 11 THEN 1 WHEN @Rr <= 20 THEN 0 WHEN @Rr <= 24 THEN 2 ELSE 3 END,
                Sp = CASE WHEN @SpO2 IS NULL THEN 0 WHEN @SpO2 <= 91 THEN 3 WHEN @SpO2 <= 93 THEN 2 WHEN @SpO2 <= 95 THEN 1 ELSE 0 END,
                O2 = CASE WHEN @OnO2 = 1 THEN 2 ELSE 0 END,
                Bp = CASE WHEN @Sbp IS NULL THEN 0 WHEN @Sbp <= 90 THEN 3 WHEN @Sbp <= 100 THEN 2 WHEN @Sbp <= 110 THEN 1 WHEN @Sbp <= 219 THEN 0 ELSE 3 END,
                Hr = CASE WHEN @Pulse IS NULL THEN 0 WHEN @Pulse <= 40 THEN 3 WHEN @Pulse <= 50 THEN 1 WHEN @Pulse <= 90 THEN 0 WHEN @Pulse <= 110 THEN 1 WHEN @Pulse <= 130 THEN 2 ELSE 3 END,
                Cn = CASE WHEN @Cons IS NULL OR @Cons = 'A' THEN 0 ELSE 3 END,
                Tp = CASE WHEN @TempC IS NULL THEN 0 WHEN @TempC <= 35.0 THEN 3 WHEN @TempC <= 36.0 THEN 1 WHEN @TempC <= 38.0 THEN 0 WHEN @TempC <= 39.0 THEN 1 ELSE 2 END
          ) s) p;
GO

-- ── scheduled doses of the medication orders of an admission in a window (eMAR) ──
--   SCHEDULED: each frequency time of each day, from the start to the end / stop of the order; STAT: one dose at the start.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_MarDue (@AdmissionId INT, @FromAt DATETIME, @ToAt DATETIME)
RETURNS TABLE
AS
RETURN
    WITH d AS (SELECT TOP (DATEDIFF(DAY, @FromAt, @ToAt) + 1) DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, CAST(CAST(@FromAt AS DATE) AS DATETIME)) AS Day0
               FROM (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) a(x) CROSS JOIN (VALUES (0),(0),(0),(0),(0),(0),(0),(0)) b(x))
    SELECT o.OrderId, DueAt = d.Day0 + CAST(CAST(t.value AS TIME) AS DATETIME)
    FROM dbo.IpdOrder o
    JOIN dbo.IpdFrequency f ON f.FrequencyCode = o.FrequencyCode AND f.Kind = 'SCHEDULED'
    CROSS JOIN d
    CROSS APPLY STRING_SPLIT(f.TimesCsv, ',') t
    WHERE o.AdmissionId = @AdmissionId AND o.OrderType = 'MED' AND o.Status IN ('ACTIVE', 'STOPPED', 'COMPLETED')
      AND d.Day0 + CAST(CAST(t.value AS TIME) AS DATETIME) >= o.StartAt
      AND d.Day0 + CAST(CAST(t.value AS TIME) AS DATETIME) <  COALESCE(o.StoppedAt, o.EndAt, '9999-12-31')
      AND d.Day0 + CAST(CAST(t.value AS TIME) AS DATETIME) BETWEEN @FromAt AND @ToAt
    UNION ALL
    SELECT o.OrderId, o.StartAt
    FROM dbo.IpdOrder o
    JOIN dbo.IpdFrequency f ON f.FrequencyCode = o.FrequencyCode AND f.Kind = 'STAT'
    WHERE o.AdmissionId = @AdmissionId AND o.OrderType = 'MED' AND o.Status IN ('ACTIVE', 'STOPPED', 'COMPLETED')
      AND o.StartAt BETWEEN @FromAt AND @ToAt AND (o.StoppedAt IS NULL OR o.StoppedAt > o.StartAt);
GO

PRINT 'Script 2562 applied: IPD Phase 3 clinical tables and functions.';
GO
