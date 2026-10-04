-- ============================================================================
-- Migration: 2214_opd_reports_doctor_payout.sql
-- Description: Reports > OPD for the doctor payout flow of 2213, on the shared register pattern (one procedure per report
--   returning Summary / Groups / Rows / Options, run through api/reports/opd/run/{report}, page on _LabReportShell).
--     OR-31 Doctor Share Register        usp_Api_OpdReport_DoctorShareRegister   by share date (day the money came in)
--     OR-32 Doctor Payout Register       usp_Api_OpdReport_DoctorPayoutRegister  by settlement date
--     OR-33 Doctor Payable & Ageing      usp_Api_OpdReport_DoctorPayable         as on the To date
--     OR-34 Doctor Statement             usp_Api_OpdReport_DoctorStatement       ledger: opening, earned, recovered, TDS, paid, closing
--     OR-35 Doctor TDS Register (194J)   usp_Api_OpdReport_DoctorTdsRegister     by payment date
--     OR-36 Doctor Revenue Share         usp_Api_OpdReport_DoctorRevenueShare    by bill date, Administrators only
--   Visibility: branch first (usp_LabReport_CheckAccess); Administrator / super admin see every doctor; any other user
--   sees only the doctor linked to their login (Doctor Master > linked user), so a doctor can follow their own earnings.
--   OR-31 / 33 / 34 bring the share lines up to date first (usp_DoctorPayout_Accrue). No grant is seeded.
-- ============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- the doctor a non-administrator may see (the one linked to their login), -1 when none
CREATE OR ALTER FUNCTION dbo.ufn_DoctorPayout_OwnDoctor (@UserId INT, @IsAdmin BIT, @IsSuperAdmin BIT, @DoctorId INT)
RETURNS INT
AS
BEGIN
    IF ISNULL(@IsAdmin, 0) = 1 OR ISNULL(@IsSuperAdmin, 0) = 1 RETURN @DoctorId;
    RETURN ISNULL((SELECT TOP 1 DoctorId FROM dbo.DoctorMaster WHERE LinkedUserId = @UserId AND IsActive = 1 ORDER BY DoctorId), -1);
END;
GO

-- ============================================================================
-- OR-31 Doctor Share Register - day-wise, doctor-wise: every share, top-up and recovery line by the day it was earned,
-- with where it stands (not settled / on a settlement awaiting approval or payment / paid).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DoctorShareRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @LineType      VARCHAR(10)   = NULL,   -- SHARE / TOPUP / RECOVERY
    @SettleStatus  VARCHAR(12)   = NULL,   -- OPEN / PREPARED / APPROVED / PAID
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @DoctorId = dbo.ufn_DoctorPayout_OwnDoctor(@UserId, @IsAdmin, @IsSuperAdmin, @DoctorId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @LineType = NULLIF(UPPER(LTRIM(RTRIM(@LineType))), '');
    SET @SettleStatus = NULLIF(UPPER(LTRIM(RTRIM(@SettleStatus))), '');
    EXEC dbo.usp_DoctorPayout_Accrue @BranchId = @BranchId, @FromDate = @FromDate, @ToDate = @ToDate, @UserId = @UserId;

    SELECT dd.DisbursalId, dd.ShareDate, CONVERT(VARCHAR(10), dd.ShareDate, 23) AS ShareDay, dd.DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           ISNULL(sp.SpecialityName, 'No speciality') AS Speciality, dd.LineType, dd.VisitId, s.OPDBillNo AS BillNo, s.TokenNo, s.CreatedDate AS BillDate,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName, pm.PatientCode,
           dd.NetBillAmount AS BillNet, dd.CollectedAmount AS Collected, dd.CommissionRule AS RuleText, dd.NetPayable AS Share,
           CASE WHEN dd.PaymentStatus = 'Paid' THEN 'PAID' WHEN ds.Status IN ('PREPARED', 'APPROVED') THEN ds.Status ELSE 'OPEN' END AS SettleStatus,
           ds.SettlementId, ds.SettlementNo, COALESCE(ds.PaymentDate, CAST(dd.PaidDate AS DATE)) AS PaymentDate, COALESCE(ds.PaymentMode, dd.PaymentMethod) AS PaymentMode
    INTO #R
    FROM dbo.DoctorDisbursal dd
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = dd.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = dd.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
    LEFT JOIN dbo.DoctorSettlement ds ON ds.SettlementId = dd.SettlementId
    WHERE dd.BranchId = @BranchId AND dd.IsActive = 1 AND dd.NetPayable <> 0
      AND dd.ShareDate BETWEEN @FromDate AND @ToDate
      AND (@DoctorId IS NULL OR dd.DoctorId = @DoctorId)
      AND (@LineType IS NULL OR dd.LineType = @LineType)
      AND (@Search IS NULL OR s.OPDBillNo LIKE '%' + @Search + '%' OR pm.PatientCode LIKE '%' + @Search + '%' OR pm.FirstName LIKE '%' + @Search + '%'
           OR pm.LastName LIKE '%' + @Search + '%' OR ds.SettlementNo LIKE '%' + @Search + '%');
    IF @SettleStatus IS NOT NULL DELETE FROM #R WHERE SettleStatus <> @SettleStatus;

    -- RS1 summary
    SELECT COUNT(1) AS Lines, COUNT(DISTINCT VisitId) AS Visits, COUNT(DISTINCT DoctorId) AS Doctors,
           ISNULL(SUM(Collected), 0) AS Collected,
           ISNULL(SUM(CASE WHEN Share > 0 THEN Share END), 0) AS GrossShare,
           ISNULL(SUM(CASE WHEN Share < 0 THEN Share END), 0) AS Recoveries,
           ISNULL(SUM(Share), 0) AS NetShare,
           ISNULL(SUM(CASE WHEN SettleStatus = 'OPEN' THEN Share END), 0) AS OpenAmount,
           ISNULL(SUM(CASE WHEN SettleStatus IN ('PREPARED', 'APPROVED') THEN Share END), 0) AS InSettlement,
           ISNULL(SUM(CASE WHEN SettleStatus = 'PAID' THEN Share END), 0) AS PaidAmount,
           (SELECT TOP 1 DoctorName FROM #R GROUP BY DoctorName ORDER BY SUM(Share) DESC, DoctorName) AS TopDoctor
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byDate', NULL, ShareDay, 0, * FROM #R
        UNION ALL SELECT 'bySpeciality', NULL, Speciality, 0, * FROM #R
        UNION ALL SELECT 'byStatus', NULL, SettleStatus, CASE SettleStatus WHEN 'OPEN' THEN 1 WHEN 'PREPARED' THEN 2 WHEN 'APPROVED' THEN 3 ELSE 4 END, * FROM #R
        UNION ALL SELECT 'byLineType', NULL, LineType, CASE LineType WHEN 'SHARE' THEN 1 WHEN 'TOPUP' THEN 2 ELSE 3 END, * FROM #R)
    SELECT GroupKey, GroupId, CAST(GroupName AS NVARCHAR(300)) AS GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Lines, COUNT(DISTINCT VisitId) AS Visits, SUM(Collected) AS Collected,
           ISNULL(SUM(CASE WHEN Share > 0 THEN Share END), 0) AS GrossShare, ISNULL(SUM(CASE WHEN Share < 0 THEN Share END), 0) AS Recoveries,
           SUM(Share) AS NetShare, ISNULL(SUM(CASE WHEN SettleStatus = 'OPEN' THEN Share END), 0) AS OpenAmount,
           ISNULL(SUM(CASE WHEN SettleStatus = 'PAID' THEN Share END), 0) AS PaidAmount
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, SUM(Share) DESC, GroupName;

    -- RS3 rows
    SELECT * FROM #R ORDER BY ShareDate DESC, DoctorName, DisbursalId DESC;

    -- RS4 options
    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(20)) AS Value, DoctorName AS Text FROM #R;
    DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-32 Doctor Payout Register - every settlement (payout voucher) by settlement date: gross share, recoveries,
-- deduction / incentive, TDS, net, status, who prepared / approved / paid, mode and reference.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DoctorPayoutRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Status        VARCHAR(12)   = NULL,   -- PREPARED / APPROVED / PAID / REJECTED / CANCELLED
    @PaymentMode   VARCHAR(10)   = NULL,
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @DoctorId = dbo.ufn_DoctorPayout_OwnDoctor(@UserId, @IsAdmin, @IsSuperAdmin, @DoctorId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Status = NULLIF(UPPER(LTRIM(RTRIM(@Status))), '');
    SET @PaymentMode = NULLIF(LTRIM(RTRIM(@PaymentMode)), '');

    SELECT ds.SettlementId, ds.SettlementNo, ds.SettlementDate, CONVERT(VARCHAR(10), ds.SettlementDate, 23) AS SettlementDay,
           ds.PeriodFrom, ds.PeriodTo, ds.DoctorId,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           ISNULL(sp.SpecialityName, 'No speciality') AS Speciality, ds.Visits, ds.LineCount,
           ds.GrossShare, ds.Recoveries, ds.OtherAdjustment, ds.OtherAdjustmentReason, ds.TaxableAmount, ds.TdsPercent, ds.TdsAmount, ds.NetPayable,
           ds.PAN, ds.Status, ISNULL(ds.PaymentMode, 'Not paid') AS PaymentMode, ds.PaymentReference, ds.PaymentDate,
           ISNULL(NULLIF(up.FullName, ''), up.Username) AS PreparedBy, ds.PreparedOn,
           ISNULL(NULLIF(ua.FullName, ''), ua.Username) AS ApprovedBy, ds.ApprovedOn,
           ISNULL(NULLIF(uy.FullName, ''), uy.Username) AS PaidBy,
           ISNULL(NULLIF(uc.FullName, ''), uc.Username) AS ClosedBy, ds.CloseReason
    INTO #R
    FROM dbo.DoctorSettlement ds
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = ds.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    LEFT JOIN dbo.Users up ON up.Id = ds.PreparedBy
    LEFT JOIN dbo.Users ua ON ua.Id = ds.ApprovedBy
    LEFT JOIN dbo.Users uy ON uy.Id = ds.PaidBy
    LEFT JOIN dbo.Users uc ON uc.Id = ds.ClosedBy
    WHERE ds.BranchId = @BranchId AND ds.SettlementDate BETWEEN @FromDate AND @ToDate
      AND (@DoctorId IS NULL OR ds.DoctorId = @DoctorId)
      AND (@Status IS NULL OR ds.Status = @Status)
      AND (@PaymentMode IS NULL OR ds.PaymentMode = @PaymentMode)
      AND (@Search IS NULL OR ds.SettlementNo LIKE '%' + @Search + '%' OR ds.PaymentReference LIKE '%' + @Search + '%' OR d.FullName LIKE '%' + @Search + '%');

    -- RS1 summary (rejected / cancelled settlements are listed but not counted in the money)
    SELECT COUNT(1) AS Settlements, COUNT(DISTINCT DoctorId) AS Doctors,
           ISNULL(SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN GrossShare END), 0) AS GrossShare,
           ISNULL(SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN Recoveries END), 0) AS Recoveries,
           ISNULL(SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN OtherAdjustment END), 0) AS OtherAdjustment,
           ISNULL(SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN TdsAmount END), 0) AS TdsAmount,
           ISNULL(SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN NetPayable END), 0) AS NetPayable,
           SUM(CASE WHEN Status = 'PAID' THEN 1 ELSE 0 END) AS PaidCount, ISNULL(SUM(CASE WHEN Status = 'PAID' THEN NetPayable END), 0) AS PaidAmount,
           SUM(CASE WHEN Status = 'PREPARED' THEN 1 ELSE 0 END) AS AwaitingApproval, ISNULL(SUM(CASE WHEN Status = 'PREPARED' THEN NetPayable END), 0) AS AwaitingApprovalAmount,
           SUM(CASE WHEN Status = 'APPROVED' THEN 1 ELSE 0 END) AS AwaitingPayment, ISNULL(SUM(CASE WHEN Status = 'APPROVED' THEN NetPayable END), 0) AS AwaitingPaymentAmount,
           SUM(CASE WHEN Status IN ('REJECTED', 'CANCELLED') THEN 1 ELSE 0 END) AS Closed
    FROM #R;

    -- RS2 groups
    ;WITH g AS (
        SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byStatus', NULL, Status, CASE Status WHEN 'PREPARED' THEN 1 WHEN 'APPROVED' THEN 2 WHEN 'PAID' THEN 3 WHEN 'REJECTED' THEN 4 ELSE 5 END, * FROM #R
        UNION ALL SELECT 'byMode', NULL, PaymentMode, CASE WHEN PaymentMode = 'Not paid' THEN 1 ELSE 0 END, * FROM #R
        UNION ALL SELECT 'byDate', NULL, SettlementDay, 0, * FROM #R)
    SELECT GroupKey, GroupId, CAST(GroupName AS NVARCHAR(300)) AS GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Settlements, SUM(Visits) AS Visits,
           SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN GrossShare ELSE 0 END) AS GrossShare,
           SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN Recoveries + OtherAdjustment ELSE 0 END) AS Deductions,
           SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN TdsAmount ELSE 0 END) AS TdsAmount,
           SUM(CASE WHEN Status IN ('PREPARED', 'APPROVED', 'PAID') THEN NetPayable ELSE 0 END) AS NetPayable,
           SUM(CASE WHEN Status = 'PAID' THEN NetPayable ELSE 0 END) AS PaidAmount
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byDate' THEN GroupName END DESC, SUM(NetPayable) DESC, GroupName;

    SELECT * FROM #R ORDER BY SettlementDate DESC, SettlementId DESC;
    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(20)) AS Value, DoctorName AS Text FROM #R;
    DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-33 Doctor Payable & Ageing - what the hospital still owes each doctor as on the To date: shares not settled yet
-- (before TDS), settlements awaiting approval and settlements approved but not paid (net of TDS), with their age.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DoctorPayable
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @Stage         VARCHAR(20)   = NULL,   -- NOT_SETTLED / AWAITING_APPROVAL / AWAITING_PAYMENT
    @AgeBucket     VARCHAR(10)   = NULL,   -- 0-1 / 2-7 / 8-30 / 30+
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @DoctorId = dbo.ufn_DoctorPayout_OwnDoctor(@UserId, @IsAdmin, @IsSuperAdmin, @DoctorId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Stage = NULLIF(UPPER(LTRIM(RTRIM(@Stage))), '');
    SET @AgeBucket = NULLIF(UPPER(LTRIM(RTRIM(@AgeBucket))), '');
    DECLARE @AccrueFrom DATE = DATEADD(DAY, -90, @ToDate);
    EXEC dbo.usp_DoctorPayout_Accrue @BranchId = @BranchId, @FromDate = @AccrueFrom, @ToDate = @ToDate, @UserId = @UserId;

    CREATE TABLE #R (ItemType VARCHAR(10), Ref NVARCHAR(60), RefId INT, DoctorId INT, ItemDate DATE, Stage VARCHAR(20), Visits INT, Amount DECIMAL(18, 2), Detail NVARCHAR(300));
    INSERT INTO #R
    SELECT 'SHARE', s.OPDBillNo, dd.DisbursalId, dd.DoctorId, dd.ShareDate, 'NOT_SETTLED', 1, dd.NetPayable,
           dd.LineType + ' · ' + LTRIM(RTRIM(ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, '')))
    FROM dbo.DoctorDisbursal dd
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = dd.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
    WHERE dd.BranchId = @BranchId AND dd.IsActive = 1 AND dd.SettlementId IS NULL AND dd.PaymentStatus <> 'Paid' AND dd.NetPayable <> 0 AND dd.ShareDate <= @ToDate;
    INSERT INTO #R
    SELECT 'SETTLEMENT', ds.SettlementNo, ds.SettlementId, ds.DoctorId, ds.SettlementDate,
           CASE ds.Status WHEN 'PREPARED' THEN 'AWAITING_APPROVAL' ELSE 'AWAITING_PAYMENT' END, ds.Visits, ds.NetPayable,
           'Net of TDS ' + FORMAT(ds.TdsAmount, '0.00') + ' · ' + FORMAT(ds.PeriodFrom, 'dd MMM') + ' to ' + FORMAT(ds.PeriodTo, 'dd MMM yyyy')
    FROM dbo.DoctorSettlement ds
    WHERE ds.BranchId = @BranchId AND ds.Status IN ('PREPARED', 'APPROVED') AND ds.SettlementDate <= @ToDate;

    SELECT r.*, ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           ISNULL(sp.SpecialityName, 'No speciality') AS Speciality,
           DATEDIFF(DAY, r.ItemDate, @ToDate) AS AgeDays,
           CASE WHEN DATEDIFF(DAY, r.ItemDate, @ToDate) <= 1 THEN '0-1' WHEN DATEDIFF(DAY, r.ItemDate, @ToDate) <= 7 THEN '2-7'
                WHEN DATEDIFF(DAY, r.ItemDate, @ToDate) <= 30 THEN '8-30' ELSE '30+' END AS AgeBucket
    INTO #P
    FROM #R r
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = r.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = d.PrimarySpecialityId
    WHERE (@DoctorId IS NULL OR r.DoctorId = @DoctorId)
      AND (@Stage IS NULL OR r.Stage = @Stage)
      AND (@Search IS NULL OR r.Ref LIKE '%' + @Search + '%' OR d.FullName LIKE '%' + @Search + '%' OR r.Detail LIKE '%' + @Search + '%');
    IF @AgeBucket IS NOT NULL DELETE FROM #P WHERE AgeBucket <> @AgeBucket;

    SELECT COUNT(DISTINCT DoctorId) AS Doctors, COUNT(1) AS Items, ISNULL(SUM(Amount), 0) AS TotalPayable,
           ISNULL(SUM(CASE WHEN Stage = 'NOT_SETTLED' THEN Amount END), 0) AS NotSettled,
           ISNULL(SUM(CASE WHEN Stage = 'AWAITING_APPROVAL' THEN Amount END), 0) AS AwaitingApproval,
           ISNULL(SUM(CASE WHEN Stage = 'AWAITING_PAYMENT' THEN Amount END), 0) AS AwaitingPayment,
           ISNULL(SUM(CASE WHEN AgeBucket = '30+' THEN Amount END), 0) AS Over30,
           ISNULL(SUM(CASE WHEN Stage = 'NOT_SETTLED' AND Amount < 0 THEN Amount END), 0) AS RecoveriesPending,
           MIN(ItemDate) AS OldestDate, MAX(AgeDays) AS OldestDays
    FROM #P;

    ;WITH g AS (
        SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, 0 AS SortOrder, * FROM #P
        UNION ALL SELECT 'byStage', NULL, Stage, CASE Stage WHEN 'NOT_SETTLED' THEN 1 WHEN 'AWAITING_APPROVAL' THEN 2 ELSE 3 END, * FROM #P
        UNION ALL SELECT 'byAge', NULL, AgeBucket, CASE AgeBucket WHEN '0-1' THEN 1 WHEN '2-7' THEN 2 WHEN '8-30' THEN 3 ELSE 4 END, * FROM #P)
    SELECT GroupKey, GroupId, CAST(GroupName AS NVARCHAR(300)) AS GroupName, MIN(SortOrder) AS SortOrder, COUNT(1) AS Items,
           ISNULL(SUM(CASE WHEN Stage = 'NOT_SETTLED' THEN Amount END), 0) AS NotSettled,
           ISNULL(SUM(CASE WHEN Stage = 'AWAITING_APPROVAL' THEN Amount END), 0) AS AwaitingApproval,
           ISNULL(SUM(CASE WHEN Stage = 'AWAITING_PAYMENT' THEN Amount END), 0) AS AwaitingPayment,
           SUM(Amount) AS TotalPayable, MAX(AgeDays) AS OldestDays
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), SUM(Amount) DESC, GroupName;

    SELECT * FROM #P ORDER BY ItemDate, DoctorName;
    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(20)) AS Value, DoctorName AS Text FROM #P;
    DROP TABLE #P; DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-34 Doctor Statement - the doctor's payable account: opening balance, shares earned (+), recoveries (-), and for
-- each paid settlement its deduction / incentive, TDS and the payment (-), with the running balance and closing.
-- A settlement only moves the balance when it is paid; until then its shares are still owed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DoctorStatement
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @EntryType     VARCHAR(12)   = NULL,   -- SHARE / TOPUP / RECOVERY / ADJUSTMENT / TDS / PAYMENT
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @DoctorId = dbo.ufn_DoctorPayout_OwnDoctor(@UserId, @IsAdmin, @IsSuperAdmin, @DoctorId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @EntryType = NULLIF(UPPER(LTRIM(RTRIM(@EntryType))), '');
    EXEC dbo.usp_DoctorPayout_Accrue @BranchId = @BranchId, @FromDate = @FromDate, @ToDate = @ToDate, @UserId = @UserId;

    -- every entry up to the To date (the ones before From make the opening balance)
    CREATE TABLE #E (DoctorId INT, EntryDate DATE, Seq INT, EntryType VARCHAR(12), Ref NVARCHAR(60), Particulars NVARCHAR(300), Credit DECIMAL(18, 2), Debit DECIMAL(18, 2), SettlementId INT NULL);
    INSERT INTO #E
    SELECT dd.DoctorId, dd.ShareDate, 1, dd.LineType, s.OPDBillNo,
           CASE dd.LineType WHEN 'SHARE' THEN 'Share earned' WHEN 'TOPUP' THEN 'Share on later collection' ELSE 'Recovery (cancellation / refund)' END
           + ' · ' + LTRIM(RTRIM(ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))),
           CASE WHEN dd.NetPayable > 0 THEN dd.NetPayable ELSE 0 END, CASE WHEN dd.NetPayable < 0 THEN -dd.NetPayable ELSE 0 END, dd.SettlementId
    FROM dbo.DoctorDisbursal dd
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = dd.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId
    WHERE dd.BranchId = @BranchId AND dd.IsActive = 1 AND dd.NetPayable <> 0 AND dd.ShareDate <= @ToDate;
    -- paid settlements: deduction / incentive, TDS, payment
    INSERT INTO #E
    SELECT ds.DoctorId, ds.PaymentDate, 2, 'ADJUSTMENT', ds.SettlementNo, ISNULL(ds.OtherAdjustmentReason, 'Deduction / incentive'),
           CASE WHEN ds.OtherAdjustment > 0 THEN ds.OtherAdjustment ELSE 0 END, CASE WHEN ds.OtherAdjustment < 0 THEN -ds.OtherAdjustment ELSE 0 END, ds.SettlementId
    FROM dbo.DoctorSettlement ds WHERE ds.BranchId = @BranchId AND ds.Status = 'PAID' AND ds.OtherAdjustment <> 0 AND ds.PaymentDate <= @ToDate
    UNION ALL
    SELECT ds.DoctorId, ds.PaymentDate, 3, 'TDS', ds.SettlementNo, 'TDS u/s 194J @ ' + FORMAT(ds.TdsPercent, '0.##') + '%' + CASE WHEN ds.PAN IS NULL THEN ' (no PAN)' ELSE ' · PAN ' + ds.PAN END,
           0, ds.TdsAmount, ds.SettlementId
    FROM dbo.DoctorSettlement ds WHERE ds.BranchId = @BranchId AND ds.Status = 'PAID' AND ds.TdsAmount <> 0 AND ds.PaymentDate <= @ToDate
    UNION ALL
    SELECT ds.DoctorId, ds.PaymentDate, 4, 'PAYMENT', ds.SettlementNo, 'Paid by ' + ds.PaymentMode + ISNULL(' · ' + ds.PaymentReference, ''), 0, ds.NetPayable, ds.SettlementId
    FROM dbo.DoctorSettlement ds WHERE ds.BranchId = @BranchId AND ds.Status = 'PAID' AND ds.PaymentDate <= @ToDate;
    -- shares paid line by line before settlements existed (old screen)
    INSERT INTO #E
    SELECT dd.DoctorId, CAST(dd.PaidDate AS DATE), 4, 'PAYMENT', 'Line ' + CAST(dd.DisbursalId AS VARCHAR(10)), 'Paid by ' + ISNULL(dd.PaymentMethod, 'old screen') + ISNULL(' · ' + dd.PaymentReference, ''),
           0, dd.NetPayable, NULL
    FROM dbo.DoctorDisbursal dd
    WHERE dd.BranchId = @BranchId AND dd.IsActive = 1 AND dd.SettlementId IS NULL AND dd.PaymentStatus = 'Paid' AND dd.PaidDate IS NOT NULL AND CAST(dd.PaidDate AS DATE) <= @ToDate;
    DELETE FROM #E WHERE @DoctorId IS NOT NULL AND DoctorId <> @DoctorId;

    -- opening per doctor, then the entries of the period with the running balance
    SELECT DoctorId, SUM(Credit - Debit) AS Opening INTO #O FROM #E WHERE EntryDate < @FromDate GROUP BY DoctorId;
    SELECT e.*, ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           CONVERT(VARCHAR(7), e.EntryDate, 23) AS Month,
           CAST(ISNULL(o.Opening, 0) + SUM(e.Credit - e.Debit) OVER (PARTITION BY e.DoctorId ORDER BY e.EntryDate, e.Seq, e.Ref ROWS UNBOUNDED PRECEDING) AS DECIMAL(18, 2)) AS Balance
    INTO #R
    FROM #E e
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = e.DoctorId
    LEFT JOIN #O o ON o.DoctorId = e.DoctorId
    WHERE e.EntryDate BETWEEN @FromDate AND @ToDate;
    -- doctors with an opening balance but no entry in the period still get their line
    INSERT INTO #R (DoctorId, EntryDate, Seq, EntryType, Ref, Particulars, Credit, Debit, SettlementId, DoctorName, Month, Balance)
    SELECT o.DoctorId, @FromDate, 0, 'OPENING', NULL, 'Opening balance', 0, 0, NULL,
           ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor'), CONVERT(VARCHAR(7), @FromDate, 23), o.Opening
    FROM #O o INNER JOIN dbo.DoctorMaster d ON d.DoctorId = o.DoctorId
    WHERE o.Opening <> 0;

    -- per doctor: opening, movements, closing
    SELECT x.DoctorId, MIN(x.DoctorName) AS DoctorName, ISNULL(MIN(o.Opening), 0) AS Opening,
           SUM(CASE WHEN x.EntryType IN ('SHARE', 'TOPUP') THEN x.Credit ELSE 0 END) AS Earned,
           SUM(CASE WHEN x.EntryType = 'RECOVERY' THEN x.Debit ELSE 0 END) AS Recovered,
           SUM(CASE WHEN x.EntryType = 'ADJUSTMENT' THEN x.Credit - x.Debit ELSE 0 END) AS Adjusted,
           SUM(CASE WHEN x.EntryType = 'TDS' THEN x.Debit ELSE 0 END) AS Tds,
           SUM(CASE WHEN x.EntryType = 'PAYMENT' THEN x.Debit ELSE 0 END) AS Paid
    INTO #D
    FROM #R x LEFT JOIN #O o ON o.DoctorId = x.DoctorId
    GROUP BY x.DoctorId;

    IF @EntryType IS NOT NULL DELETE FROM #R WHERE EntryType <> @EntryType;
    IF @Search IS NOT NULL DELETE FROM #R WHERE NOT (ISNULL(Ref, '') LIKE '%' + @Search + '%' OR ISNULL(Particulars, '') LIKE '%' + @Search + '%');

    -- RS1 summary
    SELECT COUNT(1) AS Doctors, ISNULL(SUM(Opening), 0) AS Opening, ISNULL(SUM(Earned), 0) AS Earned, ISNULL(SUM(Recovered), 0) AS Recovered,
           ISNULL(SUM(Adjusted), 0) AS Adjusted, ISNULL(SUM(Tds), 0) AS Tds, ISNULL(SUM(Paid), 0) AS Paid,
           ISNULL(SUM(Opening + Earned - Recovered + Adjusted - Tds - Paid), 0) AS Closing
    FROM #D;

    -- RS2 groups: by doctor (the statement summary), by entry type, by month
    SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, CAST(DoctorName AS NVARCHAR(300)) AS GroupName, 0 AS SortOrder,
           Opening, Earned, Recovered, Adjusted, Tds, Paid, Opening + Earned - Recovered + Adjusted - Tds - Paid AS Closing,
           CAST(NULL AS DECIMAL(18, 2)) AS Credit, CAST(NULL AS DECIMAL(18, 2)) AS Debit, CAST(NULL AS INT) AS Entries
    FROM #D
    UNION ALL
    SELECT 'byType', NULL, EntryType, MIN(CASE EntryType WHEN 'OPENING' THEN 0 WHEN 'SHARE' THEN 1 WHEN 'TOPUP' THEN 2 WHEN 'RECOVERY' THEN 3 WHEN 'ADJUSTMENT' THEN 4 WHEN 'TDS' THEN 5 ELSE 6 END),
           NULL, NULL, NULL, NULL, NULL, NULL, NULL, SUM(Credit), SUM(Debit), COUNT(1)
    FROM #R WHERE EntryType <> 'OPENING' GROUP BY EntryType
    UNION ALL
    SELECT 'byMonth', NULL, Month, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, SUM(Credit), SUM(Debit), COUNT(1)
    FROM #R WHERE EntryType <> 'OPENING' GROUP BY Month
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows: the statement, doctor by doctor, in date order
    SELECT * FROM #R ORDER BY DoctorName, EntryDate, Seq, Ref;
    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(20)) AS Value, DoctorName AS Text FROM #D;
    DROP TABLE #D; DROP TABLE #R; DROP TABLE #O; DROP TABLE #E;
END;
GO

-- ============================================================================
-- OR-35 Doctor TDS Register (section 194J) - TDS deducted on paid settlements by payment date, with PAN, taxable
-- amount, rate, TDS and net paid; quarter for the TDS return (Q1 Apr-Jun ... Q4 Jan-Mar).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DoctorTdsRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @PanStatus     VARCHAR(10)   = NULL,   -- WITH / WITHOUT
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @DoctorId = dbo.ufn_DoctorPayout_OwnDoctor(@UserId, @IsAdmin, @IsSuperAdmin, @DoctorId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @PanStatus = NULLIF(UPPER(LTRIM(RTRIM(@PanStatus))), '');

    SELECT ds.SettlementId, ds.SettlementNo, ds.PaymentDate, CONVERT(VARCHAR(7), ds.PaymentDate, 23) AS Month,
           CONCAT('FY ', YEAR(ds.PaymentDate) - CASE WHEN MONTH(ds.PaymentDate) < 4 THEN 1 ELSE 0 END, '-',
                  RIGHT(YEAR(ds.PaymentDate) + CASE WHEN MONTH(ds.PaymentDate) < 4 THEN 0 ELSE 1 END, 2), ' Q',
                  CASE WHEN MONTH(ds.PaymentDate) BETWEEN 4 AND 6 THEN 1 WHEN MONTH(ds.PaymentDate) BETWEEN 7 AND 9 THEN 2
                       WHEN MONTH(ds.PaymentDate) BETWEEN 10 AND 12 THEN 3 ELSE 4 END) AS Quarter,
           ds.DoctorId, ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           ds.PayeeName, ds.PAN, CASE WHEN NULLIF(ds.PAN, '') IS NULL THEN 'WITHOUT' ELSE 'WITH' END AS PanStatus,
           ds.TaxableAmount, ds.TdsPercent, ds.TdsAmount, ds.NetPayable, ds.PaymentMode, ds.PaymentReference
    INTO #R
    FROM dbo.DoctorSettlement ds
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = ds.DoctorId
    WHERE ds.BranchId = @BranchId AND ds.Status = 'PAID' AND ds.PaymentDate BETWEEN @FromDate AND @ToDate
      AND (@DoctorId IS NULL OR ds.DoctorId = @DoctorId)
      AND (@Search IS NULL OR ds.SettlementNo LIKE '%' + @Search + '%' OR ds.PAN LIKE '%' + @Search + '%' OR d.FullName LIKE '%' + @Search + '%');
    IF @PanStatus IS NOT NULL DELETE FROM #R WHERE PanStatus <> @PanStatus;

    SELECT COUNT(1) AS Payments, COUNT(DISTINCT DoctorId) AS Doctors, ISNULL(SUM(TaxableAmount), 0) AS Taxable, ISNULL(SUM(TdsAmount), 0) AS Tds,
           ISNULL(SUM(NetPayable), 0) AS NetPaid, SUM(CASE WHEN PanStatus = 'WITHOUT' THEN 1 ELSE 0 END) AS WithoutPan,
           ISNULL(SUM(CASE WHEN PanStatus = 'WITHOUT' THEN TdsAmount END), 0) AS TdsWithoutPan
    FROM #R;

    ;WITH g AS (
        SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName + ISNULL(' · ' + PAN, ' · no PAN') AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'byQuarter', NULL, Quarter, 0, * FROM #R
        UNION ALL SELECT 'byMonth', NULL, Month, 0, * FROM #R
        UNION ALL SELECT 'byPan', NULL, PanStatus, CASE PanStatus WHEN 'WITH' THEN 0 ELSE 1 END, * FROM #R)
    SELECT GroupKey, GroupId, CAST(GroupName AS NVARCHAR(300)) AS GroupName, MIN(SortOrder) AS SortOrder, COUNT(1) AS Payments,
           SUM(TaxableAmount) AS Taxable, SUM(TdsAmount) AS Tds, SUM(NetPayable) AS NetPaid
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), GroupName;

    SELECT * FROM #R ORDER BY PaymentDate DESC, SettlementId DESC;
    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(20)) AS Value, DoctorName AS Text FROM #R;
    DROP TABLE #R;
END;
GO

-- ============================================================================
-- OR-36 Doctor Revenue Share - management: OPD visits billed in the period, what was collected, the doctor's share
-- earned (from the commission rules) and what stays with the hospital; visits without a rule are flagged.
-- Compares doctors: for Administrators only.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Api_OpdReport_DoctorRevenueShare
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @RuleStatus    VARCHAR(10)   = NULL,   -- RULE / NORULE
    @SpecialityId  INT           = NULL,
    @DoctorId      INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0
        THROW 50011, 'Doctor Revenue Share compares doctors and is available to Administrators only.', 1;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @RuleStatus = NULLIF(UPPER(LTRIM(RTRIM(@RuleStatus))), '');

    SELECT x.VisitId, x.DoctorId, ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + ISNULL(d.FullName, ''))), ''), 'Doctor') AS DoctorName,
           ISNULL(x.SpecialityId, 0) AS SpecialityId, ISNULL(sp.SpecialityName, 'No speciality') AS Speciality,
           x.BillDate, CONVERT(VARCHAR(7), x.BillDate, 23) AS Month, s.OPDBillNo AS BillNo, s.TokenNo,
           LTRIM(RTRIM(ISNULL(pm.Salutation, '') + ' ' + ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) AS PatientName, pm.PatientCode,
           x.BillNet AS Revenue, x.BillPaid AS Collected, x.ConsultGross - x.ConsultDisc AS ConsultRevenue,
           x.EarnedShare AS DoctorShare, CAST(x.BillPaid - x.EarnedShare AS DECIMAL(18, 2)) AS HospitalShare, x.FullShare,
           x.RuleText, CASE WHEN x.CommissionConfigId IS NULL THEN 'NORULE' ELSE 'RULE' END AS RuleStatus
    INTO #R
    FROM dbo.ufn_DoctorPayout_VisitShare(@BranchId, @FromDate, @ToDate, @DoctorId) x
    INNER JOIN dbo.DoctorMaster d ON d.DoctorId = x.DoctorId
    LEFT JOIN dbo.DoctorSpecialityMaster sp ON sp.SpecialityId = x.SpecialityId
    LEFT JOIN dbo.PatientOPDService s ON s.OPDServiceId = x.VisitId
    LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = x.PatientId
    WHERE x.VisitActive = 1 AND CAST(x.BillDate AS DATE) BETWEEN @FromDate AND @ToDate
      AND (@SpecialityId IS NULL OR x.SpecialityId = @SpecialityId)
      AND (@Search IS NULL OR s.OPDBillNo LIKE '%' + @Search + '%' OR pm.PatientCode LIKE '%' + @Search + '%' OR pm.FirstName LIKE '%' + @Search + '%' OR pm.LastName LIKE '%' + @Search + '%');
    IF @RuleStatus IS NOT NULL DELETE FROM #R WHERE RuleStatus <> @RuleStatus;

    SELECT COUNT(1) AS Visits, COUNT(DISTINCT DoctorId) AS Doctors, ISNULL(SUM(Revenue), 0) AS Revenue, ISNULL(SUM(Collected), 0) AS Collected,
           ISNULL(SUM(DoctorShare), 0) AS DoctorShare, ISNULL(SUM(HospitalShare), 0) AS HospitalShare,
           CAST(SUM(DoctorShare) * 100.0 / NULLIF(SUM(Collected), 0) AS DECIMAL(10, 1)) AS DoctorSharePct,
           SUM(CASE WHEN RuleStatus = 'NORULE' THEN 1 ELSE 0 END) AS VisitsWithoutRule,
           ISNULL(SUM(FullShare - DoctorShare), 0) AS ShareOnDues
    FROM #R;

    ;WITH g AS (
        SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, 0 AS SortOrder, * FROM #R
        UNION ALL SELECT 'bySpeciality', SpecialityId, Speciality, 0, * FROM #R
        UNION ALL SELECT 'byMonth', NULL, Month, 0, * FROM #R)
    SELECT GroupKey, GroupId, CAST(GroupName AS NVARCHAR(300)) AS GroupName, MIN(SortOrder) AS SortOrder,
           COUNT(1) AS Visits, SUM(Revenue) AS Revenue, SUM(Collected) AS Collected, SUM(DoctorShare) AS DoctorShare, SUM(HospitalShare) AS HospitalShare,
           CAST(SUM(DoctorShare) * 100.0 / NULLIF(SUM(Collected), 0) AS DECIMAL(10, 1)) AS DoctorSharePct,
           SUM(CASE WHEN RuleStatus = 'NORULE' THEN 1 ELSE 0 END) AS VisitsWithoutRule
    FROM g GROUP BY GroupKey, GroupId, GroupName
    ORDER BY GroupKey, MIN(SortOrder), CASE WHEN GroupKey = 'byMonth' THEN GroupName END, SUM(Collected) DESC, GroupName;

    SELECT * FROM #R ORDER BY BillDate DESC, VisitId DESC;
    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(20)) AS Value, DoctorName AS Text FROM #R
    UNION SELECT DISTINCT 'specialityId', CAST(SpecialityId AS VARCHAR(20)), Speciality FROM #R WHERE SpecialityId > 0;
    DROP TABLE #R;
END;
GO

-- ── menu pages and endpoints (database navigation, Reports > OPD) ───────────────
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
    (N'REPORTS.OPDDOCTORSHARE',        N'Doctor Share Register',       N'OpdDoctorShareRegister',  19, N'bi bi-person-badge me-2'),
    (N'REPORTS.OPDDOCTORPAYOUT',       N'Doctor Payout Register',      N'OpdDoctorPayoutRegister', 20, N'bi bi-wallet2 me-2'),
    (N'REPORTS.OPDDOCTORPAYABLE',      N'Doctor Payable & Ageing',     N'OpdDoctorPayable',        21, N'bi bi-hourglass-split me-2'),
    (N'REPORTS.OPDDOCTORSTATEMENT',    N'Doctor Statement',            N'OpdDoctorStatement',      22, N'bi bi-journal-text me-2'),
    (N'REPORTS.OPDDOCTORTDS',          N'Doctor TDS Register (194J)',  N'OpdDoctorTdsRegister',    23, N'bi bi-bank me-2'),
    (N'REPORTS.OPDDOCTORREVENUESHARE', N'Doctor Revenue Share',        N'OpdDoctorRevenueShare',   24, N'bi bi-pie-chart me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(150), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.OPD' AND CompanyId = @co;
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
                 @Controller = N'Reports', @Action = N'GetOpdReportData', @Source = 'SEED';
            FETCH NEXT FROM pc INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pc; DEALLOCATE pc;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2214 applied: Reports > OPD > OR-31 to OR-36 (doctor share, payout, payable, statement, TDS, revenue share).';
GO
