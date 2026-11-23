-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2434  IPD Phase 5 · IPD Billing
--   Charges        usp_Ipd_PostCharge (only writer of IpdCharge), usp_Api_IpdCharge_Add / _Cancel / _List,
--                  usp_Api_Ipd_ChargeLookups (services, procedures, doctor visits, packages with the patient's rates)
--   Doctor visits  IpdDoctorVisitFee (IPD > Doctor Visit Charges, separate from the OPD consulting fee): doctor x visit type x
--                  tariff category (blank = all) with effective dates; usp_Api_IpdDoctorFee_List / _Lookups / _Save / _Remove
--   Package        fn_Ipd_PackageCover, usp_Api_IpdBill_SetPackage: package amount once, covered bed days and heads at 0
--   Final bill     usp_Ipd_BillCalc, usp_Api_IpdBill_Preview / _Finalise / _Cancel / _Get / _List
--                  bill discount (% or amount, reason) spread over the lines before GST, round off to the rupee,
--                  advance adjusted, then settlement receipts (IpdAdvance kind SETTLE) up to the balance
--   Accounts       SLS  Dr Patient Receivable, Dr Discount Allowed · Cr IPD Revenue, Cr GST Output, ± Round Off
--                  JRN  Dr IPD Patient Advance · Cr Patient Receivable (advance adjusted)
--                  RCT  Dr Cash / Bank · Cr Patient Receivable (settlement)
--                  bill cancel = reversal vouchers; settlements become advance again (JRN)
--   Day closing    module IPD (IPD.DAYCLOSING / IPD.DAYCLOSINGVERIFY): IPD receipts and refunds
-- After the final bill the live bill (fn_Ipd_BillLines) is the bill's frozen lines. Needs 2422-2433. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. schema ───────────────────────────────────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.IpdAdmission', 'BillId') IS NULL
    ALTER TABLE dbo.IpdAdmission ADD BillId INT NULL, BillUpToAt DATETIME NULL;
GO
IF COL_LENGTH('dbo.IpdCharge', 'CancelReason') IS NULL
    ALTER TABLE dbo.IpdCharge ADD CancelReason NVARCHAR(300) NULL, CancelledBy INT NULL, CancelledAt DATETIME NULL,
        ListDiscount DECIMAL(18,2) NULL, ExcludePackage BIT NOT NULL CONSTRAINT DF_IpdCharge_ExclPkg DEFAULT (0),
        MasterRate DECIMAL(18,2) NULL, RefKind VARCHAR(10) NULL, RefId INT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_IpdAdvance_Kind' AND definition NOT LIKE '%SETTLE%')
BEGIN
    ALTER TABLE dbo.IpdAdvance DROP CONSTRAINT CK_IpdAdvance_Kind;
    ALTER TABLE dbo.IpdAdvance ADD CONSTRAINT CK_IpdAdvance_Kind CHECK (Kind IN ('ADVANCE', 'REFUND', 'SETTLE'));
END
GO
IF OBJECT_ID('dbo.IpdBill', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdBill
    (
        BillId           INT IDENTITY(1,1) CONSTRAINT PK_IpdBill PRIMARY KEY,
        CompanyId        INT            NOT NULL,
        BranchId         INT            NOT NULL,
        AdmissionId      INT            NOT NULL CONSTRAINT FK_IpdBill_Adm REFERENCES dbo.IpdAdmission (AdmissionId),
        BillNo           NVARCHAR(40)   NOT NULL,
        BillAt           DATETIME       NOT NULL,
        BillUpToAt       DATETIME       NOT NULL,
        Gross            DECIMAL(18,2)  NOT NULL,
        ItemDiscount     DECIMAL(18,2)  NOT NULL,
        BillDiscountType CHAR(1)        NULL,       -- P percent, F flat amount
        BillDiscountValue DECIMAL(18,2) NOT NULL CONSTRAINT DF_IpdBill_DiscVal DEFAULT (0),
        BillDiscount     DECIMAL(18,2)  NOT NULL,
        DiscountReason   NVARCHAR(300)  NULL,
        Taxable          DECIMAL(18,2)  NOT NULL,
        Gst              DECIMAL(18,2)  NOT NULL,
        RoundOff         DECIMAL(18,2)  NOT NULL,
        Net              DECIMAL(18,2)  NOT NULL,
        AdvanceAdjusted  DECIMAL(18,2)  NOT NULL,
        PrevStatus       VARCHAR(20)    NOT NULL,
        Status           VARCHAR(10)    NOT NULL CONSTRAINT DF_IpdBill_Status DEFAULT ('FINAL'),
        SalesTxnId       BIGINT         NULL,
        AdjustTxnId      BIGINT         NULL,
        Remarks          NVARCHAR(500)  NULL,
        CancelReason     NVARCHAR(300)  NULL,
        CancelledBy      INT            NULL,
        CancelledAt      DATETIME       NULL,
        CreatedBy        INT            NULL,
        CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_IpdBill_Created DEFAULT (GETDATE()),
        CONSTRAINT CK_IpdBill_Status CHECK (Status IN ('FINAL', 'CANCELLED'))
    );
    CREATE UNIQUE INDEX UX_IpdBill_No ON dbo.IpdBill (CompanyId, BillNo);
    CREATE UNIQUE INDEX UX_IpdBill_OneFinal ON dbo.IpdBill (AdmissionId) WHERE Status = 'FINAL';
    CREATE INDEX IX_IpdBill_Branch ON dbo.IpdBill (BranchId, BillAt);
END
GO
IF OBJECT_ID('dbo.IpdBillLine', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdBillLine
    (
        BillLineId    BIGINT IDENTITY(1,1) CONSTRAINT PK_IpdBillLine PRIMARY KEY,
        BillId        INT            NOT NULL CONSTRAINT FK_IpdBillLine_Bill REFERENCES dbo.IpdBill (BillId),
        LineKey       NVARCHAR(40)   NOT NULL,
        Head          VARCHAR(20)    NOT NULL,
        ChargeAt      DATETIME       NOT NULL,
        ItemCode      NVARCHAR(50)   NULL,
        ItemName      NVARCHAR(250)  NOT NULL,
        Detail        NVARCHAR(300)  NULL,
        DoctorName    NVARCHAR(150)  NULL,
        Qty           DECIMAL(18,3)  NOT NULL,
        Rate          DECIMAL(18,2)  NOT NULL,
        Gross         DECIMAL(18,2)  NOT NULL,
        ItemDiscount  DECIMAL(18,2)  NOT NULL,
        BillDiscount  DECIMAL(18,2)  NOT NULL,
        GstPercent    DECIMAL(5,2)   NOT NULL,
        GstAmount     DECIMAL(18,2)  NOT NULL,
        Net           DECIMAL(18,2)  NOT NULL,
        SourceModule  VARCHAR(10)    NULL,
        SourceNo      NVARCHAR(50)   NULL,
        IsPackageItem BIT            NOT NULL,
        DayNo         INT            NULL,
        Sort          INT            NOT NULL,
        ChargeId      BIGINT         NULL
    );
    CREATE INDEX IX_IpdBillLine_Bill ON dbo.IpdBillLine (BillId);
END
GO
IF OBJECT_ID('dbo.IpdDoctorVisitFee', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IpdDoctorVisitFee
    (
        FeeId            INT IDENTITY(1,1) CONSTRAINT PK_IpdDoctorVisitFee PRIMARY KEY,
        CompanyId        INT            NOT NULL,
        BranchId         INT            NOT NULL,
        DoctorId         INT            NOT NULL CONSTRAINT FK_IpdDoctorVisitFee_Doctor REFERENCES dbo.DoctorMaster (DoctorId),
        VisitType        VARCHAR(12)    NOT NULL,   -- ROUTINE EMERGENCY CROSS NIGHT
        TariffCategoryId INT            NULL,       -- NULL = every tariff category
        Rate             DECIMAL(18,2)  NOT NULL,
        EffectiveFrom    DATE           NOT NULL,
        EffectiveTo      DATE           NULL,
        Remarks          NVARCHAR(300)  NULL,
        IsActive         BIT            NOT NULL CONSTRAINT DF_IpdDoctorVisitFee_Active DEFAULT (1),
        CreatedBy        INT            NULL,
        CreatedDate      DATETIME       NOT NULL CONSTRAINT DF_IpdDoctorVisitFee_Created DEFAULT (GETDATE()),
        ModifiedBy       INT            NULL,
        ModifiedDate     DATETIME       NULL,
        CONSTRAINT CK_IpdDoctorVisitFee_Type CHECK (VisitType IN ('ROUTINE', 'EMERGENCY', 'CROSS', 'NIGHT')),
        CONSTRAINT CK_IpdDoctorVisitFee_Rate CHECK (Rate > 0),
        CONSTRAINT CK_IpdDoctorVisitFee_Dates CHECK (EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom)
    );
    CREATE INDEX IX_IpdDoctorVisitFee ON dbo.IpdDoctorVisitFee (BranchId, DoctorId, VisitType, IsActive);
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Revenue')
    INSERT dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate, LedgerCode, LedgerType, IsSystem, Remarks)
    SELECT TOP (1) 'IPD Revenue', LedgerGroupId, 0, 'Cr', 1, GETDATE(), 'IPD_REVENUE', LedgerType, 1, 'Income from IPD final bills (bed, doctor, procedures, services, packages).'
    FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'OPD Revenue';
GO

-- ── 2. rates ────────────────────────────────────────────────────────────────────────────────────────────────
-- Rate of a hospital service / procedure for the patient's tariff category (else the branch's default category).
CREATE OR ALTER FUNCTION dbo.fn_Ipd_ServiceRate (@BranchId INT, @ServiceId INT, @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) CAST(r.Rate AS DECIMAL(18,2)) AS Rate, CAST(CASE WHEN r.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END AS BIT) AS UsedFallback
    FROM dbo.HospitalServiceRateMaster r
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId
    WHERE r.BranchId = @BranchId AND r.HospitalServiceId = @ServiceId AND r.IsActive = 1
      AND r.TariffCategoryId IN (@TariffCategoryId, ISNULL(s.IpdDefaultTariffCategoryId, @TariffCategoryId))
      AND r.EffectiveFrom <= @OnDate AND (r.EffectiveTo IS NULL OR r.EffectiveTo >= @OnDate)
    ORDER BY CASE WHEN r.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END, r.EffectiveFrom DESC, r.ServiceRateId DESC
);
GO
CREATE OR ALTER FUNCTION dbo.fn_Ipd_ProcedureRate (@BranchId INT, @ProcedureId INT, @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) CAST(t.TotalRate AS DECIMAL(18,2)) AS Rate, t.SurgeonFee, t.AssistantFee, t.AnaesthetistFee, t.OtCharges, t.EquipmentCharges,
           t.ConsumableCharges, t.NursingCharges, CAST(CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END AS BIT) AS UsedFallback
    FROM dbo.ProcedureTariffMaster t
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = @BranchId
    WHERE t.BranchId = @BranchId AND t.ProcedureId = @ProcedureId AND t.IsActive = 1
      AND t.TariffCategoryId IN (@TariffCategoryId, ISNULL(s.IpdDefaultTariffCategoryId, @TariffCategoryId))
      AND CAST(t.EffectiveFrom AS DATE) <= @OnDate AND (t.EffectiveTo IS NULL OR CAST(t.EffectiveTo AS DATE) >= @OnDate)
    ORDER BY CASE WHEN t.TariffCategoryId = @TariffCategoryId THEN 0 ELSE 1 END, t.EffectiveFrom DESC, t.ProcedureTariffId DESC
);
GO
-- IPD visit fee of a doctor (IPD > Doctor Visit Charges): the patient's tariff category before "all categories",
-- latest effective date first. Not the OPD consulting fee.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_DoctorFee (@BranchId INT, @DoctorId INT, @VisitType VARCHAR(12), @TariffCategoryId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) f.Rate, f.FeeId, f.TariffCategoryId
    FROM dbo.IpdDoctorVisitFee f
    WHERE f.BranchId = @BranchId AND f.DoctorId = @DoctorId AND f.IsActive = 1
      AND (f.TariffCategoryId = @TariffCategoryId OR f.TariffCategoryId IS NULL)
      AND f.EffectiveFrom <= @OnDate AND (f.EffectiveTo IS NULL OR f.EffectiveTo >= @OnDate)
    -- one charge per doctor for every visit type (the screen keeps no visit type / category); a specific row, if any, wins
    ORDER BY CASE WHEN f.VisitType = @VisitType THEN 0 ELSE 1 END, CASE WHEN f.TariffCategoryId IS NULL THEN 1 ELSE 0 END, f.EffectiveFrom DESC, f.FeeId DESC
);
GO
-- Bill heads a package covers (Master > Hospital Package details) and the bed days it includes.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_PackageCover (@PackageId INT)
RETURNS TABLE
AS RETURN
(
    SELECT x.Head, CAST(MAX(x.Days) AS INT) AS Days
    FROM (SELECT CASE WHEN d.DetailHeadType IN (N'Bed', N'Room', N'Nursing') THEN 'BED' WHEN d.DetailHeadType = N'Doctor fee' THEN 'DOCTOR'
                      WHEN d.DetailHeadType = N'Procedure' THEN 'PROCEDURE' WHEN d.DetailHeadType IN (N'OT', N'Anaesthesia', N'Equipment') THEN 'OT'
                      WHEN d.DetailHeadType = N'Consumables' THEN 'CONSUMABLE' WHEN d.DetailHeadType = N'Hospital services' THEN 'SERVICE' END AS Head,
                 CASE WHEN d.DetailHeadType IN (N'Bed', N'Room') THEN d.Quantity END AS Days
          FROM dbo.HospitalPackageDetail d WHERE d.HospitalPackage_ID = @PackageId) x
    WHERE x.Head IS NOT NULL
    GROUP BY x.Head
);
GO

-- ── 3. live bill (replaces 2422): package, frozen lines after the final bill ──────────────────────────────────
CREATE OR ALTER FUNCTION dbo.fn_Ipd_Heads ()
RETURNS TABLE
AS RETURN
(
    SELECT Head, HeadName, Sort FROM (VALUES
        ('BED', N'Bed & Nursing', 10), ('ICU', N'ICU', 20), ('DOCTOR', N'Doctor Visits', 30), ('LAB', N'Laboratory', 40),
        ('RADIOLOGY', N'Radiology / Imaging', 50), ('PHARMACY', N'Pharmacy', 60), ('CONSUMABLE', N'Consumables', 70),
        ('PROCEDURE', N'Procedures', 80), ('OT', N'Operation Theatre', 90), ('SERVICE', N'Other Services', 100), ('PACKAGE', N'Package', 110),
        ('ADJUST', N'Round off', 120)
    ) h (Head, HeadName, Sort)
);
GO
CREATE OR ALTER FUNCTION dbo.fn_Ipd_BillLines (@AdmissionId INT, @AsOf DATETIME)
RETURNS TABLE
AS RETURN
(
    WITH adm AS
    (
        SELECT a.AdmissionId, a.BillId, a.PackageId, a.AdmissionAt,
               (SELECT MAX(pc.Days) FROM dbo.fn_Ipd_PackageCover(a.PackageId) pc WHERE pc.Head = 'BED') AS PkgDays
        FROM dbo.IpdAdmission a WHERE a.AdmissionId = @AdmissionId
    )
    -- bed days (live)
    SELECT CAST(CONCAT('B', bd.DayNo, '-', v.Code) AS NVARCHAR(40)) AS LineKey,
           CAST(CASE WHEN bd.IsIcu = 1 THEN 'ICU' ELSE 'BED' END AS VARCHAR(20)) AS Head,
           CAST(bd.DayDate AS DATETIME) AS ChargeAt, CAST(v.Code AS NVARCHAR(50)) AS ItemCode,
           CAST(CASE WHEN bd.NoTariff = 1 AND pk.InPkg = 0 THEN N'No bed tariff for ' + ISNULL(bd.BedCategoryName, N'this bed')
                     WHEN bd.NoTariff = 1 THEN N'Bed (in package)' ELSE v.Name END AS NVARCHAR(250)) AS ItemName,
           CAST(CONCAT(N'Day ', bd.DayNo, N' · ', bd.WardName, N' / ', bd.RoomNumber, N' / ', bd.BedNumber) AS NVARCHAR(300)) AS Detail,
           CAST(NULL AS NVARCHAR(150)) AS DoctorName,
           CAST(1 AS DECIMAL(18,3)) AS Qty, v.Amount AS Rate,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE v.Amount END AS DECIMAL(18,2)) AS Gross, CAST(0 AS DECIMAL(18,2)) AS Discount,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE bd.GstPercent END AS DECIMAL(5,2)) AS GstPercent,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE ROUND(v.Amount * bd.GstPercent / 100, 2) END AS DECIMAL(18,2)) AS GstAmount,
           CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE v.Amount + ROUND(v.Amount * bd.GstPercent / 100, 2) END AS DECIMAL(18,2)) AS Net,
           CAST('ACCRUED' AS VARCHAR(10)) AS Status, CAST('IPD' AS VARCHAR(10)) AS SourceModule, CAST(NULL AS NVARCHAR(50)) AS SourceNo,
           CAST(pk.InPkg AS BIT) AS IsPackageItem, CAST(CASE WHEN pk.InPkg = 1 THEN 0 ELSE bd.NoTariff END AS BIT) AS NoTariff, bd.UsedFallback, bd.DayNo, v.Sort
    FROM adm
    CROSS APPLY dbo.fn_Ipd_BedDays(@AdmissionId, @AsOf) bd
    CROSS APPLY (SELECT CASE WHEN bd.IsIcu = 0 AND bd.DayNo <= ISNULL(adm.PkgDays, 0) THEN 1 ELSE 0 END AS InPkg) pk
    CROSS APPLY (VALUES ('ROOM', N'Room Rent', bd.RoomCharge, 1), ('BED', N'Bed Charge', bd.BedCharge, 2),
                        ('NURSING', N'Nursing Charge', bd.NursingCharge, 3), ('ATTENDANT', N'Attendant Charge', bd.AttendantCharge, 4),
                        ('ISOLATION', N'Isolation Charge', bd.IsolationCharge, 5), ('NOTARIFF', N'', CAST(0 AS DECIMAL(18,2)), 6)) v (Code, Name, Amount, Sort)
    WHERE adm.BillId IS NULL AND ((bd.NoTariff = 0 AND v.Code <> 'NOTARIFF' AND v.Amount > 0) OR (bd.NoTariff = 1 AND v.Code = 'NOTARIFF'))

    UNION ALL
    -- the package amount (live, once)
    SELECT CAST('PKG' AS NVARCHAR(40)), CAST('PACKAGE' AS VARCHAR(20)), adm.AdmissionAt, CAST(p.Package_Code AS NVARCHAR(50)), CAST(p.Package_Name AS NVARCHAR(250)),
           CAST(N'Package' AS NVARCHAR(300)), CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), CAST(p.TotalPackageAmount AS DECIMAL(18,2)),
           CAST(p.TotalPackageAmount AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)),
           CAST(p.TotalPackageAmount AS DECIMAL(18,2)), CAST('ACCRUED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), CAST(NULL AS NVARCHAR(50)),
           CAST(0 AS BIT), CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm JOIN dbo.HospitalPackageMaster p ON p.HospitalPackage_ID = adm.PackageId
    WHERE adm.BillId IS NULL AND adm.AdmissionAt <= @AsOf

    UNION ALL
    -- posted charges (live)
    SELECT CAST(CONCAT('C', c.ChargeId) AS NVARCHAR(40)), c.Head, c.ChargeAt, c.ItemCode, c.ItemName,
           CAST(CASE WHEN c.SourceNo IS NOT NULL THEN CONCAT(c.SourceModule, N' ', c.SourceNo) ELSE c.Remarks END AS NVARCHAR(300)),
           CAST(doc.FullName AS NVARCHAR(150)),
           c.Qty, c.Rate, c.Gross, c.Discount, c.GstPercent, c.GstAmount, c.Net,
           CAST('POSTED' AS VARCHAR(10)), c.SourceModule, c.SourceNo, c.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm
    JOIN dbo.IpdCharge c ON c.AdmissionId = adm.AdmissionId AND c.Status = 'POSTED' AND c.ChargeAt <= @AsOf
    LEFT JOIN dbo.DoctorMaster doc ON doc.DoctorId = c.DoctorId
    WHERE adm.BillId IS NULL

    UNION ALL
    -- the final bill: its frozen lines
    SELECT l.LineKey, l.Head, l.ChargeAt, l.ItemCode, l.ItemName, l.Detail, l.DoctorName, l.Qty, l.Rate, l.Gross,
           CAST(l.ItemDiscount + l.BillDiscount AS DECIMAL(18,2)), l.GstPercent, l.GstAmount, l.Net,
           CAST('BILLED' AS VARCHAR(10)), l.SourceModule, l.SourceNo, l.IsPackageItem, CAST(0 AS BIT), CAST(0 AS BIT), l.DayNo, l.Sort
    FROM adm JOIN dbo.IpdBillLine l ON l.BillId = adm.BillId

    UNION ALL
    SELECT CAST('ROUNDOFF' AS NVARCHAR(40)), CAST('ADJUST' AS VARCHAR(20)), b.BillUpToAt, CAST(NULL AS NVARCHAR(50)), CAST(N'Round off' AS NVARCHAR(250)),
           CAST(NULL AS NVARCHAR(300)), CAST(NULL AS NVARCHAR(150)), CAST(1 AS DECIMAL(18,3)), b.RoundOff, CAST(0 AS DECIMAL(18,2)), CAST(0 AS DECIMAL(18,2)),
           CAST(0 AS DECIMAL(5,2)), CAST(0 AS DECIMAL(18,2)), b.RoundOff, CAST('BILLED' AS VARCHAR(10)), CAST('IPD' AS VARCHAR(10)), b.BillNo,
           CAST(0 AS BIT), CAST(0 AS BIT), CAST(0 AS BIT), CAST(NULL AS INT), 0
    FROM adm JOIN dbo.IpdBill b ON b.BillId = adm.BillId WHERE b.RoundOff <> 0
);
GO
-- Money of an admission. NetAdvance = money held from the patient: advances + settlements - refunds.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_Money (@AdmissionId INT)
RETURNS TABLE
AS RETURN
(
    SELECT CAST(ISNULL(SUM(CASE WHEN Kind = 'ADVANCE' THEN Amount END), 0) AS DECIMAL(18,2)) AS AdvanceTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'REFUND' THEN Amount END), 0) AS DECIMAL(18,2)) AS RefundTotal,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'REFUND' THEN -Amount ELSE Amount END), 0) AS DECIMAL(18,2)) AS NetAdvance,
           CAST(ISNULL(SUM(CASE WHEN Kind = 'SETTLE' THEN Amount END), 0) AS DECIMAL(18,2)) AS SettleTotal
    FROM dbo.IpdAdvance WHERE AdmissionId = @AdmissionId AND IsActive = 1
);
GO

-- ── 4. ledger (replaces 2423): advance, refund, bill, adjustment, settlement ─────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostLedger
    @Kind   VARCHAR(10),   -- ADVRCPT / SETTLERCPT (RefId = PaymentDetailId) | ADVREFUND (RefId = AdvanceId)
                           -- BILL / BILLADJ / SETTLEMOVE (RefId = IpdBill.BillId; SETTLEMOVE needs @Amount)
    @RefId  INT,
    @UserId INT = NULL,
    @Amount DECIMAL(18,2) = NULL,
    @TransactionId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Patient Advance'),
            @cash INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account'),
            @bank INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account'),
            @recv INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable'),
            @rev INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'IPD Revenue'),
            @discL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed'),
            @roL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off'),
            @gstL INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'GST Output Payable');
    IF @adv IS NULL THROW 54090, 'The ledger "IPD Patient Advance" is missing (run SQLScripts/2422).', 1;
    DECLARE @co INT, @br INT, @date DATETIME, @amt DECIMAL(18,2), @mode VARCHAR(30), @ref NVARCHAR(100), @no NVARCHAR(50), @ip NVARCHAR(40),
            @party NVARCHAR(250), @narr NVARCHAR(400), @lines NVARCHAR(MAX), @modeLedger INT, @tid BIGINT, @vno NVARCHAR(50);
    SET @TransactionId = NULL;
    IF @Kind IN ('ADVRCPT', 'SETTLERCPT')
    BEGIN
        SELECT @co = ph.CompanyId, @br = ph.BranchId, @date = COALESCE(pd.PaymentDate, pd.CreatedDate), @amt = pd.PaidAmount, @mode = UPPER(pm.MethodCode),
               @ref = COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo), @no = pd.ReceiptNo, @ip = a.IpNo,
               @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.PaymentDetail pd
        JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND RTRIM(ph.ModuleCode) = 'IPD'
        JOIN dbo.IpdAdmission a ON a.AdmissionId = ph.ModuleRefId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1;
        IF @amt IS NULL OR @amt <= 0 RETURN;
        IF @Kind = 'SETTLERCPT' AND @recv IS NULL THROW 54091, 'The ledger "Patient Receivable" is missing.', 1;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(CASE WHEN @Kind = 'ADVRCPT' THEN N'IPD advance receipt ' ELSE N'IPD bill settlement ' END, @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@modeLedger, @amt, 0, N'Received by ' + @mode),
                      (CASE WHEN @Kind = 'ADVRCPT' THEN @adv ELSE @recv END, 0, @amt, CASE WHEN @Kind = 'ADVRCPT' THEN N'Advance from patient' ELSE N'Bill amount received' END)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        DECLARE @rt NVARCHAR(30) = CASE WHEN @Kind = 'ADVRCPT' THEN 'IPD_ADVANCE' ELSE 'IPD_SETTLE' END;
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'RCT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt, @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind = 'ADVREFUND'
    BEGIN
        SELECT @co = a.CompanyId, @br = a.BranchId, @date = v.CreatedDate, @amt = v.Amount, @mode = UPPER(ISNULL(pm.MethodCode, v.Mode)), @ref = v.RefNo,
               @no = v.DocNo, @ip = a.IpNo, @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName)))
        FROM dbo.IpdAdvance v
        JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
        JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.MethodName = v.Mode OR UPPER(pm.MethodCode) = UPPER(v.Mode)
        WHERE v.AdvanceId = @RefId AND v.Kind = 'REFUND' AND v.IsActive = 1;
        IF @amt IS NULL OR @amt <= 0 RETURN;
        SET @modeLedger = dbo.fn_Acc_ModeLedger(@br, @mode, CASE WHEN @mode = 'CASH' THEN @cash ELSE @bank END);
        SET @narr = CONCAT(N'IPD advance refund ', @no, N' - ', @ip, N' - ', @party, N' (', @mode, ISNULL(N' ' + @ref, N''), N')');
        SET @lines = (SELECT * FROM (VALUES (@adv, @amt, 0, N'Advance refunded'), (@modeLedger, 0, @amt, N'Paid back by ' + @mode)) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH);
        EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'PMT', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_ADVREFUND', @ReferenceId = @RefId,
             @Narration = @narr, @PayeeName = @party, @PaymentMode = @mode, @InstrumentNo = @ref, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
             @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
    END
    ELSE IF @Kind IN ('BILL', 'BILLADJ', 'SETTLEMOVE')
    BEGIN
        IF @recv IS NULL OR @rev IS NULL OR @discL IS NULL OR @roL IS NULL OR @gstL IS NULL
            THROW 54092, 'A ledger of the IPD bill is missing (Patient Receivable, IPD Revenue, Discount Allowed, Round Off, GST Output Payable).', 1;
        DECLARE @gross DECIMAL(18,2), @disc DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @adj DECIMAL(18,2);
        SELECT @co = b.CompanyId, @br = b.BranchId, @date = CASE WHEN @Kind = 'SETTLEMOVE' THEN GETDATE() ELSE b.BillAt END, @no = b.BillNo, @ip = a.IpNo,
               @party = LTRIM(RTRIM(CONCAT(p.FirstName, ' ', p.LastName))),
               @gross = b.Gross, @disc = b.ItemDiscount + b.BillDiscount, @gst = b.Gst, @ro = b.RoundOff, @net = b.Net, @adj = b.AdvanceAdjusted
        FROM dbo.IpdBill b JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
        WHERE b.BillId = @RefId;
        IF @no IS NULL RETURN;
        IF @Kind = 'BILL'
        BEGIN
            IF @gross <= 0 AND @net <= 0 RETURN;
            SET @narr = CONCAT(N'IPD final bill ', @no, N' - ', @ip, N' - ', @party);
            SET @lines = (SELECT LedgerId, Dr, Cr, Narration FROM (VALUES
                            (@recv, @net, CAST(0 AS DECIMAL(18,2)), N'Bill amount'),
                            (@discL, @disc, 0, N'Discount on the bill'),
                            (@rev, 0, @gross, N'IPD charges'),
                            (@gstL, 0, @gst, N'GST on the bill'),
                            (@roL, CASE WHEN @ro < 0 THEN -@ro ELSE 0 END, CASE WHEN @ro > 0 THEN @ro ELSE 0 END, N'Round off')) v (LedgerId, Dr, Cr, Narration)
                          WHERE Dr > 0 OR Cr > 0 FOR JSON PATH);
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'SLS', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = 'IPD_BILL', @ReferenceId = @RefId,
                 @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
                 @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
        END
        ELSE
        BEGIN
            SET @amt = CASE WHEN @Kind = 'BILLADJ' THEN @adj ELSE @Amount END;
            IF ISNULL(@amt, 0) <= 0 RETURN;
            SET @narr = CASE WHEN @Kind = 'BILLADJ' THEN CONCAT(N'IPD advance adjusted against bill ', @no, N' - ', @ip, N' - ', @party)
                             ELSE CONCAT(N'IPD bill ', @no, N' cancelled: settlement received kept as advance - ', @ip, N' - ', @party) END;
            SET @lines = CASE WHEN @Kind = 'BILLADJ'
                              THEN (SELECT * FROM (VALUES (@adv, @amt, 0, N'Advance adjusted'), (@recv, 0, @amt, N'Against the bill')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH)
                              ELSE (SELECT * FROM (VALUES (@recv, @amt, 0, N'Bill cancelled'), (@adv, 0, @amt, N'Kept as advance')) v (LedgerId, Dr, Cr, Narration) FOR JSON PATH) END;
            DECLARE @rt2 NVARCHAR(30) = CASE WHEN @Kind = 'BILLADJ' THEN 'IPD_BILLADJ' ELSE 'IPD_SETTLEMOVE' END;
            EXEC dbo.usp_Acc_PostVoucher @VoucherTypeCode = 'JRN', @TransactionDate = @date, @CompanyId = @co, @BranchId = @br, @ReferenceType = @rt2, @ReferenceId = @RefId,
                 @Narration = @narr, @PayeeName = @party, @PaymentMode = NULL, @InstrumentNo = NULL, @LinesJson = @lines, @IsManual = 0, @UserId = @UserId,
                 @TransactionId = @tid OUTPUT, @VoucherNo = @vno OUTPUT;
        END
    END
    SET @TransactionId = @tid;
END;
GO

-- ── 5. receipts (replaces 2423): before the final bill = advance, after it = settlement up to the balance ──
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostAdvance
    @AdmissionId INT, @UserId INT, @Payments NVARCHAR(MAX), @Remarks NVARCHAR(300) = NULL,
    @AdvanceId INT OUTPUT, @ReceiptNo NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Pay TABLE (Seq INT IDENTITY(1,1), Method VARCHAR(20), Amount DECIMAL(18,4), Ref NVARCHAR(100), MethodId INT NULL);
    IF ISJSON(@Payments) = 1
        INSERT @Pay (Method, Amount, Ref)
        SELECT UPPER(LTRIM(RTRIM(j.Method))), j.Amount, NULLIF(LTRIM(RTRIM(j.Ref)), N'')
        FROM OPENJSON(@Payments) WITH (Method VARCHAR(20), Amount DECIMAL(18,4), Ref NVARCHAR(100)) j
        WHERE ISNULL(j.Amount, 0) <> 0;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Amount < 0) THROW 54101, 'A payment amount cannot be negative.', 1;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Amount <> ROUND(Amount, 2)) THROW 54102, 'A payment amount can have at most two decimals.', 1;
    UPDATE p SET MethodId = pm.PaymentMethodId FROM @Pay p JOIN dbo.PaymentMethodMaster pm ON UPPER(pm.MethodCode) = p.Method AND pm.IsActive = 1 AND UPPER(pm.MethodCode) <> 'POINTS';
    IF EXISTS (SELECT 1 FROM @Pay WHERE MethodId IS NULL) THROW 54103, 'Choose a valid payment mode for every amount entered.', 1;
    IF EXISTS (SELECT 1 FROM @Pay WHERE Method <> 'CASH' AND Ref IS NULL) THROW 54111, 'Enter the reference (UPI / card / NEFT / cheque no.) of every non-cash payment.', 1;
    DECLARE @total DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM @Pay);
    IF @total <= 0 THROW 54104, 'Enter the amount.', 1;
    DECLARE @dupRef NVARCHAR(100) = (SELECT TOP 1 Ref FROM @Pay WHERE Ref IS NOT NULL GROUP BY Ref HAVING COUNT(*) > 1);
    IF @dupRef IS NOT NULL BEGIN DECLARE @m1 NVARCHAR(300) = N'Reference ' + @dupRef + N' is entered on more than one payment line.'; THROW 54105, @m1, 1; END;
    DECLARE @usedRef NVARCHAR(100), @usedRcpt NVARCHAR(50);
    SELECT TOP 1 @usedRef = p.Ref, @usedRcpt = pd.ReceiptNo
    FROM @Pay p JOIN dbo.PaymentDetail pd ON pd.IsActive = 1 AND p.Method <> 'CASH' AND p.Ref IS NOT NULL AND (pd.UPIRefNo = p.Ref OR pd.TransactionRef = p.Ref OR pd.ChequeNo = p.Ref);
    IF @usedRef IS NOT NULL
    BEGIN
        DECLARE @m2 NVARCHAR(400) = N'Reference ' + @usedRef + N' is already recorded on receipt ' + ISNULL(@usedRcpt, N'(no receipt no.)') + N'. The same UPI / bank transaction cannot be collected twice.';
        THROW 54106, @m2, 1;
    END;

    DECLARE @co INT, @br INT, @patient INT, @ip NVARCHAR(40), @open BIT, @status VARCHAR(20), @billId INT;
    SELECT @co = CompanyId, @br = BranchId, @patient = PatientId, @ip = IpNo, @open = IsOpen, @status = Status, @billId = BillId
    FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId;
    IF @ip IS NULL THROW 54107, 'The admission was not found.', 1;
    IF @open = 0 THROW 54108, 'The admission is closed: money can be taken only while the patient is admitted.', 1;
    DECLARE @kind VARCHAR(10) = CASE WHEN @billId IS NOT NULL THEN 'SETTLE' ELSE 'ADVANCE' END;
    IF @kind = 'SETTLE'
    BEGIN
        DECLARE @due DECIMAL(18,2) = (SELECT b.Net FROM dbo.IpdBill b WHERE b.BillId = @billId) - (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        IF @due <= 0 THROW 54109, 'The final bill is fully paid: nothing is due.', 1;
        IF @total > @due BEGIN DECLARE @m3 NVARCHAR(300) = CONCAT(N'Only ₹', FORMAT(@due, 'N2', 'en-IN'), N' is due on the final bill.'); THROW 54110, @m3, 1; END;
    END

    DECLARE @label NVARCHAR(40) = CASE WHEN @kind = 'SETTLE' THEN N'IPD bill settlement ' ELSE N'IPD advance ' END;
    INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue, HeaderDiscountAmount,
           NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
    VALUES ('IPD', @AdmissionId, @br, @patient, @total, 0, NULL, 0, 0, @total, @total, 0, 'P', LEFT(@label + @ip + ISNULL(N' - ' + @Remarks, N''), 500),
            GETDATE(), @UserId, 1, 0, 0, 0, @co, 0);
    DECLARE @headerId INT = CAST(SCOPE_IDENTITY() AS INT);
    EXEC dbo.usp_Receipt_GetNextNo @BranchId = @br, @ReceiptNo = @ReceiptNo OUTPUT;

    DECLARE @s INT = (SELECT MIN(Seq) FROM @Pay), @pd INT, @lk VARCHAR(10) = CASE WHEN @kind = 'SETTLE' THEN 'SETTLERCPT' ELSE 'ADVRCPT' END;
    WHILE @s IS NOT NULL
    BEGIN
        INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
        SELECT @headerId, p.MethodId, p.Amount, CASE WHEN p.Method NOT IN ('UPI', 'CHEQUE') THEN p.Ref END, CASE WHEN p.Method = 'UPI' THEN p.Ref END,
               CASE WHEN p.Method = 'CARD' AND LEN(p.Ref) >= 4 THEN RIGHT(p.Ref, 4) END, CASE WHEN p.Method = 'CHEQUE' THEN p.Ref END,
               GETDATE(), LEFT(@label + @ip, 300), GETDATE(), @UserId, 1, @ReceiptNo, @co
        FROM @Pay p WHERE p.Seq = @s;
        SET @pd = CAST(SCOPE_IDENTITY() AS INT);
        EXEC dbo.usp_Ipd_PostLedger @Kind = @lk, @RefId = @pd, @UserId = @UserId;
        SET @s = (SELECT MIN(Seq) FROM @Pay WHERE Seq > @s);
    END

    INSERT dbo.IpdAdvance (AdmissionId, Kind, Amount, DocNo, PaymentHeaderId, Remarks, CreatedBy)
    VALUES (@AdmissionId, @kind, @total, @ReceiptNo, @headerId, @Remarks, @UserId);
    SET @AdvanceId = CAST(SCOPE_IDENTITY() AS INT);
    INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
    VALUES (@AdmissionId, @kind, CONCAT(CASE WHEN @kind = 'SETTLE' THEN N'Bill payment ₹' ELSE N'Advance ₹' END, FORMAT(@total, 'N2', 'en-IN'), N' received, receipt ', @ReceiptNo), @UserId);
END;
GO

-- ── 6. charges ──────────────────────────────────────────────────────────────────────────────────────────────
-- Is a head of an admission inside its package? (posted charges of a covered head are package items at 0)
CREATE OR ALTER FUNCTION dbo.fn_Ipd_InPackage (@AdmissionId INT, @Head VARCHAR(20))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM dbo.IpdAdmission a CROSS APPLY dbo.fn_Ipd_PackageCover(a.PackageId) c
                             WHERE a.AdmissionId = @AdmissionId AND c.Head = @Head AND @Head <> 'BED') THEN 1 ELSE 0 END;
END;
GO
-- The only writer of IpdCharge. Inside the caller's transaction; refuses with THROW 549xx.
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_PostCharge
    @AdmissionId INT, @UserId INT, @Head VARCHAR(20), @ItemCode NVARCHAR(50) = NULL, @ItemName NVARCHAR(250),
    @SourceModule VARCHAR(10) = 'IPD', @SourceId INT = NULL, @SourceNo NVARCHAR(50) = NULL, @DoctorId INT = NULL, @ChargeAt DATETIME,
    @Qty DECIMAL(18,3), @Rate DECIMAL(18,2), @Discount DECIMAL(18,2) = 0, @GstPercent DECIMAL(5,2) = 0, @Remarks NVARCHAR(300) = NULL,
    @ExcludePackage BIT = 0, @MasterRate DECIMAL(18,2) = NULL, @RefKind VARCHAR(10) = NULL, @RefId INT = NULL,
    @ChargeId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @open BIT, @status VARCHAR(20), @admAt DATETIME, @bill INT;
    SELECT @open = IsOpen, @status = Status, @admAt = AdmissionAt, @bill = BillId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId;
    IF @open IS NULL THROW 54901, 'The admission was not found.', 1;
    IF @open = 0 OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') OR @bill IS NOT NULL
        THROW 54902, 'Charges can be added only before the final bill (cancel the bill to add more).', 1;
    IF @Head NOT IN ('DOCTOR', 'LAB', 'RADIOLOGY', 'PHARMACY', 'CONSUMABLE', 'PROCEDURE', 'OT', 'SERVICE') THROW 54903, 'Choose the bill head of the charge.', 1;
    IF NULLIF(LTRIM(RTRIM(@ItemName)), N'') IS NULL THROW 54904, 'Enter the name of the charge.', 1;
    IF ISNULL(@Qty, 0) <= 0 THROW 54905, 'The quantity must be more than zero.', 1;
    IF ISNULL(@Rate, -1) < 0 THROW 54906, 'The rate cannot be negative.', 1;
    IF @ChargeAt < @admAt THROW 54907, 'The charge cannot be dated before the admission.', 1;
    IF @ChargeAt > DATEADD(MINUTE, 5, GETDATE()) THROW 54908, 'The charge cannot be dated in the future.', 1;
    IF @GstPercent < 0 OR @GstPercent > 28 THROW 54909, 'GST % must be between 0 and 28.', 1;
    DECLARE @gross DECIMAL(18,2) = ROUND(@Qty * @Rate, 2);
    SET @Discount = ISNULL(@Discount, 0);
    IF @Discount < 0 OR @Discount > @gross THROW 54910, 'The discount cannot be more than the amount.', 1;
    DECLARE @pkg BIT = CASE WHEN ISNULL(@ExcludePackage, 0) = 0 THEN dbo.fn_Ipd_InPackage(@AdmissionId, @Head) ELSE 0 END;
    DECLARE @g DECIMAL(18,2) = CASE WHEN @pkg = 1 THEN 0 ELSE @gross END, @d DECIMAL(18,2) = CASE WHEN @pkg = 1 THEN 0 ELSE @Discount END;
    DECLARE @gst DECIMAL(18,2) = ROUND((@g - @d) * CASE WHEN @pkg = 1 THEN 0 ELSE @GstPercent END / 100, 2);
    INSERT dbo.IpdCharge (AdmissionId, ChargeAt, Head, ItemCode, ItemName, SourceModule, SourceId, SourceNo, DoctorId, Qty, Rate, Gross, Discount, GstPercent, GstAmount, Net,
           IsPackageItem, Status, Remarks, CreatedBy, ListDiscount, ExcludePackage, MasterRate, RefKind, RefId)
    VALUES (@AdmissionId, @ChargeAt, @Head, @ItemCode, LTRIM(RTRIM(@ItemName)), ISNULL(@SourceModule, 'IPD'), @SourceId, @SourceNo, @DoctorId, @Qty, @Rate, @g, @d,
            CASE WHEN @pkg = 1 THEN 0 ELSE @GstPercent END, @gst, @g - @d + @gst, @pkg, 'POSTED', NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId,
            @Discount, ISNULL(@ExcludePackage, 0), @MasterRate, @RefKind, @RefId);
    SET @ChargeId = SCOPE_IDENTITY();
END;
GO
-- Lines: [{Kind: SERVICE|PROCEDURE|DOCTOR|MANUAL, RefId, Head, ItemName, Qty, Rate, Discount, GstPercent, DoctorId, ChargeAt, Remarks, ExcludePackage}]
-- The master rate is used; a different rate (or a charge without a master rate) needs @CanEditRate, a discount @CanDiscount.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCharge_Add
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @Lines NVARCHAR(MAX), @CanEditRate BIT = 0, @CanDiscount BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @tcat INT;
        SELECT @tcat = TariffCategoryId FROM dbo.IpdAdmission WITH (UPDLOCK) WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @tcat IS NULL THROW 54911, 'The admission was not found in this branch.', 1;
        IF ISJSON(@Lines) <> 1 THROW 54912, 'Add at least one charge.', 1;
        DECLARE @L TABLE (Seq INT IDENTITY(1,1), Kind VARCHAR(10), RefId INT, Head VARCHAR(20), ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Qty DECIMAL(18,3), Rate DECIMAL(18,2),
                          Discount DECIMAL(18,2), GstPercent DECIMAL(5,2), DoctorId INT, ChargeAt DATETIME, Remarks NVARCHAR(300), ExcludePackage BIT, MasterRate DECIMAL(18,2), VisitType VARCHAR(12));
        INSERT @L (Kind, RefId, Head, ItemName, Qty, Rate, Discount, GstPercent, DoctorId, ChargeAt, Remarks, ExcludePackage, VisitType)
        SELECT UPPER(j.Kind), j.RefId, UPPER(NULLIF(j.Head, '')), j.ItemName, ISNULL(j.Qty, 1), j.Rate, ISNULL(j.Discount, 0), ISNULL(j.GstPercent, 0), j.DoctorId,
               ISNULL(j.ChargeAt, @now), j.Remarks, ISNULL(j.ExcludePackage, 0), ISNULL(UPPER(NULLIF(j.VisitType, '')), 'ROUTINE')
        FROM OPENJSON(@Lines) WITH (Kind VARCHAR(10), RefId INT, Head VARCHAR(20), ItemName NVARCHAR(250), Qty DECIMAL(18,3), Rate DECIMAL(18,2), Discount DECIMAL(18,2),
                                    GstPercent DECIMAL(5,2), DoctorId INT, ChargeAt DATETIME, Remarks NVARCHAR(300), ExcludePackage BIT, VisitType VARCHAR(12)) j;
        IF NOT EXISTS (SELECT 1 FROM @L) THROW 54912, 'Add at least one charge.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE Kind NOT IN ('SERVICE', 'PROCEDURE', 'DOCTOR', 'MANUAL') OR Kind IS NULL) THROW 54913, 'Unknown kind of charge.', 1;
        -- masters
        UPDATE l SET ItemCode = s.ServiceCode, ItemName = s.ServiceName, GstPercent = ISNULL(s.TaxPercentage, 0),
               Head = CASE WHEN s.ServiceType LIKE N'OT%' THEN 'OT' WHEN s.ServiceType LIKE N'%Consumable%' THEN 'CONSUMABLE' WHEN s.ServiceType LIKE N'%Radiolog%' OR s.ServiceType LIKE N'%Imaging%' THEN 'RADIOLOGY' ELSE 'SERVICE' END,
               MasterRate = r.Rate
        FROM @L l JOIN dbo.HospitalServiceMaster s ON s.HospitalServiceId = l.RefId AND s.BranchId = @BranchId AND s.IsActive = 1
        OUTER APPLY dbo.fn_Ipd_ServiceRate(@BranchId, l.RefId, @tcat, CAST(l.ChargeAt AS DATE)) r
        WHERE l.Kind = 'SERVICE';
        UPDATE l SET ItemCode = p.ProcedureCode, ItemName = p.ProcedureName, GstPercent = 0, Head = 'PROCEDURE', MasterRate = r.Rate
        FROM @L l JOIN dbo.ProcedureMaster p ON p.ProcedureId = l.RefId AND p.BranchId = @BranchId AND p.IsActive = 1
        OUTER APPLY dbo.fn_Ipd_ProcedureRate(@BranchId, l.RefId, @tcat, CAST(l.ChargeAt AS DATE)) r
        WHERE l.Kind = 'PROCEDURE';
        IF EXISTS (SELECT 1 FROM @L WHERE Kind = 'DOCTOR' AND VisitType NOT IN ('ROUTINE', 'EMERGENCY', 'CROSS', 'NIGHT')) THROW 54919, 'Choose the type of visit.', 1;
        UPDATE l SET DoctorId = d.DoctorId, ItemCode = l.VisitType,
               ItemName = CASE l.VisitType WHEN 'EMERGENCY' THEN N'Emergency visit' WHEN 'CROSS' THEN N'Cross consultation' WHEN 'NIGHT' THEN N'Night visit' ELSE N'Routine round' END + N' - ' + d.FullName,
               GstPercent = 0, Head = 'DOCTOR', MasterRate = f.Rate
        FROM @L l JOIN dbo.DoctorMaster d ON d.DoctorId = l.RefId AND d.IsActive = 1 AND d.CompanyId = @CompanyId
        OUTER APPLY dbo.fn_Ipd_DoctorFee(@BranchId, l.RefId, l.VisitType, @tcat, CAST(l.ChargeAt AS DATE)) f
        WHERE l.Kind = 'DOCTOR';
        IF EXISTS (SELECT 1 FROM @L WHERE Kind <> 'MANUAL' AND Head IS NULL) THROW 54914, 'A service, procedure or doctor chosen is not active in this branch.', 1;
        -- a service / procedure / doctor without a tariff rate for the patient cannot be charged (no rate entry instead)
        DECLARE @noRateKind VARCHAR(10);
        SELECT TOP 1 @msg = ItemName, @noRateKind = Kind FROM @L WHERE Kind <> 'MANUAL' AND ISNULL(MasterRate, 0) <= 0;
        IF @msg IS NOT NULL
        BEGIN
            SET @msg = N'"' + @msg + N'" has no rate for this patient''s tariff category: it cannot be charged. '
                     + CASE WHEN @noRateKind = 'DOCTOR' THEN N'Add the doctor''s visit charge in Master > IPD Master > IPD Doctor Visit Charges first.' ELSE N'Add the rate in the master tariff first.' END;
            THROW 54918, @msg, 1;
        END
        UPDATE @L SET Rate = MasterRate WHERE Rate IS NULL AND MasterRate IS NOT NULL;
        IF EXISTS (SELECT 1 FROM @L WHERE Rate IS NULL) THROW 54915, 'Enter the rate of every charge.', 1;
        -- a doctor visit is always charged at the doctor's IPD visit charge (no rate change, even with RATE_EDIT)
        UPDATE @L SET Rate = MasterRate WHERE Kind = 'DOCTOR';
        IF ISNULL(@CanEditRate, 0) = 0
        BEGIN
            SET @msg = (SELECT TOP 1 ItemName FROM @L WHERE Kind = 'MANUAL' OR Rate <> MasterRate);
            IF @msg IS NOT NULL
            BEGIN
                SET @msg = N'"' + @msg + N'": the rate was changed or entered - you are not allowed to (ask for the rate-edit right).';
                THROW 54916, @msg, 1;
            END
        END
        IF ISNULL(@CanDiscount, 0) = 0 AND EXISTS (SELECT 1 FROM @L WHERE Discount > 0) THROW 54917, 'You are not allowed to give a discount on a charge.', 1;
        IF EXISTS (SELECT 1 FROM @L WHERE Kind = 'DOCTOR' AND ISNULL(Head, '') <> 'DOCTOR') THROW 54914, 'Choose the doctor.', 1;
        DECLARE @s INT = 1, @id BIGINT, @n INT = (SELECT COUNT(*) FROM @L);
        DECLARE @Ids TABLE (ChargeId BIGINT);
        DECLARE @h VARCHAR(20), @ic NVARCHAR(50), @in NVARCHAR(250), @q DECIMAL(18,3), @r DECIMAL(18,2), @dsc DECIMAL(18,2), @gp DECIMAL(5,2), @doc INT, @at DATETIME,
                @rm NVARCHAR(300), @ex BIT, @mr DECIMAL(18,2), @k VARCHAR(10), @ref INT;
        WHILE @s <= @n
        BEGIN
            SELECT @h = Head, @ic = ItemCode, @in = ItemName, @q = Qty, @r = Rate, @dsc = Discount, @gp = GstPercent, @doc = DoctorId, @at = ChargeAt, @rm = Remarks,
                   @ex = ExcludePackage, @mr = MasterRate, @k = Kind, @ref = RefId FROM @L WHERE Seq = @s;
            EXEC dbo.usp_Ipd_PostCharge @AdmissionId = @AdmissionId, @UserId = @UserId, @Head = @h, @ItemCode = @ic, @ItemName = @in, @SourceModule = 'IPD',
                 @DoctorId = @doc, @ChargeAt = @at, @Qty = @q, @Rate = @r, @Discount = @dsc, @GstPercent = @gp, @Remarks = @rm, @ExcludePackage = @ex,
                 @MasterRate = @mr, @RefKind = @k, @RefId = @ref, @ChargeId = @id OUTPUT;
            INSERT @Ids VALUES (@id);
            SET @s += 1;
        END
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        SELECT @AdmissionId, 'CHARGE', CONCAT(@n, N' charge(s) added: ', STRING_AGG(CAST(ItemName AS NVARCHAR(MAX)), N', ')), @UserId FROM @L;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @n AS Added, (SELECT STRING_AGG(CAST(ChargeId AS VARCHAR(20)), ',') FROM @Ids) AS ChargeIds;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCharge_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @ChargeId BIGINT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54921, 'Enter the reason for cancelling the charge.', 1;
        DECLARE @adm INT, @st VARCHAR(10), @src VARCHAR(10), @bill INT, @name NVARCHAR(250), @net DECIMAL(18,2);
        SELECT @adm = c.AdmissionId, @st = c.Status, @src = c.SourceModule, @bill = a.BillId, @name = c.ItemName, @net = c.Net
        FROM dbo.IpdCharge c WITH (UPDLOCK) JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId
        WHERE c.ChargeId = @ChargeId AND a.CompanyId = @CompanyId AND a.BranchId = @BranchId;
        IF @adm IS NULL THROW 54922, 'The charge was not found in this branch.', 1;
        IF @st <> 'POSTED' THROW 54923, 'The charge is already cancelled.', 1;
        IF @bill IS NOT NULL THROW 54924, 'The final bill is made: cancel the bill first.', 1;
        IF ISNULL(@src, 'IPD') <> 'IPD' THROW 54925, 'This charge comes from another module: cancel it there (e.g. LAB order, pharmacy issue).', 1;
        UPDATE dbo.IpdCharge SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = GETDATE() WHERE ChargeId = @ChargeId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@adm, 'CHARGE_CANCEL', CONCAT(N'Charge cancelled: ', @name, N' ₹', FORMAT(@net, 'N2', 'en-IN'), N' - ', LTRIM(RTRIM(@Reason))), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdCharge_List @CompanyId INT, @AdmissionId INT, @Head VARCHAR(20) = NULL, @IncludeCancelled BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Head = NULLIF(@Head, '');
    SELECT c.ChargeId, c.ChargeAt, c.Head, hd.HeadName, c.ItemCode, c.ItemName, c.SourceModule, c.SourceNo, c.DoctorId, d.FullName AS DoctorName,
           c.Qty, c.Rate, c.MasterRate, c.Gross, c.Discount, c.ListDiscount, c.GstPercent, c.GstAmount, c.Net, c.IsPackageItem, c.ExcludePackage, c.Status,
           c.Remarks, c.CancelReason, c.CancelledAt, uc.FullName AS CancelledByName, u.FullName AS CreatedByName, c.CreatedDate, c.RefKind
    FROM dbo.IpdCharge c
    JOIN dbo.IpdAdmission a ON a.AdmissionId = c.AdmissionId AND a.CompanyId = @CompanyId
    LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = c.Head
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = c.DoctorId
    LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    LEFT JOIN dbo.Users uc ON uc.Id = c.CancelledBy
    WHERE c.AdmissionId = @AdmissionId AND (@Head IS NULL OR c.Head = @Head) AND (ISNULL(@IncludeCancelled, 0) = 1 OR c.Status = 'POSTED')
    ORDER BY c.ChargeAt DESC, c.ChargeId DESC;
END;
GO
-- Pick lists of the charge screens with the patient's rates (tariff category of the admission).
CREATE OR ALTER PROCEDURE dbo.usp_Api_Ipd_ChargeLookups @CompanyId INT, @BranchId INT, @AdmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tc INT, @pkg INT, @today DATE = CAST(GETDATE() AS DATE);
    SELECT @tc = TariffCategoryId, @pkg = PackageId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    IF @tc IS NULL RETURN;
    -- 1 services
    SELECT s.HospitalServiceId AS Id, s.ServiceCode AS Code, s.ServiceName AS Name, s.ServiceType AS [Type], s.UOM, CAST(ISNULL(s.TaxPercentage, 0) AS DECIMAL(5,2)) AS GstPercent,
           r.Rate, r.UsedFallback
    FROM dbo.HospitalServiceMaster s OUTER APPLY dbo.fn_Ipd_ServiceRate(@BranchId, s.HospitalServiceId, @tc, @today) r
    WHERE s.BranchId = @BranchId AND s.IsActive = 1 ORDER BY s.ServiceName;
    -- 2 procedures
    SELECT p.ProcedureId AS Id, p.ProcedureCode AS Code, p.ProcedureName AS Name, p.ProcedureCategory AS [Type], r.Rate, r.SurgeonFee, r.AssistantFee, r.AnaesthetistFee,
           r.OtCharges, r.EquipmentCharges, r.ConsumableCharges, r.NursingCharges, r.UsedFallback
    FROM dbo.ProcedureMaster p OUTER APPLY dbo.fn_Ipd_ProcedureRate(@BranchId, p.ProcedureId, @tc, @today) r
    WHERE p.BranchId = @BranchId AND p.IsActive = 1 ORDER BY p.ProcedureName;
    -- 3 doctors of IPD-type departments with their IPD visit charges (IPD > Doctor Visit Charges)
    SELECT d.DoctorId AS Id, d.FullName AS Name, fr.Rate AS RoutineRate, fe.Rate AS EmergencyRate, fc.Rate AS CrossRate, fn.Rate AS NightRate,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster dp ON dp.DeptId = m.DeptId AND dp.IsActive = 1 WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 AND dp.DeptType = 'IPD') THEN 1 ELSE 0 END AS BIT) AS IsIpd
    FROM dbo.DoctorMaster d
    OUTER APPLY dbo.fn_Ipd_DoctorFee(@BranchId, d.DoctorId, 'ROUTINE', @tc, @today) fr
    OUTER APPLY dbo.fn_Ipd_DoctorFee(@BranchId, d.DoctorId, 'EMERGENCY', @tc, @today) fe
    OUTER APPLY dbo.fn_Ipd_DoctorFee(@BranchId, d.DoctorId, 'CROSS', @tc, @today) fc
    OUTER APPLY dbo.fn_Ipd_DoctorFee(@BranchId, d.DoctorId, 'NIGHT', @tc, @today) fn
    WHERE d.CompanyId = @CompanyId AND d.IsActive = 1
      AND EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster dp ON dp.DeptId = m.DeptId AND dp.IsActive = 1 WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 AND dp.DeptType = 'IPD')
    ORDER BY d.FullName;
    -- 4 packages of the branch
    SELECT p.HospitalPackage_ID AS Id, p.Package_Code AS Code, p.Package_Name AS Name, p.Package_Type AS [Type], p.TotalPackageAmount AS Amount,
           (SELECT MAX(c.Days) FROM dbo.fn_Ipd_PackageCover(p.HospitalPackage_ID) c WHERE c.Head = 'BED') AS BedDays,
           (SELECT STRING_AGG(c.Head, ',') FROM dbo.fn_Ipd_PackageCover(p.HospitalPackage_ID) c) AS Heads
    FROM dbo.HospitalPackageMaster p
    WHERE p.Branch_ID = @BranchId AND p.Status = 1 AND (p.ValidTo IS NULL OR p.ValidTo >= @today) AND ISNULL(p.TotalPackageAmount, 0) > 0 ORDER BY p.Package_Name;
    -- 5 the admission's package and what it includes
    SELECT d.DetailHeadType, d.ItemName, d.Quantity, d.UnitRate, d.Amount, d.BillingFrequency, d.Remarks
    FROM dbo.HospitalPackageDetail d WHERE d.HospitalPackage_ID = @pkg ORDER BY d.DisplayOrder, d.HospitalPackageDetail_ID;
END;
GO
-- Puts the admission on a package (or takes it off): the posted charges of covered heads are re-priced.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_SetPackage @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @PackageId INT = NULL, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @bill INT, @old INT, @status VARCHAR(20);
        SELECT @open = IsOpen, @bill = BillId, @old = PackageId, @status = Status FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54931, 'The admission was not found in this branch.', 1;
        IF @open = 0 OR @bill IS NOT NULL OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 54932, 'The package can be changed only before the final bill.', 1;
        IF @PackageId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId AND Branch_ID = @BranchId AND Status = 1)
            THROW 54933, 'Choose an active package of this branch.', 1;
        IF @PackageId IS NOT NULL AND ISNULL((SELECT TotalPackageAmount FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), 0) <= 0
            THROW 54936, 'This package has no amount (Master > Hospital Package): it cannot be applied.', 1;
        IF ISNULL(@old, 0) = ISNULL(@PackageId, 0) THROW 54934, 'The admission is already on this package.', 1;
        IF @old IS NOT NULL AND NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54935, 'Enter the reason for changing the package.', 1;
        UPDATE dbo.IpdAdmission SET PackageId = @PackageId, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE AdmissionId = @AdmissionId;
        UPDATE c SET IsPackageItem = x.Pkg,
               Gross = CASE WHEN x.Pkg = 1 THEN 0 ELSE ROUND(c.Qty * c.Rate, 2) END,
               Discount = CASE WHEN x.Pkg = 1 THEN 0 ELSE ISNULL(c.ListDiscount, 0) END,
               GstPercent = CASE WHEN x.Pkg = 1 THEN 0 ELSE ISNULL(c.GstPercent, 0) END
        FROM dbo.IpdCharge c CROSS APPLY (SELECT CASE WHEN c.ExcludePackage = 0 THEN dbo.fn_Ipd_InPackage(c.AdmissionId, c.Head) ELSE 0 END AS Pkg) x
        WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED' AND ISNULL(c.SourceModule, 'IPD') = 'IPD';
        -- GST % of a charge that left the package comes back from its master
        UPDATE c SET GstPercent = ISNULL(s.TaxPercentage, 0)
        FROM dbo.IpdCharge c JOIN dbo.HospitalServiceMaster s ON s.HospitalServiceId = c.RefId
        WHERE c.AdmissionId = @AdmissionId AND c.Status = 'POSTED' AND c.RefKind = 'SERVICE' AND c.IsPackageItem = 0;
        UPDATE dbo.IpdCharge SET GstAmount = ROUND((Gross - Discount) * GstPercent / 100, 2) WHERE AdmissionId = @AdmissionId AND Status = 'POSTED';
        UPDATE dbo.IpdCharge SET Net = Gross - Discount + GstAmount WHERE AdmissionId = @AdmissionId AND Status = 'POSTED';
        INSERT dbo.IpdStatusLog (AdmissionId, Action, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'PACKAGE', CONCAT(N'Package ', ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @old), N'none'), N' → ',
                ISNULL((SELECT Package_Name FROM dbo.HospitalPackageMaster WHERE HospitalPackage_ID = @PackageId), N'none'), ISNULL(N': ' + NULLIF(LTRIM(RTRIM(@Reason)), N''), N'')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO

-- ── 7. the final bill ───────────────────────────────────────────────────────────────────────────────────────
-- Works out the bill into the caller's #IpdBillCalc (see usp_Api_IpdBill_Preview for its columns): the lines up to
-- @UpTo, the bill discount spread over the lines in proportion (before GST, GST worked out again), round off.
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_BillCalc
    @AdmissionId INT, @UpTo DATETIME, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0,
    @Gross DECIMAL(18,2) OUTPUT, @ItemDiscount DECIMAL(18,2) OUTPUT, @BillDiscount DECIMAL(18,2) OUTPUT, @Taxable DECIMAL(18,2) OUTPUT,
    @Gst DECIMAL(18,2) OUTPUT, @RoundOff DECIMAL(18,2) OUTPUT, @Net DECIMAL(18,2) OUTPUT, @NoTariff BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE #IpdBillCalc;
    INSERT #IpdBillCalc (LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
                         SourceModule, SourceNo, IsPackageItem, NoTariff, DayNo, Sort, ChargeId)
    SELECT l.LineKey, l.Head, l.ChargeAt, l.ItemCode, l.ItemName, l.Detail, l.DoctorName, l.Qty, l.Rate, l.Gross, l.Discount, 0, l.GstPercent, l.GstAmount, l.Net,
           l.SourceModule, l.SourceNo, l.IsPackageItem, l.NoTariff, l.DayNo, l.Sort,
           CASE WHEN l.LineKey LIKE 'C%' THEN TRY_CAST(SUBSTRING(l.LineKey, 2, 20) AS BIGINT) END
    FROM dbo.fn_Ipd_BillLines(@AdmissionId, @UpTo) l WHERE l.Status IN ('ACCRUED', 'POSTED');
    SET @NoTariff = CASE WHEN EXISTS (SELECT 1 FROM #IpdBillCalc WHERE NoTariff = 1) THEN 1 ELSE 0 END;
    SELECT @Gross = ISNULL(SUM(Gross), 0), @ItemDiscount = ISNULL(SUM(ItemDiscount), 0) FROM #IpdBillCalc;
    DECLARE @base DECIMAL(18,2) = @Gross - @ItemDiscount;
    SET @DiscountType = NULLIF(UPPER(@DiscountType), '');
    SET @DiscountValue = ISNULL(@DiscountValue, 0);
    IF @DiscountValue < 0 THROW 54941, 'The discount cannot be negative.', 1;
    IF @DiscountType = 'P' AND @DiscountValue > 100 THROW 54942, 'The discount % cannot be more than 100.', 1;
    SET @BillDiscount = CASE WHEN @DiscountType = 'P' THEN ROUND(@base * @DiscountValue / 100, 2) WHEN @DiscountType = 'F' THEN @DiscountValue ELSE 0 END;
    IF @BillDiscount > @base THROW 54943, 'The discount cannot be more than the bill amount.', 1;
    IF @BillDiscount > 0
    BEGIN
        UPDATE #IpdBillCalc SET BillDiscount = ROUND(@BillDiscount * (Gross - ItemDiscount) / @base, 2) WHERE Gross - ItemDiscount > 0;
        DECLARE @rest DECIMAL(18,2) = @BillDiscount - (SELECT SUM(BillDiscount) FROM #IpdBillCalc);
        IF @rest <> 0
            UPDATE t SET BillDiscount = BillDiscount + @rest
            FROM (SELECT TOP (1) * FROM #IpdBillCalc WHERE Gross - ItemDiscount - BillDiscount + @rest >= 0 AND Gross - ItemDiscount > 0 ORDER BY Gross - ItemDiscount DESC, LineKey) t;
        UPDATE #IpdBillCalc SET GstAmount = ROUND((Gross - ItemDiscount - BillDiscount) * GstPercent / 100, 2);
        UPDATE #IpdBillCalc SET Net = Gross - ItemDiscount - BillDiscount + GstAmount;
    END
    SET @Taxable = @base - @BillDiscount;
    SET @Gst = (SELECT ISNULL(SUM(GstAmount), 0) FROM #IpdBillCalc);
    DECLARE @exact DECIMAL(18,2) = @Taxable + @Gst;
    SET @Net = ROUND(@exact, 0);
    SET @RoundOff = @Net - @exact;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Preview @CompanyId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @admAt DATETIME, @bill INT;
    SELECT @admAt = AdmissionAt, @bill = BillId FROM dbo.IpdAdmission WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND Status <> 'CANCELLED';
    IF @admAt IS NULL RETURN;
    SET @UpTo = ISNULL(@UpTo, GETDATE());
    CREATE TABLE #IpdBillCalc (LineKey NVARCHAR(40), Head VARCHAR(20), ChargeAt DATETIME, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Detail NVARCHAR(300), DoctorName NVARCHAR(150),
        Qty DECIMAL(18,3), Rate DECIMAL(18,2), Gross DECIMAL(18,2), ItemDiscount DECIMAL(18,2), BillDiscount DECIMAL(18,2), GstPercent DECIMAL(5,2), GstAmount DECIMAL(18,2),
        Net DECIMAL(18,2), SourceModule VARCHAR(10), SourceNo NVARCHAR(50), IsPackageItem BIT, NoTariff BIT, DayNo INT, Sort INT, ChargeId BIGINT);
    DECLARE @g DECIMAL(18,2), @id DECIMAL(18,2), @bd DECIMAL(18,2), @tx DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @nt BIT, @err NVARCHAR(400);
    BEGIN TRY
        IF @bill IS NULL
            EXEC dbo.usp_Ipd_BillCalc @AdmissionId = @AdmissionId, @UpTo = @UpTo, @DiscountType = @DiscountType, @DiscountValue = @DiscountValue,
                 @Gross = @g OUTPUT, @ItemDiscount = @id OUTPUT, @BillDiscount = @bd OUTPUT, @Taxable = @tx OUTPUT, @Gst = @gst OUTPUT, @RoundOff = @ro OUTPUT, @Net = @net OUTPUT, @NoTariff = @nt OUTPUT;
    END TRY
    BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH
    IF @bill IS NOT NULL
        INSERT #IpdBillCalc (LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
                             SourceModule, SourceNo, IsPackageItem, NoTariff, DayNo, Sort, ChargeId)
        SELECT LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, 0, DayNo, Sort, ChargeId FROM dbo.IpdBillLine WHERE BillId = @bill;
    IF @bill IS NOT NULL
        SELECT @g = Gross, @id = ItemDiscount, @bd = BillDiscount, @tx = Taxable, @gst = Gst, @ro = RoundOff, @net = Net, @nt = 0, @UpTo = BillUpToAt FROM dbo.IpdBill WHERE BillId = @bill;
    DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId)), @adj DECIMAL(18,2);
    SET @adj = CASE WHEN @bill IS NOT NULL THEN (SELECT AdvanceAdjusted FROM dbo.IpdBill WHERE BillId = @bill) WHEN @held < ISNULL(@net, 0) THEN @held ELSE ISNULL(@net, 0) END;
    IF @adj < 0 SET @adj = 0;
    -- 1 totals
    SELECT @UpTo AS UpTo, @bill AS BillId, (SELECT BillNo FROM dbo.IpdBill WHERE BillId = @bill) AS BillNo, (SELECT BillAt FROM dbo.IpdBill WHERE BillId = @bill) AS BillAt, (SELECT SettleTotal FROM dbo.fn_Ipd_Money(@AdmissionId)) AS SettleTotal, ISNULL(@g, 0) AS Gross, ISNULL(@id, 0) AS ItemDiscount, ISNULL(@bd, 0) AS BillDiscount, ISNULL(@tx, 0) AS Taxable, ISNULL(@gst, 0) AS Gst,
           ISNULL(@ro, 0) AS RoundOff, ISNULL(@net, 0) AS Net, @held AS AdvanceHeld, @adj AS AdvanceAdjusted,
           CAST(CASE WHEN ISNULL(@net, 0) - @held > 0 THEN ISNULL(@net, 0) - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN @held - ISNULL(@net, 0) > 0 THEN @held - ISNULL(@net, 0) ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           ISNULL(@nt, 0) AS NoTariff, @err AS Error,
           (SELECT COUNT(*) FROM #IpdBillCalc) AS Lines,
           (SELECT COUNT(*) FROM #IpdBillCalc WHERE IsPackageItem = 1) AS PackageLines;
    -- 2 heads
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(l.Head) AS Lines, CAST(ISNULL(SUM(l.Gross), 0) AS DECIMAL(18,2)) AS Gross,
           CAST(ISNULL(SUM(l.ItemDiscount + l.BillDiscount), 0) AS DECIMAL(18,2)) AS Discount, CAST(ISNULL(SUM(l.GstAmount), 0) AS DECIMAL(18,2)) AS Gst,
           CAST(ISNULL(SUM(l.Net), 0) AS DECIMAL(18,2)) AS Net
    FROM dbo.fn_Ipd_Heads() hd LEFT JOIN #IpdBillCalc l ON l.Head = hd.Head
    WHERE hd.Head <> 'ADJUST'
    GROUP BY hd.Head, hd.HeadName, hd.Sort HAVING COUNT(l.Head) > 0 OR @bill IS NULL ORDER BY hd.Sort;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Finalise
    @CompanyId INT, @BranchId INT, @UserId INT, @AdmissionId INT, @UpTo DATETIME = NULL, @DiscountType CHAR(1) = NULL, @DiscountValue DECIMAL(18,2) = 0,
    @DiscountReason NVARCHAR(300) = NULL, @Remarks NVARCHAR(500) = NULL, @CanDiscount BIT = 0, @CanBackdate BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @msg NVARCHAR(600), @now DATETIME = GETDATE();
    CREATE TABLE #IpdBillCalc (LineKey NVARCHAR(40), Head VARCHAR(20), ChargeAt DATETIME, ItemCode NVARCHAR(50), ItemName NVARCHAR(250), Detail NVARCHAR(300), DoctorName NVARCHAR(150),
        Qty DECIMAL(18,3), Rate DECIMAL(18,2), Gross DECIMAL(18,2), ItemDiscount DECIMAL(18,2), BillDiscount DECIMAL(18,2), GstPercent DECIMAL(5,2), GstAmount DECIMAL(18,2),
        Net DECIMAL(18,2), SourceModule VARCHAR(10), SourceNo NVARCHAR(50), IsPackageItem BIT, NoTariff BIT, DayNo INT, Sort INT, ChargeId BIGINT);
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        DECLARE @open BIT, @status VARCHAR(20), @bill INT, @admAt DATETIME, @ip NVARCHAR(40);
        SELECT @open = IsOpen, @status = Status, @bill = BillId, @admAt = AdmissionAt, @ip = IpNo FROM dbo.IpdAdmission WITH (UPDLOCK)
        WHERE AdmissionId = @AdmissionId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF @open IS NULL THROW 54951, 'The admission was not found in this branch.', 1;
        IF @bill IS NOT NULL THROW 54952, 'The final bill is already made.', 1;
        IF @open = 0 OR @status NOT IN ('ADMITTED', 'DISCHARGE_ADVISED') THROW 54953, 'The final bill can be made only for an admitted patient.', 1;
        SET @UpTo = ISNULL(@UpTo, @now);
        IF @UpTo > DATEADD(MINUTE, 5, @now) THROW 54954, 'The bill time cannot be in the future.', 1;
        IF @UpTo < DATEADD(MINUTE, -30, @now) AND ISNULL(@CanBackdate, 0) = 0 THROW 54955, 'You are not allowed to bill up to an earlier time (more than 30 minutes back).', 1;
        IF @UpTo < @admAt THROW 54956, 'The bill time cannot be before the admission.', 1;
        IF EXISTS (SELECT 1 FROM dbo.IpdCharge WHERE AdmissionId = @AdmissionId AND Status = 'POSTED' AND ChargeAt > @UpTo)
            THROW 54957, 'Some charges are dated after the bill time: bill up to a later time or cancel them.', 1;
        SET @DiscountType = NULLIF(UPPER(@DiscountType), '');
        IF ISNULL(@DiscountValue, 0) > 0 AND @DiscountType IS NULL THROW 54958, 'Choose % or amount for the discount.', 1;
        IF ISNULL(@DiscountValue, 0) > 0 AND ISNULL(@CanDiscount, 0) = 0 THROW 54959, 'You are not allowed to give a discount on the bill.', 1;
        IF ISNULL(@DiscountValue, 0) > 0 AND NULLIF(LTRIM(RTRIM(@DiscountReason)), N'') IS NULL THROW 54960, 'Enter the reason for the discount.', 1;
        DECLARE @g DECIMAL(18,2), @id DECIMAL(18,2), @bd DECIMAL(18,2), @tx DECIMAL(18,2), @gst DECIMAL(18,2), @ro DECIMAL(18,2), @net DECIMAL(18,2), @nt BIT;
        EXEC dbo.usp_Ipd_BillCalc @AdmissionId = @AdmissionId, @UpTo = @UpTo, @DiscountType = @DiscountType, @DiscountValue = @DiscountValue,
             @Gross = @g OUTPUT, @ItemDiscount = @id OUTPUT, @BillDiscount = @bd OUTPUT, @Taxable = @tx OUTPUT, @Gst = @gst OUTPUT, @RoundOff = @ro OUTPUT, @Net = @net OUTPUT, @NoTariff = @nt OUTPUT;
        IF @nt = 1 THROW 54961, 'A bed day has no tariff (Master > IPD > Bed / Room Tariff): add the rate before the final bill.', 1;
        IF NOT EXISTS (SELECT 1 FROM #IpdBillCalc) THROW 54962, 'There is nothing to bill.', 1;
        DECLARE @held DECIMAL(18,2) = (SELECT NetAdvance FROM dbo.fn_Ipd_Money(@AdmissionId));
        DECLARE @adj DECIMAL(18,2) = CASE WHEN @held < @net THEN @held ELSE @net END;
        IF @adj < 0 SET @adj = 0;
        DECLARE @no NVARCHAR(40);
        EXEC dbo.usp_Ipd_NextNumber @BranchId = @BranchId, @DocType = 'IPB', @DocDate = @now, @DocNo = @no OUTPUT;
        INSERT dbo.IpdBill (CompanyId, BranchId, AdmissionId, BillNo, BillAt, BillUpToAt, Gross, ItemDiscount, BillDiscountType, BillDiscountValue, BillDiscount, DiscountReason,
               Taxable, Gst, RoundOff, Net, AdvanceAdjusted, PrevStatus, Status, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @AdmissionId, @no, @now, @UpTo, @g, @id, CASE WHEN @bd > 0 THEN @DiscountType END, CASE WHEN @bd > 0 THEN @DiscountValue ELSE 0 END, @bd,
                CASE WHEN @bd > 0 THEN LTRIM(RTRIM(@DiscountReason)) END, @tx, @gst, @ro, @net, @adj, @status, 'FINAL', NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
        DECLARE @billId INT = CAST(SCOPE_IDENTITY() AS INT);
        INSERT dbo.IpdBillLine (BillId, LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, DayNo, Sort, ChargeId)
        SELECT @billId, LineKey, Head, ChargeAt, ItemCode, ItemName, Detail, DoctorName, Qty, Rate, Gross, ItemDiscount, BillDiscount, GstPercent, GstAmount, Net,
               SourceModule, SourceNo, IsPackageItem, DayNo, Sort, ChargeId FROM #IpdBillCalc;
        UPDATE dbo.IpdAdmission SET BillId = @billId, BillUpToAt = @UpTo, Status = 'BILL_FINAL', ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @AdmissionId;
        DECLARE @t1 BIGINT, @t2 BIGINT;
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'BILL', @RefId = @billId, @UserId = @UserId, @TransactionId = @t1 OUTPUT;
        EXEC dbo.usp_Ipd_PostLedger @Kind = 'BILLADJ', @RefId = @billId, @UserId = @UserId, @TransactionId = @t2 OUTPUT;
        UPDATE dbo.IpdBill SET SalesTxnId = @t1, AdjustTxnId = @t2 WHERE BillId = @billId;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@AdmissionId, 'FINAL_BILL', @status, 'BILL_FINAL', CONCAT(N'Final bill ', @no, N' ₹', FORMAT(@net, 'N2', 'en-IN'),
                CASE WHEN @bd > 0 THEN CONCAT(N', discount ₹', FORMAT(@bd, 'N2', 'en-IN'), N' (', LTRIM(RTRIM(@DiscountReason)), N')') ELSE N'' END,
                N', advance adjusted ₹', FORMAT(@adj, 'N2', 'en-IN')), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @billId AS BillId, @no AS BillNo, @net AS Net, @adj AS AdvanceAdjusted,
               CAST(CASE WHEN @net - @held > 0 THEN @net - @held ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
               CAST(CASE WHEN @held - @net > 0 THEN @held - @net ELSE 0 END AS DECIMAL(18,2)) AS RefundDue;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
-- Reopens the bill: reversal vouchers, settlements received become advance, charges can be added again.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @BillId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT, @now DATETIME = GETDATE();
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL THROW 54971, 'Enter the reason for cancelling the bill.', 1;
        DECLARE @adm INT, @st VARCHAR(10), @prev VARCHAR(20), @no NVARCHAR(40), @t1 BIGINT, @t2 BIGINT, @open BIT, @admStatus VARCHAR(20);
        SELECT @adm = b.AdmissionId, @st = b.Status, @prev = b.PrevStatus, @no = b.BillNo, @t1 = b.SalesTxnId, @t2 = b.AdjustTxnId, @open = a.IsOpen, @admStatus = a.Status
        FROM dbo.IpdBill b WITH (UPDLOCK) JOIN dbo.IpdAdmission a WITH (UPDLOCK) ON a.AdmissionId = b.AdmissionId
        WHERE b.BillId = @BillId AND b.CompanyId = @CompanyId AND b.BranchId = @BranchId;
        IF @adm IS NULL THROW 54972, 'The bill was not found in this branch.', 1;
        IF @st <> 'FINAL' THROW 54973, 'The bill is already cancelled.', 1;
        IF @open = 0 OR @admStatus <> 'BILL_FINAL' THROW 54974, 'The patient is discharged: the bill cannot be cancelled.', 1;
        DECLARE @r BIGINT, @why NVARCHAR(300) = CONCAT(N'IPD bill ', @no, N' cancelled: ', LTRIM(RTRIM(@Reason)));
        IF @t1 IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @t1 AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t1, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        IF @t2 IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE TransactionId = @t2 AND Status <> 'C')
            EXEC dbo.usp_Acc_CancelVoucher @TransactionId = @t2, @Reason = @why, @UserId = @UserId, @ReversalId = @r OUTPUT;
        DECLARE @settled DECIMAL(18,2) = (SELECT ISNULL(SUM(Amount), 0) FROM dbo.IpdAdvance WHERE AdmissionId = @adm AND Kind = 'SETTLE' AND IsActive = 1);
        IF @settled > 0
        BEGIN
            EXEC dbo.usp_Ipd_PostLedger @Kind = 'SETTLEMOVE', @RefId = @BillId, @UserId = @UserId, @Amount = @settled;
            UPDATE dbo.IpdAdvance SET Kind = 'ADVANCE', Remarks = LEFT(CONCAT(ISNULL(Remarks + N' · ', N''), N'paid on cancelled bill ', @no), 300)
            WHERE AdmissionId = @adm AND Kind = 'SETTLE' AND IsActive = 1;
        END
        UPDATE dbo.IpdBill SET Status = 'CANCELLED', CancelReason = LTRIM(RTRIM(@Reason)), CancelledBy = @UserId, CancelledAt = @now WHERE BillId = @BillId;
        UPDATE dbo.IpdAdmission SET BillId = NULL, BillUpToAt = NULL, Status = @prev, ModifiedBy = @UserId, ModifiedDate = @now WHERE AdmissionId = @adm;
        INSERT dbo.IpdStatusLog (AdmissionId, Action, FromStatus, ToStatus, Remarks, CreatedBy)
        VALUES (@adm, 'BILL_CANCEL', 'BILL_FINAL', @prev, CONCAT(N'Bill ', @no, N' cancelled: ', LTRIM(RTRIM(@Reason)),
                CASE WHEN @settled > 0 THEN CONCAT(N' (₹', FORMAT(@settled, 'N2', 'en-IN'), N' received on it kept as advance)') ELSE N'' END), @UserId);
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @adm AS AdmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
-- A bill for print: bill, admission header, lines, heads, money.
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_Get @CompanyId INT, @BillId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adm INT = (SELECT AdmissionId FROM dbo.IpdBill WHERE BillId = @BillId AND CompanyId = @CompanyId);
    IF @adm IS NULL RETURN;
    SELECT b.*, u.FullName AS CreatedByName, uc.FullName AS CancelledByName, mo.NetAdvance AS AdvanceHeld, mo.AdvanceTotal, mo.RefundTotal, mo.SettleTotal,
           CAST(CASE WHEN b.Status = 'FINAL' AND b.Net - mo.NetAdvance > 0 THEN b.Net - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN b.Status = 'FINAL' AND mo.NetAdvance - b.Net > 0 THEN mo.NetAdvance - b.Net ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           s.HotelName AS HospitalName, s.Address AS HospitalAddress, s.ContactNumber1 AS HospitalPhone, s.EmailAddress AS HospitalEmail, s.GSTCode AS HospitalGstin
    FROM dbo.IpdBill b
    LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy LEFT JOIN dbo.Users uc ON uc.Id = b.CancelledBy
    LEFT JOIN dbo.HospitalSettings s ON s.BranchID = b.BranchId
    CROSS APPLY dbo.fn_Ipd_Money(b.AdmissionId) mo
    WHERE b.BillId = @BillId;
    SELECT h.* FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h;
    SELECT l.*, hd.HeadName, hd.Sort AS HeadSort FROM dbo.IpdBillLine l LEFT JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head
    WHERE l.BillId = @BillId ORDER BY hd.Sort, l.ChargeAt, l.DayNo, l.Sort, l.BillLineId;
    SELECT hd.Head, hd.HeadName, hd.Sort, COUNT(*) AS Lines, SUM(l.Gross) AS Gross, SUM(l.ItemDiscount + l.BillDiscount) AS Discount, SUM(l.GstAmount) AS Gst, SUM(l.Net) AS Net
    FROM dbo.IpdBillLine l JOIN dbo.fn_Ipd_Heads() hd ON hd.Head = l.Head WHERE l.BillId = @BillId GROUP BY hd.Head, hd.HeadName, hd.Sort ORDER BY hd.Sort;
    SELECT v.AdvanceId, v.Kind, v.Amount, v.DocNo, v.Mode, v.CreatedDate,
           (SELECT STRING_AGG(pm.MethodName, ', ') FROM dbo.PaymentDetail pd JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
            WHERE pd.PaymentHeaderId = v.PaymentHeaderId AND pd.IsActive = 1) AS Modes
    FROM dbo.IpdAdvance v WHERE v.AdmissionId = @adm AND v.IsActive = 1 ORDER BY v.CreatedDate, v.AdvanceId;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdBill_List @CompanyId INT, @BranchId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @Status VARCHAR(10) = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -30, CAST(GETDATE() AS DATE))); SET @ToDate = ISNULL(@ToDate, CAST(GETDATE() AS DATE));
    SET @Status = NULLIF(@Status, ''); SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Search + N'%';
    SELECT b.BillId, b.BillNo, b.BillAt, b.BillUpToAt, b.Status, b.Gross, b.ItemDiscount + b.BillDiscount AS Discount, b.Gst, b.RoundOff, b.Net, b.AdvanceAdjusted,
           a.AdmissionId, a.IpNo, a.PayerType, a.Status AS AdmissionStatus, p.PatientCode, p.PhoneNumber,
           LTRIM(RTRIM(CONCAT(NULLIF(p.Salutation, '') + ' ', p.FirstName, ' ', p.LastName))) AS PatientName, d.FullName AS ConsultantDoctorName,
           CAST(CASE WHEN b.Status = 'FINAL' AND b.Net - mo.NetAdvance > 0 THEN b.Net - mo.NetAdvance ELSE 0 END AS DECIMAL(18,2)) AS BalanceDue,
           CAST(CASE WHEN b.Status = 'FINAL' AND mo.NetAdvance - b.Net > 0 THEN mo.NetAdvance - b.Net ELSE 0 END AS DECIMAL(18,2)) AS RefundDue,
           u.FullName AS CreatedByName, b.CancelReason
    FROM dbo.IpdBill b
    JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    LEFT JOIN dbo.Users u ON u.Id = b.CreatedBy
    CROSS APPLY dbo.fn_Ipd_Money(a.AdmissionId) mo
    WHERE b.CompanyId = @CompanyId AND b.BranchId = @BranchId AND b.BillAt >= @FromDate AND b.BillAt < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))
      AND (@Status IS NULL OR b.Status = @Status)
      AND (@Search IS NULL OR b.BillNo LIKE @like OR a.IpNo LIKE @like OR p.PatientCode LIKE @like OR p.PhoneNumber LIKE @like OR CONCAT(p.FirstName, ' ', p.LastName) LIKE @like)
    ORDER BY b.BillAt DESC, b.BillId DESC;
END;
GO

-- ── 7b. IPD > Doctor Visit Charges (master) ─────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDoctorFee_Lookups @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1 doctors of IPD-type departments only, with their IPD departments
    SELECT d.DoctorId AS Id, d.FullName AS Name,
           (SELECT STRING_AGG(dp.DeptName, ', ') FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster dp ON dp.DeptId = m.DeptId AND dp.IsActive = 1
            WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 AND dp.DeptType = 'IPD') AS Departments
    FROM dbo.DoctorMaster d WHERE d.CompanyId = @CompanyId AND d.IsActive = 1 AND EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster dp ON dp.DeptId = m.DeptId AND dp.IsActive = 1 WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 AND dp.DeptType = 'IPD') ORDER BY d.FullName;
    -- 2 tariff categories
    SELECT TariffCategoryId AS Id, Name FROM dbo.TariffCategoryMaster WHERE IsActive = 1 ORDER BY Name;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDoctorFee_List @CompanyId INT, @BranchId INT, @DoctorId INT = NULL, @Search NVARCHAR(100) = NULL, @IncludeInactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    SELECT f.FeeId, f.DoctorId, d.FullName AS DoctorName, f.VisitType,
           CASE f.VisitType WHEN 'EMERGENCY' THEN N'Emergency visit' WHEN 'CROSS' THEN N'Cross consultation' WHEN 'NIGHT' THEN N'Night visit' ELSE N'Routine round' END AS VisitTypeName,
           f.TariffCategoryId, ISNULL(tc.Name, N'All categories') AS TariffCategoryName, f.Rate, f.EffectiveFrom, f.EffectiveTo, f.Remarks, f.IsActive,
           CAST(CASE WHEN f.IsActive = 1 AND f.EffectiveFrom <= @today AND (f.EffectiveTo IS NULL OR f.EffectiveTo >= @today) THEN 1 ELSE 0 END AS BIT) AS IsCurrent,
           u.FullName AS ModifiedByName, ISNULL(f.ModifiedDate, f.CreatedDate) AS ModifiedAt
    FROM dbo.IpdDoctorVisitFee f
    JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId
    LEFT JOIN dbo.TariffCategoryMaster tc ON tc.TariffCategoryId = f.TariffCategoryId
    LEFT JOIN dbo.Users u ON u.Id = ISNULL(f.ModifiedBy, f.CreatedBy)
    WHERE f.CompanyId = @CompanyId AND f.BranchId = @BranchId AND (ISNULL(@IncludeInactive, 0) = 1 OR f.IsActive = 1)
      AND (@DoctorId IS NULL OR f.DoctorId = @DoctorId) AND (@Search IS NULL OR d.FullName LIKE N'%' + @Search + N'%')
    ORDER BY d.FullName, CASE f.VisitType WHEN 'ROUTINE' THEN 1 WHEN 'EMERGENCY' THEN 2 WHEN 'CROSS' THEN 3 ELSE 4 END, tc.Name, f.EffectiveFrom DESC;
END;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDoctorFee_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @FeeId INT = NULL, @DoctorId INT, @VisitType VARCHAR(12), @TariffCategoryId INT = NULL,
    @Rate DECIMAL(18,2), @EffectiveFrom DATE, @EffectiveTo DATE = NULL, @Remarks NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @tc INT = @@TRANCOUNT;
    BEGIN TRY
        IF @tc = 0 BEGIN TRAN; ELSE SAVE TRAN ipd_sp;
        SET @VisitType = UPPER(@VisitType);
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND CompanyId = @CompanyId AND IsActive = 1) THROW 54981, 'Choose the doctor.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.DoctorMaster d WHERE d.DoctorId = @DoctorId AND EXISTS (SELECT 1 FROM dbo.DoctorDepartmentMap m JOIN dbo.DepartmentMaster dp ON dp.DeptId = m.DeptId AND dp.IsActive = 1 WHERE m.DoctorId = d.DoctorId AND m.IsActive = 1 AND dp.DeptType = 'IPD'))
            THROW 54990, 'Only a doctor of an IPD-type department can have IPD visit charges (Master > Doctor > departments of type IPD).', 1;
        IF @VisitType NOT IN ('ROUTINE', 'EMERGENCY', 'CROSS', 'NIGHT') OR @VisitType IS NULL THROW 54982, 'Choose the type of visit.', 1;
        IF @TariffCategoryId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.TariffCategoryMaster WHERE TariffCategoryId = @TariffCategoryId AND IsActive = 1) THROW 54983, 'Choose a valid tariff category.', 1;
        IF ISNULL(@Rate, 0) <= 0 THROW 54984, 'Enter the visit charge (more than zero).', 1;
        IF @Rate <> ROUND(@Rate, 2) THROW 54985, 'The charge can have at most two decimals.', 1;
        IF @EffectiveFrom IS NULL THROW 54986, 'Enter the date from which the charge applies.', 1;
        IF @EffectiveTo IS NOT NULL AND @EffectiveTo < @EffectiveFrom THROW 54987, 'The end date cannot be before the start date.', 1;
        IF @FeeId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.IpdDoctorVisitFee WITH (UPDLOCK) WHERE FeeId = @FeeId AND CompanyId = @CompanyId AND BranchId = @BranchId)
            THROW 54988, 'The charge was not found in this branch.', 1;
        -- no two active charges of the same doctor, visit and category over the same dates
        IF EXISTS (SELECT 1 FROM dbo.IpdDoctorVisitFee WITH (UPDLOCK, HOLDLOCK)
                   WHERE BranchId = @BranchId AND DoctorId = @DoctorId AND VisitType = @VisitType AND IsActive = 1 AND FeeId <> ISNULL(@FeeId, 0)
                     AND ISNULL(TariffCategoryId, 0) = ISNULL(@TariffCategoryId, 0)
                     AND EffectiveFrom <= ISNULL(@EffectiveTo, '9999-12-31') AND ISNULL(EffectiveTo, '9999-12-31') >= @EffectiveFrom)
            THROW 54989, 'This doctor already has a visit charge over these dates. Edit it, or end it (Effective To) before adding a new one.', 1;
        IF @FeeId IS NULL
        BEGIN
            INSERT dbo.IpdDoctorVisitFee (CompanyId, BranchId, DoctorId, VisitType, TariffCategoryId, Rate, EffectiveFrom, EffectiveTo, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @DoctorId, @VisitType, @TariffCategoryId, @Rate, @EffectiveFrom, @EffectiveTo, NULLIF(LTRIM(RTRIM(@Remarks)), N''), @UserId);
            SET @FeeId = CAST(SCOPE_IDENTITY() AS INT);
        END
        ELSE
            UPDATE dbo.IpdDoctorVisitFee SET DoctorId = @DoctorId, VisitType = @VisitType, TariffCategoryId = @TariffCategoryId, Rate = @Rate, EffectiveFrom = @EffectiveFrom,
                   EffectiveTo = @EffectiveTo, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), N''), IsActive = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE FeeId = @FeeId;
        IF @tc = 0 COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error, @FeeId AS FeeId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 OR (XACT_STATE() = 1 AND @tc = 0) ROLLBACK; ELSE IF XACT_STATE() = 1 ROLLBACK TRAN ipd_sp;
        IF ERROR_NUMBER() >= 50000 SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; ELSE THROW;
    END CATCH
END;
GO
-- Deactivates a charge (kept for history; visits already charged keep their amount).
CREATE OR ALTER PROCEDURE dbo.usp_Api_IpdDoctorFee_Remove @CompanyId INT, @BranchId INT, @UserId INT, @FeeId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.IpdDoctorVisitFee SET IsActive = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE FeeId = @FeeId AND CompanyId = @CompanyId AND BranchId = @BranchId AND IsActive = 1;
    IF @@ROWCOUNT = 0 SELECT CAST(0 AS BIT) AS Success, CAST(N'The charge was not found or is already removed.' AS NVARCHAR(600)) AS Error;
    ELSE SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(600)) AS Error;
END;
GO

-- ── 8. ledger check (replaces 2432): settlements and bills too ─────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ipd_LedgerCheck @BranchId INT = NULL, @Repair BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @M TABLE (Kind VARCHAR(10), RefId INT, DocNo NVARCHAR(50), Amount DECIMAL(18,2), IpNo NVARCHAR(40), CreatedDate DATETIME);
    INSERT @M
    SELECT CASE WHEN v.Kind = 'SETTLE' THEN 'SETTLERCPT' ELSE 'ADVRCPT' END, pd.PaymentDetailId, pd.ReceiptNo, pd.PaidAmount, a.IpNo, pd.CreatedDate
    FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND RTRIM(ph.ModuleCode) = 'IPD' AND ph.IsActive = 1
    JOIN dbo.IpdAdmission a ON a.AdmissionId = ph.ModuleRefId
    LEFT JOIN dbo.IpdAdvance v ON v.PaymentHeaderId = ph.PaymentHeaderId
    WHERE pd.IsActive = 1 AND pd.PaidAmount > 0 AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType IN ('IPD_ADVANCE', 'IPD_SETTLE') AND t.ReferenceId = pd.PaymentDetailId AND t.IsActive = 1 AND t.ReversalOfTransactionId IS NULL)
    UNION ALL
    SELECT 'ADVREFUND', v.AdvanceId, v.DocNo, v.Amount, a.IpNo, v.CreatedDate
    FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
    WHERE v.Kind = 'REFUND' AND v.IsActive = 1 AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t WHERE t.ReferenceType = 'IPD_ADVREFUND' AND t.ReferenceId = v.AdvanceId AND t.IsActive = 1 AND t.ReversalOfTransactionId IS NULL)
    UNION ALL
    SELECT 'BILL', b.BillId, b.BillNo, b.Net, a.IpNo, b.BillAt
    FROM dbo.IpdBill b JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId
    WHERE b.Status = 'FINAL' AND b.SalesTxnId IS NULL AND b.Gross > 0 AND (@BranchId IS NULL OR b.BranchId = @BranchId)
    UNION ALL
    SELECT 'BILLADJ', b.BillId, b.BillNo, b.AdvanceAdjusted, a.IpNo, b.BillAt
    FROM dbo.IpdBill b JOIN dbo.IpdAdmission a ON a.AdmissionId = b.AdmissionId
    WHERE b.Status = 'FINAL' AND b.AdjustTxnId IS NULL AND b.AdvanceAdjusted > 0 AND (@BranchId IS NULL OR b.BranchId = @BranchId);

    IF @Repair = 1
    BEGIN
        DECLARE @k VARCHAR(10), @id INT, @t BIGINT;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Kind, RefId FROM @M ORDER BY CreatedDate;
        OPEN c; FETCH NEXT FROM c INTO @k, @id;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @t = NULL;
                EXEC dbo.usp_Ipd_PostLedger @Kind = @k, @RefId = @id, @UserId = @UserId, @TransactionId = @t OUTPUT;
                IF @k = 'BILL' UPDATE dbo.IpdBill SET SalesTxnId = @t WHERE BillId = @id;
                IF @k = 'BILLADJ' UPDATE dbo.IpdBill SET AdjustTxnId = @t WHERE BillId = @id;
            END TRY
            BEGIN CATCH PRINT CONCAT('Not posted ', @k, ' ', @id, ': ', ERROR_MESSAGE()); END CATCH
            FETCH NEXT FROM c INTO @k, @id;
        END
        CLOSE c; DEALLOCATE c;
    END
    -- 1 money / bills without a voucher (before the repair)
    SELECT * FROM @M ORDER BY CreatedDate;
    -- 2 advance held per IPD (advances - refunds - adjusted on final bills) against the IPD Patient Advance ledger
    SELECT (SELECT ISNULL(SUM(CASE WHEN v.Kind = 'ADVANCE' THEN v.Amount WHEN v.Kind = 'REFUND' THEN -v.Amount ELSE 0 END), 0) FROM dbo.IpdAdvance v
             JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId WHERE v.IsActive = 1 AND (@BranchId IS NULL OR a.BranchId = @BranchId))
         - (SELECT ISNULL(SUM(b.AdvanceAdjusted), 0) FROM dbo.IpdBill b WHERE b.Status = 'FINAL' AND (@BranchId IS NULL OR b.BranchId = @BranchId)) AS AdvanceHeldPerIpd,
           (SELECT ISNULL(SUM(d.CreditAmount - d.DebitAmount), 0) FROM dbo.Acc_LedgerTransactionDetail d
             JOIN dbo.Acc_LedgerTransaction t ON t.TransactionId = d.TransactionId AND t.IsActive = 1 AND (@BranchId IS NULL OR t.BranchId = @BranchId)
             JOIN dbo.Acc_LedgerMaster l ON l.LedgerId = d.LedgerId AND l.LedgerName = 'IPD Patient Advance') AS AdvanceLedgerBalance;
END;
GO

-- ── 9. day closing: module IPD (receipts = advances and settlements, refunds = IPD advance refunds) ──────
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_CashClosing_Module' AND definition NOT LIKE '%IPD%')
BEGIN
    ALTER TABLE dbo.CashClosing DROP CONSTRAINT CK_CashClosing_Module;
    ALTER TABLE dbo.CashClosing ADD CONSTRAINT CK_CashClosing_Module CHECK (Module IN ('OPD', 'LAB', 'PHR', 'IPD'));
END
GO
-- ── 4. A user's cash-desk transactions at a branch, by business date ──────────────────────────────────────────
-- @Module OPD / LAB / PHR / IPD (NULL = all): the module's money receipts (not a franchise wallet deduction: no money at the
-- counter) and refunds paid; and always the petty cash floats against a CASH ledger (common to both modules) with the
-- closing that took each one (PettyClosingId, NULL = not closed yet). CreatedAt (when it was entered) decides which
-- closing of the day covers a receipt or a refund.
CREATE OR ALTER FUNCTION dbo.fn_CashClosing_Txns (@UserId INT, @BranchId INT, @Module VARCHAR(10), @FromDate DATE, @ToDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT ph.BranchId, CAST(COALESCE(pd.PaymentDate, pd.CreatedDate) AS DATE) AS BusinessDate,
           'RECEIPT' AS Kind, CAST(ph.ModuleCode AS VARCHAR(10)) AS Module, pd.PaymentDetailId AS RefId, CAST(pd.ReceiptNo AS NVARCHAR(60)) AS RefNo,
           CAST(COALESCE(pos.OPDBillNo, lo.BillNo, phs.SaleNo, ia.IpNo) AS NVARCHAR(60)) AS BillNo,
           CAST(COALESCE(NULLIF(phs.CustomerName, ''), NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))), ''), N'Walk-in') AS NVARCHAR(250)) AS PartyName,
           CAST(ISNULL(pm.MethodName, 'Unknown') AS NVARCHAR(100)) AS ModeName,
           CAST(CASE WHEN pm.MethodCode = 'CASH' THEN 1 ELSE 0 END AS BIT) AS IsCash,
           CAST(pd.PaidAmount AS DECIMAL(18, 2)) AS Amount,
           COALESCE(pd.PaymentDate, pd.CreatedDate) AS TxnAt, pd.CreatedDate AS CreatedAt, CAST(NULL AS INT) AS PettyClosingId
    FROM dbo.PaymentDetail pd
    INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId AND ph.IsActive = 1
    LEFT  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = ph.PatientId
    LEFT  JOIN dbo.PatientOPDService pos ON ph.ModuleCode = 'OPD' AND pos.OPDServiceId = COALESCE(ph.OPDServiceId, ph.ModuleRefId)
    LEFT  JOIN dbo.LabOrder lo ON ph.ModuleCode = 'LAB' AND lo.LabOrderId = ph.ModuleRefId
    LEFT  JOIN dbo.PhSale phs ON ph.ModuleCode = 'PHR' AND phs.SaleId = ph.ModuleRefId
    LEFT  JOIN dbo.IpdAdmission ia ON ph.ModuleCode = 'IPD' AND ia.AdmissionId = ph.ModuleRefId
    WHERE pd.IsActive = 1 AND pd.CreatedBy = @UserId AND pd.PaidAmount > 0
      AND ph.ModuleCode IN ('OPD', 'LAB', 'PHR', 'IPD') AND (@Module IS NULL OR ph.ModuleCode = @Module)
      AND (@BranchId IS NULL OR ph.BranchId = @BranchId)
      AND ISNULL(pd.TransactionRef, '') NOT LIKE 'WALLET-DEBIT-%'
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) >= @FromDate
      AND COALESCE(pd.PaymentDate, pd.CreatedDate) < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))

    UNION ALL

    SELECT COALESCE(ph.BranchId, pos.BranchId, lo.BranchId, phs.BranchId), CAST(r.RefundDate AS DATE),
           'REFUND', CAST(r.ModuleCode AS VARCHAR(10)), r.RefundId, CAST(bc.CancellationNo AS NVARCHAR(60)),
           CAST(COALESCE(pos.OPDBillNo, lo.BillNo, phs.SaleNo) AS NVARCHAR(60)),
           CAST(COALESCE(NULLIF(phs.CustomerName, ''), NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))), ''), N'Walk-in') AS NVARCHAR(250)),
           CAST(ISNULL(NULLIF(LTRIM(RTRIM(r.RefundMode)), ''), 'Not recorded') AS NVARCHAR(100)),
           CAST(CASE WHEN r.RefundMode LIKE '%cash%' THEN 1 ELSE 0 END AS BIT),
           CAST(r.RefundAmount AS DECIMAL(18, 2)), r.RefundDate, r.CreatedDate, NULL
    FROM dbo.BillRefund r
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = r.ModuleCode AND ph.ModuleRefId = r.ModuleRefId AND ph.IsActive = 1
    LEFT  JOIN dbo.PatientOPDService pos ON r.ModuleCode = 'OPD' AND pos.OPDServiceId = r.ModuleRefId
    LEFT  JOIN dbo.LabOrder lo ON r.ModuleCode = 'LAB' AND lo.LabOrderId = r.ModuleRefId
    LEFT  JOIN dbo.PhSale phs ON r.ModuleCode = 'PHR' AND phs.SaleId = r.ModuleRefId
    LEFT  JOIN dbo.PatientMaster p ON p.PatientId = COALESCE(ph.PatientId, pos.PatientId, lo.PatientId)
    LEFT  JOIN dbo.BillCancellation bc ON bc.CancellationId = r.CancellationId
    WHERE r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P' AND r.CreatedBy = @UserId AND ISNULL(r.RefundAmount, 0) > 0
      AND r.ModuleCode IN ('OPD', 'LAB', 'PHR') AND (@Module IS NULL OR r.ModuleCode = @Module)
      AND (@BranchId IS NULL OR COALESCE(ph.BranchId, pos.BranchId, lo.BranchId, phs.BranchId) = @BranchId)
      AND r.RefundDate >= @FromDate AND r.RefundDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))

    UNION ALL

    -- IPD advance refunds (SQLScripts/2434): IpdAdvance REFUND rows (IPD does not use BillRefund)
    SELECT a.BranchId, CAST(v.CreatedDate AS DATE), 'REFUND', CAST('IPD' AS VARCHAR(10)), v.AdvanceId, CAST(v.DocNo AS NVARCHAR(60)),
           CAST(a.IpNo AS NVARCHAR(60)),
           CAST(NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName + ' ', '') + ISNULL(p.LastName, ''))), '') AS NVARCHAR(250)),
           CAST(ISNULL(NULLIF(LTRIM(RTRIM(v.Mode)), ''), 'Not recorded') AS NVARCHAR(100)),
           CAST(CASE WHEN v.Mode LIKE '%cash%' THEN 1 ELSE 0 END AS BIT),
           CAST(v.Amount AS DECIMAL(18, 2)), v.CreatedDate, v.CreatedDate, NULL
    FROM dbo.IpdAdvance v
    JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    WHERE v.Kind = 'REFUND' AND v.IsActive = 1 AND v.CreatedBy = @UserId AND (@Module IS NULL OR @Module = 'IPD')
      AND (@BranchId IS NULL OR a.BranchId = @BranchId)
      AND v.CreatedDate >= @FromDate AND v.CreatedDate < DATEADD(DAY, 1, CAST(@ToDate AS DATETIME))

    UNION ALL

    SELECT c.BranchId, f.TxnDate,
           CASE WHEN f.Kind = 'RETURN' THEN 'PETTYIN' ELSE 'PETTYOUT' END, 'PETTY', f.FloatId, CAST(f.VoucherNo AS NVARCHAR(60)), NULL,
           CAST(c.CounterName AS NVARCHAR(250)),
           CAST(CASE f.Kind WHEN 'ISSUE' THEN N'Float issued' WHEN 'REPLENISH' THEN N'Float replenished' ELSE N'Float returned' END AS NVARCHAR(100)),
           CAST(1 AS BIT), CAST(f.Amount AS DECIMAL(18, 2)),
           CASE WHEN CAST(f.CreatedDate AS DATE) = f.TxnDate THEN f.CreatedDate ELSE CAST(f.TxnDate AS DATETIME) END, f.CreatedDate,
           cp.CashClosingId
    FROM dbo.Acc_PettyCashFloat f
    INNER JOIN dbo.Acc_PettyCashCounter c ON c.CounterId = f.CounterId
    INNER JOIN dbo.Acc_LedgerMaster src ON src.LedgerId = f.SourceLedgerId AND src.LedgerType = 'CASH'
    LEFT  JOIN dbo.CashClosingPetty cp ON cp.FloatId = f.FloatId
    WHERE f.CreatedBy = @UserId AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND f.TxnDate >= @FromDate AND f.TxnDate <= @ToDate
);
GO
DECLARE @p SYSNAME, @def NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM (VALUES ('usp_CashClosing_Summary'), ('usp_CashClosing_Submit')) v (name);
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.' + @p));
    IF @def LIKE '%NOT IN (''OPD'', ''LAB'', ''PHR'')%'
    BEGIN
        SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
        SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
        SET @def = REPLACE(@def, 'NOT IN (''OPD'', ''LAB'', ''PHR'')', 'NOT IN (''OPD'', ''LAB'', ''PHR'', ''IPD'')');
        EXEC (@def);
    END
    FETCH NEXT FROM c INTO @p;
END
CLOSE c; DEALLOCATE c;
GO

-- ── 10. pages ───────────────────────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @nav INT, @page INT, @view INT, @ctl INT, @i INT = 1;
SELECT @nav = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'IPD';
SET @co = 1;
DECLARE @pages TABLE (n INT IDENTITY, Code NVARCHAR(60), Title NVARCHAR(100), Ctl NVARCHAR(60), Act NVARCHAR(60), Sort INT, Icon NVARCHAR(60), ViewActs NVARCHAR(400));
INSERT @pages (Code, Title, Ctl, Act, Sort, Icon, ViewActs) VALUES
 (N'IPD.DOCTORFEE',        N'IPD Doctor Visit Charges',      N'IpdDoctorFee',  N'Index', 240, N'bi bi-person-badge-fill me-2', N'Index,ListData,Lookups'),
 (N'IPD.BILLS',            N'IPD Bills',                     N'IpdBilling',    N'Index',  45, N'bi bi-receipt-cutoff me-2', N'Index,ListData,PrintBill'),
 (N'IPD.DAYCLOSING',       N'IPD Day Closing',               N'IpdDayClosing', N'Index',  60, N'bi bi-calendar2-check me-2', N'Index,Summary,Receivers'),
 (N'IPD.DAYCLOSINGVERIFY', N'IPD Day Closing Verification',  N'IpdDayClosing', N'Verify', 65, N'bi bi-shield-check me-2', N'Verify,Board,Detail,VerifySlip');
DECLARE @controls TABLE (Code NVARCHAR(60), Control VARCHAR(30), Title NVARCHAR(150), Sort INT, Method VARCHAR(4), Ctl NVARCHAR(60), Acts NVARCHAR(200));
INSERT @controls VALUES
 (N'IPD.DOCTORFEE',        'SAVE',          N'Add / edit a doctor visit charge', 20, 'POST', N'IpdDoctorFee', N'Save'),
 (N'IPD.DOCTORFEE',        'DELETE',        N'Remove a doctor visit charge', 30, 'POST', N'IpdDoctorFee', N'Remove'),
 (N'IPD.DAYCLOSING',       'CREATE',        N'Submit a day closing', 20, 'POST', N'IpdDayClosing', N'Submit'),
 (N'IPD.DAYCLOSING',       'PRINT',         N'Print the hand-over slip', 30, 'GET', N'IpdDayClosing', N'Slip'),
 (N'IPD.DAYCLOSINGVERIFY', 'VERIFY',        N'Verify / send back a day closing', 20, 'POST', N'IpdDayClosing', N'VerifyAction'),
 (N'IPD.PATIENT',          'CHARGE',        N'Add charges (services, procedures, doctor visits)', 90, 'POST', N'IpdBilling', N'AddCharges'),
 (N'IPD.PATIENT',          'CHARGE_CANCEL', N'Cancel a charge', 92, 'POST', N'IpdBilling', N'CancelCharge'),
 (N'IPD.PATIENT',          'RATE_EDIT',     N'Enter / change the rate of a charge', 94, 'POST', N'IpdBilling', N''),
 (N'IPD.PATIENT',          'DISCOUNT',      N'Give a discount on a charge or the bill', 96, 'POST', N'IpdBilling', N''),
 (N'IPD.PATIENT',          'PACKAGE',       N'Put the patient on a package / change it', 98, 'POST', N'IpdBilling', N'SetPackage'),
 (N'IPD.PATIENT',          'FINAL_BILL',    N'Make the final bill', 100, 'POST', N'IpdBilling', N'Finalise'),
 (N'IPD.PATIENT',          'BILL_BACKDATE', N'Bill up to an earlier time', 101, 'POST', N'IpdBilling', N''),
 (N'IPD.PATIENT',          'BILL_CANCEL',   N'Cancel a final bill (reopen)', 102, 'POST', N'IpdBilling', N'CancelBill');
DECLARE @code NVARCHAR(60), @title NVARCHAR(100), @c NVARCHAR(60), @a NVARCHAR(60), @sort INT, @icon NVARCHAR(60), @va NVARCHAR(400), @act NVARCHAR(60),
        @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @cm VARCHAR(4), @cctl NVARCHAR(60), @ca NVARCHAR(200);
WHILE @i <= (SELECT COUNT(*) FROM @pages)
BEGIN
    SELECT @code = Code, @title = Title, @c = Ctl, @a = Act, @sort = Sort, @icon = Icon, @va = ViewActs FROM @pages WHERE n = @i;
    SET @page = NULL;
    DECLARE @menuId INT = CASE WHEN @code = N'IPD.DOCTORFEE' THEN (SELECT Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.IPD_MASTER') ELSE @nav END;   -- Master > IPD Master
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menuId, @Page_Code = @code, @Title = @title, @Controller = @c, @Action = @a,
         @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@va, ',');
    OPEN a; FETCH NEXT FROM a INTO @act;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = @c, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
    CLOSE a; DEALLOCATE a;
    SET @i += 1;
END
-- controls (IPD.PATIENT gets the billing controls; its view also opens the billing reads)
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Control, Title, Sort, Method, Ctl, Acts FROM @controls;
OPEN k; FETCH NEXT FROM k INTO @code, @cc, @ct, @cs, @cm, @cctl, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = @code AND CompanyId = @co);
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(@ca, ',') WHERE value <> '';
    OPEN a; FETCH NEXT FROM a INTO @act;
    WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @cm, @Controller = @cctl, @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
    CLOSE a; DEALLOCATE a;
    FETCH NEXT FROM k INTO @code, @cc, @ct, @cs, @cm, @cctl, @ca;
END
CLOSE k; DEALLOCATE k;
DECLARE @pp INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'IPD.PATIENT' AND CompanyId = @co), @pv INT;
SELECT @pv = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @pp AND Control_Code = 'VIEW';
DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'ChargeLookups,Charges,Preview,PrintBill', ',');
OPEN a; FETCH NEXT FROM a INTO @act;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @pp, @Control_ID = @pv, @App = 'WEB', @Http_Method = 'GET', @Controller = N'IpdBilling', @Action = @act, @Source = 'SEED'; FETCH NEXT FROM a INTO @act; END
CLOSE a; DEALLOCATE a;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2434 IPD billing - done.';
GO
