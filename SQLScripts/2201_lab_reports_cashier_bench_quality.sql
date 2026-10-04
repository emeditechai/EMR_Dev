-- ============================================================================
-- Migration: 2201_lab_reports_cashier_bench_quality.sql
-- Description: six more Reports > LAB registers from the LAB Reports Roadmap, on the shared register pattern
--   (one procedure per report returning Summary / Groups / Rows / Options, run through api/reports/lab/run/{report},
--   page on _LabReportShell + lab-report.js). Visibility: branch first (usp_LabReport_CheckAccess), Administrator /
--   super admin see every user's data, everyone else only their own (defined per report below).
--     LR-03 Cashier Day-end Closing         usp_Api_LabReport_CashierClosing     by receipt / refund date
--     LR-14 Work Pending by Stage           usp_Api_LabReport_WorkPending        by bill date, what waits now
--     LR-15 Turnaround Time (TAT)  QI       usp_Api_LabReport_Turnaround         by approval date (dbo.ufn_LabReport_TatUnits, 2200)
--     LR-16 Critical & Panic Value Register usp_Api_LabReport_CriticalValues     by result entry date
--     LR-17 Delta-check Exceptions          usp_Api_LabReport_DeltaCheck         by result entry date
--     LR-18 Abnormal Results Summary        usp_Api_LabReport_AbnormalResults    by result entry date, per week
--   Pages are added to the database navigation (Reports > LAB) with their VIEW endpoints. No role or user grant is
--   seeded: who may open them is set in Role Permissions. Read-only: nothing in billing, sample or result entry changes.
--   Run after 2200.
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ============================================================================
-- LR-03 Cashier Day-end Closing - what each cashier collected, by payment mode, less refunds paid out.
-- Money in: LAB money receipts taken at the branch (B2C, B2B spot and settlement payments) by receipt date, and franchise wallet top-ups
-- (branch from the receipt number; their payment mode is not recorded). Bills paid from a franchise wallet are listed
-- apart: no money changes hands at the counter. Refunds: LAB refunds paid out, by refund date and mode.
-- Net cash to hand over = cash received - cash refunded. Own data: their own collections and refunds.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CashierClosing
    @BranchId        INT,
    @FromDate        DATE,
    @ToDate          DATE,
    @PaymentMethodId INT           = NULL,
    @CollectedBy     INT           = NULL,
    @Search          NVARCHAR(100) = NULL,
    @UserId          INT           = NULL,
    @IsAdmin         BIT           = 0,
    @IsSuperAdmin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @OwnOnly = 1 SET @CollectedBy = @UserId;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    DECLARE @BranchCode NVARCHAR(20) = (SELECT BranchCode FROM dbo.Branchmaster WHERE BranchID = @BranchId);

    CREATE TABLE #E (
        EntryType   VARCHAR(10),       -- RECEIPT / TOPUP / WALLET / REFUND
        EntryOn     DATETIME,
        ReceiptNo   NVARCHAR(50),
        LabOrderId  INT NULL,
        BillNo      NVARCHAR(50) NULL,
        PartyName   NVARCHAR(250) NULL,
        PartyCode   NVARCHAR(50) NULL,
        IsB2B       BIT,
        MethodId    INT NULL,
        ModeName    NVARCHAR(100),
        Bucket      VARCHAR(10),       -- CASH / UPI / CARD / BANK / OTHER / TOPUP / WALLET
        Reference   NVARCHAR(200) NULL,
        Received    DECIMAL(18, 2),
        Refunded    DECIMAL(18, 2),
        WalletUsed  DECIMAL(18, 2),
        CashierId   INT NULL);

    -- LAB money receipts (a franchise wallet deduction is kept apart: WALLET-DEBIT-...)
    INSERT INTO #E
    SELECT CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 'WALLET' ELSE 'RECEIPT' END,
           COALESCE(pd.PaymentDate, pd.CreatedDate), pd.ReceiptNo, lo.LabOrderId, lo.BillNo,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))), p.PatientCode,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT), pd.PaymentMethodId,
           CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 'Franchise wallet' ELSE ISNULL(pm.MethodName, 'Unknown') END,
           CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 'WALLET'
                WHEN pm.MethodCode = 'CASH' THEN 'CASH' WHEN pm.MethodCode = 'UPI' THEN 'UPI' WHEN pm.MethodCode = 'CARD' THEN 'CARD'
                WHEN pm.MethodCode IN ('NEFT', 'CHEQUE') THEN 'BANK' ELSE 'OTHER' END,
           NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.ChequeNo, ''),
                                       CASE WHEN NULLIF(pd.CardLast4, '') IS NOT NULL THEN 'Card xx' + pd.CardLast4 END,
                                       CASE WHEN ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%' THEN pd.TransactionRef END, ''))), ''),
           CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN 0 ELSE pd.PaidAmount END, 0,
           CASE WHEN ISNULL(pd.TransactionRef, '') LIKE 'WALLET-DEBIT-%' THEN pd.PaidAmount ELSE 0 END,
           pd.CreatedBy
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.ModuleCode = 'LAB' AND ph.IsActive = 1
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = ph.ModuleRefId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    WHERE pd.IsActive = 1 AND ph.BranchId = @BranchId   -- the branch where the money was taken
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @From AND COALESCE(pd.PaymentDate, pd.CreatedDate) < @To;

    -- franchise wallet top-ups taken at this branch (the receipt number carries the branch code)
    INSERT INTO #E
    SELECT 'TOPUP', t.CreatedDate, t.ReceiptNo, NULL, NULL, f.Franchise_Name, f.Franchise_Code, 1, NULL,
           N'Wallet top-up (mode not recorded)', 'TOPUP', NULLIF(LTRIM(RTRIM(t.Narration)), ''), t.Amount, 0, 0, t.CreatedBy
    FROM dbo.LabFranchiseWalletTransaction t
    INNER JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = t.Franchise_ID
    WHERE t.TransactionType = 'CREDIT' AND t.ReferenceType = 'TOPUP'
      AND t.CreatedDate >= @From AND t.CreatedDate < @To
      AND @BranchCode IS NOT NULL AND t.ReceiptNo LIKE @BranchCode + '[0-9][0-9][0-9][0-9]%'
      AND LEN(t.ReceiptNo) = LEN(@BranchCode) + 12;

    -- refunds paid out
    INSERT INTO #E
    SELECT 'REFUND', r.RefundDate, bc.CancellationNo, lo.LabOrderId, lo.BillNo,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))), p.PatientCode,
           CAST(ISNULL(lo.IsB2B, 0) AS BIT), NULL, ISNULL(NULLIF(r.RefundMode, ''), 'Not recorded'),
           CASE WHEN r.RefundMode LIKE '%cash%' THEN 'CASH' WHEN r.RefundMode LIKE '%upi%' THEN 'UPI' WHEN r.RefundMode LIKE '%card%' THEN 'CARD'
                WHEN r.RefundMode LIKE '%neft%' OR r.RefundMode LIKE '%rtgs%' OR r.RefundMode LIKE '%bank%' OR r.RefundMode LIKE '%cheque%' THEN 'BANK'
                ELSE 'OTHER' END,
           NULLIF(LTRIM(RTRIM(r.TransactionRef)), ''), 0, r.RefundAmount, 0, r.CreatedBy
    FROM dbo.BillRefund r
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = r.ModuleRefId
    LEFT  JOIN dbo.BillCancellation bc ON bc.CancellationId = r.CancellationId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    WHERE r.ModuleCode = 'LAB' AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P' AND lo.BranchId = @BranchId
      AND r.RefundDate >= @From AND r.RefundDate < @To;

    DELETE FROM #E
    WHERE (@CollectedBy IS NOT NULL AND ISNULL(CashierId, -1) <> @CollectedBy)
       OR (@PaymentMethodId IS NOT NULL AND ISNULL(MethodId, -1) <> @PaymentMethodId)
       OR (@Search IS NOT NULL AND NOT (ISNULL(ReceiptNo, '') LIKE '%' + @Search + '%' OR ISNULL(BillNo, '') LIKE '%' + @Search + '%'
                                       OR ISNULL(PartyName, '') LIKE '%' + @Search + '%' OR ISNULL(PartyCode, '') LIKE '%' + @Search + '%'
                                       OR ISNULL(Reference, '') LIKE '%' + @Search + '%'));

    SELECT e.*, CONVERT(VARCHAR(10), CAST(e.EntryOn AS DATE), 23) AS EntryDay,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'Not recorded')) AS Cashier
    INTO #R
    FROM #E e LEFT JOIN dbo.Users u ON u.Id = e.CashierId;
    ALTER TABLE #R ADD CashierDay NVARCHAR(300);
    UPDATE #R SET CashierDay = Cashier + N' · ' + FORMAT(CAST(EntryOn AS DATE), 'dd MMM yyyy');

    -- RS1 summary
    SELECT SUM(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN 1 ELSE 0 END) AS Receipts,
           ISNULL(SUM(Received), 0) AS TotalReceived,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received END), 0) AS Cash,
           ISNULL(SUM(CASE WHEN Bucket = 'UPI' THEN Received END), 0) AS Upi,
           ISNULL(SUM(CASE WHEN Bucket = 'CARD' THEN Received END), 0) AS Card,
           ISNULL(SUM(CASE WHEN Bucket = 'BANK' THEN Received END), 0) AS Bank,
           ISNULL(SUM(CASE WHEN Bucket = 'OTHER' THEN Received END), 0) AS Other,
           ISNULL(SUM(CASE WHEN Bucket = 'TOPUP' THEN Received END), 0) AS TopUps,
           ISNULL(SUM(Refunded), 0) AS Refunds,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Refunded END), 0) AS CashRefunds,
           SUM(CASE WHEN EntryType = 'REFUND' THEN 1 ELSE 0 END) AS RefundCount,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received - Refunded END), 0) AS NetCash,
           ISNULL(SUM(WalletUsed), 0) AS WalletUsed,
           SUM(CASE WHEN EntryType = 'WALLET' THEN 1 ELSE 0 END) AS WalletBills,
           COUNT(DISTINCT CashierId) AS Cashiers,
           MIN(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END) AS FirstReceiptNo,
           MAX(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END) AS LastReceiptNo
    FROM #R;

    -- RS2 groups: per cashier (the hand-over), cashier x day, payment mode, day
    ;WITH g AS (
        SELECT 'byCashier' AS GroupKey, CashierId AS GroupId, Cashier AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL
        SELECT 'byCashierDay', CashierId, CashierDay, DATEDIFF(DAY, '2000-01-01', EntryOn), * FROM #R
        UNION ALL
        SELECT 'byMode', NULL, ModeName, CASE Bucket WHEN 'CASH' THEN 1 WHEN 'UPI' THEN 2 WHEN 'CARD' THEN 3 WHEN 'BANK' THEN 4 WHEN 'OTHER' THEN 5 WHEN 'TOPUP' THEN 6 ELSE 7 END, * FROM #R
        UNION ALL
        SELECT 'byDate', NULL, EntryDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           SUM(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN 1 ELSE 0 END) AS Receipts,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received END), 0) AS Cash,
           ISNULL(SUM(CASE WHEN Bucket = 'UPI' THEN Received END), 0) AS Upi,
           ISNULL(SUM(CASE WHEN Bucket = 'CARD' THEN Received END), 0) AS Card,
           ISNULL(SUM(CASE WHEN Bucket = 'BANK' THEN Received END), 0) AS Bank,
           ISNULL(SUM(CASE WHEN Bucket = 'OTHER' THEN Received END), 0) AS Other,
           ISNULL(SUM(CASE WHEN Bucket = 'TOPUP' THEN Received END), 0) AS TopUps,
           ISNULL(SUM(Received), 0) AS TotalReceived,
           ISNULL(SUM(Refunded), 0) AS Refunds,
           ISNULL(SUM(CASE WHEN Bucket = 'CASH' THEN Received - Refunded END), 0) AS NetCash,
           ISNULL(SUM(WalletUsed), 0) AS WalletUsed,
           CASE WHEN MIN(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END) IS NULL THEN NULL
                WHEN MIN(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END) = MAX(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END)
                    THEN MIN(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END)
                ELSE MIN(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END) + N' – ' + MAX(CASE WHEN EntryType IN ('RECEIPT', 'TOPUP') THEN ReceiptNo END) END AS ReceiptRange
    FROM g
    GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), SUM(Received) DESC, GroupName;

    -- RS3 rows: in time order (the cashier's day as it happened)
    SELECT * FROM #R ORDER BY EntryOn, ReceiptNo;

    -- RS4 filter options
    SELECT 'paymentMethodId' AS FilterKey, CAST(PaymentMethodId AS VARCHAR(20)) AS Value, MethodName AS Text
    FROM dbo.PaymentMethodMaster WHERE IsActive = 1
    UNION
    SELECT DISTINCT 'collectedBy', CAST(CashierId AS VARCHAR(20)), Cashier FROM #R WHERE CashierId IS NOT NULL;

    DROP TABLE #R; DROP TABLE #E;
END;
GO

-- ============================================================================
-- LR-14 Work Pending by Stage - every collected test of the branch not yet fully approved, at the stage it waits in:
-- Pending entry -> Draft -> Submitted -> Validated, awaiting approval level n of N (the approval flow of its
-- department / category). A profile is one test, at the stage of its least advanced parameter. Outsourced tests are
-- in LR-13. Waiting = hours since the test reached its stage; TAT due = received at lab + the test's TAT hours.
-- Date filter: bill date. Own data (strict rule until confirmed): tests they entered, and tests waiting for their
-- signature at the current level (dbo.ufn_LabPathologistScope).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_WorkPending
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Stage         VARCHAR(20)   = NULL,   -- PENDING / DRAFT / SUBMITTED / AWAIT_L1 / AWAIT_L2 / AWAIT_L3 / AWAITING
    @WaitBand      VARCHAR(10)   = NULL,   -- 0-2 / 2-6 / 6-24 / 24+
    @DepartmentId  INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME)), @Now DATETIME = GETDATE();
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Stage = NULLIF(UPPER(LTRIM(RTRIM(@Stage))), '');
    SET @WaitBand = NULLIF(LTRIM(RTRIM(@WaitBand)), '');
    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.Branchmaster WHERE BranchID = @BranchId);

    -- the parameters (sample rows) this branch holds, collected and not fully approved
    SELECT sc.samplecollectionID AS SampleId, sc.Laborderid AS LabOrderId, sc.ProfileId,
           CASE WHEN sc.ProfileId IS NOT NULL THEN -sc.ProfileId ELSE sc.samplecollectionID END AS UnitKey,
           COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DepartmentId,
           COALESCE(NULLIF(sc.TestcategoryID, 0), lim.Category_ID) AS CategoryId,
           COALESCE(NULLIF(sc.ProfileName, ''), lim.Test_Name) AS TestName, lim.Test_Code, lim.TAT_Hours,
           CAST(ISNULL(sc.IsTransferred, 0) AS INT) AS IsTransferred,
           CASE WHEN ISNULL(sc.IsTransferred, 0) = 1 AND sc.ReceivedDate IS NOT NULL THEN sc.ReceivedDate
                ELSE COALESCE(col.ChangedOn, CAST(sc.Samplecollectiondate AS DATETIME) + CAST(ISNULL(sc.Samplecollectiontime, '00:00') AS DATETIME)) END AS ReceivedOn,
           -- 1 pending entry, 2 draft, 3 submitted, 4 validated (awaiting approval), 9 approved
           CASE WHEN led.LabEntryDetailId IS NULL THEN 1
                WHEN led.ReportStatusId = 5 THEN 9
                WHEN led.ReportStatusId = 3 THEN 4
                WHEN led.ReportStatusId = 2 THEN 3
                WHEN led.ReportStatusId = 1 THEN 2
                WHEN LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> '' OR led.Template_Html IS NOT NULL THEN 2
                ELSE 1 END AS RowStage,
           COALESCE(led.Drafted_Date, led.CreatedDate) AS DraftedOn, led.Submitted_Date, COALESCE(led.Validated_date, led.Submitted_Date) AS ValidatedOn,
           led.CreatedBy AS EnteredById, led.ModifiedBy AS UpdatedById,
           (SELECT COUNT(1) FROM dbo.LabReportApproval a WHERE a.SamplecollectionID = sc.samplecollectionID) AS LevelsDone,
           (SELECT MAX(a.ApprovedDate) FROM dbo.LabReportApproval a WHERE a.SamplecollectionID = sc.samplecollectionID) AS LastSignedOn
    INTO #P
    FROM dbo.SampleCollection sc
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = sc.Laborderid AND lo.IsActive = 1
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = sc.InvestigationID
    LEFT  JOIN dbo.labentrydetails led ON led.SamplecollectionID = sc.samplecollectionID AND led.IsActive = 1
    OUTER APPLY (SELECT TOP 1 l.ChangedOn FROM dbo.LabSampleStatusLog l
                  WHERE l.SampleCollectionId = sc.samplecollectionID AND l.ToStatusId = 2 ORDER BY l.ChangedOn DESC, l.LogId DESC) col
    WHERE sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0 AND ISNULL(sc.IsoutSource, 0) = 0
      AND sc.CollectionstatusID = 2
      AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId AND ISNULL(sc.IsReceived, 0) = 1))
      AND lo.OrderDate >= @From AND lo.OrderDate < @To;

    -- approval flow of each waiting parameter: category beats department beats branch beats company (as ufn_LabPathologistScope)
    ALTER TABLE #P ADD TotalLevels INT NULL;
    UPDATE p SET TotalLevels = ISNULL(f.Required_Levels, 1)
    FROM #P p
    OUTER APPLY (SELECT TOP 1 f2.Required_Levels FROM dbo.LabApprovalFlow f2
                  WHERE f2.CompanyId = @CompanyId AND f2.IsDeleted = 0 AND f2.Status = 1
                    AND (f2.Branch_ID IS NULL OR f2.Branch_ID = @BranchId)
                    AND ((f2.Category_IDs IS NOT NULL AND p.CategoryId IS NOT NULL
                          AND EXISTS (SELECT 1 FROM STRING_SPLIT(f2.Category_IDs, ',') x WHERE TRY_CAST(LTRIM(RTRIM(x.value)) AS INT) = p.CategoryId))
                         OR (f2.Category_IDs IS NULL AND (f2.Department_ID IS NULL OR f2.Department_ID = p.DepartmentId)))
                  ORDER BY CASE WHEN f2.Category_IDs IS NOT NULL THEN 3 WHEN f2.Department_ID IS NOT NULL THEN 2 ELSE 1 END DESC,
                           CASE WHEN f2.Branch_ID IS NOT NULL THEN 1 ELSE 0 END DESC, f2.Flow_ID) f;

    -- tests waiting for this user's signature now (own-data rule for pathologists)
    SELECT s.SamplecollectionID INTO #Mine FROM dbo.ufn_LabPathologistScope(@UserId, @BranchId) s WHERE @OwnOnly = 1 AND s.CanApproveNow = 1;
    ALTER TABLE #P ADD IsMineToSign INT NOT NULL DEFAULT 0;
    UPDATE p SET IsMineToSign = 1 FROM #P p INNER JOIN #Mine m ON m.SamplecollectionID = p.SampleId;

    -- one line per test (a profile once), at its least advanced stage
    ;WITH u AS (
        SELECT LabOrderId, UnitKey, MIN(SampleId) AS FirstSampleId, MAX(ProfileId) AS ProfileId, MAX(DepartmentId) AS DepartmentId,
               MAX(TestName) AS TestName, MAX(Test_Code) AS TestCode, MAX(TAT_Hours) AS ParamTat, COUNT(1) AS Parameters,
               SUM(CASE WHEN RowStage = 9 THEN 1 ELSE 0 END) AS ParamsApproved,
               MIN(RowStage) AS UnitStage, MAX(IsTransferred) AS IsTransferred, MAX(ReceivedOn) AS ReceivedOn,
               MIN(CASE WHEN RowStage = 2 THEN DraftedOn END) AS DraftedOn,
               MIN(CASE WHEN RowStage = 3 THEN Submitted_Date END) AS SubmittedOn,
               MAX(CASE WHEN RowStage = 4 THEN COALESCE(LastSignedOn, ValidatedOn) END) AS AwaitSince,
               MIN(CASE WHEN RowStage = 4 THEN LevelsDone END) AS LevelsDone,
               MAX(CASE WHEN RowStage = 4 THEN TotalLevels END) AS TotalLevels,
               MAX(CASE WHEN EnteredById = @UserId OR UpdatedById = @UserId THEN 1 ELSE 0 END) AS IsMineEntered,
               MAX(IsMineToSign) AS IsMineToSign,
               MAX(EnteredById) AS EnteredById
        FROM #P
        GROUP BY LabOrderId, UnitKey
        HAVING MIN(RowStage) < 9)
    SELECT u.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BilledOn, CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
           p.PatientId, p.PatientCode,
           LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           u.FirstSampleId, COALESCE(h.Profile_Code, u.TestCode) AS TestCode, u.TestName, u.Parameters, u.ParamsApproved,
           u.DepartmentId, ISNULL(dm.DeptName, 'Not set') AS Department,
           CAST(u.IsTransferred AS BIT) AS IsTransferred,
           CASE u.UnitStage WHEN 1 THEN 'PENDING' WHEN 2 THEN 'DRAFT' WHEN 3 THEN 'SUBMITTED'
                ELSE 'AWAIT_L' + CAST(ISNULL(u.LevelsDone, 0) + 1 AS VARCHAR(2)) END AS Stage,
           CASE u.UnitStage WHEN 1 THEN 'Pending entry' WHEN 2 THEN 'Draft' WHEN 3 THEN 'Submitted'
                ELSE CASE WHEN ISNULL(u.LevelsDone, 0) = 0 THEN 'Validated · awaiting approval L1' ELSE 'Awaiting approval L' + CAST(u.LevelsDone + 1 AS VARCHAR(2)) END
                     + CASE WHEN ISNULL(u.TotalLevels, 1) > 1 THEN ' of ' + CAST(u.TotalLevels AS VARCHAR(2)) ELSE '' END END AS StageName,
           CASE WHEN u.UnitStage <= 3 THEN u.UnitStage ELSE 4 + ISNULL(u.LevelsDone, 0) END AS StageOrder,
           u.TotalLevels,
           CASE u.UnitStage WHEN 1 THEN u.ReceivedOn WHEN 2 THEN COALESCE(u.DraftedOn, u.ReceivedOn) WHEN 3 THEN COALESCE(u.SubmittedOn, u.ReceivedOn)
                ELSE COALESCE(u.AwaitSince, u.ReceivedOn) END AS StageSince,
           u.ReceivedOn,
           COALESCE(NULLIF(h.Profile_TAT_Hours, 0), NULLIF(hp.TAT_Hours, 0), NULLIF(u.ParamTat, 0)) AS TargetHours,
           CAST(CASE WHEN ISNULL(lo.IsUrgent, 0) = 1
                       OR EXISTS (SELECT 1 FROM dbo.LabOrderItem uli WHERE uli.LabOrderId = lo.LabOrderId AND uli.IsUrgent = 1 AND uli.IsActive = 1)
                     THEN 1 ELSE 0 END AS BIT) AS IsUrgent,
           NULLIF(LTRIM(RTRIM(eu.FullName)), '') AS EnteredBy
    INTO #R
    FROM u
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = u.LabOrderId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = u.DepartmentId
    LEFT  JOIN dbo.LabInvestigationProfileHeader h ON h.Profile_ID = u.ProfileId
    LEFT  JOIN dbo.LabInvestigationMaster hp ON hp.Test_ID = h.Test_ID
    LEFT  JOIN dbo.Users eu ON eu.Id = u.EnteredById
    WHERE (@OwnOnly = 0 OR u.IsMineEntered = 1 OR u.IsMineToSign = 1)
      AND (@DepartmentId IS NULL OR u.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR u.TestName LIKE '%' + @Search + '%' OR u.TestCode LIKE '%' + @Search + '%');

    ALTER TABLE #R ADD HoursWaiting DECIMAL(10, 1), HoursSinceReceipt DECIMAL(10, 1), WaitBand VARCHAR(10), TatDueOn DATETIME, IsOverdue BIT;
    UPDATE #R SET HoursWaiting = CAST(CASE WHEN StageSince <= @Now THEN DATEDIFF(MINUTE, StageSince, @Now) / 60.0 END AS DECIMAL(10, 1)),
                  HoursSinceReceipt = CAST(CASE WHEN ReceivedOn <= @Now THEN DATEDIFF(MINUTE, ReceivedOn, @Now) / 60.0 END AS DECIMAL(10, 1)),
                  TatDueOn = CASE WHEN TargetHours IS NOT NULL THEN DATEADD(HOUR, TargetHours, ReceivedOn) END;
    UPDATE #R SET WaitBand = CASE WHEN HoursWaiting IS NULL OR HoursWaiting < 2 THEN '0-2' WHEN HoursWaiting < 6 THEN '2-6' WHEN HoursWaiting < 24 THEN '6-24' ELSE '24+' END,
                  IsOverdue = CASE WHEN TatDueOn IS NOT NULL AND TatDueOn < @Now THEN 1 ELSE 0 END;

    IF @Stage = 'AWAITING' DELETE FROM #R WHERE Stage NOT LIKE 'AWAIT_L%';
    ELSE IF @Stage IS NOT NULL DELETE FROM #R WHERE Stage <> @Stage;
    IF @WaitBand IS NOT NULL DELETE FROM #R WHERE WaitBand <> @WaitBand;

    -- RS1 summary
    SELECT COUNT(1) AS PendingTests, COUNT(DISTINCT LabOrderId) AS BillCount,
           SUM(CASE WHEN Stage = 'PENDING' THEN 1 ELSE 0 END) AS PendingEntry,
           SUM(CASE WHEN Stage = 'DRAFT' THEN 1 ELSE 0 END) AS Draft,
           SUM(CASE WHEN Stage = 'SUBMITTED' THEN 1 ELSE 0 END) AS Submitted,
           SUM(CASE WHEN Stage LIKE 'AWAIT_L%' THEN 1 ELSE 0 END) AS AwaitingApproval,
           SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END) AS UrgentTests,
           SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) AS OverdueTests,
           MAX(HoursWaiting) AS OldestHours, CAST(AVG(HoursWaiting) AS DECIMAL(10, 1)) AS AvgHours
    FROM #R;

    -- RS2 groups: stage, department (a stage x department matrix), test, bill date
    ;WITH g AS (
        SELECT 'byStage' AS GroupKey, StageOrder AS GroupId, StageName AS GroupName, StageOrder AS SortOrder, * FROM #R
        UNION ALL SELECT 'byDepartment', DepartmentId, Department, 0, * FROM #R
        UNION ALL SELECT 'byTest', NULL, TestName, 0, * FROM #R
        UNION ALL SELECT 'byBillDate', NULL, BillDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS PendingTests,
           SUM(CASE WHEN Stage = 'PENDING' THEN 1 ELSE 0 END) AS PendingEntry,
           SUM(CASE WHEN Stage = 'DRAFT' THEN 1 ELSE 0 END) AS Draft,
           SUM(CASE WHEN Stage = 'SUBMITTED' THEN 1 ELSE 0 END) AS Submitted,
           SUM(CASE WHEN Stage LIKE 'AWAIT_L%' THEN 1 ELSE 0 END) AS AwaitingApproval,
           SUM(CASE WHEN IsUrgent = 1 THEN 1 ELSE 0 END) AS UrgentTests,
           SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) AS OverdueTests,
           MAX(HoursWaiting) AS OldestHours, CAST(AVG(HoursWaiting) AS DECIMAL(10, 1)) AS AvgHours
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), COUNT(1) DESC, GroupName;

    -- RS3 rows: urgent first, then the longest wait
    SELECT * FROM #R ORDER BY IsUrgent DESC, IsOverdue DESC, HoursWaiting DESC, LabOrderId;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL;

    DROP TABLE #R; DROP TABLE #P; DROP TABLE #Mine;
END;
GO

-- ============================================================================
-- LR-15 Turnaround Time (TAT) - NABL / NABH quality indicator. Tests approved in the period (a profile once), with every
-- stage timestamp: billed -> collected -> received at lab -> entered -> validated -> approved (dbo.ufn_LabReport_TatUnits).
-- Lab TAT = received at lab -> approval, against the profile's / test's TAT hours; a breach is a test over its hours.
-- Branch: the branch that tested it. Own data: tests they entered, updated or signed at any level.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_Turnaround
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @TatStatus     VARCHAR(10)   = NULL,   -- ONTIME / BREACH / NOTARGET / NOTIMED
    @DepartmentId  INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @TatStatus = NULLIF(UPPER(LTRIM(RTRIM(@TatStatus))), '');

    SELECT t.*, CONVERT(VARCHAR(10), CAST(t.ApprovedOn AS DATE), 23) AS ApprovedDay,
           ISNULL(dm.DeptName, 'Not set') AS Department,
           p.PatientCode, LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           CAST(CASE WHEN t.TatStatus = 'BREACH' THEN t.LabHours - t.TargetHours END AS DECIMAL(10, 1)) AS OverByHours,
           fa.ApprovedBy AS ApprovedById, ISNULL(NULLIF(LTRIM(RTRIM(au.FullName)), ''), au.Username) AS ApprovedBy, fa.TotalLevels,
           CASE WHEN t.TatStatus <> 'BREACH' THEN NULL
                -- where most of the time went: transport, bench (entry), validation or sign-off
                WHEN ISNULL(t.TransportHours, 0) >= ISNULL(t.BenchHours, 0) AND ISNULL(t.TransportHours, 0) >= ISNULL(t.ValidationHours, 0)
                     AND ISNULL(t.TransportHours, 0) >= ISNULL(t.SignoffHours, 0) AND ISNULL(t.TransportHours, 0) > 0 THEN 'Transport'
                WHEN ISNULL(t.BenchHours, 0) >= ISNULL(t.ValidationHours, 0) AND ISNULL(t.BenchHours, 0) >= ISNULL(t.SignoffHours, 0) THEN 'Result entry'
                WHEN ISNULL(t.ValidationHours, 0) >= ISNULL(t.SignoffHours, 0) THEN 'Validation'
                ELSE 'Sign-off' END AS DelayStage
    INTO #R
    FROM dbo.ufn_LabReport_TatUnits(@From, @To) t
    INNER JOIN dbo.PatientMaster p ON p.PatientId = t.PatientId
    LEFT  JOIN dbo.DepartmentMaster dm ON dm.DeptId = t.DepartmentId
    OUTER APPLY (SELECT TOP 1 a.ApprovedBy, a.TotalLevels FROM dbo.LabReportApproval a
                  WHERE a.SamplecollectionID = t.FirstSampleId ORDER BY a.Level_No DESC, a.ApprovalId DESC) fa
    LEFT  JOIN dbo.Users au ON au.Id = fa.ApprovedBy
    WHERE t.HolderBranchId = @BranchId
      AND (@TatStatus IS NULL OR t.TatStatus = @TatStatus)
      AND (@DepartmentId IS NULL OR t.DepartmentId = @DepartmentId)
      AND (@OwnOnly = 0 OR t.EnteredById = @UserId OR t.UpdatedById = @UserId
           OR EXISTS (SELECT 1 FROM dbo.LabReportApproval a
                      INNER JOIN dbo.SampleCollection s2 ON s2.samplecollectionID = a.SamplecollectionID
                      WHERE s2.Laborderid = t.LabOrderId AND a.ApprovedBy = @UserId
                        AND (CASE WHEN s2.ProfileId IS NOT NULL THEN -s2.ProfileId ELSE s2.samplecollectionID END) = t.UnitKey))
      AND (@Search IS NULL OR t.BillNo LIKE '%' + @Search + '%' OR t.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR t.TestName LIKE '%' + @Search + '%' OR t.TestCode LIKE '%' + @Search + '%');

    ALTER TABLE #R ADD DelayGroup NVARCHAR(40);
    UPDATE #R SET DelayGroup = ISNULL(DelayStage, CASE TatStatus WHEN 'ONTIME' THEN 'Within TAT' WHEN 'NOTARGET' THEN 'No TAT hours set' ELSE 'Times not in order' END);

    -- RS1 summary
    SELECT COUNT(1) AS Tests,
           SUM(CASE WHEN TatStatus IN ('ONTIME', 'BREACH') THEN 1 ELSE 0 END) AS WithTarget,
           SUM(CASE WHEN TatStatus = 'ONTIME' THEN 1 ELSE 0 END) AS OnTime,
           SUM(CASE WHEN TatStatus = 'BREACH' THEN 1 ELSE 0 END) AS Breaches,
           CAST(100.0 * SUM(CASE WHEN TatStatus = 'ONTIME' THEN 1 ELSE 0 END) / NULLIF(SUM(CASE WHEN TatStatus IN ('ONTIME', 'BREACH') THEN 1 ELSE 0 END), 0) AS DECIMAL(6, 2)) AS OnTimePct,
           CAST(AVG(LabHours) AS DECIMAL(10, 1)) AS AvgLabHours, CAST(AVG(TotalHours) AS DECIMAL(10, 1)) AS AvgTotalHours,
           CAST(AVG(PreHours) AS DECIMAL(10, 1)) AS AvgPreHours, CAST(AVG(TransportHours) AS DECIMAL(10, 1)) AS AvgTransportHours,
           CAST(AVG(BenchHours) AS DECIMAL(10, 1)) AS AvgBenchHours, CAST(AVG(ValidationHours) AS DECIMAL(10, 1)) AS AvgValidationHours,
           CAST(AVG(SignoffHours) AS DECIMAL(10, 1)) AS AvgSignoffHours,
           MAX(OverByHours) AS WorstOverBy,
           (SELECT TOP 1 DelayStage FROM #R WHERE DelayStage IS NOT NULL GROUP BY DelayStage ORDER BY COUNT(1) DESC) AS TopDelayStage
    FROM #R;

    -- RS2 groups: department, test, approval date, delay stage of breaches
    ;WITH g AS (
        SELECT 'byDepartment' AS GroupKey, DepartmentId AS GroupId, Department AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byTest', NULL, TestName, 0, * FROM #R
        UNION ALL SELECT 'byDate', NULL, ApprovedDay, 0, * FROM #R
        UNION ALL SELECT 'byDelay', NULL, DelayGroup, CASE WHEN DelayStage IS NULL THEN 1 ELSE 0 END, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Tests,
           SUM(CASE WHEN TatStatus = 'ONTIME' THEN 1 ELSE 0 END) AS OnTime,
           SUM(CASE WHEN TatStatus = 'BREACH' THEN 1 ELSE 0 END) AS Breaches,
           CAST(100.0 * SUM(CASE WHEN TatStatus = 'ONTIME' THEN 1 ELSE 0 END) / NULLIF(SUM(CASE WHEN TatStatus IN ('ONTIME', 'BREACH') THEN 1 ELSE 0 END), 0) AS DECIMAL(6, 2)) AS OnTimePct,
           CAST(AVG(PreHours) AS DECIMAL(10, 1)) AS AvgPreHours,
           CAST(AVG(TransportHours) AS DECIMAL(10, 1)) AS AvgTransportHours,
           CAST(AVG(BenchHours) AS DECIMAL(10, 1)) AS AvgBenchHours,
           CAST(AVG(ValidationHours) AS DECIMAL(10, 1)) AS AvgValidationHours,
           CAST(AVG(SignoffHours) AS DECIMAL(10, 1)) AS AvgSignoffHours,
           CAST(AVG(LabHours) AS DECIMAL(10, 1)) AS AvgLabHours,
           CAST(AVG(CAST(TargetHours AS DECIMAL(10, 1))) AS DECIMAL(10, 1)) AS AvgTargetHours
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), COUNT(1) DESC, GroupName;

    -- RS3 rows: breaches first, the worst first
    SELECT * FROM #R ORDER BY CASE TatStatus WHEN 'BREACH' THEN 0 WHEN 'ONTIME' THEN 2 ELSE 1 END, OverByHours DESC, ApprovedOn DESC;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- Shared for LR-16 / LR-17 / LR-18: results entered at the branch in a period, one row per parameter, with the patient's
-- age (at the bill date) and gender, the numeric value and its saved flag. Branch = the branch that tested the sample.
-- ============================================================================
CREATE OR ALTER FUNCTION dbo.ufn_LabReport_Results (@BranchId INT, @From DATETIME, @To DATETIME)
RETURNS TABLE
AS
RETURN
(
    SELECT led.LabEntryDetailId, led.SamplecollectionID AS SampleId, led.LabOrderId, led.PatientId, led.InvestigationID,
           lo.BillNo, lo.TokenNo, lo.OrderDate AS BilledOn,
           COALESCE(led.Submitted_Date, led.Drafted_Date, led.CreatedDate) AS EnteredOn,
           led.Approved_Date AS ApprovedOn, ISNULL(led.ReportStatusId, 0) AS ReportStatusId,
           LTRIM(RTRIM(led.TestValue)) AS TestValue, TRY_CAST(LTRIM(RTRIM(led.TestValue)) AS DECIMAL(18, 4)) AS NumValue,
           NULLIF(LTRIM(RTRIM(led.AbnormalFlag)), '') AS AbnormalFlag,
           led.CreatedBy AS EnteredById, led.ModifiedBy AS UpdatedById,
           lim.Test_Code AS TestCode, lim.Test_Name AS TestName, NULLIF(sc.ProfileName, '') AS ProfileName,
           COALESCE(NULLIF(sc.DepartmentID, 0), lim.Department_ID) AS DepartmentId,
           COALESCE(NULLIF(u.Unit_Symbol, ''), u.Unit_Name, '') AS Unit,
           p.PatientCode, LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           p.PhoneNumber, p.Gender,
           CASE WHEN p.DateOfBirth IS NULL THEN NULL
                ELSE DATEDIFF(YEAR, p.DateOfBirth, lo.OrderDate)
                     - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, lo.OrderDate), p.DateOfBirth) > lo.OrderDate THEN 1 ELSE 0 END END AS AgeYears,
           lo.CompanyIdOf AS CompanyId
    FROM dbo.labentrydetails led
    INNER JOIN dbo.SampleCollection sc ON sc.samplecollectionID = led.SamplecollectionID
    CROSS APPLY (SELECT lo0.*, bm.CompanyId AS CompanyIdOf FROM dbo.LabOrder lo0 LEFT JOIN dbo.Branchmaster bm ON bm.BranchID = lo0.BranchId
                 WHERE lo0.LabOrderId = led.LabOrderId) lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    INNER JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = led.InvestigationID
    LEFT  JOIN dbo.LabUnitMaster u ON u.Unit_ID = lim.Unit_ID
    WHERE led.IsActive = 1 AND lo.IsActive = 1
      AND sc.Is_Active = 1 AND ISNULL(sc.Iscancelled, 0) = 0
      AND LTRIM(RTRIM(ISNULL(led.TestValue, ''))) <> ''
      AND COALESCE(led.Submitted_Date, led.Drafted_Date, led.CreatedDate) >= @From
      AND COALESCE(led.Submitted_Date, led.Drafted_Date, led.CreatedDate) < @To
      AND ((ISNULL(sc.IsTransferred, 0) = 0 AND sc.BranchID = @BranchId)
           OR (sc.IsTransferred = 1 AND sc.TargetBranchID = @BranchId))
);
GO

-- ============================================================================
-- LR-16 Critical & Panic Value Register - NABL / NABH quality indicator. Results that crossed a critical or panic
-- threshold: flagged 'Critical' / 'Panic' on Report Entry, or a numeric value beyond the Low / High threshold of the
-- patient's matching 'Critical Value' / 'Panic Value' reference range (age, gender; same match as Report Entry).
-- Date: result entry date. Who was informed and when is not recorded yet (roadmap data gap), so it is not listed.
-- Own data: results they entered, updated or signed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CriticalValues
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Severity      VARCHAR(10)   = NULL,   -- CRITICAL / PANIC
    @ResultStatus  VARCHAR(10)   = NULL,   -- APPROVED / PENDING
    @DepartmentId  INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Severity = NULLIF(UPPER(LTRIM(RTRIM(@Severity))), '');
    SET @ResultStatus = NULLIF(UPPER(LTRIM(RTRIM(@ResultStatus))), '');

    SELECT r.*, rng.Tier, rng.Low_Threshold AS LowThreshold, rng.High_Threshold AS HighThreshold,
           CASE WHEN r.NumValue IS NOT NULL AND rng.Low_Threshold IS NOT NULL AND r.NumValue < rng.Low_Threshold THEN 'L'
                WHEN r.NumValue IS NOT NULL AND rng.High_Threshold IS NOT NULL AND r.NumValue > rng.High_Threshold THEN 'H' END AS ThresholdDir
    INTO #C
    FROM dbo.ufn_LabReport_Results(@BranchId, @From, @To) r
    OUTER APPLY (
        SELECT TOP 1 x.Tier, x.Low_Threshold, x.High_Threshold
        FROM dbo.LabReferenceRangeMaster x
        WHERE x.Test_ID = r.InvestigationID AND x.IsDeleted = 0 AND x.Status = 1
          AND x.Tier IN ('Critical Value', 'Panic Value')
          AND (x.CompanyId = r.CompanyId OR x.CompanyId = 1)
          AND x.Effective_From <= CAST(r.EnteredOn AS DATE) AND (x.Effective_To IS NULL OR x.Effective_To >= CAST(r.EnteredOn AS DATE))
          AND (r.AgeYears IS NULL OR x.Is_Common_For_All = 1
               OR (x.Age_Unit = 'Years' AND r.AgeYears >= x.Age_From AND r.AgeYears <= x.Age_To)
               OR (x.Age_Unit = 'Months' AND r.AgeYears * 12.0 >= x.Age_From AND r.AgeYears * 12.0 <= x.Age_To)
               OR (x.Age_Unit = 'Days' AND r.AgeYears * 365.25 >= x.Age_From AND r.AgeYears * 365.25 <= x.Age_To))
          AND (x.Is_Common_For_All = 1 OR x.Gender = 'All' OR LOWER(x.Gender) = LOWER(ISNULL(r.Gender, '')))
        ORDER BY CASE WHEN LOWER(x.Gender) = LOWER(ISNULL(r.Gender, '')) THEN 1 ELSE 2 END,
                 CASE WHEN x.Is_Common_For_All = 0 THEN 1 ELSE 2 END, x.RefRange_ID DESC) rng
    WHERE r.AbnormalFlag IN ('Critical', 'Panic')
       OR EXISTS (SELECT 1 FROM dbo.LabReferenceRangeMaster x2
                  WHERE x2.Test_ID = r.InvestigationID AND x2.IsDeleted = 0 AND x2.Status = 1 AND x2.Tier IN ('Critical Value', 'Panic Value'));

    DELETE FROM #C WHERE ISNULL(AbnormalFlag, '') NOT IN ('Critical', 'Panic') AND ThresholdDir IS NULL;

    SELECT c.LabEntryDetailId, c.SampleId, c.LabOrderId, c.BillNo, c.TokenNo, c.PatientCode, c.PatientName, c.PhoneNumber, c.Gender, c.AgeYears,
           c.TestCode, c.TestName, c.ProfileName, c.DepartmentId, ISNULL(dm.DeptName, 'Not set') AS Department,
           c.TestValue, c.Unit, c.ThresholdDir,
           CASE WHEN c.AbnormalFlag IN ('Critical', 'Panic') THEN UPPER(c.AbnormalFlag)
                WHEN c.Tier = 'Panic Value' THEN 'PANIC' ELSE 'CRITICAL' END AS Severity,
           CASE WHEN c.LowThreshold IS NULL AND c.HighThreshold IS NULL THEN NULL
                ELSE CONCAT(CASE WHEN c.LowThreshold IS NOT NULL THEN N'< ' + CAST(CAST(c.LowThreshold AS FLOAT) AS NVARCHAR(30)) END,
                            CASE WHEN c.LowThreshold IS NOT NULL AND c.HighThreshold IS NOT NULL THEN N' or ' END,
                            CASE WHEN c.HighThreshold IS NOT NULL THEN N'> ' + CAST(CAST(c.HighThreshold AS FLOAT) AS NVARCHAR(30)) END,
                            CASE WHEN c.Unit <> '' THEN N' ' + c.Unit END) END AS Threshold,
           c.Tier AS RangeTier, c.AbnormalFlag AS SavedFlag,
           c.EnteredOn, CONVERT(VARCHAR(10), CAST(c.EnteredOn AS DATE), 23) AS EnteredDay,
           c.EnteredById, NULLIF(LTRIM(RTRIM(eu.FullName)), '') AS EnteredBy,
           CASE WHEN c.ReportStatusId = 5 THEN 'APPROVED' ELSE 'PENDING' END AS ResultStatus,
           c.ApprovedOn, ISNULL(NULLIF(LTRIM(RTRIM(au.FullName)), ''), au.Username) AS ApprovedBy,
           CAST(CASE WHEN c.ApprovedOn >= c.EnteredOn THEN DATEDIFF(MINUTE, c.EnteredOn, c.ApprovedOn) / 60.0 END AS DECIMAL(10, 1)) AS HoursToApproval
    INTO #R
    FROM #C c
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = c.DepartmentId
    LEFT JOIN dbo.Users eu ON eu.Id = c.EnteredById
    OUTER APPLY (SELECT TOP 1 a.ApprovedBy FROM dbo.LabReportApproval a WHERE a.SamplecollectionID = c.SampleId ORDER BY a.Level_No DESC, a.ApprovalId DESC) fa
    LEFT JOIN dbo.Users au ON au.Id = fa.ApprovedBy
    WHERE (@OwnOnly = 0 OR c.EnteredById = @UserId OR c.UpdatedById = @UserId
           OR EXISTS (SELECT 1 FROM dbo.LabReportApproval a2 WHERE a2.SamplecollectionID = c.SampleId AND a2.ApprovedBy = @UserId))
      AND (@DepartmentId IS NULL OR c.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR c.BillNo LIKE '%' + @Search + '%' OR c.TokenNo LIKE '%' + @Search + '%' OR c.PatientCode LIKE '%' + @Search + '%'
           OR c.PatientName LIKE '%' + @Search + '%' OR c.PhoneNumber LIKE '%' + @Search + '%' OR c.TestName LIKE '%' + @Search + '%');

    IF @Severity IS NOT NULL DELETE FROM #R WHERE Severity <> @Severity;
    IF @ResultStatus IS NOT NULL DELETE FROM #R WHERE ResultStatus <> @ResultStatus;

    -- RS1 summary
    SELECT COUNT(1) AS Flagged, SUM(CASE WHEN Severity = 'PANIC' THEN 1 ELSE 0 END) AS Panic,
           SUM(CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 0 END) AS Critical,
           COUNT(DISTINCT PatientCode) AS Patients,
           SUM(CASE WHEN ResultStatus = 'PENDING' THEN 1 ELSE 0 END) AS AwaitingApproval,
           CAST(AVG(HoursToApproval) AS DECIMAL(10, 1)) AS AvgHoursToApproval,
           (SELECT TOP 1 TestName FROM #R GROUP BY TestName ORDER BY COUNT(1) DESC, TestName) AS TopTest
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byTest' AS GroupKey, NULL AS GroupId, TestName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'bySeverity', NULL, Severity, CASE Severity WHEN 'PANIC' THEN 0 ELSE 1 END, * FROM #R
        UNION ALL SELECT 'byDepartment', DepartmentId, Department, 0, * FROM #R
        UNION ALL SELECT 'byStatus', NULL, ResultStatus, CASE ResultStatus WHEN 'PENDING' THEN 0 ELSE 1 END, * FROM #R
        UNION ALL SELECT 'byDate', NULL, EnteredDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Flagged, SUM(CASE WHEN Severity = 'PANIC' THEN 1 ELSE 0 END) AS Panic,
           SUM(CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 0 END) AS Critical,
           SUM(CASE WHEN ThresholdDir = 'L' THEN 1 ELSE 0 END) AS Low, SUM(CASE WHEN ThresholdDir = 'H' THEN 1 ELSE 0 END) AS High,
           SUM(CASE WHEN ResultStatus = 'PENDING' THEN 1 ELSE 0 END) AS AwaitingApproval,
           CAST(AVG(HoursToApproval) AS DECIMAL(10, 1)) AS AvgHoursToApproval
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), COUNT(1) DESC, GroupName;

    -- RS3 rows: not yet approved first, newest first
    SELECT * FROM #R ORDER BY CASE ResultStatus WHEN 'PENDING' THEN 0 ELSE 1 END, EnteredOn DESC;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL;

    DROP TABLE #R; DROP TABLE #C;
END;
GO

-- ============================================================================
-- LR-17 Delta-check Exceptions - numeric results entered in the period that changed by at least the delta limit
-- (25% by default, as on Report Entry) from the same patient's previous result of the same test on an earlier bill.
-- Change % = |current - previous| / |previous| x 100. Own data: results they entered, updated or signed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DeltaCheck
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @DeltaLimit    INT           = NULL,   -- %, default 25
    @Direction     VARCHAR(10)   = NULL,   -- UP / DOWN
    @DepartmentId  INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Direction = NULLIF(UPPER(LTRIM(RTRIM(@Direction))), '');
    IF ISNULL(@DeltaLimit, 0) <= 0 SET @DeltaLimit = 25;

    SELECT r.LabEntryDetailId, r.SampleId, r.LabOrderId, r.BillNo, r.TokenNo, r.PatientId, r.PatientCode, r.PatientName, r.Gender, r.AgeYears,
           r.TestCode, r.TestName, r.ProfileName, r.DepartmentId, ISNULL(dm.DeptName, 'Not set') AS Department, r.Unit,
           r.TestValue, r.NumValue, r.AbnormalFlag, r.EnteredOn, CONVERT(VARCHAR(10), CAST(r.EnteredOn AS DATE), 23) AS EnteredDay,
           r.EnteredById, r.UpdatedById, NULLIF(LTRIM(RTRIM(eu.FullName)), '') AS EnteredBy,
           CASE WHEN r.ReportStatusId = 5 THEN 'APPROVED' ELSE 'PENDING' END AS ResultStatus,
           pv.PrevValue, pv.PrevNum, pv.PrevBillNo, pv.PrevOn, pv.PrevFlag,
           DATEDIFF(DAY, pv.PrevOn, r.BilledOn) AS DaysApart,
           CAST(ABS(r.NumValue - pv.PrevNum) * 100.0 / ABS(pv.PrevNum) AS DECIMAL(10, 1)) AS ChangePct,
           CASE WHEN r.NumValue > pv.PrevNum THEN 'UP' ELSE 'DOWN' END AS Direction
    INTO #R
    FROM dbo.ufn_LabReport_Results(@BranchId, @From, @To) r
    CROSS APPLY (
        -- the patient's previous numeric result of this test, on an earlier bill
        SELECT TOP 1 LTRIM(RTRIM(pl.TestValue)) AS PrevValue, TRY_CAST(LTRIM(RTRIM(pl.TestValue)) AS DECIMAL(18, 4)) AS PrevNum,
               plo.BillNo AS PrevBillNo, plo.OrderDate AS PrevOn, NULLIF(LTRIM(RTRIM(pl.AbnormalFlag)), '') AS PrevFlag
        FROM dbo.labentrydetails pl
        INNER JOIN dbo.LabOrder plo ON plo.LabOrderId = pl.LabOrderId AND plo.IsActive = 1
        WHERE pl.PatientId = r.PatientId AND pl.InvestigationID = r.InvestigationID AND pl.LabOrderId <> r.LabOrderId
          AND pl.IsActive = 1 AND plo.OrderDate < r.BilledOn
          AND TRY_CAST(LTRIM(RTRIM(pl.TestValue)) AS DECIMAL(18, 4)) IS NOT NULL
        ORDER BY plo.OrderDate DESC, pl.LabEntryDetailId DESC) pv
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = r.DepartmentId
    LEFT JOIN dbo.Users eu ON eu.Id = r.EnteredById
    WHERE r.NumValue IS NOT NULL AND pv.PrevNum IS NOT NULL AND pv.PrevNum <> 0
      AND ABS(r.NumValue - pv.PrevNum) * 100.0 / ABS(pv.PrevNum) >= @DeltaLimit
      AND (@OwnOnly = 0 OR r.EnteredById = @UserId OR r.UpdatedById = @UserId
           OR EXISTS (SELECT 1 FROM dbo.LabReportApproval a2 WHERE a2.SamplecollectionID = r.SampleId AND a2.ApprovedBy = @UserId))
      AND (@DepartmentId IS NULL OR r.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR r.BillNo LIKE '%' + @Search + '%' OR r.TokenNo LIKE '%' + @Search + '%' OR r.PatientCode LIKE '%' + @Search + '%'
           OR r.PatientName LIKE '%' + @Search + '%' OR r.TestName LIKE '%' + @Search + '%');

    IF @Direction IS NOT NULL DELETE FROM #R WHERE Direction <> @Direction;
    ALTER TABLE #R ADD Band VARCHAR(10);
    UPDATE #R SET Band = CASE WHEN ChangePct < 50 THEN '25-50' WHEN ChangePct < 100 THEN '50-100' ELSE '100+' END;
    UPDATE #R SET Band = CASE WHEN ChangePct < 25 THEN '<25' ELSE Band END;

    -- RS1 summary
    SELECT COUNT(1) AS Exceptions, COUNT(DISTINCT PatientId) AS Patients, @DeltaLimit AS DeltaLimit,
           SUM(CASE WHEN Direction = 'UP' THEN 1 ELSE 0 END) AS Rises, SUM(CASE WHEN Direction = 'DOWN' THEN 1 ELSE 0 END) AS Falls,
           SUM(CASE WHEN ChangePct >= 100 THEN 1 ELSE 0 END) AS Over100,
           MAX(ChangePct) AS MaxChangePct,
           SUM(CASE WHEN ResultStatus = 'PENDING' THEN 1 ELSE 0 END) AS AwaitingApproval,
           (SELECT TOP 1 TestName FROM #R GROUP BY TestName ORDER BY COUNT(1) DESC, TestName) AS TopTest
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byTest' AS GroupKey, NULL AS GroupId, TestName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byBand', NULL, Band, CASE Band WHEN '<25' THEN 0 WHEN '25-50' THEN 1 WHEN '50-100' THEN 2 ELSE 3 END, * FROM #R
        UNION ALL SELECT 'byDepartment', DepartmentId, Department, 0, * FROM #R
        UNION ALL SELECT 'byDate', NULL, EnteredDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Exceptions, SUM(CASE WHEN Direction = 'UP' THEN 1 ELSE 0 END) AS Rises,
           SUM(CASE WHEN Direction = 'DOWN' THEN 1 ELSE 0 END) AS Falls,
           CAST(AVG(ChangePct) AS DECIMAL(10, 1)) AS AvgChangePct, MAX(ChangePct) AS MaxChangePct
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), COUNT(1) DESC, GroupName;

    -- RS3 rows: the largest change first
    SELECT * FROM #R ORDER BY ChangePct DESC, EnteredOn DESC;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #R WHERE DepartmentId IS NOT NULL;

    DROP TABLE #R;
END;
GO

-- ============================================================================
-- LR-18 Abnormal Results Summary - per test (parameter): results with a flag, % High, % Low, % Normal, critical / panic,
-- week by week (weeks start Monday). A test whose share of high or low results in its latest week is 15 points or more
-- above its share in the earlier weeks (with at least 5 results that week) is marked "Rising" - a sign of analyser drift
-- or a calibration issue. Date: result entry date. Own data: results they entered.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_AbnormalResults
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @DepartmentId  INT           = NULL,
    @Signal        VARCHAR(10)   = NULL,   -- RISING
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Signal = NULLIF(UPPER(LTRIM(RTRIM(@Signal))), '');

    SELECT r.InvestigationID, r.TestCode, r.TestName, r.DepartmentId, ISNULL(dm.DeptName, 'Not set') AS Department,
           DATEADD(DAY, -(DATEDIFF(DAY, '19000101', CAST(r.EnteredOn AS DATE)) % 7), CAST(r.EnteredOn AS DATE)) AS WeekStart,
           CASE WHEN r.AbnormalFlag = 'H' THEN 'H' WHEN r.AbnormalFlag = 'L' THEN 'L' WHEN r.AbnormalFlag = 'Normal' THEN 'N'
                WHEN r.AbnormalFlag IN ('Critical', 'Panic') THEN 'C' ELSE 'A' END AS Cls
    INTO #F
    FROM dbo.ufn_LabReport_Results(@BranchId, @From, @To) r
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = r.DepartmentId
    WHERE r.AbnormalFlag IS NOT NULL
      AND (@OwnOnly = 0 OR r.EnteredById = @UserId)
      AND (@DepartmentId IS NULL OR r.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR r.TestName LIKE '%' + @Search + '%' OR r.TestCode LIKE '%' + @Search + '%');

    -- per test x week (the detail lines)
    SELECT InvestigationID, MAX(TestCode) AS TestCode, MAX(TestName) AS TestName, MAX(DepartmentId) AS DepartmentId, MAX(Department) AS Department,
           WeekStart, CONVERT(VARCHAR(10), WeekStart, 23) AS WeekKey,
           COUNT(1) AS Results, SUM(CASE WHEN Cls = 'H' THEN 1 ELSE 0 END) AS High, SUM(CASE WHEN Cls = 'L' THEN 1 ELSE 0 END) AS Low,
           SUM(CASE WHEN Cls = 'N' THEN 1 ELSE 0 END) AS Normal, SUM(CASE WHEN Cls = 'C' THEN 1 ELSE 0 END) AS CriticalPanic,
           SUM(CASE WHEN Cls = 'A' THEN 1 ELSE 0 END) AS AbnormalText
    INTO #W
    FROM #F GROUP BY InvestigationID, WeekStart;

    ALTER TABLE #W ADD HighPct DECIMAL(6, 1), LowPct DECIMAL(6, 1), NormalPct DECIMAL(6, 1), OutPct DECIMAL(6, 1), PrevOutPct DECIMAL(6, 1), ChangePts DECIMAL(6, 1);
    UPDATE #W SET HighPct = 100.0 * High / Results, LowPct = 100.0 * Low / Results, NormalPct = 100.0 * Normal / Results,
                  OutPct = 100.0 * (Results - Normal) / Results;
    UPDATE w SET PrevOutPct = (SELECT TOP 1 p.OutPct FROM #W p WHERE p.InvestigationID = w.InvestigationID AND p.WeekStart < w.WeekStart ORDER BY p.WeekStart DESC)
    FROM #W w;
    UPDATE #W SET ChangePts = OutPct - PrevOutPct;

    -- per test: latest week against the earlier weeks of the period
    SELECT t.InvestigationID, CASE WHEN lw.Results >= 5 AND ew.Results > 0 AND lw.OutPct - 100.0 * (ew.Results - ew.Normal) / ew.Results >= 15 THEN 'RISING' END AS Signal,
           CAST(lw.OutPct - 100.0 * (ew.Results - ew.Normal) / NULLIF(ew.Results, 0) AS DECIMAL(6, 1)) AS LatestVsEarlierPts
    INTO #S
    FROM (SELECT DISTINCT InvestigationID FROM #W) t
    OUTER APPLY (SELECT TOP 1 w.Results, w.OutPct, w.WeekStart FROM #W w WHERE w.InvestigationID = t.InvestigationID ORDER BY w.WeekStart DESC) lw
    OUTER APPLY (SELECT SUM(w.Results) AS Results, SUM(w.Normal) AS Normal FROM #W w WHERE w.InvestigationID = t.InvestigationID AND w.WeekStart < lw.WeekStart) ew;

    IF @Signal = 'RISING'
    BEGIN
        DELETE FROM #W WHERE InvestigationID NOT IN (SELECT InvestigationID FROM #S WHERE Signal = 'RISING');
        DELETE FROM #F WHERE InvestigationID NOT IN (SELECT InvestigationID FROM #S WHERE Signal = 'RISING');
    END

    -- RS1 summary
    SELECT ISNULL(SUM(Results), 0) AS Results, COUNT(DISTINCT InvestigationID) AS TestsCount,
           ISNULL(SUM(High), 0) AS High, ISNULL(SUM(Low), 0) AS Low, ISNULL(SUM(Normal), 0) AS Normal, ISNULL(SUM(CriticalPanic), 0) AS CriticalPanic,
           CAST(100.0 * SUM(High) / NULLIF(SUM(Results), 0) AS DECIMAL(6, 1)) AS HighPct,
           CAST(100.0 * SUM(Low) / NULLIF(SUM(Results), 0) AS DECIMAL(6, 1)) AS LowPct,
           CAST(100.0 * SUM(Normal) / NULLIF(SUM(Results), 0) AS DECIMAL(6, 1)) AS NormalPct,
           (SELECT COUNT(1) FROM #S WHERE Signal = 'RISING' AND InvestigationID IN (SELECT InvestigationID FROM #W)) AS RisingTests,
           (SELECT TOP 1 TestName FROM #W GROUP BY TestName HAVING SUM(Results) >= 5
             ORDER BY 1.0 * SUM(Results - Normal) / SUM(Results) DESC, SUM(Results) DESC) AS MostAbnormalTest
    FROM #W;

    -- RS2 groups: test (with its drift signal), week, department
    SELECT 'byTest' AS GroupKey, w.InvestigationID AS GroupId, MAX(w.TestName) AS GroupName, 0 AS SortOrder,
           SUM(w.Results) AS Results, SUM(w.High) AS High, SUM(w.Low) AS Low, SUM(w.Normal) AS Normal,
           SUM(w.CriticalPanic) AS CriticalPanic, SUM(w.AbnormalText) AS AbnormalText,
           CAST(100.0 * SUM(w.High) / SUM(w.Results) AS DECIMAL(6, 1)) AS HighPct, CAST(100.0 * SUM(w.Low) / SUM(w.Results) AS DECIMAL(6, 1)) AS LowPct,
           CAST(100.0 * SUM(w.Normal) / SUM(w.Results) AS DECIMAL(6, 1)) AS NormalPct,
           MAX(s.Signal) AS Signal, MAX(s.LatestVsEarlierPts) AS LatestVsEarlierPts
    FROM #W w LEFT JOIN #S s ON s.InvestigationID = w.InvestigationID
    GROUP BY w.InvestigationID
    UNION ALL
    SELECT 'byWeek', NULL, WeekKey, 0, SUM(Results), SUM(High), SUM(Low), SUM(Normal), SUM(CriticalPanic), SUM(AbnormalText),
           CAST(100.0 * SUM(High) / SUM(Results) AS DECIMAL(6, 1)), CAST(100.0 * SUM(Low) / SUM(Results) AS DECIMAL(6, 1)),
           CAST(100.0 * SUM(Normal) / SUM(Results) AS DECIMAL(6, 1)), NULL, NULL
    FROM #W GROUP BY WeekKey
    UNION ALL
    SELECT 'byDepartment', DepartmentId, Department, 0, SUM(Results), SUM(High), SUM(Low), SUM(Normal), SUM(CriticalPanic), SUM(AbnormalText),
           CAST(100.0 * SUM(High) / SUM(Results) AS DECIMAL(6, 1)), CAST(100.0 * SUM(Low) / SUM(Results) AS DECIMAL(6, 1)),
           CAST(100.0 * SUM(Normal) / SUM(Results) AS DECIMAL(6, 1)), NULL, NULL
    FROM #W GROUP BY DepartmentId, Department
    ORDER BY GroupKey, SortOrder, Results DESC, GroupName;

    -- RS3 rows: one line per test per week
    SELECT w.*, s.Signal FROM #W w LEFT JOIN #S s ON s.InvestigationID = w.InvestigationID
    ORDER BY w.TestName, w.WeekStart;

    -- RS4 filter options
    SELECT DISTINCT 'departmentId' AS FilterKey, CAST(DepartmentId AS VARCHAR(20)) AS Value, Department AS Text FROM #W WHERE DepartmentId IS NOT NULL;

    DROP TABLE #S; DROP TABLE #W; DROP TABLE #F;
END;
GO

-- ── menu pages and endpoints (database navigation, Reports > LAB) ───────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.LABCASHIERCLOSING', N'Cashier Day-end Closing',          N'LabCashierClosing',  25,  N'bi bi-cash-coin me-2'),
    (N'REPORTS.LABWORKPENDING',    N'Work Pending by Stage',            N'LabWorkPending',     165, N'bi bi-hourglass-split me-2'),
    (N'REPORTS.LABTAT',            N'Turnaround Time (TAT)',            N'LabTurnaroundTime',  170, N'bi bi-stopwatch me-2'),
    (N'REPORTS.LABCRITICAL',       N'Critical & Panic Value Register',  N'LabCriticalValues',  175, N'bi bi-exclamation-octagon me-2'),
    (N'REPORTS.LABDELTA',          N'Delta-check Exceptions',           N'LabDeltaCheck',      180, N'bi bi-arrow-left-right me-2'),
    (N'REPORTS.LABABNORMAL',       N'Abnormal Results Summary',         N'LabAbnormalResults', 185, N'bi bi-activity me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pc; FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title,
                 @Controller = N'Reports', @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon,
                 @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2201 applied: Reports > LAB > LR-03, LR-14, LR-15, LR-16, LR-17, LR-18.';
GO
