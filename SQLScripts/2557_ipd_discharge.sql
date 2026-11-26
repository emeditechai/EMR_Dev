-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2557: IPD Phase 7 - Discharge, end to end.
--   Flow   advice by the consultant (type, planned date / time) -> clearances (pharmacy, LAB, nursing, TPA) -> final bill
--          (Billing tab, unchanged) -> settlement -> discharge summary signed -> gate pass -> bed released to housekeeping
--          -> OPD follow-up. Every step is time-stamped, so the discharge TAT (advice to gate pass) is measured.
--   Types  NORMAL, LAMA, DAMA, ABSCONDED, TRANSFER (to another hospital), DEATH.
--   Tables IpdDischarge (one live row per admission: advice + gate pass), IpdDischargeClearance, IpdDischargeSummary
--          (NABH content, versioned, signed by the consultant), IpdLamaRecord (LAMA / DAMA form with signatures),
--          IpdDeathRecord (death summary data, MCCD Form 4 / 4A cause of death, death register no.), IpdFollowUp.
--   Gate pass refused until: final bill made; patient share settled and no refund pending (credit discharge only with
--          GATEPASS_CREDIT and a reason); clearances done; no OT in progress; signed summary for NORMAL / TRANSFER / DEATH;
--          LAMA / DAMA form for LAMA / DAMA; death record for DEATH. Then: admission DISCHARGED and closed, bed movement
--          ended with DISCHARGE and the bed released through usp_Ipd_ReleaseBed (housekeeping job or Available).
--   Settings HospitalSettings.IpdDischargeTatTargetMinutes (default 180 = 3 h, NABH discharge TAT indicator).
--   Errors 58400-58599. Nothing existing changes: the final bill, bill cancel and every other IPD procedure are untouched.
-- Needs 2422-2542. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- the doctor's signature (Doctor Master, SQLScripts/2559) is read by the discharge prints
IF COL_LENGTH('dbo.DoctorMaster', 'SignaturePath') IS NULL
    ALTER TABLE dbo.DoctorMaster ADD SignaturePath NVARCHAR(300) NULL;
GO

IF COL_LENGTH('dbo.HospitalSettings', 'IpdDischargeTatTargetMinutes') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD IpdDischargeTatTargetMinutes INT NOT NULL CONSTRAINT DF_HS_IpdDischTat DEFAULT (180);
GO

-- ── 1. tables ───────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdDischarge', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdDischarge
    (
        DischargeId        INT IDENTITY(1,1) CONSTRAINT PK_IpdDischarge PRIMARY KEY,
        CompanyId          INT            NOT NULL,
        BranchId           INT            NOT NULL,
        AdmissionId        INT            NOT NULL CONSTRAINT FK_IpdDischarge_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        DischargeType      VARCHAR(12)    NOT NULL,
        Status             VARCHAR(12)    NOT NULL CONSTRAINT DF_IpdDischarge_Status DEFAULT ('ADVISED'),
        AdvisedAt          DATETIME       NOT NULL,
        AdvisedByDoctorId  INT            NULL,
        PlannedAt          DATETIME       NULL,
        AdviceRemarks      NVARCHAR(500)  NULL,
        TransferTo         NVARCHAR(300)  NULL,       -- TRANSFER: hospital and reason
        ClearedAt          DATETIME       NULL,       -- the last clearance done
        GatePassNo         NVARCHAR(40)   NULL,
        GatePassAt         DATETIME       NULL,
        GatePassBy         INT            NULL,
        HandedOverTo       NVARCHAR(150)  NULL,
        HandedOverRelation NVARCHAR(50)   NULL,
        HandedOverPhone    NVARCHAR(20)   NULL,
        TransportMode      NVARCHAR(40)   NULL,
        GatePassRemarks    NVARCHAR(500)  NULL,
        IsCreditDischarge  BIT            NOT NULL CONSTRAINT DF_IpdDischarge_Credit DEFAULT (0),
        CreditReason       NVARCHAR(300)  NULL,
        CreditAmount       DECIMAL(18,2)  NULL,
        CancelReason       NVARCHAR(300)  NULL,
        CancelledBy        INT            NULL,
        CancelledAt        DATETIME       NULL,
        CreatedBy          INT            NULL,
        CreatedDate        DATETIME       NOT NULL CONSTRAINT DF_IpdDischarge_Created DEFAULT (GETDATE()),
        ModifiedBy         INT            NULL,
        ModifiedDate       DATETIME       NULL,
        CONSTRAINT CK_IpdDischarge_Type CHECK (DischargeType IN ('NORMAL', 'LAMA', 'DAMA', 'ABSCONDED', 'TRANSFER', 'DEATH')),
        CONSTRAINT CK_IpdDischarge_Status CHECK (Status IN ('ADVISED', 'DISCHARGED', 'CANCELLED'))
    );
    CREATE UNIQUE INDEX UX_IpdDischarge_Live ON dbo.IpdDischarge (AdmissionId) WHERE Status <> 'CANCELLED';
    CREATE INDEX IX_IpdDischarge_Branch ON dbo.IpdDischarge (BranchId, Status, GatePassAt);
END
GO

IF OBJECT_ID('dbo.IpdDischargeClearance', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdDischargeClearance
    (
        ClearanceId  INT IDENTITY(1,1) CONSTRAINT PK_IpdDischargeClearance PRIMARY KEY,
        DischargeId  INT            NOT NULL CONSTRAINT FK_IpdDischargeClearance_Dis REFERENCES dbo.IpdDischarge (DischargeId),
        AdmissionId  INT            NOT NULL,
        Dept         VARCHAR(10)    NOT NULL,
        Status       VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdDischargeClearance_Status DEFAULT ('PENDING'),
        Checklist    NVARCHAR(MAX)  NULL,       -- JSON [{code, answer, note}]
        Remarks      NVARCHAR(500)  NULL,
        ClearedBy    INT            NULL,
        ClearedAt    DATETIME       NULL,
        ModifiedDate DATETIME       NULL,
        CONSTRAINT CK_IpdDischargeClearance_Dept CHECK (Dept IN ('PHARMACY', 'LAB', 'NURSING', 'TPA')),
        CONSTRAINT CK_IpdDischargeClearance_Status CHECK (Status IN ('PENDING', 'CLEARED', 'NA'))
    );
    CREATE UNIQUE INDEX UX_IpdDischargeClearance ON dbo.IpdDischargeClearance (DischargeId, Dept);
END
GO

IF OBJECT_ID('dbo.IpdDischargeSummary', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdDischargeSummary
    (
        SummaryId            INT IDENTITY(1,1) CONSTRAINT PK_IpdDischargeSummary PRIMARY KEY,
        AdmissionId          INT            NOT NULL CONSTRAINT FK_IpdDischargeSummary_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        Version              INT            NOT NULL,
        Status               VARCHAR(12)    NOT NULL CONSTRAINT DF_IpdDischargeSummary_Status DEFAULT ('DRAFT'),
        SummaryType          VARCHAR(12)    NOT NULL CONSTRAINT DF_IpdDischargeSummary_Type DEFAULT ('NORMAL'),
        Diagnoses            NVARCHAR(MAX)  NULL,   -- JSON [{kind: PRIMARY|SECONDARY|COMORBID, code, title}]
        PresentingComplaints NVARCHAR(MAX)  NULL,
        HistoryOfIllness     NVARCHAR(MAX)  NULL,
        PastHistory          NVARCHAR(MAX)  NULL,
        Allergies            NVARCHAR(500)  NULL,
        Examination          NVARCHAR(MAX)  NULL,
        Investigations       NVARCHAR(MAX)  NULL,
        Procedures           NVARCHAR(MAX)  NULL,
        CourseInHospital     NVARCHAR(MAX)  NULL,
        ConditionAtDischarge VARCHAR(15)    NULL,   -- STABLE IMPROVED UNCHANGED DETERIORATED CRITICAL EXPIRED
        ConditionNotes       NVARCHAR(MAX)  NULL,
        Medicines            NVARCHAR(MAX)  NULL,   -- JSON [{drug, dose, route, frequency, duration, instructions}]
        Diet                 NVARCHAR(500)  NULL,
        Activity             NVARCHAR(500)  NULL,
        Advice               NVARCHAR(MAX)  NULL,
        WarningSigns         NVARCHAR(MAX)  NULL,   -- when to come back at once
        FollowUp             NVARCHAR(500)  NULL,
        EmergencyContact     NVARCHAR(300)  NULL,
        SignedByDoctorId     INT            NULL,
        SignedByUserId       INT            NULL,
        SignedAt             DATETIME       NULL,
        AmendReason          NVARCHAR(300)  NULL,
        CreatedBy            INT            NULL,
        CreatedDate          DATETIME       NOT NULL CONSTRAINT DF_IpdDischargeSummary_Created DEFAULT (GETDATE()),
        ModifiedBy           INT            NULL,
        ModifiedDate         DATETIME       NULL,
        CONSTRAINT CK_IpdDischargeSummary_Status CHECK (Status IN ('DRAFT', 'SIGNED', 'SUPERSEDED'))
    );
    CREATE UNIQUE INDEX UX_IpdDischargeSummary_Version ON dbo.IpdDischargeSummary (AdmissionId, Version);
    CREATE UNIQUE INDEX UX_IpdDischargeSummary_Draft ON dbo.IpdDischargeSummary (AdmissionId) WHERE Status = 'DRAFT';
    CREATE UNIQUE INDEX UX_IpdDischargeSummary_Signed ON dbo.IpdDischargeSummary (AdmissionId) WHERE Status = 'SIGNED';
END
GO

IF OBJECT_ID('dbo.IpdLamaRecord', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdLamaRecord
    (
        LamaId               INT IDENTITY(1,1) CONSTRAINT PK_IpdLamaRecord PRIMARY KEY,
        AdmissionId          INT            NOT NULL CONSTRAINT FK_IpdLamaRecord_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        DischargeId          INT            NOT NULL CONSTRAINT FK_IpdLamaRecord_Dis REFERENCES dbo.IpdDischarge (DischargeId),
        Kind                 VARCHAR(4)     NOT NULL,   -- LAMA DAMA
        Reason               NVARCHAR(500)  NOT NULL,
        RisksExplained       NVARCHAR(MAX)  NOT NULL,
        ExplainedByDoctorId  INT            NOT NULL,
        SignedByName         NVARCHAR(150)  NOT NULL,
        SignedByRelation     NVARCHAR(50)   NULL,
        SignaturePath        NVARCHAR(400)  NULL,
        WitnessName          NVARCHAR(150)  NULL,
        WitnessSignaturePath NVARCHAR(400)  NULL,
        DoctorSignaturePath  NVARCHAR(400)  NULL,
        RecordedAt           DATETIME       NOT NULL,
        IsActive             BIT            NOT NULL CONSTRAINT DF_IpdLamaRecord_Active DEFAULT (1),
        VoidReason           NVARCHAR(300)  NULL,
        CreatedBy            INT            NULL,
        CreatedDate          DATETIME       NOT NULL CONSTRAINT DF_IpdLamaRecord_Created DEFAULT (GETDATE()),
        CONSTRAINT CK_IpdLamaRecord_Kind CHECK (Kind IN ('LAMA', 'DAMA'))
    );
    CREATE UNIQUE INDEX UX_IpdLamaRecord_Live ON dbo.IpdLamaRecord (DischargeId) WHERE IsActive = 1;
END
GO

IF OBJECT_ID('dbo.IpdDeathRecord', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdDeathRecord
    (
        DeathId              INT IDENTITY(1,1) CONSTRAINT PK_IpdDeathRecord PRIMARY KEY,
        CompanyId            INT            NOT NULL,
        BranchId             INT            NOT NULL,
        AdmissionId          INT            NOT NULL CONSTRAINT FK_IpdDeathRecord_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        DischargeId          INT            NOT NULL CONSTRAINT FK_IpdDeathRecord_Dis REFERENCES dbo.IpdDischarge (DischargeId),
        DeathRegNo           NVARCHAR(40)   NOT NULL,
        DeathAt              DATETIME       NOT NULL,
        FormType             VARCHAR(3)     NOT NULL CONSTRAINT DF_IpdDeathRecord_Form DEFAULT ('4'),   -- MCCD Form 4 (institutional) / 4A
        CauseImmediate       NVARCHAR(300)  NOT NULL,   -- Part I (a)
        IntervalImmediate    NVARCHAR(50)   NULL,
        CauseAntecedent      NVARCHAR(300)  NULL,       -- Part I (b)
        IntervalAntecedent   NVARCHAR(50)   NULL,
        CauseUnderlying      NVARCHAR(300)  NULL,       -- Part I (c)
        IntervalUnderlying   NVARCHAR(50)   NULL,
        UnderlyingIcd        NVARCHAR(10)   NULL,
        OtherConditions      NVARCHAR(500)  NULL,       -- Part II
        MannerOfDeath        VARCHAR(12)    NOT NULL,   -- NATURAL ACCIDENT SUICIDE HOMICIDE PENDING
        PregnancyStatus      VARCHAR(12)    NULL,       -- NA NOT_PREGNANT PREGNANT WITHIN_42D
        DeliveryInvolved     BIT            NOT NULL CONSTRAINT DF_IpdDeathRecord_Delivery DEFAULT (0),
        PoliceIntimated      BIT            NOT NULL CONSTRAINT DF_IpdDeathRecord_Police DEFAULT (0),
        PoliceStation        NVARCHAR(150)  NULL,
        PostMortem           BIT            NOT NULL CONSTRAINT DF_IpdDeathRecord_PM DEFAULT (0),
        CertifiedByDoctorId  INT            NOT NULL,
        BodyHandedTo         NVARCHAR(150)  NULL,
        BodyHandedRelation   NVARCHAR(50)   NULL,
        BodyHandedAt         DATETIME       NULL,
        Remarks              NVARCHAR(500)  NULL,
        IsActive             BIT            NOT NULL CONSTRAINT DF_IpdDeathRecord_Active DEFAULT (1),
        VoidReason           NVARCHAR(300)  NULL,
        CreatedBy            INT            NULL,
        CreatedDate          DATETIME       NOT NULL CONSTRAINT DF_IpdDeathRecord_Created DEFAULT (GETDATE()),
        ModifiedBy           INT            NULL,
        ModifiedDate         DATETIME       NULL,
        CONSTRAINT CK_IpdDeathRecord_Manner CHECK (MannerOfDeath IN ('NATURAL', 'ACCIDENT', 'SUICIDE', 'HOMICIDE', 'PENDING')),
        CONSTRAINT CK_IpdDeathRecord_Form CHECK (FormType IN ('4', '4A'))
    );
    CREATE UNIQUE INDEX UX_IpdDeathRecord_Live ON dbo.IpdDeathRecord (AdmissionId) WHERE IsActive = 1;
    CREATE INDEX IX_IpdDeathRecord_Branch ON dbo.IpdDeathRecord (BranchId, DeathAt);
END
GO

IF OBJECT_ID('dbo.IpdFollowUp', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdFollowUp
    (
        FollowUpId    INT IDENTITY(1,1) CONSTRAINT PK_IpdFollowUp PRIMARY KEY,
        CompanyId     INT            NOT NULL,
        BranchId      INT            NOT NULL,
        AdmissionId   INT            NOT NULL CONSTRAINT FK_IpdFollowUp_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        PatientId     INT            NOT NULL,
        DoctorId      INT            NOT NULL,
        FollowUpDate  DATE           NOT NULL,
        ScheduleId    INT            NULL,       -- Doctor Roster slot, when one was picked
        SlotTime      VARCHAR(5)     NULL,
        Notes         NVARCHAR(300)  NULL,
        Status        VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdFollowUp_Status DEFAULT ('BOOKED'),
        CancelReason  NVARCHAR(300)  NULL,
        CreatedBy     INT            NULL,
        CreatedDate   DATETIME       NOT NULL CONSTRAINT DF_IpdFollowUp_Created DEFAULT (GETDATE()),
        ModifiedBy    INT            NULL,
        ModifiedDate  DATETIME       NULL,
        CONSTRAINT CK_IpdFollowUp_Status CHECK (Status IN ('BOOKED', 'CANCELLED'))
    );
    CREATE INDEX IX_IpdFollowUp_Date ON dbo.IpdFollowUp (BranchId, FollowUpDate, Status);
    CREATE INDEX IX_IpdFollowUp_Adm ON dbo.IpdFollowUp (AdmissionId);
END
GO

-- signing on behalf of the consultant (bypass): who clicked Sign is SignedByUserId, the doctor is SignedByDoctorId
IF COL_LENGTH('dbo.IpdDischargeSummary', 'SignedOnBehalf') IS NULL
    ALTER TABLE dbo.IpdDischargeSummary ADD SignedOnBehalf BIT NOT NULL CONSTRAINT DF_IpdDischargeSummary_OnBehalf DEFAULT (0), OnBehalfReason NVARCHAR(300) NULL;
GO

-- ── 2. the state of one admission's discharge (read by the tab, the board and the gate pass) ─────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_DischargeState (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT a.AdmissionId, d.DischargeId, d.DischargeType, d.Status AS DischargeStatus, d.AdvisedAt, d.PlannedAt, d.ClearedAt, d.GatePassAt,
           b.BillId, b.BillNo, b.BillAt,
           CAST(CASE WHEN b.BillId IS NULL THEN NULL ELSE (b.Net - b.PayerShare + b.PayerToPatient) - mo.NetAdvance END AS DECIMAL(18,2)) AS PatientBalance,
           (SELECT COUNT(*) FROM dbo.IpdPhIndent i WHERE i.AdmissionId = a.AdmissionId AND i.Status IN ('PENDING', 'PARTIAL')) AS OpenIndents,
           lab.LabNotCollected, lab.LabPending,
           (SELECT TOP 1 pa.Status FROM dbo.IpdPreAuth pa WHERE pa.AdmissionId = a.AdmissionId AND pa.IsLive = 1
              AND pa.Status IN ('REQUESTED', 'QUERY', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED') ORDER BY pa.PreAuthId DESC) AS TpaWaiting,
           (SELECT COUNT(*) FROM dbo.IpdOtBooking o WHERE o.AdmissionId = a.AdmissionId AND o.Status IN ('SCHEDULED', 'IN_OT')) AS OpenOt,
           (SELECT COUNT(*) FROM dbo.IpdDischargeClearance c WHERE c.DischargeId = d.DischargeId AND c.Status = 'PENDING') AS ClearancesPending,
           s.SummaryId AS SignedSummaryId, s.SignedAt AS SummarySignedAt,
           (SELECT TOP 1 1 FROM dbo.IpdDischargeSummary x WHERE x.AdmissionId = a.AdmissionId AND x.Status = 'DRAFT') AS HasDraft,
           (SELECT TOP 1 l.LamaId FROM dbo.IpdLamaRecord l WHERE l.DischargeId = d.DischargeId AND l.IsActive = 1) AS LamaId,
           (SELECT TOP 1 r.DeathId FROM dbo.IpdDeathRecord r WHERE r.AdmissionId = a.AdmissionId AND r.IsActive = 1) AS DeathId,
           (SELECT MAX(v.CreatedDate) FROM dbo.IpdAdvance v WHERE v.AdmissionId = a.AdmissionId AND v.IsActive = 1 AND b.BillAt IS NOT NULL AND v.CreatedDate >= b.BillAt) AS LastPaymentAfterBill,
           (SELECT TOP 1 ISNULL(k.CompletedAt, k.RequestedAt) FROM dbo.IpdBedCleaning k WHERE k.AdmissionId = a.AdmissionId AND k.Reason = 'DISCHARGE' ORDER BY k.CleaningTaskId DESC) AS BedCleaningAt,
           (SELECT TOP 1 k.CompletedAt FROM dbo.IpdBedCleaning k WHERE k.AdmissionId = a.AdmissionId AND k.Reason = 'DISCHARGE' ORDER BY k.CleaningTaskId DESC) AS BedReadyAt,
           ISNULL((SELECT TOP 1 hs.IpdDischargeTatTargetMinutes FROM dbo.HospitalSettings hs WHERE hs.BranchID = a.BranchId ORDER BY hs.Id DESC), 180) AS TatTargetMinutes
    FROM dbo.IpdAdmission a
    OUTER APPLY (SELECT TOP 1 * FROM dbo.IpdDischarge x WHERE x.AdmissionId = a.AdmissionId AND x.Status <> 'CANCELLED' ORDER BY x.DischargeId DESC) d
    LEFT JOIN dbo.IpdBill b ON b.BillId = a.BillId AND b.Status = 'FINAL'
    OUTER APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    OUTER APPLY (SELECT TOP 1 x.SummaryId, x.SignedAt FROM dbo.IpdDischargeSummary x WHERE x.AdmissionId = a.AdmissionId AND x.Status = 'SIGNED') s
    OUTER APPLY (SELECT SUM(CASE WHEN ISNULL(st.Collected, 0) = 0 AND ISNULL(st.Entered, 0) = 0 THEN 1 ELSE 0 END) AS LabNotCollected,
                        SUM(CASE WHEN ISNULL(st.ReportLevel, 0) < 3 THEN 1 ELSE 0 END) AS LabPending
                 FROM dbo.LabOrder lo JOIN dbo.LabOrderItem li ON li.LabOrderId = lo.LabOrderId AND li.IsActive = 1
                 OUTER APPLY dbo.fn_Ipd_LabItemStatus(li.LabOrderItemId) st
                 WHERE lo.AdmissionId = a.AdmissionId) lab
    WHERE a.AdmissionId = @AdmissionId
);
GO

-- ── 3. the Discharge tab ─────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Data @CompanyId INT, @BranchId INT, @AdmissionId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId) RETURN;
    DECLARE @now DATETIME = GETDATE();
    -- 0 header and state
    SELECT a.IpNo, a.Status, a.IsOpen, a.AdmissionAt, a.DischargeAt, a.PayerType, a.IsMlc, a.ConsultantDoctorId, cd.FullName AS ConsultantName,
           a.ProvisionalDiagnosis, a.DiagnosisCode, p.PatientId, p.PatientCode, p.Gender, p.KnownAllergies,
           LTRIM(RTRIM(CONCAT(p.Salutation, ' ', p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName,
           st.*, CAST(DATEDIFF(MINUTE, st.AdvisedAt, ISNULL(st.GatePassAt, @now)) AS INT) AS TatMinutes,
           (SELECT TOP 1 md.DoctorId FROM dbo.DoctorMaster md WHERE md.LinkedUserId = @UserId AND md.IsActive = 1 AND @UserId IS NOT NULL ORDER BY md.DoctorId) AS MyDoctorId
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    CROSS APPLY dbo.fn_Ipd_DischargeState(a.AdmissionId) st
    WHERE a.AdmissionId = @AdmissionId;
    -- 1 discharge (live one)
    SELECT d.*, ad.FullName AS AdvisedByDoctorName, u.FullName AS GatePassByName, uc.FullName AS CreatedByName
    FROM dbo.IpdDischarge d
    LEFT JOIN dbo.DoctorMaster ad ON ad.DoctorId = d.AdvisedByDoctorId
    LEFT JOIN dbo.Users u ON u.Id = d.GatePassBy
    LEFT JOIN dbo.Users uc ON uc.Id = d.CreatedBy
    WHERE d.AdmissionId = @AdmissionId AND d.Status <> 'CANCELLED';
    -- 2 clearances
    SELECT c.ClearanceId, c.Dept, c.Status, c.Checklist, c.Remarks, c.ClearedAt, u.FullName AS ClearedByName
    FROM dbo.IpdDischargeClearance c
    JOIN dbo.IpdDischarge d ON d.DischargeId = c.DischargeId AND d.Status <> 'CANCELLED'
    LEFT JOIN dbo.Users u ON u.Id = c.ClearedBy
    WHERE c.AdmissionId = @AdmissionId
    ORDER BY CASE c.Dept WHEN 'PHARMACY' THEN 1 WHEN 'LAB' THEN 2 WHEN 'NURSING' THEN 3 ELSE 4 END;
    -- 3 summaries (every version)
    SELECT s.*, d.FullName AS SignedByDoctorName, u.FullName AS CreatedByName, um.FullName AS ModifiedByName, us.FullName AS SignedByUserName
    FROM dbo.IpdDischargeSummary s
    LEFT JOIN dbo.Users us ON us.Id = s.SignedByUserId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.SignedByDoctorId
    LEFT JOIN dbo.Users u ON u.Id = s.CreatedBy
    LEFT JOIN dbo.Users um ON um.Id = s.ModifiedBy
    WHERE s.AdmissionId = @AdmissionId ORDER BY s.Version DESC;
    -- 4 LAMA / DAMA form
    SELECT l.*, d.FullName AS ExplainedByDoctorName
    FROM dbo.IpdLamaRecord l LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = l.ExplainedByDoctorId
    WHERE l.AdmissionId = @AdmissionId AND l.IsActive = 1;
    -- 5 death record
    SELECT r.*, d.FullName AS CertifiedByDoctorName
    FROM dbo.IpdDeathRecord r LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.CertifiedByDoctorId
    WHERE r.AdmissionId = @AdmissionId AND r.IsActive = 1;
    -- 6 follow-ups
    SELECT f.FollowUpId, f.DoctorId, d.FullName AS DoctorName, f.FollowUpDate, f.ScheduleId, f.SlotTime, f.Notes, f.Status, f.CancelReason, f.CreatedDate, u.FullName AS CreatedByName
    FROM dbo.IpdFollowUp f LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId LEFT JOIN dbo.Users u ON u.Id = f.CreatedBy
    WHERE f.AdmissionId = @AdmissionId ORDER BY f.Status, f.FollowUpDate;
    -- 7 LAB items not reported yet (clearance)
    SELECT lo.BillNo, li.LabOrderItemId, COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, i.Test_Name) AS ItemName,
           CASE WHEN ISNULL(st.Collected, 0) = 0 AND ISNULL(st.Entered, 0) = 0 THEN 'NOT_COLLECTED' WHEN st.ReportLevel = 2 THEN 'VALIDATED' ELSE 'IN_PROCESS' END AS ItemStatus
    FROM dbo.LabOrder lo
    JOIN dbo.LabOrderItem li ON li.LabOrderId = lo.LabOrderId AND li.IsActive = 1
    LEFT JOIN dbo.LabInvestigationMaster i ON li.[Type] <> 'P' AND i.Test_ID = li.InvestigationId
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    OUTER APPLY dbo.fn_Ipd_LabItemStatus(li.LabOrderItemId) st
    WHERE lo.AdmissionId = @AdmissionId AND ISNULL(st.ReportLevel, 0) < 3;
    -- 8 doctors (advice, LAMA, death certificate, summary signer, follow-up)
    SELECT d.DoctorId, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName, d.MedicalLicenseNo
    FROM dbo.DoctorMaster d
    WHERE d.IsActive = 1 AND ISNULL(d.IsReferralDoctor, 0) = 0 AND ISNULL(d.IsSuspended, 0) = 0 AND (d.CompanyId = @CompanyId OR d.CompanyId IS NULL)
    ORDER BY d.FullName;
END;
GO

-- Prefill of a new discharge summary from what the admission already holds.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Prefill @CompanyId INT, @BranchId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId) RETURN;
    -- 0 admission: diagnosis, reason, allergies, emergency contact
    SELECT a.ProvisionalDiagnosis, a.DiagnosisCode, ic.Title AS DiagnosisTitle, a.ReasonForAdmission, p.KnownAllergies,
           CONCAT(ISNULL(NULLIF(hs.EmergencyNumber, ''), hs.ContactNumber1), CASE WHEN hs.HotelName IS NOT NULL THEN N' (' + hs.HotelName + N')' ELSE N'' END) AS EmergencyContact
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.IcdCode ic ON ic.Code = a.DiagnosisCode
    OUTER APPLY (SELECT TOP 1 * FROM dbo.HospitalSettings s WHERE s.BranchID = a.BranchId ORDER BY s.Id DESC) hs
    WHERE a.AdmissionId = @AdmissionId;
    -- 1 procedures: completed surgeries and bedside procedures charged
    SELECT 'OT' AS Kind, ISNULL(n.ProcedurePerformed, o.ProcedureName) AS Name, o.ClosureAt AS DoneAt, sd.FullName AS DoctorName
    FROM dbo.IpdOtBooking o
    LEFT JOIN dbo.DoctorMaster sd ON sd.DoctorId = o.SurgeonId
    OUTER APPLY (SELECT TOP 1 x.ProcedurePerformed FROM dbo.IpdSurgeryNote x WHERE x.OtBookingId = o.OtBookingId ORDER BY x.Version DESC) n
    WHERE o.AdmissionId = @AdmissionId AND o.Status = 'COMPLETED'
    UNION ALL
    SELECT 'PROC', c.ItemName, c.ChargeAt, d.FullName
    FROM dbo.IpdCharge c LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    WHERE c.AdmissionId = @AdmissionId AND c.Head = 'PROCEDURE' AND c.Status = 'POSTED' AND c.ReversalOfChargeId IS NULL
    ORDER BY 3;
    -- 2 investigations reported / in process
    SELECT DISTINCT COALESCE(CASE WHEN li.[Type] = 'P' THEN h.Profile_Name END, i.Test_Name) AS ItemName, CAST(lo.OrderDate AS DATE) AS OrderDate,
           CASE WHEN st.ReportLevel = 3 THEN 'Reported' WHEN ISNULL(st.Collected, 0) = 0 THEN 'Not collected' ELSE 'Report awaited' END AS ItemStatus
    FROM dbo.LabOrder lo
    JOIN dbo.LabOrderItem li ON li.LabOrderId = lo.LabOrderId AND li.IsActive = 1
    LEFT JOIN dbo.LabInvestigationMaster i ON li.[Type] <> 'P' AND i.Test_ID = li.InvestigationId
    LEFT JOIN dbo.LabInvestigationProfileHeader h ON li.[Type] = 'P' AND h.Profile_ID = li.InvestigationId
    OUTER APPLY dbo.fn_Ipd_LabItemStatus(li.LabOrderItemId) st
    WHERE lo.AdmissionId = @AdmissionId
    ORDER BY 2, 1;
    -- 3 medicines issued in the last 48 hours of the stay (to pick the discharge medicines from)
    SELECT it.ItemName, MAX(s.IssueAt) AS LastIssued, SUM(l.Qty - ISNULL(l.ReturnedQty, 0)) AS Qty
    FROM dbo.IpdPhIssue s
    JOIN dbo.IpdPhIssueLine l ON l.IssueId = s.IssueId
    JOIN dbo.PhItem it ON it.ItemId = l.ItemId
    WHERE s.AdmissionId = @AdmissionId AND s.Kind = 'ISSUE' AND s.Head = 'PHARMACY'
      AND s.IssueAt >= DATEADD(HOUR, -48, (SELECT MAX(IssueAt) FROM dbo.IpdPhIssue WHERE AdmissionId = @AdmissionId AND Kind = 'ISSUE'))
    GROUP BY it.ItemName
    HAVING SUM(l.Qty - ISNULL(l.ReturnedQty, 0)) > 0
    ORDER BY it.ItemName;
END;
GO

-- ── 4. advice ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Advise
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @DischargeType VARCHAR(12), @AdvisedByDoctorId INT,
    @PlannedAt DATETIME = NULL, @Remarks NVARCHAR(500) = NULL, @TransferTo NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @payer VARCHAR(12), @admAt DATETIME;
        SELECT @open = IsOpen, @status = Status, @payer = PayerType, @admAt = AdmissionAt FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL') THROW 58401, 'The patient is not admitted: discharge cannot be advised.', 1;
        SET @DischargeType = UPPER(LTRIM(RTRIM(ISNULL(@DischargeType, ''))));
        IF @DischargeType NOT IN ('NORMAL', 'LAMA', 'DAMA', 'ABSCONDED', 'TRANSFER', 'DEATH') THROW 58402, 'Choose the discharge type.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @AdvisedByDoctorId AND IsActive = 1) THROW 58403, 'Choose the consultant advising the discharge.', 1;
        IF @PlannedAt IS NOT NULL AND @PlannedAt < @admAt THROW 58404, 'The planned discharge cannot be before the admission.', 1;
        IF @DischargeType = 'TRANSFER' AND NULLIF(LTRIM(RTRIM(@TransferTo)), N'') IS NULL THROW 58405, 'Enter the hospital the patient is transferred to, and why.', 1;
        IF @DischargeType IN ('LAMA', 'DAMA', 'ABSCONDED') AND NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NULL THROW 58406, 'Enter the reason / circumstances.', 1;

        DECLARE @id INT, @oldType VARCHAR(12);
        SELECT @id = DischargeId, @oldType = DischargeType FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'ADVISED';
        IF EXISTS (SELECT 1 FROM dbo.IpdDischarge WHERE AdmissionId = @AdmissionId AND Status = 'DISCHARGED') THROW 58407, 'The patient is already discharged.', 1;
        IF @id IS NULL
        BEGIN
            INSERT dbo.IpdDischarge (CompanyId, BranchId, AdmissionId, DischargeType, AdvisedAt, AdvisedByDoctorId, PlannedAt, AdviceRemarks, TransferTo, CreatedBy)
            VALUES (@CompanyId, @BranchId, @AdmissionId, @DischargeType, @now, @AdvisedByDoctorId, @PlannedAt, NULLIF(LTRIM(RTRIM(@Remarks)), N''), NULLIF(LTRIM(RTRIM(@TransferTo)), N''), @UserId);
            SET @id = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.IpdDischargeClearance (DischargeId, AdmissionId, Dept, Status, Remarks, ClearedAt)
            SELECT @id, @AdmissionId, v.Dept, CASE WHEN v.Dept = 'TPA' AND @payer <> 'INSURANCE' THEN 'NA' ELSE 'PENDING' END,
                   CASE WHEN v.Dept = 'TPA' AND @payer <> 'INSURANCE' THEN N'Not an insurance patient' END,
                   CASE WHEN v.Dept = 'TPA' AND @payer <> 'INSURANCE' THEN @now END
            FROM (VALUES ('PHARMACY'), ('LAB'), ('NURSING'), ('TPA')) v (Dept);
            IF @status = 'ADMITTED'
                UPDATE dbo.IpdAdmission SET Status = 'DISCHARGE_ADVISED', ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'DISCHARGE_ADVICE', @status, CASE WHEN @status = 'ADMITTED' THEN 'DISCHARGE_ADVISED' ELSE @status END,
                    CONCAT(N'Discharge advised (', @DischargeType, N')', CASE WHEN @PlannedAt IS NOT NULL THEN N', planned ' + FORMAT(@PlannedAt, 'dd-MMM-yyyy HH:mm') ELSE N'' END,
                           CASE WHEN NULLIF(LTRIM(RTRIM(@Remarks)), N'') IS NOT NULL THEN N': ' + LTRIM(RTRIM(@Remarks)) ELSE N'' END), @UserId);
        END
        ELSE
        BEGIN
            IF @oldType <> @DischargeType AND EXISTS (SELECT 1 FROM dbo.IpdLamaRecord WHERE DischargeId = @id AND IsActive = 1)
                THROW 58408, 'A LAMA / DAMA form is recorded: void it before changing the discharge type.', 1;
            IF @oldType = 'DEATH' AND @DischargeType <> 'DEATH' AND EXISTS (SELECT 1 FROM dbo.IpdDeathRecord WHERE AdmissionId = @AdmissionId AND IsActive = 1)
                THROW 58409, 'A death record is recorded: void it before changing the discharge type.', 1;
            UPDATE dbo.IpdDischarge SET DischargeType = @DischargeType, AdvisedByDoctorId = @AdvisedByDoctorId, PlannedAt = @PlannedAt,
                   AdviceRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), TransferTo = NULLIF(LTRIM(RTRIM(@TransferTo)), N''), ModifiedBy = @UserId, ModifiedDate = @now
            WHERE DischargeId = @id;
            INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
            VALUES (@AdmissionId, 'DISCHARGE_ADVICE_EDIT', @status, @status, CONCAT(N'Discharge advice changed (', @DischargeType, N')',
                    CASE WHEN @PlannedAt IS NOT NULL THEN N', planned ' + FORMAT(@PlannedAt, 'dd-MMM-yyyy HH:mm') ELSE N'' END), @UserId);
        END
        IF @PlannedAt IS NOT NULL AND @status <> 'BILL_FINAL'
            UPDATE dbo.IpdAdmission SET ExpectedDischargeAt = @PlannedAt WHERE AdmissionId = @AdmissionId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @id AS DischargeId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_CancelAdvice @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @status VARCHAR(20), @id INT;
        SELECT @status = Status FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @status IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        SELECT @id = DischargeId FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'ADVISED';
        IF @id IS NULL THROW 58410, 'There is no open discharge advice.', 1;
        IF @status = 'BILL_FINAL' THROW 58411, 'The final bill is made: cancel the bill first to cancel the discharge advice.', 1;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 58412, 'Enter the reason.', 1;
        UPDATE dbo.IpdDischarge SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = @now WHERE DischargeId = @id;
        UPDATE dbo.IpdLamaRecord SET IsActive = 0, VoidReason = N'Discharge advice cancelled' WHERE DischargeId = @id AND IsActive = 1;
        UPDATE dbo.IpdDeathRecord SET IsActive = 0, VoidReason = N'Discharge advice cancelled', ModifiedBy = @UserId, ModifiedDate = @now WHERE DischargeId = @id AND IsActive = 1;
        IF @status = 'DISCHARGE_ADVISED'
            UPDATE dbo.IpdAdmission SET Status = 'ADMITTED', ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'DISCHARGE_ADVICE_CANCEL', @status, CASE WHEN @status = 'DISCHARGE_ADVISED' THEN 'ADMITTED' ELSE @status END, N'Discharge advice cancelled: ' + LTRIM(RTRIM(@Reason)), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

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

-- ── 7. LAMA / DAMA form ──────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Lama
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Reason NVARCHAR(500), @RisksExplained NVARCHAR(MAX), @ExplainedByDoctorId INT,
    @SignedByName NVARCHAR(150), @SignedByRelation NVARCHAR(50) = NULL, @SignaturePath NVARCHAR(400) = NULL, @WitnessName NVARCHAR(150) = NULL,
    @WitnessSignaturePath NVARCHAR(400) = NULL, @DoctorSignaturePath NVARCHAR(400) = NULL, @VoidReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 58400, 'The admission was not found in this branch.', 1;
        DECLARE @id INT, @type VARCHAR(12);
        SELECT @id = DischargeId, @type = DischargeType FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'ADVISED';
        IF @id IS NULL THROW 58460, 'Advise the discharge as LAMA or DAMA first.', 1;
        IF NULLIF(LTRIM(RTRIM(@VoidReason)), N'') IS NOT NULL
        BEGIN
            UPDATE dbo.IpdLamaRecord SET IsActive = 0, VoidReason = LTRIM(RTRIM(@VoidReason)) WHERE DischargeId = @id AND IsActive = 1;
            IF @@ROWCOUNT = 0 THROW 58461, 'There is no LAMA / DAMA form to void.', 1;
        END
        ELSE
        BEGIN
            IF @type NOT IN ('LAMA', 'DAMA') THROW 58462, 'The discharge type is not LAMA or DAMA.', 1;
            IF EXISTS (SELECT 1 FROM dbo.IpdLamaRecord WHERE DischargeId = @id AND IsActive = 1) THROW 58463, 'The form is already recorded: void it to record it again.', 1;
            IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 58464, 'Enter why the patient is leaving.', 1;
            IF NULLIF(LTRIM(RTRIM(@RisksExplained)), N'') IS NULL THROW 58465, 'Enter the risks explained.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @ExplainedByDoctorId AND IsActive = 1) THROW 58466, 'Choose the doctor who explained the risks.', 1;
            IF NULLIF(LTRIM(RTRIM(@SignedByName)), N'') IS NULL THROW 58467, 'Enter who signs the form (patient or attendant).', 1;
            IF @SignaturePath IS NULL THROW 58468, 'The patient / attendant must sign (or give the thumb impression on the pad).', 1;
            IF NULLIF(LTRIM(RTRIM(@WitnessName)), N'') IS NULL THROW 58469, 'Enter the witness.', 1;
            INSERT dbo.IpdLamaRecord (AdmissionId, DischargeId, Kind, Reason, RisksExplained, ExplainedByDoctorId, SignedByName, SignedByRelation, SignaturePath,
                   WitnessName, WitnessSignaturePath, DoctorSignaturePath, RecordedAt, CreatedBy)
            VALUES (@AdmissionId, @id, @type, LTRIM(RTRIM(@Reason)), LTRIM(RTRIM(@RisksExplained)), @ExplainedByDoctorId, LTRIM(RTRIM(@SignedByName)), NULLIF(LTRIM(RTRIM(@SignedByRelation)), N''),
                    @SignaturePath, LTRIM(RTRIM(@WitnessName)), @WitnessSignaturePath, @DoctorSignaturePath, @now, @UserId);
        END
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        SELECT @AdmissionId, 'LAMA_FORM', Status, Status, CASE WHEN NULLIF(LTRIM(RTRIM(@VoidReason)), N'') IS NOT NULL THEN N'LAMA / DAMA form voided: ' + LTRIM(RTRIM(@VoidReason))
               ELSE @type + N' form signed by ' + LTRIM(RTRIM(@SignedByName)) END, @UserId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

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
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, (SELECT DeathRegNo FROM dbo.IpdDeathRecord WHERE DeathId = @live) AS DeathRegNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 9. gate pass: the patient leaves, the admission closes and the bed goes to housekeeping ───────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_GatePass
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @HandedOverTo NVARCHAR(150) = NULL, @HandedOverRelation NVARCHAR(50) = NULL,
    @HandedOverPhone NVARCHAR(20) = NULL, @TransportMode NVARCHAR(40) = NULL, @Remarks NVARCHAR(500) = NULL,
    @Credit BIT = 0, @CreditReason NVARCHAR(300) = NULL, @CanCredit BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bed INT;
        SELECT @open = IsOpen, @status = Status, @bed = CurrentBedId FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        IF @open = 0 THROW 58500, 'The patient is already discharged.', 1;
        DECLARE @id INT, @type VARCHAR(12);
        SELECT @id = DischargeId, @type = DischargeType FROM dbo.IpdDischarge WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND Status = 'ADVISED';
        IF @id IS NULL THROW 58501, 'Advise the discharge first.', 1;
        IF @status <> 'BILL_FINAL' THROW 58502, 'Make the final bill (Billing tab) before the gate pass.', 1;
        DECLARE @bal DECIMAL(18,2), @clr INT, @ot INT, @sum INT, @lama INT, @death INT;
        SELECT @bal = ISNULL(PatientBalance, 0), @clr = ClearancesPending, @ot = OpenOt, @sum = SignedSummaryId, @lama = LamaId, @death = DeathId
        FROM dbo.fn_Ipd_DischargeState(@AdmissionId);
        IF @clr > 0 THROW 58503, 'Some clearances are pending (pharmacy, LAB, nursing, TPA).', 1;
        IF @ot > 0 THROW 58504, 'An OT booking is scheduled or in progress: complete or cancel it first.', 1;
        IF @type IN ('NORMAL', 'TRANSFER', 'DEATH') AND @sum IS NULL
            THROW 58505, 'The discharge summary must be signed by the consultant before the gate pass.', 1;
        IF @type IN ('LAMA', 'DAMA') AND @lama IS NULL THROW 58506, 'Record the LAMA / DAMA form with the signatures before the gate pass.', 1;
        IF @type = 'DEATH' AND @death IS NULL THROW 58507, 'Record the death (cause of death, certifying doctor) before the gate pass.', 1;
        IF @bal < -0.5 THROW 58508, 'Excess advance is held: refund it (Billing tab) before the gate pass.', 1;
        SET @CreditReason = NULLIF(LTRIM(RTRIM(@CreditReason)), N'');
        IF @bal > 0.5 AND ISNULL(@Credit, 0) = 0 THROW 58509, 'The patient''s balance is not paid: collect it (Billing tab), or make a credit discharge.', 1;
        IF @bal > 0.5 AND ISNULL(@CanCredit, 0) = 0 THROW 58510, 'You are not allowed to discharge with a balance due (credit discharge).', 1;
        IF @bal > 0.5 AND @CreditReason IS NULL THROW 58511, 'Enter the reason for the credit discharge.', 1;
        SET @HandedOverTo = NULLIF(LTRIM(RTRIM(@HandedOverTo)), N'');
        IF @type NOT IN ('ABSCONDED') AND @HandedOverTo IS NULL
            THROW 58512, 'Enter to whom the patient (or the body) is handed over.', 1;

        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'GP', @DocDate = @now, @DocNo = @no OUTPUT;
        UPDATE dbo.IpdDischarge SET Status = 'DISCHARGED', GatePassNo = @no, GatePassAt = @now, GatePassBy = @UserId, HandedOverTo = @HandedOverTo,
               HandedOverRelation = NULLIF(LTRIM(RTRIM(@HandedOverRelation)), N''), HandedOverPhone = NULLIF(LTRIM(RTRIM(@HandedOverPhone)), N''),
               TransportMode = NULLIF(LTRIM(RTRIM(@TransportMode)), N''), GatePassRemarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''),
               IsCreditDischarge = CASE WHEN @bal > 0.5 THEN 1 ELSE 0 END, CreditReason = CASE WHEN @bal > 0.5 THEN @CreditReason END,
               CreditAmount = CASE WHEN @bal > 0.5 THEN @bal END, ModifiedBy = @UserId, ModifiedDate = @now
        WHERE DischargeId = @id;
        -- bed: end the movement with DISCHARGE and release it (housekeeping job, or Available per Hospital Settings > IPD)
        DECLARE @mv INT, @mbed INT;
        SELECT @mv = MovementId, @mbed = BedId FROM dbo.IpdBedMovement WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND ToAt IS NULL;
        IF @mv IS NOT NULL
        BEGIN
            UPDATE dbo.IpdBedMovement SET ToAt = @now, EndType = 'DISCHARGE' WHERE MovementId = @mv;
            EXEC dbo.usp_Ipd_ReleaseBed @BedId = @mbed, @AdmissionId = @AdmissionId, @Reason = 'DISCHARGE', @UserId = @UserId;
        END
        UPDATE dbo.IpdAdmission SET Status = 'DISCHARGED', IsOpen = 0, DischargeAt = @now, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        UPDATE dbo.IpdDeathRecord SET BodyHandedTo = ISNULL(BodyHandedTo, @HandedOverTo), BodyHandedRelation = ISNULL(BodyHandedRelation, NULLIF(LTRIM(RTRIM(@HandedOverRelation)), N'')),
               BodyHandedAt = ISNULL(BodyHandedAt, @now) WHERE AdmissionId = @AdmissionId AND IsActive = 1;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'GATE_PASS', @status, 'DISCHARGED', CONCAT(N'Gate pass ', @no, N' (', @type, N')', CASE WHEN @HandedOverTo IS NOT NULL THEN N', handed over to ' + @HandedOverTo ELSE N'' END,
                CASE WHEN @bal > 0.5 THEN CONCAT(N', credit discharge ₹', FORMAT(@bal, 'N2', 'en-IN'), N': ', @CreditReason) ELSE N'' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @no AS GatePassNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 10. OPD follow-up ────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_FollowUp
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @FollowUpId INT = NULL, @DoctorId INT = NULL, @FollowUpDate DATE = NULL,
    @ScheduleId INT = NULL, @SlotTime VARCHAR(5) = NULL, @Notes NVARCHAR(300) = NULL, @CancelReason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @pid INT, @status VARCHAR(20);
        SELECT @pid = PatientId, @status = Status FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @pid IS NULL THROW 58400, 'The admission was not found in this branch.', 1;
        IF @status = 'CANCELLED' THROW 58440, 'The admission is cancelled.', 1;
        IF NULLIF(LTRIM(RTRIM(@CancelReason)), N'') IS NOT NULL
        BEGIN
            UPDATE dbo.IpdFollowUp SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@CancelReason)), ModifiedBy = @UserId, ModifiedDate = @now
            WHERE FollowUpId = @FollowUpId AND AdmissionId = @AdmissionId AND Status = 'BOOKED';
            IF @@ROWCOUNT = 0 THROW 58520, 'The follow-up was not found.', 1;
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND IsActive = 1) THROW 58521, 'Choose the doctor for the follow-up.', 1;
            IF @FollowUpDate IS NULL OR @FollowUpDate < CAST(@now AS DATE) THROW 58522, 'Choose a follow-up date from today on.', 1;
            IF @SlotTime IS NOT NULL AND @SlotTime NOT LIKE '[0-2][0-9]:[0-5][0-9]' THROW 58523, 'The slot time could not be read.', 1;
            IF @FollowUpId IS NULL
                INSERT dbo.IpdFollowUp (CompanyId, BranchId, AdmissionId, PatientId, DoctorId, FollowUpDate, ScheduleId, SlotTime, Notes, CreatedBy)
                VALUES (@CompanyId, @BranchId, @AdmissionId, @pid, @DoctorId, @FollowUpDate, @ScheduleId, NULLIF(@SlotTime, ''), NULLIF(LTRIM(RTRIM(@Notes)), N''), @UserId);
            ELSE
            BEGIN
                UPDATE dbo.IpdFollowUp SET DoctorId = @DoctorId, FollowUpDate = @FollowUpDate, ScheduleId = @ScheduleId, SlotTime = NULLIF(@SlotTime, ''),
                       Notes = NULLIF(LTRIM(RTRIM(@Notes)), N''), ModifiedBy = @UserId, ModifiedDate = @now
                WHERE FollowUpId = @FollowUpId AND AdmissionId = @AdmissionId AND Status = 'BOOKED';
                IF @@ROWCOUNT = 0 THROW 58520, 'The follow-up was not found.', 1;
            END
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

-- ── 11. prints (summary / death summary, LAMA / DAMA form, MCCD, gate pass) ──────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Print @CompanyId INT, @BranchId INT, @AdmissionId INT, @SummaryId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId) RETURN;
    -- 0 header
    SELECT a.AdmissionId, a.BranchId, a.IpNo, a.Status, a.AdmissionAt, a.DischargeAt, a.AdmissionType, a.PayerType, a.IsMlc, p.PatientCode, p.Gender, p.PhoneNumber, p.Address,
           LTRIM(RTRIM(CONCAT(p.Salutation, ' ', p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName, p.GuardianName, p.DateOfBirth,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL ELSE CONCAT(DATEDIFF(YEAR, p.DateOfBirth, a.AdmissionAt) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, a.AdmissionAt), p.DateOfBirth) > a.AdmissionAt THEN 1 ELSE 0 END, N' Y') END AS AgeText,
           LTRIM(RTRIM(ISNULL(cd.NamePrefix + ' ', '') + cd.FullName)) AS ConsultantName, dep.DeptName AS DepartmentName, w.WardName, bm.BedNumber,
           ad.FullName AS AdmittingDoctorName, ml.MlcNo
    FROM dbo.IpdAdmission a
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.DoctorMaster ad ON ad.DoctorId = a.AdmittingDoctorId
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = a.DepartmentId
    LEFT JOIN dbo.BedMaster bm ON bm.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = bm.WardId
    OUTER APPLY (SELECT TOP 1 m.MlcNo FROM dbo.IpdMlc m WHERE m.AdmissionId = a.AdmissionId) ml
    WHERE a.AdmissionId = @AdmissionId;
    -- 1 summary: the one asked for, else the signed one, else the draft
    SELECT TOP 1 s.*, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS SignedByDoctorName, d.MedicalLicenseNo AS SignedByRegNo, CAST(CASE WHEN NULLIF(d.SignaturePath, N'') IS NULL THEN 0 ELSE 1 END AS BIT) AS SignedByHasSignature,
           ub.FullName AS SignedByUserName
    FROM dbo.IpdDischargeSummary s
    LEFT JOIN dbo.Users ub ON ub.Id = s.SignedByUserId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = s.SignedByDoctorId
    WHERE s.AdmissionId = @AdmissionId AND (@SummaryId IS NULL OR s.SummaryId = @SummaryId)
    ORDER BY CASE WHEN @SummaryId IS NOT NULL THEN 0 WHEN s.Status = 'SIGNED' THEN 1 WHEN s.Status = 'DRAFT' THEN 2 ELSE 3 END, s.Version DESC;
    -- 2 discharge
    SELECT TOP 1 d.*, LTRIM(RTRIM(ISNULL(dd.NamePrefix + ' ', '') + dd.FullName)) AS AdvisedByDoctorName, u.FullName AS GatePassByName
    FROM dbo.IpdDischarge d LEFT JOIN dbo.DoctorMaster dd ON dd.DoctorId = d.AdvisedByDoctorId LEFT JOIN dbo.Users u ON u.Id = d.GatePassBy
    WHERE d.AdmissionId = @AdmissionId AND d.Status <> 'CANCELLED' ORDER BY d.DischargeId DESC;
    -- 3 LAMA / DAMA
    SELECT l.*, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS ExplainedByDoctorName, d.MedicalLicenseNo AS ExplainedByRegNo
    FROM dbo.IpdLamaRecord l LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = l.ExplainedByDoctorId
    WHERE l.AdmissionId = @AdmissionId AND l.IsActive = 1;
    -- 4 death
    SELECT r.*, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS CertifiedByDoctorName, d.MedicalLicenseNo AS CertifiedByRegNo, CAST(CASE WHEN NULLIF(d.SignaturePath, N'') IS NULL THEN 0 ELSE 1 END AS BIT) AS CertifiedByHasSignature
    FROM dbo.IpdDeathRecord r LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.CertifiedByDoctorId
    WHERE r.AdmissionId = @AdmissionId AND r.IsActive = 1;
    -- 5 follow-ups
    SELECT f.FollowUpDate, f.SlotTime, f.Notes, LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS DoctorName
    FROM dbo.IpdFollowUp f LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId
    WHERE f.AdmissionId = @AdmissionId AND f.Status = 'BOOKED' ORDER BY f.FollowUpDate;
    -- 6 bill (gate pass)
    SELECT b.BillNo, b.BillAt, b.Net, b.PayerShare, st.PatientBalance FROM dbo.IpdBill b CROSS APPLY dbo.fn_Ipd_DischargeState(@AdmissionId) st
    WHERE b.BillId = (SELECT BillId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId) AND b.Status = 'FINAL';
END;
GO

-- ── 12. IPD > Discharges: tracker, register, TAT, death register ─────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Board
    @CompanyId INT, @BranchId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @DischargeType VARCHAR(12) = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME = GETDATE();
    SET @ToDate = ISNULL(@ToDate, CAST(@now AS DATE));
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -30, @ToDate));
    DECLARE @to DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @target INT = ISNULL((SELECT TOP 1 IpdDischargeTatTargetMinutes FROM dbo.HospitalSettings WHERE BranchID = @BranchId ORDER BY Id DESC), 180);

    SELECT d.DischargeId, d.AdmissionId, d.DischargeType, d.Status AS DischargeStatus, d.AdvisedAt, d.PlannedAt, d.ClearedAt, d.GatePassNo, d.GatePassAt,
           d.IsCreditDischarge, d.CreditAmount, a.IpNo, a.Status AS AdmStatus, a.AdmissionAt, a.PayerType, p.PatientCode, p.PhoneNumber, p.Gender,
           LTRIM(RTRIM(CONCAT(p.Salutation, ' ', p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName,
           cd.FullName AS ConsultantName, w.WardName, bm.BedNumber,
           st.BillNo, st.BillAt, st.PatientBalance, st.ClearancesPending, st.SummarySignedAt, st.LastPaymentAfterBill, st.BedCleaningAt, st.BedReadyAt,
           CAST(DATEDIFF(MINUTE, d.AdvisedAt, ISNULL(d.GatePassAt, @now)) AS INT) AS TatMinutes, @target AS TatTargetMinutes,
           DATEDIFF(DAY, a.AdmissionAt, ISNULL(a.DischargeAt, @now)) + 1 AS StayDays
    INTO #d
    FROM dbo.IpdDischarge d
    JOIN dbo.IpdAdmission a ON a.AdmissionId = d.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster cd ON cd.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.BedMaster bm ON bm.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = bm.WardId
    CROSS APPLY dbo.fn_Ipd_DischargeState(a.AdmissionId) st
    WHERE d.CompanyId = @CompanyId AND d.BranchId = @BranchId
      AND (d.Status = 'ADVISED' OR (d.Status = 'DISCHARGED' AND d.GatePassAt >= @FromDate AND d.GatePassAt < @to))
      AND (@DischargeType IS NULL OR d.DischargeType = @DischargeType)
      AND (@Search IS NULL OR a.IpNo LIKE N'%' + @Search + N'%' OR p.PatientCode LIKE N'%' + @Search + N'%' OR p.PhoneNumber LIKE N'%' + @Search + N'%'
           OR CONCAT(p.FirstName, ' ', p.LastName) LIKE N'%' + @Search + N'%');

    -- 0 in progress (advised, not yet out)
    SELECT * FROM #d WHERE DischargeStatus = 'ADVISED' ORDER BY AdvisedAt;
    -- 1 discharged in the period
    SELECT * FROM #d WHERE DischargeStatus = 'DISCHARGED' ORDER BY GatePassAt DESC;
    -- 2 KPIs of the period (NABH: discharge TAT, LAMA / DAMA %, mortality, summaries)
    SELECT COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' THEN 1 END) AS Discharged,
           COUNT(CASE WHEN DischargeStatus = 'ADVISED' THEN 1 END) AS InProgress,
           COUNT(CASE WHEN DischargeStatus = 'ADVISED' AND TatMinutes > @target THEN 1 END) AS InProgressOverTarget,
           CAST(AVG(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('NORMAL', 'TRANSFER') THEN CAST(TatMinutes AS DECIMAL(18,2)) END) AS DECIMAL(18,1)) AS AvgTatMinutes,
           CAST(AVG(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('NORMAL', 'TRANSFER') AND PayerType = 'INSURANCE' THEN CAST(TatMinutes AS DECIMAL(18,2)) END) AS DECIMAL(18,1)) AS AvgTatInsurance,
           CAST(AVG(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('NORMAL', 'TRANSFER') AND PayerType <> 'INSURANCE' THEN CAST(TatMinutes AS DECIMAL(18,2)) END) AS DECIMAL(18,1)) AS AvgTatCash,
           CAST(100.0 * COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('NORMAL', 'TRANSFER') AND TatMinutes <= @target THEN 1 END)
                / NULLIF(COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('NORMAL', 'TRANSFER') THEN 1 END), 0) AS DECIMAL(5,1)) AS WithinTargetPct,
           COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('LAMA', 'DAMA') THEN 1 END) AS LamaDama,
           CAST(100.0 * COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType IN ('LAMA', 'DAMA') THEN 1 END)
                / NULLIF(COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' THEN 1 END), 0) AS DECIMAL(5,1)) AS LamaDamaPct,
           COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType = 'DEATH' THEN 1 END) AS Deaths,
           CAST(100.0 * COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType = 'DEATH' THEN 1 END)
                / NULLIF(COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' THEN 1 END), 0) AS DECIMAL(5,1)) AS MortalityPct,
           COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND DischargeType = 'ABSCONDED' THEN 1 END) AS Absconded,
           COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND IsCreditDischarge = 1 THEN 1 END) AS CreditDischarges,
           COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND SummarySignedAt IS NULL THEN 1 END) AS SummaryPending,
           COUNT(CASE WHEN DischargeStatus = 'DISCHARGED' AND SummarySignedAt IS NOT NULL AND SummarySignedAt <= GatePassAt THEN 1 END) AS SummaryBeforeGatePass,
           @target AS TatTargetMinutes
    FROM #d;
    -- 3 death register of the period
    SELECT r.DeathRegNo, r.DeathAt, r.FormType, r.CauseImmediate, r.CauseAntecedent, r.CauseUnderlying, r.UnderlyingIcd, r.MannerOfDeath, r.PoliceIntimated, r.PoliceStation,
           r.PostMortem, r.BodyHandedTo, r.BodyHandedRelation, r.BodyHandedAt, a.AdmissionId, a.IpNo, a.AdmissionAt, a.IsMlc, p.PatientCode, p.Gender, p.Address,
           LTRIM(RTRIM(CONCAT(p.Salutation, ' ', p.FirstName, ' ', ISNULL(p.MiddleName + ' ', ''), p.LastName))) AS PatientName, p.GuardianName,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL ELSE DATEDIFF(YEAR, p.DateOfBirth, r.DeathAt) - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, r.DeathAt), p.DateOfBirth) > r.DeathAt THEN 1 ELSE 0 END END AS AgeYears,
           d.FullName AS CertifiedByDoctorName
    FROM dbo.IpdDeathRecord r
    JOIN dbo.IpdAdmission a ON a.AdmissionId = r.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = r.CertifiedByDoctorId
    WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.IsActive = 1 AND r.DeathAt >= @FromDate AND r.DeathAt < @to
    ORDER BY r.DeathAt;
    DROP TABLE #d;
END;
GO

-- ── 13. medicines on discharge: search of Master > EMR Medication (EmrMedicationMaster) ───────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDischarge_Medicines @CompanyId INT, @Q NVARCHAR(100) = NULL, @Top INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    SELECT TOP (ISNULL(@Top, 20)) m.MedicationId, m.MedicationName, m.GenericName, m.Category, m.Strength, m.Unit, m.RouteOfAdministration
    FROM dbo.EmrMedicationMaster m
    WHERE m.IsActive = 1 AND (m.CompanyId = @CompanyId OR m.CompanyId IS NULL)
      AND (@Q IS NULL OR m.MedicationName LIKE N'%' + @Q + N'%' OR m.GenericName LIKE N'%' + @Q + N'%')
    ORDER BY CASE WHEN m.MedicationName LIKE @Q + N'%' THEN 0 ELSE 1 END, m.MedicationName;
END;
GO

PRINT '2557 IPD discharge - tables and procedures done.';
GO
