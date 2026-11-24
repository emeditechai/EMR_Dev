-- ============================================================================
-- Migration: 2534_doctor_ip_paid_bills_and_payout.sql
-- Description: Doctor IP commission - bill payment rule and commission paid per bill.
--   1. Hospital Settings > LAB: DoctorIpIncludeUnpaidBills (default 0 = No). With No, a lab bill earns
--      commission only once it is fully paid (PaymentHeader LAB, BalanceDue <= 0; no payment record = not paid).
--      A part-paid bill is held back completely and is computed in the first cycle after it is fully paid:
--      the scheduled run now looks back to the Doctor IP start date, not only the closed cycle.
--   2. Doctor_IP_Commission_Dtl: Is_Paid, Paid_Date, Paid_Reference, Paid_Remarks, Paid_By, Paid_On.
--      Commission is marked paid (or unmarked) per bill: all lines of the bill in a run together.
--   3. fn_DoctorIpCommission_Candidates: Is_Bill_Paid, Bill_Balance_Due, Is_Waiting_Payment;
--      fn_DoctorIpCommission_Eligible skips items waiting for payment (manual and scheduled runs).
--   4. GetPending / GetPendingTests / GetList / GetDetail / GetDueSchedules and the Pending and
--      Statement reports show payment status; new usp_DoctorIpCommission_SetPaid.
--   5. Authorization: control PAY on MASTER.DOCTORIP_COMMISSION.
--   Run after 2533. Re-runnable.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Columns -------------------------------------------------------------------------
IF COL_LENGTH('dbo.HospitalSettings', 'DoctorIpIncludeUnpaidBills') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD DoctorIpIncludeUnpaidBills BIT NOT NULL
        CONSTRAINT DF_HospitalSettings_DoctorIpIncludeUnpaidBills DEFAULT 0;
GO
IF COL_LENGTH('dbo.Doctor_IP_Commission_Dtl', 'Is_Paid') IS NULL
BEGIN
    ALTER TABLE dbo.Doctor_IP_Commission_Dtl ADD
        Is_Paid        BIT NOT NULL CONSTRAINT DF_Doctor_IP_Commission_Dtl_Is_Paid DEFAULT 0,
        Paid_Date      DATE NULL,
        Paid_Reference NVARCHAR(100) NULL,
        Paid_Remarks   NVARCHAR(250) NULL,
        Paid_By        INT NULL,
        Paid_On        DATETIME NULL;
END
GO

-- 2. Functions and procedures ------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_DoctorIpCommission_Candidates
(
    @BranchId INT, @DoctorId INT, @FromDate DATE, @ToDate DATE, @CompanyId INT
)
RETURNS TABLE
AS
RETURN
    SELECT h.Doctor_IP_Hdr_ID, h.CompanyId, h.Doctor_ID, h.Branch_ID, h.Frequency_Of_Disbursal,
           lo.LabOrderId, lo.OrderDate AS Order_Date, lo.PatientId,
           loi.LabOrderItemId, d.Item_Type, CAST(loi.InvestigationId AS BIGINT) AS Test_ID,
           CAST(loi.Price AS DECIMAL(18,2)) AS Billed_Amount,
           d.Commission_Rate,
           CAST(ROUND(loi.Price * d.Commission_Rate / 100.0, 2) AS DECIMAL(18,2)) AS Commission_Amount,
           CAST(CASE WHEN x.Omitted_ID IS NULL THEN 0 ELSE 1 END AS BIT) AS Is_Omitted,
           x.Omitted_ID,
           CAST(CASE WHEN pay.BalanceDue IS NOT NULL AND pay.BalanceDue <= 0 THEN 1 ELSE 0 END AS BIT) AS Is_Bill_Paid,
           CAST(ISNULL(pay.BalanceDue, lo.TotalAmount) AS DECIMAL(18,2)) AS Bill_Balance_Due,
           -- Hospital Settings > LAB: unless bills not fully paid are included, they wait for the next cycle after payment.
           CAST(CASE WHEN ISNULL(hs.DoctorIpIncludeUnpaidBills, 0) = 0 AND NOT (pay.BalanceDue IS NOT NULL AND pay.BalanceDue <= 0)
                     THEN 1 ELSE 0 END AS BIT) AS Is_Waiting_Payment
    FROM dbo.LabOrderItem loi
    JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    JOIN dbo.Doctor_IP_Hdr h ON h.Doctor_ID = lo.RefDoctorId AND h.Branch_ID = lo.BranchId
                            AND h.IsActive = 1 AND h.IsDeleted = 0
                            AND CAST(lo.OrderDate AS DATE) BETWEEN h.Effective_From AND h.Effective_To
    JOIN dbo.Doctor_IP_Dtl d ON d.Doctor_IP_Hdr_ID = h.Doctor_IP_Hdr_ID AND d.Test_ID = loi.InvestigationId
                            AND ((loi.Type = 'P' AND d.Item_Type = 'Package') OR (loi.Type = 'I' AND d.Item_Type <> 'Package'))
    LEFT JOIN dbo.Doctor_IP_Commission_Omitted x ON x.LabOrderItemId = loi.LabOrderItemId AND x.IsActive = 1
    OUTER APPLY (SELECT TOP 1 ph.BalanceDue FROM dbo.PaymentHeader ph
                 WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
                 ORDER BY ph.PaymentHeaderId DESC) pay
    OUTER APPLY (SELECT TOP 1 s.DoctorIpIncludeUnpaidBills FROM dbo.HospitalSettings s
                 WHERE s.BranchID = lo.BranchId AND s.IsActive = 1 ORDER BY s.Id) hs
    WHERE ISNULL(loi.is_IPGenerated, 0) = 0
      AND loi.IsActive = 1
      AND lo.IsActive = 1
      AND ISNULL(lo.IsB2B, 0) = 0   -- B2B (partner / franchise) bills earn no Doctor IP commission
      AND lo.BranchId = @BranchId
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
      AND (@CompanyId IS NULL OR h.CompanyId = @CompanyId)
      AND (@FromDate IS NULL OR CAST(lo.OrderDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(lo.OrderDate AS DATE) <= @ToDate);
GO

CREATE OR ALTER FUNCTION dbo.fn_DoctorIpCommission_Eligible
(
    @BranchId INT, @DoctorId INT, @FromDate DATE, @ToDate DATE, @CompanyId INT
)
RETURNS TABLE
AS
RETURN
    SELECT c.Doctor_IP_Hdr_ID, c.CompanyId, c.Doctor_ID, c.Branch_ID, c.Frequency_Of_Disbursal,
           c.LabOrderId, c.Order_Date, c.PatientId, c.LabOrderItemId, c.Item_Type, c.Test_ID,
           c.Billed_Amount, c.Commission_Rate, c.Commission_Amount
    FROM dbo.fn_DoctorIpCommission_Candidates(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId) c
    WHERE c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 0;
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetPending
    @BranchId INT, @DoctorId INT = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.Doctor_ID, dm.FullName AS Doctor_Name, MAX(c.Frequency_Of_Disbursal) AS Frequency_Of_Disbursal,
           COUNT(DISTINCT CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 0 THEN c.LabOrderId END) AS Pending_Orders,
           SUM(CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 0 THEN 1 ELSE 0 END) AS Pending_Items,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 0 THEN c.Billed_Amount END), 0) AS Pending_Amount,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 0 THEN c.Commission_Amount END), 0) AS Estimated_Commission,
           SUM(CASE WHEN c.Is_Omitted = 1 THEN 1 ELSE 0 END) AS Omitted_Items,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 1 THEN c.Billed_Amount END), 0) AS Omitted_Amount,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 1 THEN c.Commission_Amount END), 0) AS Omitted_Commission,
           SUM(CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 1 THEN 1 ELSE 0 END) AS Waiting_Items,
           COUNT(DISTINCT CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 1 THEN c.LabOrderId END) AS Waiting_Orders,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 0 AND c.Is_Waiting_Payment = 1 THEN c.Commission_Amount END), 0) AS Waiting_Commission,
           MIN(c.Order_Date) AS First_Order_Date, MAX(c.Order_Date) AS Last_Order_Date
    FROM dbo.fn_DoctorIpCommission_Candidates(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId) c
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = c.Doctor_ID
    GROUP BY c.Doctor_ID, dm.FullName
    ORDER BY dm.FullName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetPendingTests
    @BranchId INT, @DoctorId INT, @FromDate DATE, @ToDate DATE, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.LabOrderItemId, c.LabOrderId, lo.BillNo, c.Order_Date,
           LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS Patient_Name,
           c.Item_Type, c.Test_ID, i.Item_Code AS Test_Code, ISNULL(i.Item_Name, 'Unknown') AS Test_Name,
           c.Billed_Amount, c.Commission_Rate, c.Commission_Amount, c.Is_Omitted, c.Is_Bill_Paid, c.Bill_Balance_Due, c.Is_Waiting_Payment,
           x.Reason AS Omit_Reason, x.Omitted_On, u.FullName AS Omitted_By_Name
    FROM dbo.fn_DoctorIpCommission_Candidates(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId) c
    JOIN dbo.LabOrder lo ON lo.LabOrderId = c.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = c.PatientId
    LEFT JOIN dbo.vw_DoctorIp_Item i ON i.Item_ID = c.Test_ID AND i.IsPackage = CASE WHEN c.Item_Type = 'Package' THEN 1 ELSE 0 END
    LEFT JOIN dbo.Doctor_IP_Commission_Omitted x ON x.Omitted_ID = c.Omitted_ID
    LEFT JOIN dbo.Users u ON u.Id = x.Omitted_By
    ORDER BY c.Order_Date, lo.BillNo, i.Item_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetDueSchedules
    @Today DATE, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
    DECLARE @IsMonday BIT = CASE WHEN DATEDIFF(DAY, '19000101', @Today) % 7 = 0 THEN 1 ELSE 0 END; -- 1900-01-01 was a Monday

    -- Period_From reaches back to the Doctor IP start: bills of earlier cycles that were waiting for payment
    -- (or were otherwise left pending) are computed in the first run after they qualify.
    SELECT h.Doctor_IP_Hdr_ID, h.CompanyId, h.Doctor_ID, h.Branch_ID, h.Frequency_Of_Disbursal,
           h.Effective_From AS Period_From, p.Period_To, p.Period_From AS Cycle_From
    FROM dbo.Doctor_IP_Hdr h
    CROSS APPLY (SELECT CASE h.Frequency_Of_Disbursal
                            WHEN 'Daily'     THEN DATEADD(DAY, -1, @Today)
                            WHEN 'Weekly'    THEN DATEADD(DAY, -7, @Today)
                            WHEN 'Monthly'   THEN DATEADD(MONTH, -1, @MonthStart)
                            WHEN 'Quarterly' THEN DATEADD(MONTH, -3, @MonthStart)
                            WHEN 'Annually'  THEN DATEADD(YEAR, -1, @MonthStart)
                        END AS Period_From,
                        DATEADD(DAY, -1, @Today) AS Period_To) p
    WHERE h.IsActive = 1 AND h.IsDeleted = 0
      AND (@BranchId IS NULL OR h.Branch_ID = @BranchId)
      AND h.Effective_From <= p.Period_To AND h.Effective_To >= p.Period_From
      AND (   h.Frequency_Of_Disbursal = 'Daily'
           OR (h.Frequency_Of_Disbursal = 'Weekly'    AND @IsMonday = 1)
           OR (h.Frequency_Of_Disbursal = 'Monthly'   AND DAY(@Today) = 1)
           OR (h.Frequency_Of_Disbursal = 'Quarterly' AND DAY(@Today) = 1 AND MONTH(@Today) IN (1, 4, 7, 10))
           OR (h.Frequency_Of_Disbursal = 'Annually'  AND DAY(@Today) = 1 AND MONTH(@Today) = 1));
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetList
    @BranchId INT = NULL, @DoctorId INT = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ch.Commission_Hdr_ID, ch.Doctor_ID, dm.FullName AS Doctor_Name, ch.Branch_ID, b.BranchName AS Branch_Name,
           ch.Doctor_IP_Hdr_ID, ch.Frequency_Of_Disbursal, ch.Period_From, ch.Period_To,
           ch.Total_Orders, ch.Total_Items, ch.Total_Billed_Amount, ch.Total_Commission,
           ch.Computed_Date, ch.Source, ISNULL(u.FullName, 'System') AS Computed_By_Name,
           pd.Paid_Bills, pd.Unpaid_Bills, pd.Paid_Commission, ch.Total_Commission - pd.Paid_Commission AS Unpaid_Commission
    FROM dbo.Doctor_IP_Commission_Hdr ch
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = ch.Doctor_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = ch.Branch_ID
    LEFT JOIN dbo.Users u ON u.Id = ch.Computed_By
    CROSS APPLY (SELECT COUNT(DISTINCT CASE WHEN d.Is_Paid = 1 THEN d.LabOrderId END) AS Paid_Bills,
                        COUNT(DISTINCT CASE WHEN d.Is_Paid = 0 THEN d.LabOrderId END) AS Unpaid_Bills,
                        ISNULL(SUM(CASE WHEN d.Is_Paid = 1 THEN d.Commission_Amount END), 0) AS Paid_Commission
                 FROM dbo.Doctor_IP_Commission_Dtl d WHERE d.Commission_Hdr_ID = ch.Commission_Hdr_ID) pd
    WHERE ch.IsDeleted = 0
      AND (@BranchId IS NULL OR ch.Branch_ID = @BranchId)
      AND (@DoctorId IS NULL OR ch.Doctor_ID = @DoctorId)
      AND (@CompanyId IS NULL OR ch.CompanyId = @CompanyId)
      AND (@FromDate IS NULL OR ch.Period_To >= @FromDate)
      AND (@ToDate IS NULL OR ch.Period_From <= @ToDate)
    ORDER BY ch.Computed_Date DESC, ch.Commission_Hdr_ID DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetDetail
    @CommissionHdrId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ch.Commission_Hdr_ID, ch.Doctor_ID, dm.FullName AS Doctor_Name, ch.Branch_ID, b.BranchName AS Branch_Name,
           ch.Doctor_IP_Hdr_ID, ch.Frequency_Of_Disbursal, ch.Period_From, ch.Period_To,
           ch.Total_Orders, ch.Total_Items, ch.Total_Billed_Amount, ch.Total_Commission,
           ch.Computed_Date, ch.Source, ISNULL(u.FullName, 'System') AS Computed_By_Name
    FROM dbo.Doctor_IP_Commission_Hdr ch
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = ch.Doctor_ID
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = ch.Branch_ID
    LEFT JOIN dbo.Users u ON u.Id = ch.Computed_By
    WHERE ch.Commission_Hdr_ID = @CommissionHdrId AND ch.IsDeleted = 0;

    SELECT cd.Commission_Dtl_ID, cd.LabOrderId, lo.BillNo, cd.Order_Date,
           LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS Patient_Name,
           cd.Item_Type, cd.Test_ID, ISNULL(m.Test_Code, ph.Profile_Code) AS Test_Code,
           ISNULL(ISNULL(m.Test_Name, ph.Profile_Name), 'Unknown') AS Test_Name,
           cd.Billed_Amount, cd.Commission_Rate, cd.Commission_Amount,
           cd.Is_Paid, cd.Paid_Date, cd.Paid_Reference, cd.Paid_Remarks, cd.Paid_On, pu.FullName AS Paid_By_Name
    FROM dbo.Doctor_IP_Commission_Dtl cd
    JOIN dbo.LabOrder lo ON lo.LabOrderId = cd.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = cd.PatientId
    LEFT JOIN dbo.LabInvestigationMaster m ON cd.Item_Type <> 'Package' AND m.Test_ID = cd.Test_ID
    LEFT JOIN dbo.LabInvestigationProfileHeader ph ON cd.Item_Type = 'Package' AND ph.Profile_ID = cd.Test_ID
    LEFT JOIN dbo.Users pu ON pu.Id = cd.Paid_By
    WHERE cd.Commission_Hdr_ID = @CommissionHdrId
    ORDER BY cd.Order_Date, cd.LabOrderId, ISNULL(m.Test_Name, ph.Profile_Name);
END
GO

-- Marks commission paid (or not paid) per bill. @LabOrderIdsJson: [123, 124]. All lines of each bill in the run change together.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_SetPaid
    @CommissionHdrId BIGINT, @LabOrderIdsJson NVARCHAR(MAX), @IsPaid BIT,
    @PaidDate DATE = NULL, @Reference NVARCHAR(100) = NULL, @Remarks NVARCHAR(250) = NULL, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Commission_Hdr WHERE Commission_Hdr_ID = @CommissionHdrId AND IsDeleted = 0)
    BEGIN RAISERROR('Commission record not found.', 16, 1); RETURN; END
    IF @LabOrderIdsJson IS NULL OR ISJSON(@LabOrderIdsJson) = 0
    BEGIN RAISERROR('Select at least one bill.', 16, 1); RETURN; END
    IF @IsPaid = 1 AND @PaidDate IS NULL
    BEGIN RAISERROR('Enter the date the commission was paid.', 16, 1); RETURN; END
    IF @IsPaid = 1 AND @PaidDate > CAST(GETDATE() AS DATE)
    BEGIN RAISERROR('The paid date cannot be in the future.', 16, 1); RETURN; END

    DECLARE @Bills TABLE (LabOrderId INT PRIMARY KEY);
    DECLARE @Done TABLE (LabOrderId INT, Commission_Amount DECIMAL(18,2));
    INSERT INTO @Bills SELECT DISTINCT TRY_CAST(value AS INT) FROM OPENJSON(@LabOrderIdsJson) WHERE TRY_CAST(value AS INT) IS NOT NULL;

    UPDATE d SET Is_Paid = @IsPaid,
                 Paid_Date = CASE WHEN @IsPaid = 1 THEN @PaidDate END,
                 Paid_Reference = CASE WHEN @IsPaid = 1 THEN NULLIF(LTRIM(RTRIM(@Reference)), '') END,
                 Paid_Remarks = CASE WHEN @IsPaid = 1 THEN NULLIF(LTRIM(RTRIM(@Remarks)), '') END,
                 Paid_By = CASE WHEN @IsPaid = 1 THEN @UserId END,
                 Paid_On = CASE WHEN @IsPaid = 1 THEN GETDATE() END
    OUTPUT inserted.LabOrderId, inserted.Commission_Amount INTO @Done
    FROM dbo.Doctor_IP_Commission_Dtl d
    JOIN @Bills b ON b.LabOrderId = d.LabOrderId
    WHERE d.Commission_Hdr_ID = @CommissionHdrId AND d.Is_Paid <> @IsPaid;

    SELECT COUNT(DISTINCT LabOrderId) AS Updated_Bills, ISNULL(SUM(Commission_Amount), 0) AS Updated_Commission FROM @Done;
END
GO

-- 3. Reports ---------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpPending
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @ItemType VARCHAR(20) = NULL, @Frequency VARCHAR(20) = NULL,
    @BillPayment VARCHAR(20) = NULL,   -- READY / WAITING
    @Search NVARCHAR(100) = NULL, @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @ItemType = NULLIF(LTRIM(RTRIM(@ItemType)), '');
    SET @Frequency = NULLIF(LTRIM(RTRIM(@Frequency)), '');
    SET @BillPayment = NULLIF(UPPER(LTRIM(RTRIM(@BillPayment))), '');

    SELECT e.LabOrderItemId, e.Order_Date AS OrderDate, CONVERT(VARCHAR(10), CAST(e.Order_Date AS DATE), 23) AS OrderDay,
           DATEDIFF(DAY, e.Order_Date, GETDATE()) AS DaysPending,
           e.Doctor_ID AS DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName, e.Frequency_Of_Disbursal AS Frequency,
           e.LabOrderId, lo.BillNo, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           e.Item_Type AS ItemType, ISNULL(i.Item_Code + ' - ', '') + ISNULL(i.Item_Name, 'Unknown') AS ItemLabel,
           e.Billed_Amount AS BilledAmount, e.Commission_Rate AS CommissionRate, e.Commission_Amount AS CommissionAmount,
           CASE WHEN e.Is_Waiting_Payment = 1 THEN 'WAITING' ELSE 'READY' END AS PaymentCode,
           CASE WHEN e.Is_Waiting_Payment = 1 THEN 'Waiting for bill payment' ELSE 'Ready to calculate' END AS PaymentLabel,
           e.Bill_Balance_Due AS BillBalanceDue
    INTO #R
    FROM dbo.fn_DoctorIpCommission_Candidates(@BranchId, @DoctorId, @FromDate, @ToDate, NULL) e
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = e.Doctor_ID
    JOIN dbo.LabOrder lo ON lo.LabOrderId = e.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = e.PatientId
    LEFT JOIN dbo.vw_DoctorIp_Item i ON i.Item_ID = e.Test_ID AND i.IsPackage = CASE WHEN e.Item_Type = 'Package' THEN 1 ELSE 0 END
    WHERE e.Is_Omitted = 0
      AND (@ItemType IS NULL OR e.Item_Type = @ItemType)
      AND (@BillPayment IS NULL OR (@BillPayment = 'WAITING' AND e.Is_Waiting_Payment = 1) OR (@BillPayment = 'READY' AND e.Is_Waiting_Payment = 0))
      AND (@Frequency IS NULL OR e.Frequency_Of_Disbursal = @Frequency)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR i.Item_Name LIKE '%' + @Search + '%' OR i.Item_Code LIKE '%' + @Search + '%');

    SELECT COUNT(DISTINCT DoctorId) AS DoctorCount, COUNT(DISTINCT LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           ISNULL(SUM(BilledAmount), 0) AS BilledAmount, ISNULL(SUM(CommissionAmount), 0) AS CommissionAmount,
           ISNULL(MAX(DaysPending), 0) AS OldestDays,
           COUNT(DISTINCT CASE WHEN PaymentCode = 'WAITING' THEN LabOrderId END) AS WaitingBills,
           ISNULL(SUM(CASE WHEN PaymentCode = 'WAITING' THEN CommissionAmount END), 0) AS WaitingCommission
    FROM #R;

    SELECT g.GroupKey, g.GroupId, g.GroupName, 0 AS SortOrder, COUNT(DISTINCT g.LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           SUM(g.BilledAmount) AS BilledAmount, SUM(g.CommissionAmount) AS CommissionAmount, MAX(g.DaysPending) AS OldestDays
    FROM (SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byFrequency', NULL, ISNULL(Frequency, 'Not set'), LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byItemType', NULL, ItemType, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byPayment', NULL, PaymentLabel, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byDate', NULL, OrderDay, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R) g
    GROUP BY g.GroupKey, g.GroupId, g.GroupName
    ORDER BY g.GroupKey, g.GroupName;

    SELECT * FROM #R ORDER BY DoctorName, OrderDate, BillNo, ItemLabel;

    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(10)) AS Value, DoctorName AS Text FROM #R ORDER BY Text;
    DROP TABLE #R;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpStatement
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @ItemType VARCHAR(20) = NULL, @PaidStatus VARCHAR(10) = NULL,   -- PAID / UNPAID
    @Search NVARCHAR(100) = NULL, @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @ItemType = NULLIF(LTRIM(RTRIM(@ItemType)), '');
    SET @PaidStatus = NULLIF(UPPER(LTRIM(RTRIM(@PaidStatus))), '');

    SELECT cd.Commission_Dtl_ID AS CommissionDtlId, cd.Order_Date AS OrderDate,
           CONVERT(VARCHAR(10), CAST(cd.Order_Date AS DATE), 23) AS OrderDay, CONVERT(VARCHAR(7), cd.Order_Date, 126) AS OrderMonth,
           ch.Doctor_ID AS DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName,
           cd.LabOrderId, lo.BillNo, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           cd.Item_Type AS ItemType, i.Item_Code AS ItemCode, ISNULL(i.Item_Name, 'Unknown') AS ItemName,
           ISNULL(i.Item_Code + ' - ', '') + ISNULL(i.Item_Name, 'Unknown') AS ItemLabel,
           ISNULL(i.Department_Name, 'Not mapped') AS DepartmentName,
           cd.Billed_Amount AS BilledAmount, cd.Commission_Rate AS CommissionRate, cd.Commission_Amount AS CommissionAmount,
           ch.Commission_Hdr_ID AS RunNo, ch.Computed_Date AS ComputedDate,
           CASE ch.Source WHEN 'AUTO' THEN 'Scheduled' ELSE 'Manual' END AS Source, ch.Frequency_Of_Disbursal AS Frequency,
           CASE WHEN cd.Is_Paid = 1 THEN 'Paid' ELSE 'Not paid' END AS PaidLabel, cd.Paid_Date AS PaidDate, cd.Paid_Reference AS PaidReference
    INTO #R
    FROM dbo.Doctor_IP_Commission_Dtl cd
    JOIN dbo.Doctor_IP_Commission_Hdr ch ON ch.Commission_Hdr_ID = cd.Commission_Hdr_ID AND ch.IsDeleted = 0
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = ch.Doctor_ID
    JOIN dbo.LabOrder lo ON lo.LabOrderId = cd.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = cd.PatientId
    LEFT JOIN dbo.vw_DoctorIp_Item i ON i.Item_ID = cd.Test_ID AND i.IsPackage = CASE WHEN cd.Item_Type = 'Package' THEN 1 ELSE 0 END
    WHERE ch.Branch_ID = @BranchId AND cd.Order_Date >= @From AND cd.Order_Date < @To
      AND (@DoctorId IS NULL OR ch.Doctor_ID = @DoctorId)
      AND (@ItemType IS NULL OR cd.Item_Type = @ItemType)
      AND (@PaidStatus IS NULL OR (@PaidStatus = 'PAID' AND cd.Is_Paid = 1) OR (@PaidStatus = 'UNPAID' AND cd.Is_Paid = 0))
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR i.Item_Name LIKE '%' + @Search + '%' OR i.Item_Code LIKE '%' + @Search + '%');

    SELECT COUNT(DISTINCT DoctorId) AS DoctorCount, COUNT(DISTINCT LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           ISNULL(SUM(BilledAmount), 0) AS BilledAmount, ISNULL(SUM(CommissionAmount), 0) AS CommissionAmount,
           CAST(CASE WHEN ISNULL(SUM(BilledAmount), 0) = 0 THEN 0 ELSE SUM(CommissionAmount) * 100.0 / SUM(BilledAmount) END AS DECIMAL(9,2)) AS EffectiveRate,
           ISNULL(SUM(CASE WHEN PaidLabel = 'Paid' THEN CommissionAmount END), 0) AS PaidAmount,
           ISNULL(SUM(CASE WHEN PaidLabel <> 'Paid' THEN CommissionAmount END), 0) AS UnpaidAmount
    FROM #R;

    SELECT g.GroupKey, g.GroupId, g.GroupName, 0 AS SortOrder, COUNT(DISTINCT g.LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           SUM(g.BilledAmount) AS BilledAmount, SUM(g.CommissionAmount) AS CommissionAmount,
           CAST(CASE WHEN SUM(g.BilledAmount) = 0 THEN 0 ELSE SUM(g.CommissionAmount) * 100.0 / SUM(g.BilledAmount) END AS DECIMAL(9,2)) AS EffectiveRate
    FROM (SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byItem', NULL, ItemLabel, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byDepartment', NULL, DepartmentName, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byItemType', NULL, ItemType, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byPaid', NULL, PaidLabel, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byDate', NULL, OrderDay, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byMonth', NULL, OrderMonth, LabOrderId, BilledAmount, CommissionAmount FROM #R) g
    GROUP BY g.GroupKey, g.GroupId, g.GroupName
    ORDER BY g.GroupKey, g.GroupName;

    SELECT * FROM #R ORDER BY DoctorName, OrderDate, BillNo, ItemName;

    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(10)) AS Value, DoctorName AS Text FROM #R ORDER BY Text;
    DROP TABLE #R;
END
GO

-- 4. Authorization: PAY control on the commission page ----------------------------------------
DECLARE @co INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.DOCTORIP_COMMISSION' AND CompanyId = @co;
    IF @page IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'PAY', @Title = N'Mark commission paid', @Sort_Order = 40, @Control_ID = @ctl OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
             @Controller = N'DoctorIpCommission', @Action = N'MarkPaid', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
