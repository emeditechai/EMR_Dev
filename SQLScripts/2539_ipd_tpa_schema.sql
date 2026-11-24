-- ============================================================================================================
-- Migration: 2539_ipd_tpa_schema.sql
-- IPD Phase 6 - Insurance / TPA (manual TPA workflow; NHCX later): tables, document checklist master, ledgers,
-- payer split functions and the TPA ledger postings. Procedures in 2540, billing changes in 2541, pages in 2542.
--   * IpdPreAuth + IpdPreAuthEvent: pre-authorisation of an insurance admission - request, query / reply, approval,
--     enhancement, final authorisation, rejection - every step with its time (IRDAI clock: cashless decision within
--     1 hour of the request, final discharge authorisation within 3 hours).
--   * Payer split of the final bill (2541): approved / final authorised amount, co-pay %, deductible, non-payables;
--     IpdBill.PayerShare goes to the TPA's receivable ledger, the rest is the patient's.
--   * IpdClaim: one claim per final bill with a payer share - document checklist, submission, query / reply,
--     settlements (bank amount, TDS, disallowance -> patient or write-off), write-off approval (Approval Matrix
--     IPD.TPAWRITEOFF, maker never approves). TPA receivable ledger per TPA under Sundry Debtors, ageing.
--   * IpdTpaDocType: Master > IPD Master > TPA Document Checklist (pre-auth / claim documents, mandatory flag).
-- Error numbers 58001-58299. Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. document checklist master ───────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdTpaDocType', 'U') IS NULL
CREATE TABLE dbo.IpdTpaDocType (
    DocTypeId   INT IDENTITY(1,1) CONSTRAINT PK_IpdTpaDocType PRIMARY KEY,
    CompanyId   INT NOT NULL,
    Name        NVARCHAR(150) NOT NULL,
    Stage       VARCHAR(10) NOT NULL CONSTRAINT DF_IpdTpaDocType_Stage DEFAULT ('CLAIM'),   -- PREAUTH | CLAIM | BOTH
    IsMandatory BIT NOT NULL CONSTRAINT DF_IpdTpaDocType_Mand DEFAULT (1),
    SortOrder   INT NOT NULL CONSTRAINT DF_IpdTpaDocType_Sort DEFAULT (100),
    IsActive    BIT NOT NULL CONSTRAINT DF_IpdTpaDocType_Active DEFAULT (1),
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdTpaDocType_Created DEFAULT (GETDATE()),
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_IpdTpaDocType_Name UNIQUE (CompanyId, Name),
    CONSTRAINT CK_IpdTpaDocType_Stage CHECK (Stage IN ('PREAUTH', 'CLAIM', 'BOTH'))
);
GO
-- the usual cashless file (IRDAI standard forms and what TPAs ask for); edit in the master
DECLARE @seed TABLE (Name NVARCHAR(150), Stage VARCHAR(10), Mand BIT, Sort INT);
INSERT @seed VALUES
 (N'Pre-authorisation request form (signed by the treating doctor)', 'PREAUTH', 1, 10),
 (N'Health card / e-card and policy copy', 'BOTH', 1, 20),
 (N'Patient photo ID proof (Aadhaar / PAN)', 'BOTH', 1, 30),
 (N'Doctor''s consultation / admission notes', 'PREAUTH', 1, 40),
 (N'Investigation reports supporting the diagnosis', 'BOTH', 1, 50),
 (N'Pre-authorisation approval letter(s) / final authorisation letter', 'CLAIM', 1, 110),
 (N'Claim form Part B (hospital), signed and stamped', 'CLAIM', 1, 120),
 (N'Final bill with detailed break-up', 'CLAIM', 1, 130),
 (N'Discharge summary', 'CLAIM', 1, 140),
 (N'Pharmacy bills with prescriptions', 'CLAIM', 0, 150),
 (N'Indoor case papers', 'CLAIM', 0, 160),
 (N'OT notes / implant invoices and stickers', 'CLAIM', 0, 170),
 (N'Patient payment receipts (co-pay / non-payables)', 'CLAIM', 0, 180),
 (N'MLC / FIR copy (accident cases)', 'BOTH', 0, 190);
INSERT dbo.IpdTpaDocType (CompanyId, Name, Stage, IsMandatory, SortOrder)
SELECT c.CompanyId, s.Name, s.Stage, s.Mand, s.Sort
FROM dbo.CompanyMaster c CROSS JOIN @seed s
WHERE c.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM dbo.IpdTpaDocType t WHERE t.CompanyId = c.CompanyId);
GO

-- ── 2. pre-authorisation ───────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdPreAuth', 'U') IS NULL
CREATE TABLE dbo.IpdPreAuth (
    PreAuthId            INT IDENTITY(1,1) CONSTRAINT PK_IpdPreAuth PRIMARY KEY,
    CompanyId            INT NOT NULL,
    BranchId             INT NOT NULL,
    AdmissionId          INT NOT NULL CONSTRAINT FK_IpdPreAuth_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
    PayerId              INT NULL,                       -- IpdAdmissionPayer row
    InsuranceTpaId       INT NOT NULL,
    PreAuthNo            NVARCHAR(40) NOT NULL,          -- IPA/<branch>/<FY>/000001
    TpaRefNo             NVARCHAR(60) NULL,              -- the TPA's / insurer's reference (claim / authorisation no.)
    PolicyNo             NVARCHAR(60) NULL,
    MemberId             NVARCHAR(60) NULL,
    Status               VARCHAR(20) NOT NULL CONSTRAINT DF_IpdPreAuth_Status DEFAULT ('DRAFT'),
    PrevStatus           VARCHAR(20) NULL,               -- the stage a QUERY came on
    IsLive               BIT NOT NULL CONSTRAINT DF_IpdPreAuth_Live DEFAULT (1),   -- 0 = REJECTED / CANCELLED
    Diagnosis            NVARCHAR(300) NULL,
    TreatmentPlan        NVARCHAR(500) NULL,             -- line of treatment / procedure
    ExpectedDays         INT NULL,
    EstimatedAmount      DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdPreAuth_Est DEFAULT (0),
    RequestedAmount      DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdPreAuth_Req DEFAULT (0),
    ApprovedAmount       DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdPreAuth_App DEFAULT (0),   -- total approved so far (incl. enhancements)
    EnhancementRequested DECIMAL(18,2) NULL,
    FinalRequestedAmount DECIMAL(18,2) NULL,
    FinalApprovedAmount  DECIMAL(18,2) NULL,
    CoPayPercent         DECIMAL(5,2) NOT NULL CONSTRAINT DF_IpdPreAuth_CoPay DEFAULT (0),
    Deductible           DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdPreAuth_Ded DEFAULT (0),
    NonPayable           DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdPreAuth_NonPay DEFAULT (0),
    SplitRemarks         NVARCHAR(300) NULL,
    RequestedAt          DATETIME NULL,                  -- IRDAI clock
    DecisionAt           DATETIME NULL,
    FinalRequestedAt     DATETIME NULL,
    FinalDecisionAt      DATETIME NULL,
    Remarks              NVARCHAR(500) NULL,
    CancelReason         NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdPreAuth_Created DEFAULT (GETDATE()),
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT CK_IpdPreAuth_Status CHECK (Status IN ('DRAFT', 'REQUESTED', 'QUERY', 'APPROVED', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED', 'FINAL_APPROVED', 'REJECTED', 'CANCELLED')),
    CONSTRAINT CK_IpdPreAuth_Split CHECK (CoPayPercent BETWEEN 0 AND 100 AND Deductible >= 0 AND NonPayable >= 0)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_IpdPreAuth_Live' AND object_id = OBJECT_ID('dbo.IpdPreAuth'))
    CREATE UNIQUE INDEX UX_IpdPreAuth_Live ON dbo.IpdPreAuth (AdmissionId) WHERE IsLive = 1;   -- one live pre-auth per admission
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdPreAuth_Branch' AND object_id = OBJECT_ID('dbo.IpdPreAuth'))
    CREATE INDEX IX_IpdPreAuth_Branch ON dbo.IpdPreAuth (BranchId, Status);
GO
IF OBJECT_ID('dbo.IpdPreAuthEvent', 'U') IS NULL
CREATE TABLE dbo.IpdPreAuthEvent (
    EventId     INT IDENTITY(1,1) CONSTRAINT PK_IpdPreAuthEvent PRIMARY KEY,
    PreAuthId   INT NOT NULL CONSTRAINT FK_IpdPreAuthEvent_PA REFERENCES dbo.IpdPreAuth (PreAuthId),
    EventType   VARCHAR(20) NOT NULL,   -- REQUEST QUERY QUERY_REPLY APPROVAL REJECTION ENHANCE_REQUEST FINAL_REQUEST FINAL_APPROVAL CANCEL NOTE
    EventAt     DATETIME NOT NULL,
    Amount      DECIMAL(18,2) NULL,
    RefNo       NVARCHAR(60) NULL,
    Remarks     NVARCHAR(500) NULL,
    FromStatus  VARCHAR(20) NULL,
    ToStatus    VARCHAR(20) NULL,
    DocumentId  INT NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdPreAuthEvent_Created DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdPreAuthEvent_PA' AND object_id = OBJECT_ID('dbo.IpdPreAuthEvent'))
    CREATE INDEX IX_IpdPreAuthEvent_PA ON dbo.IpdPreAuthEvent (PreAuthId, EventAt);
GO

-- ── 3. the bill's payer split (2541 fills it) ────────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.IpdBill', 'PayerShare') IS NULL
    ALTER TABLE dbo.IpdBill ADD
        InsuranceTpaId  INT NULL,
        PreAuthId       INT NULL,
        PayerAuthorised DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_PayerAuth DEFAULT (0),
        CoPayPercent    DECIMAL(5,2) NOT NULL CONSTRAINT DF_IpdBill_CoPayPct DEFAULT (0),
        CoPayAmount     DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_CoPayAmt DEFAULT (0),
        Deductible      DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_Ded DEFAULT (0),
        NonPayable      DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_NonPay DEFAULT (0),
        PayerShare      DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_PayerShare DEFAULT (0),   -- billed to the TPA
        PayerToPatient  DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_PayerToPat DEFAULT (0);  -- disallowed later, recovered from the patient
GO

-- ── 4. documents of a pre-auth / claim (the admission's documents, so they also show on Documents & Consents) ────
IF COL_LENGTH('dbo.IpdDocument', 'PreAuthId') IS NULL
    ALTER TABLE dbo.IpdDocument ADD PreAuthId INT NULL, ClaimId INT NULL, TpaDocTypeId INT NULL;
GO

-- ── 5. claims ──────────────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.IpdClaim', 'U') IS NULL
CREATE TABLE dbo.IpdClaim (
    ClaimId          INT IDENTITY(1,1) CONSTRAINT PK_IpdClaim PRIMARY KEY,
    CompanyId        INT NOT NULL,
    BranchId         INT NOT NULL,
    AdmissionId      INT NOT NULL CONSTRAINT FK_IpdClaim_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
    BillId           INT NOT NULL CONSTRAINT FK_IpdClaim_Bill REFERENCES dbo.IpdBill (BillId),
    PreAuthId        INT NULL,
    InsuranceTpaId   INT NOT NULL,
    ClaimNo          NVARCHAR(40) NOT NULL,          -- CLM/<branch>/<FY>/000001
    TpaClaimRef      NVARCHAR(60) NULL,
    ClaimAmount      DECIMAL(18,2) NOT NULL,         -- = bill payer share
    Status           VARCHAR(20) NOT NULL CONSTRAINT DF_IpdClaim_Status DEFAULT ('OPEN'),
    PrevStatus       VARCHAR(20) NULL,
    IsLive           BIT NOT NULL CONSTRAINT DF_IpdClaim_Live DEFAULT (1),
    SubmittedAt      DATETIME NULL,
    SubmissionMode   VARCHAR(20) NULL,               -- PORTAL | COURIER | EMAIL | HAND | NHCX (later)
    SubmissionRef    NVARCHAR(100) NULL,             -- portal acknowledgement / docket no.
    SettledAmount    DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaim_Settled DEFAULT (0),
    TdsAmount        DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaim_Tds DEFAULT (0),
    DisallowedAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaim_Dis DEFAULT (0),     -- to patient + written off + write-off pending
    ToPatientAmount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaim_ToPat DEFAULT (0),
    WrittenOffAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaim_WO DEFAULT (0),
    LastSettledAt    DATE NULL,
    Remarks          NVARCHAR(500) NULL,
    CancelReason     NVARCHAR(300) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdClaim_Created DEFAULT (GETDATE()),
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT CK_IpdClaim_Status CHECK (Status IN ('OPEN', 'SUBMITTED', 'QUERY', 'PART_SETTLED', 'SETTLED', 'CANCELLED'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_IpdClaim_Bill' AND object_id = OBJECT_ID('dbo.IpdClaim'))
    CREATE UNIQUE INDEX UX_IpdClaim_Bill ON dbo.IpdClaim (BillId) WHERE IsLive = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_IpdClaim_Tpa' AND object_id = OBJECT_ID('dbo.IpdClaim'))
    CREATE INDEX IX_IpdClaim_Tpa ON dbo.IpdClaim (BranchId, InsuranceTpaId, Status);
GO
IF OBJECT_ID('dbo.IpdClaimEvent', 'U') IS NULL
CREATE TABLE dbo.IpdClaimEvent (
    EventId    INT IDENTITY(1,1) CONSTRAINT PK_IpdClaimEvent PRIMARY KEY,
    ClaimId    INT NOT NULL CONSTRAINT FK_IpdClaimEvent_Claim REFERENCES dbo.IpdClaim (ClaimId),
    EventType  VARCHAR(25) NOT NULL,   -- CREATED SUBMITTED QUERY QUERY_REPLY NOTE SETTLEMENT SETTLEMENT_CANCEL WRITEOFF_REQUEST WRITEOFF_APPROVED WRITEOFF_REJECTED CANCELLED
    EventAt    DATETIME NOT NULL,
    Amount     DECIMAL(18,2) NULL,
    RefNo      NVARCHAR(100) NULL,
    Remarks    NVARCHAR(500) NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdClaimEvent_Created DEFAULT (GETDATE())
);
GO
IF OBJECT_ID('dbo.IpdTpaChecklist', 'U') IS NULL
CREATE TABLE dbo.IpdTpaChecklist (
    ChecklistId INT IDENTITY(1,1) CONSTRAINT PK_IpdTpaChecklist PRIMARY KEY,
    PreAuthId   INT NULL,
    ClaimId     INT NULL,
    DocTypeId   INT NOT NULL CONSTRAINT FK_IpdTpaChecklist_Type REFERENCES dbo.IpdTpaDocType (DocTypeId),
    IsDone      BIT NOT NULL CONSTRAINT DF_IpdTpaChecklist_Done DEFAULT (0),
    DocumentId  INT NULL,
    Remarks     NVARCHAR(300) NULL,
    CheckedBy INT NULL, CheckedAt DATETIME NULL,
    CONSTRAINT CK_IpdTpaChecklist_Ref CHECK ((PreAuthId IS NULL AND ClaimId IS NOT NULL) OR (PreAuthId IS NOT NULL AND ClaimId IS NULL))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_IpdTpaChecklist_PA' AND object_id = OBJECT_ID('dbo.IpdTpaChecklist'))
    CREATE UNIQUE INDEX UX_IpdTpaChecklist_PA ON dbo.IpdTpaChecklist (PreAuthId, DocTypeId) WHERE PreAuthId IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_IpdTpaChecklist_Claim' AND object_id = OBJECT_ID('dbo.IpdTpaChecklist'))
    CREATE UNIQUE INDEX UX_IpdTpaChecklist_Claim ON dbo.IpdTpaChecklist (ClaimId, DocTypeId) WHERE ClaimId IS NOT NULL;
GO
IF OBJECT_ID('dbo.IpdClaimSettlement', 'U') IS NULL
CREATE TABLE dbo.IpdClaimSettlement (
    SettlementId     INT IDENTITY(1,1) CONSTRAINT PK_IpdClaimSettlement PRIMARY KEY,
    ClaimId          INT NOT NULL CONSTRAINT FK_IpdClaimSettlement_Claim REFERENCES dbo.IpdClaim (ClaimId),
    SettlementNo     NVARCHAR(40) NOT NULL,          -- TPS/<branch>/<FY>/000001
    SettledOn        DATE NOT NULL,
    Mode             NVARCHAR(100) NULL,             -- payment method name (NEFT, RTGS, cheque ...)
    UtrNo            NVARCHAR(60) NULL,
    Amount           DECIMAL(18,2) NOT NULL,         -- received in the bank
    TdsAmount        DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaimSet_Tds DEFAULT (0),
    DisallowedAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdClaimSet_Dis DEFAULT (0),
    DisallowReason   NVARCHAR(300) NULL,
    DisallowAction   VARCHAR(10) NULL,               -- PATIENT (recover from the patient) | WRITEOFF (approval)
    Remarks          NVARCHAR(300) NULL,
    Status           VARCHAR(10) NOT NULL CONSTRAINT DF_IpdClaimSet_Status DEFAULT ('POSTED'),   -- POSTED | CANCELLED
    ReceiptTxnId     BIGINT NULL,
    PatientTxnId     BIGINT NULL,
    WriteOffId       INT NULL,
    CancelReason     NVARCHAR(300) NULL, CancelledBy INT NULL, CancelledAt DATETIME NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL CONSTRAINT DF_IpdClaimSet_Created DEFAULT (GETDATE()),
    CONSTRAINT CK_IpdClaimSet_Amounts CHECK (Amount >= 0 AND TdsAmount >= 0 AND DisallowedAmount >= 0 AND Amount + TdsAmount + DisallowedAmount > 0),
    CONSTRAINT CK_IpdClaimSet_Action CHECK (DisallowAction IS NULL OR DisallowAction IN ('PATIENT', 'WRITEOFF'))
);
GO
IF OBJECT_ID('dbo.IpdClaimWriteOff', 'U') IS NULL
CREATE TABLE dbo.IpdClaimWriteOff (
    WriteOffId      INT IDENTITY(1,1) CONSTRAINT PK_IpdClaimWriteOff PRIMARY KEY,
    ClaimId         INT NOT NULL CONSTRAINT FK_IpdClaimWriteOff_Claim REFERENCES dbo.IpdClaim (ClaimId),
    SettlementId    INT NULL,
    Amount          DECIMAL(18,2) NOT NULL,
    Reason          NVARCHAR(300) NOT NULL,
    Status          VARCHAR(10) NOT NULL CONSTRAINT DF_IpdClaimWO_Status DEFAULT ('PENDING'),   -- PENDING APPROVED REJECTED CANCELLED
    RequestedBy INT NULL, RequestedAt DATETIME NOT NULL CONSTRAINT DF_IpdClaimWO_Req DEFAULT (GETDATE()),
    DecidedBy INT NULL, DecidedAt DATETIME NULL, DecisionRemarks NVARCHAR(300) NULL,
    TxnId           BIGINT NULL,
    CONSTRAINT CK_IpdClaimWO_Amount CHECK (Amount > 0)
);
GO

-- ── 6. ledgers: TDS receivable, claim write-off; TPA ledgers are made on first use (usp_Ipd_TpaLedger) ──────────
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'IPD_TDS_RECV')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'TDS Receivable (TPA / Insurance)', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'IPD_TDS_RECV', 'TAX', 1, N'TDS deducted by TPAs / insurers on IPD claim settlements (claim it in the income-tax return).'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Assets';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'IPD_TPA_WRITEOFF')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT N'TPA Claim Disallowance Written Off', LedgerGroupId, 0, 'Dr', 1, GETDATE(), 'IPD_TPA_WRITEOFF', 'EXPENSE', 1, N'IPD claim amounts disallowed by the TPA and written off after approval.'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
GO

-- ── 7. approval matrix module for claim write-offs ──────────────────────────────────────────────────────────────
MERGE dbo.ApprovalModule AS t
USING (VALUES ('IPD.TPAWRITEOFF', N'IPD TPA Claim Write-off', 110)) s (Code, Name, Sort)
ON t.Module_Code = s.Code
WHEN NOT MATCHED THEN INSERT (Module_Code, Module_Name, Sort_Order, IsActive) VALUES (s.Code, s.Name, s.Sort, 1);
GO

-- ── 8. payer split ─────────────────────────────────────────────────────────────────────────────────────────────
-- the authorised amount of an admission's live pre-auth (cashless only once something is approved)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PreAuthAuthorised (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT TOP 1 pa.PreAuthId, pa.InsuranceTpaId, pa.PreAuthNo, pa.Status,
           CAST(CASE WHEN pa.Status = 'FINAL_APPROVED' THEN ISNULL(pa.FinalApprovedAmount, 0) ELSE pa.ApprovedAmount END AS DECIMAL(18,2)) AS Authorised,
           pa.CoPayPercent, pa.Deductible, pa.NonPayable
    FROM dbo.IpdPreAuth pa
    WHERE pa.AdmissionId = @AdmissionId AND pa.IsLive = 1
      AND pa.Status IN ('APPROVED', 'ENHANCE_REQUESTED', 'FINAL_REQUESTED', 'FINAL_APPROVED', 'QUERY')
      AND (pa.ApprovedAmount > 0 OR ISNULL(pa.FinalApprovedAmount, 0) > 0)
    ORDER BY pa.PreAuthId DESC
);
GO
-- payer share of a bill amount: (net - non-payables - deductible) less co-pay, capped at the authorised amount
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PayerSplit (@Net DECIMAL(18,2), @Authorised DECIMAL(18,2), @CoPayPercent DECIMAL(5,2), @Deductible DECIMAL(18,2), @NonPayable DECIMAL(18,2))
RETURNS TABLE
AS RETURN
(
    SELECT x.Base, x.CoPayAmount, x.Claimable,
           CAST(CASE WHEN x.Claimable <= 0 OR ISNULL(@Authorised, 0) <= 0 THEN 0
                     WHEN x.Claimable > @Authorised THEN @Authorised ELSE x.Claimable END AS DECIMAL(18,2)) AS PayerShare
    FROM (SELECT b.Base, CAST(ROUND(b.Base * ISNULL(@CoPayPercent, 0) / 100.0, 2) AS DECIMAL(18,2)) AS CoPayAmount,
                 CAST(b.Base - ROUND(b.Base * ISNULL(@CoPayPercent, 0) / 100.0, 2) AS DECIMAL(18,2)) AS Claimable
          FROM (SELECT CAST(CASE WHEN ISNULL(@Net, 0) - ISNULL(@NonPayable, 0) - ISNULL(@Deductible, 0) > 0
                                 THEN ISNULL(@Net, 0) - ISNULL(@NonPayable, 0) - ISNULL(@Deductible, 0) ELSE 0 END AS DECIMAL(18,2)) AS Base) b) x
);
GO
-- what the payer pays of an admission (always one row): after the final bill the bill's share (less what was later
-- moved to the patient); before it, the live pre-auth's split of @Net (insurance admissions only); else 0
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PayerShare (@AdmissionId INT, @Net DECIMAL(18,2))
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(CASE WHEN bl.BillId IS NOT NULL THEN bl.PayerShare - bl.PayerToPatient
                            WHEN a.PayerType = 'INSURANCE' AND a.BillId IS NULL THEN sp.PayerShare END, 0) AS DECIMAL(18,2)) AS PayerShare,
           pa.Authorised AS ApprovedAmount
    FROM (SELECT 1 AS One) o
    LEFT JOIN dbo.IpdAdmission a ON a.AdmissionId = @AdmissionId
    LEFT JOIN dbo.IpdBill bl ON bl.BillId = a.BillId AND bl.Status = 'FINAL'
    OUTER APPLY (SELECT TOP 1 Authorised, CoPayPercent, Deductible, NonPayable FROM dbo.fn_Ipd_PreAuthAuthorised(@AdmissionId)) pa
    OUTER APPLY dbo.fn_Ipd_PayerSplit(@Net, pa.Authorised, pa.CoPayPercent, pa.Deductible, pa.NonPayable) sp
);
GO

-- ── 9. the TPA's receivable ledger (Sundry Debtors), made on first use ─────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_TpaLedger @InsuranceTpaId INT, @LedgerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @code NVARCHAR(50) = CONCAT('IPD_TPA_', @InsuranceTpaId), @name NVARCHAR(200);
    SELECT @LedgerId = LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = @code;
    IF @LedgerId IS NOT NULL RETURN;
    SELECT @name = LEFT(Name, 160) + N' (TPA receivable)' FROM dbo.InsuranceTPAMaster WHERE InsuranceTPA_ID = @InsuranceTpaId;
    IF @name IS NULL THROW 58001, 'The insurance / TPA was not found (Master > Insurance / TPA).', 1;
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT @name, LedgerGroupId, 0, 'Dr', 1, GETDATE(), @code, 'PARTY', 1, N'IPD claims receivable from this insurance / TPA (IPD Phase 6).'
    FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Sundry Debtors';
    SET @LedgerId = SCOPE_IDENTITY();
    IF @LedgerId IS NULL THROW 58002, 'The ledger group "Sundry Debtors" is missing.', 1;
END;
GO

-- ── 10. TPA postings: SETTLE (RefId = settlement: bank + TDS against the TPA), TOPATIENT (settlement: disallowance
--        moved to the patient), WRITEOFF (RefId = write-off, after approval) ───────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostTpaLedger @Kind VARCHAR(10), @RefId INT, @UserId INT = NULL, @TransactionId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TransactionId = NULL;
    DECLARE @recv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @tdsL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'IPD_TDS_RECV'),
            @woL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerCode = 'IPD_TPA_WRITEOFF');
    DECLARE @co INT, @br INT, @tpa INT, @tpaL INT, @tpaName NVARCHAR(200), @claimNo NVARCHAR(40), @billNo NVARCHAR(40), @ip NVARCHAR(40), @party NVARCHAR(250),
            @date DATETIME, @amt DECIMAL(18,2), @tds DECIMAL(18,2), @dis DECIMAL(18,2), @mode NVARCHAR(100), @utr NVARCHAR(60), @no NVARCHAR(40),
            @narr NVARCHAR(400), @lines NVARCHAR(MAX), @tid BIGINT, @vno NVARCHAR(50), @claim INT;
    IF @Kind IN ('SETTLE', 'TOPATIENT')
        SELECT @claim = s.ClaimId, @date = CAST(s.SettledOn AS DATETIME), @amt = s.Amount, @tds = s.TdsAmount, @dis = s.DisallowedAmount, @mode = s.Mode, @utr = s.UtrNo, @no = s.SettlementNo
        FROM dbo.IpdClaimSettlement s WHERE s.SettlementId = @RefId AND s.Status = 'POSTED';
    ELSE IF @Kind = 'WRITEOFF'
        SELECT @claim = w.ClaimId, @date = ISNULL(w.DecidedAt, GETDATE()), @dis = w.Amount, @no = CONCAT(N'WO-', w.WriteOffId)
        FROM dbo.IpdClaimWriteOff w WHERE w.WriteOffId = @RefId AND w.Status = 'APPROVED';
    ELSE THROW 58010, 'Unknown TPA posting.', 1;
    IF @claim IS NULL RETURN;
    SELECT @co = c.CompanyId, @br = c.BranchId, @tpa = c.InsuranceTpaId, @claimNo = c.ClaimNo, @billNo = b.BillNo, @ip = a.IpNo,
           @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))), @tpaName = t.Name
    FROM dbo.IpdClaim c JOIN dbo.IpdBill b ON b.BillId = c.BillId JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId LEFT JOIN dbo.InsuranceTPAMaster t ON t.InsuranceTPA_ID = c.InsuranceTpaId
    WHERE c.ClaimId = @claim;
    EXEC dbo.usp_Ipd_TpaLedger @InsuranceTpaId = @tpa, @LedgerId = @tpaL OUTPUT;

    IF @Kind = 'SETTLE'
    BEGIN
        IF ISNULL(@amt, 0) + ISNULL(@tds, 0) <= 0 RETURN;
        IF @tds > 0 AND @tdsL IS NULL THROW 58011, 'The ledger "TDS Receivable (TPA / Insurance)" is missing (run SQLScripts/2539).', 1;
        DECLARE @modeCode NVARCHAR(30) = (SELECT TOP 1 UPPER(MethodCode) FROM dbo.PaymentMethodMaster WHERE MethodName = @mode OR UPPER(MethodCode) = UPPER(@mode));
        DECLARE @modeL INT = dbo.fn_Acc_ModeLedger(@br, ISNULL(@modeCode, 'NEFT'), CASE WHEN @modeCode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'TPA settlement ', @no, N' - claim ', @claimNo, N' (bill ', @billNo, N', ', @ip, N' - ', @party, N') - ', @tpaName, ISNULL(N' - UTR ' + @utr, N''));
        SET @lines = (SELECT LedgerId, Dr, Cr, Narration FROM (VALUES
                        (@modeL, @amt, CAST(0 AS DECIMAL(18,2)), N'Received from the TPA'),
                        (@tdsL, @tds, 0, N'TDS deducted by the TPA'),
                        (@tpaL, 0, @amt + @tds, N'Claim ' + @claimNo + N' settled')) v (LedgerId, Dr, Cr, Narration)
                      WHERE Dr > 0 OR Cr > 0 FOR JSON PATH);
        DECLARE @vt VARCHAR(5) = CASE WHEN @amt > 0 THEN 'RCT' ELSE 'JRN' END;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = @vt, @TransactionDate = @date, @CompanyId = @co, @BranchId = @br,
             @ReferenceType = 'IPD_TPASETTLE', @ReferenceId = @RefId, @Narration = @narr, @PayeeName = @tpaName, @PaymentMode = @modeCode, @InstrumentNo = @utr,
             @LinesJson = @lines, @IsManual = 0, @UserId = @UserId, @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE
    BEGIN
        IF ISNULL(@dis, 0) <= 0 RETURN;
        IF @Kind = 'TOPATIENT' AND @recv IS NULL THROW 58012, 'The ledger "Patient Receivable" is missing.', 1;
        IF @Kind = 'WRITEOFF' AND @woL IS NULL THROW 58013, 'The ledger "TPA Claim Disallowance Written Off" is missing (run SQLScripts/2539).', 1;
        SET @narr = CASE WHEN @Kind = 'TOPATIENT'
                         THEN CONCAT(N'Claim ', @claimNo, N' disallowance recovered from the patient - bill ', @billNo, N', ', @ip, N' - ', @party, N' (', @tpaName, N')')
                         ELSE CONCAT(N'Claim ', @claimNo, N' disallowance written off - bill ', @billNo, N', ', @ip, N' - ', @party, N' (', @tpaName, N')') END;
        SET @lines = (SELECT * FROM (VALUES (CASE WHEN @Kind = 'TOPATIENT' THEN @recv ELSE @woL END, @dis, CAST(0 AS DECIMAL(18,2)),
                                             CASE WHEN @Kind = 'TOPATIENT' THEN N'Now payable by the patient' ELSE N'Written off' END),
                                            (@tpaL, 0, @dis, N'Disallowed by the TPA')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        DECLARE @rt NVARCHAR(30) = CASE WHEN @Kind = 'TOPATIENT' THEN 'IPD_TPAPATIENT' ELSE 'IPD_TPAWRITEOFF' END;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt, @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    SET @TransactionId = @tid;
END;
GO

-- ── 11. claim totals and status from its settlements / write-offs ──────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_ClaimRefresh @ClaimId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE c SET
        SettledAmount = x.Settled, TdsAmount = x.Tds, ToPatientAmount = x.ToPatient,
        WrittenOffAmount = w.WrittenOff,
        DisallowedAmount = x.ToPatient + w.WrittenOff + w.Pending,
        LastSettledAt = x.LastOn,
        Status = CASE WHEN c.Status IN ('CANCELLED', 'OPEN') THEN c.Status
                      WHEN c.ClaimAmount - x.Settled - x.Tds - (x.ToPatient + w.WrittenOff + w.Pending) <= 0 THEN 'SETTLED'
                      WHEN c.Status = 'QUERY' THEN 'QUERY'
                      WHEN x.Settled + x.Tds + x.ToPatient + w.WrittenOff + w.Pending > 0 THEN 'PART_SETTLED'
                      ELSE 'SUBMITTED' END,
        ModifiedDate = GETDATE()
    FROM dbo.IpdClaim c
    CROSS APPLY (SELECT CAST(ISNULL(SUM(s.Amount), 0) AS DECIMAL(18,2)) AS Settled, CAST(ISNULL(SUM(s.TdsAmount), 0) AS DECIMAL(18,2)) AS Tds,
                        CAST(ISNULL(SUM(CASE WHEN s.DisallowAction = 'PATIENT' THEN s.DisallowedAmount ELSE 0 END), 0) AS DECIMAL(18,2)) AS ToPatient,
                        (SELECT MAX(z.SettledOn) FROM dbo.IpdClaimSettlement z WHERE z.ClaimId = c.ClaimId AND z.Status = 'POSTED') AS LastOn
                 FROM dbo.IpdClaimSettlement s WHERE s.ClaimId = c.ClaimId AND s.Status = 'POSTED') x
    CROSS APPLY (SELECT CAST(ISNULL(SUM(CASE WHEN o.Status = 'APPROVED' THEN o.Amount ELSE 0 END), 0) AS DECIMAL(18,2)) AS WrittenOff,
                        CAST(ISNULL(SUM(CASE WHEN o.Status = 'PENDING' THEN o.Amount ELSE 0 END), 0) AS DECIMAL(18,2)) AS Pending
                 FROM dbo.IpdClaimWriteOff o WHERE o.ClaimId = c.ClaimId) w
    WHERE c.ClaimId = @ClaimId;
    -- the bill: what the TPA no longer owes and the patient now does
    UPDATE b SET PayerToPatient = c.ToPatientAmount
    FROM dbo.IpdBill b JOIN dbo.IpdClaim c ON c.BillId = b.BillId WHERE c.ClaimId = @ClaimId;
END;
GO

PRINT 'Script 2539 applied: IPD Insurance / TPA schema, checklist master, ledgers, payer split.';
GO
