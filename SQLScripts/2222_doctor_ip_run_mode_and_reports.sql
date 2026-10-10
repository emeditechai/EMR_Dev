-- ============================================================================
-- Migration: 2222_doctor_ip_run_mode_and_reports.sql
-- Description:
--   1. Hospital Settings > LAB parameters (per branch):
--        DoctorIpComputeMode  'Manual' (screen only, default) / 'Automatic' (scheduled job only) / 'Both'
--        DoctorIpAutoRunTime  time of day the scheduled job runs (required for Automatic / Both)
--   2. Doctor_IP_Commission_RunLog - one row per branch per day the scheduled job ran, so it runs
--      once a day even if the API restarts, and still runs if the API starts after the set time.
--   3. Reports > LAB > Doctor IP reports (result shape of SQLScripts/2124: summary, groups, rows, options):
--        usp_Api_LabReport_DoctorIpStatement     computed commission, bill-wise / test-wise
--        usp_Api_LabReport_DoctorIpBusiness      referral doctor business with commission computed / pending
--        usp_Api_LabReport_DoctorIpPending       commission not yet computed
--        usp_Api_LabReport_DoctorIpUnconfigured  referred items that have no commission rate
--   4. Authorization: five pages under REPORTS.LAB (controller DoctorIpCommission).
--   Run after 2221 (Doctor IP commission transaction).
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Hospital Settings parameters ---------------------------------------------
IF COL_LENGTH('dbo.HospitalSettings', 'DoctorIpComputeMode') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD DoctorIpComputeMode VARCHAR(10) NOT NULL
        CONSTRAINT DF_HospitalSettings_DoctorIpComputeMode DEFAULT 'Manual'
        CONSTRAINT CK_HospitalSettings_DoctorIpComputeMode CHECK (DoctorIpComputeMode IN ('Manual', 'Automatic', 'Both'));
GO
IF COL_LENGTH('dbo.HospitalSettings', 'DoctorIpAutoRunTime') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD DoctorIpAutoRunTime TIME(0) NULL;
GO

-- 2. Scheduled-run log -----------------------------------------------------------
IF OBJECT_ID('dbo.Doctor_IP_Commission_RunLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Doctor_IP_Commission_RunLog
    (
        Run_ID           BIGINT IDENTITY(1,1) PRIMARY KEY,
        Branch_ID        INT NOT NULL,
        Run_Date         DATE NOT NULL,
        Started_On       DATETIME NOT NULL DEFAULT GETDATE(),
        Finished_On      DATETIME NULL,
        Schedules_Due    INT NOT NULL DEFAULT 0,
        Items_Computed   INT NOT NULL DEFAULT 0,
        Total_Commission DECIMAL(18,2) NOT NULL DEFAULT 0,
        Failed_Count     INT NOT NULL DEFAULT 0,
        Message          NVARCHAR(500) NULL
    );
    CREATE UNIQUE INDEX UX_Doctor_IP_Commission_RunLog ON dbo.Doctor_IP_Commission_RunLog (Branch_ID, Run_Date);
END
GO

-- Branches whose scheduled run is due now: mode Automatic / Both, run time reached, not yet run today.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetDueBranches
    @Now DATETIME
AS
BEGIN
    SET NOCOUNT ON;
    SELECT hs.BranchID AS Branch_ID, hs.DoctorIpComputeMode AS Compute_Mode, hs.DoctorIpAutoRunTime AS Run_Time
    FROM dbo.HospitalSettings hs
    WHERE hs.IsActive = 1
      AND hs.DoctorIpComputeMode IN ('Automatic', 'Both')
      AND hs.DoctorIpAutoRunTime IS NOT NULL
      AND CAST(@Now AS TIME(0)) >= hs.DoctorIpAutoRunTime
      AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Commission_RunLog l
                      WHERE l.Branch_ID = hs.BranchID AND l.Run_Date = CAST(@Now AS DATE));
END
GO

-- Claims today's run for a branch. Returns Run_ID, or NULL when another instance already took it.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_StartRun
    @BranchId INT, @RunDate DATE
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO dbo.Doctor_IP_Commission_RunLog (Branch_ID, Run_Date) VALUES (@BranchId, @RunDate);
        SELECT CAST(SCOPE_IDENTITY() AS BIGINT) AS Run_ID;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627) SELECT CAST(NULL AS BIGINT) AS Run_ID; ELSE THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_FinishRun
    @RunId BIGINT, @SchedulesDue INT, @ItemsComputed INT, @TotalCommission DECIMAL(18,2), @FailedCount INT, @Message NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Doctor_IP_Commission_RunLog
       SET Finished_On = GETDATE(), Schedules_Due = @SchedulesDue, Items_Computed = @ItemsComputed,
           Total_Commission = @TotalCommission, Failed_Count = @FailedCount, Message = @Message
     WHERE Run_ID = @RunId;
END
GO

-- 3. Reports ---------------------------------------------------------------------
-- Name / code / department of anything a Doctor IP can hold. Package ids overlap with test ids: use IsPackage + Item_ID.
CREATE OR ALTER VIEW dbo.vw_DoctorIp_Item
AS
    SELECT CAST(0 AS BIT) AS IsPackage, CAST(m.Test_ID AS BIGINT) AS Item_ID, m.Test_Code AS Item_Code, m.Test_Name AS Item_Name,
           CAST(CASE WHEN m.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS VARCHAR(10)) AS Item_Type,
           ISNULL(dep.DeptName, 'Not mapped') AS Department_Name
    FROM dbo.LabInvestigationMaster m
    LEFT JOIN dbo.LabTestCategoryMaster c ON c.Category_ID = m.Category_ID
    LEFT JOIN dbo.DepartmentMaster dep ON dep.DeptId = ISNULL(m.Department_ID, c.Department_ID)
    UNION ALL
    SELECT CAST(1 AS BIT), CAST(ph.Profile_ID AS BIGINT), ph.Profile_Code, ph.Profile_Name, CAST('Package' AS VARCHAR(10)), 'Packages'
    FROM dbo.LabInvestigationProfileHeader ph
    WHERE ph.Profile_Type = 2;
GO

-- 3a. Commission statement: every order item whose commission has been computed.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpStatement
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @ItemType VARCHAR(20) = NULL,
    @Search NVARCHAR(100) = NULL, @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @ItemType = NULLIF(LTRIM(RTRIM(@ItemType)), '');

    SELECT cd.Commission_Dtl_ID AS CommissionDtlId, cd.Order_Date AS OrderDate,
           CONVERT(VARCHAR(10), CAST(cd.Order_Date AS DATE), 23) AS OrderDay, CONVERT(VARCHAR(7), cd.Order_Date, 126) AS OrderMonth,
           ch.Doctor_ID AS DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName,
           cd.LabOrderId, lo.BillNo, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           cd.Item_Type AS ItemType, i.Item_Code AS ItemCode, ISNULL(i.Item_Name, 'Unknown') AS ItemName,
           ISNULL(i.Item_Code + ' - ', '') + ISNULL(i.Item_Name, 'Unknown') AS ItemLabel,
           ISNULL(i.Department_Name, 'Not mapped') AS DepartmentName,
           cd.Billed_Amount AS BilledAmount, cd.Commission_Rate AS CommissionRate, cd.Commission_Amount AS CommissionAmount,
           ch.Commission_Hdr_ID AS RunNo, ch.Computed_Date AS ComputedDate,
           CASE ch.Source WHEN 'AUTO' THEN 'Scheduled' ELSE 'Manual' END AS Source, ch.Frequency_Of_Disbursal AS Frequency
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
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR i.Item_Name LIKE '%' + @Search + '%' OR i.Item_Code LIKE '%' + @Search + '%');

    SELECT COUNT(DISTINCT DoctorId) AS DoctorCount, COUNT(DISTINCT LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           ISNULL(SUM(BilledAmount), 0) AS BilledAmount, ISNULL(SUM(CommissionAmount), 0) AS CommissionAmount,
           CAST(CASE WHEN ISNULL(SUM(BilledAmount), 0) = 0 THEN 0 ELSE SUM(CommissionAmount) * 100.0 / SUM(BilledAmount) END AS DECIMAL(9,2)) AS EffectiveRate
    FROM #R;

    SELECT g.GroupKey, g.GroupId, g.GroupName, 0 AS SortOrder, COUNT(DISTINCT g.LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           SUM(g.BilledAmount) AS BilledAmount, SUM(g.CommissionAmount) AS CommissionAmount,
           CAST(CASE WHEN SUM(g.BilledAmount) = 0 THEN 0 ELSE SUM(g.CommissionAmount) * 100.0 / SUM(g.BilledAmount) END AS DECIMAL(9,2)) AS EffectiveRate
    FROM (SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byItem', NULL, ItemLabel, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byDepartment', NULL, DepartmentName, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byItemType', NULL, ItemType, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byDate', NULL, OrderDay, LabOrderId, BilledAmount, CommissionAmount FROM #R
          UNION ALL SELECT 'byMonth', NULL, OrderMonth, LabOrderId, BilledAmount, CommissionAmount FROM #R) g
    GROUP BY g.GroupKey, g.GroupId, g.GroupName
    ORDER BY g.GroupKey, g.GroupName;

    SELECT * FROM #R ORDER BY DoctorName, OrderDate, BillNo, ItemName;

    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(10)) AS Value, DoctorName AS Text FROM #R ORDER BY Text;
    DROP TABLE #R;
END
GO

-- 3b. Referral doctor business: every bill referred by a doctor, with commission computed / pending.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpBusiness
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @CommissionStatus VARCHAR(20) = NULL,   -- COMPUTED / PENDING / PARTLY / NONE
    @Search NVARCHAR(100) = NULL, @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @CommissionStatus = NULLIF(UPPER(LTRIM(RTRIM(@CommissionStatus))), '');

    SELECT lo.LabOrderId, MAX(lo.OrderDate) AS OrderDate, MAX(lo.BillNo) AS BillNo, MAX(lo.PatientId) AS PatientId, MAX(lo.RefDoctorId) AS DoctorId,
           COUNT(1) AS ItemCount, SUM(CAST(loi.Price AS DECIMAL(18,2))) AS BilledAmount,
           SUM(CASE WHEN cd.LabOrderItemId IS NOT NULL OR e.LabOrderItemId IS NOT NULL THEN CAST(loi.Price AS DECIMAL(18,2)) ELSE 0 END) AS EligibleAmount,
           ISNULL(SUM(cd.Commission_Amount), 0) AS CommissionComputed, ISNULL(SUM(e.Commission_Amount), 0) AS CommissionPending,
           COUNT(cd.LabOrderItemId) AS ComputedItems, COUNT(e.LabOrderItemId) AS PendingItems
    INTO #B
    FROM dbo.LabOrder lo
    JOIN dbo.LabOrderItem loi ON loi.LabOrderId = lo.LabOrderId AND loi.IsActive = 1
    LEFT JOIN dbo.Doctor_IP_Commission_Dtl cd ON cd.LabOrderItemId = loi.LabOrderItemId
    LEFT JOIN dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, NULL) e ON e.LabOrderItemId = loi.LabOrderItemId
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND lo.RefDoctorId IS NOT NULL
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
    GROUP BY lo.LabOrderId;

    SELECT b.LabOrderId, b.OrderDate, CONVERT(VARCHAR(10), CAST(b.OrderDate AS DATE), 23) AS OrderDay, CONVERT(VARCHAR(7), b.OrderDate, 126) AS OrderMonth,
           b.BillNo, b.PatientId, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           b.DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName,
           b.ItemCount, b.BilledAmount, b.EligibleAmount, b.CommissionComputed, b.CommissionPending,
           b.CommissionComputed + b.CommissionPending AS CommissionTotal,
           x.StatusCode,
           CASE x.StatusCode WHEN 'COMPUTED' THEN 'Computed' WHEN 'PENDING' THEN 'Pending' WHEN 'PARTLY' THEN 'Partly computed' ELSE 'No commission rate' END AS StatusLabel
    INTO #R
    FROM #B b
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = b.DoctorId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = b.PatientId
    CROSS APPLY (SELECT CASE WHEN b.ComputedItems > 0 AND b.PendingItems > 0 THEN 'PARTLY' WHEN b.ComputedItems > 0 THEN 'COMPUTED'
                             WHEN b.PendingItems > 0 THEN 'PENDING' ELSE 'NONE' END AS StatusCode) x
    WHERE (@CommissionStatus IS NULL OR x.StatusCode = @CommissionStatus)
      AND (@Search IS NULL OR b.BillNo LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    SELECT COUNT(DISTINCT DoctorId) AS DoctorCount, COUNT(1) AS BillCount, COUNT(DISTINCT PatientId) AS PatientCount,
           ISNULL(SUM(ItemCount), 0) AS ItemCount, ISNULL(SUM(BilledAmount), 0) AS BilledAmount, ISNULL(SUM(EligibleAmount), 0) AS EligibleAmount,
           ISNULL(SUM(CommissionComputed), 0) AS CommissionComputed, ISNULL(SUM(CommissionPending), 0) AS CommissionPending
    FROM #R;

    SELECT g.GroupKey, g.GroupId, g.GroupName, 0 AS SortOrder, COUNT(1) AS BillCount, COUNT(DISTINCT g.PatientId) AS PatientCount,
           SUM(g.BilledAmount) AS BilledAmount, SUM(g.CommissionComputed) AS CommissionComputed, SUM(g.CommissionPending) AS CommissionPending,
           SUM(g.CommissionTotal) AS CommissionTotal
    FROM (SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, PatientId, BilledAmount, CommissionComputed, CommissionPending, CommissionTotal FROM #R
          UNION ALL SELECT 'byStatus', NULL, StatusLabel, PatientId, BilledAmount, CommissionComputed, CommissionPending, CommissionTotal FROM #R
          UNION ALL SELECT 'byDate', NULL, OrderDay, PatientId, BilledAmount, CommissionComputed, CommissionPending, CommissionTotal FROM #R
          UNION ALL SELECT 'byMonth', NULL, OrderMonth, PatientId, BilledAmount, CommissionComputed, CommissionPending, CommissionTotal FROM #R) g
    GROUP BY g.GroupKey, g.GroupId, g.GroupName
    ORDER BY g.GroupKey, g.GroupName;

    SELECT * FROM #R ORDER BY DoctorName, OrderDate, BillNo;

    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(10)) AS Value, DoctorName AS Text FROM #R ORDER BY Text;
    DROP TABLE #R; DROP TABLE #B;
END
GO

-- 3c. Pending commission: order items that have a rate but are not computed yet.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpPending
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @ItemType VARCHAR(20) = NULL, @Frequency VARCHAR(20) = NULL,
    @Search NVARCHAR(100) = NULL, @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @ItemType = NULLIF(LTRIM(RTRIM(@ItemType)), '');
    SET @Frequency = NULLIF(LTRIM(RTRIM(@Frequency)), '');

    SELECT e.LabOrderItemId, e.Order_Date AS OrderDate, CONVERT(VARCHAR(10), CAST(e.Order_Date AS DATE), 23) AS OrderDay,
           DATEDIFF(DAY, e.Order_Date, GETDATE()) AS DaysPending,
           e.Doctor_ID AS DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName, e.Frequency_Of_Disbursal AS Frequency,
           e.LabOrderId, lo.BillNo, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           e.Item_Type AS ItemType, ISNULL(i.Item_Code + ' - ', '') + ISNULL(i.Item_Name, 'Unknown') AS ItemLabel,
           e.Billed_Amount AS BilledAmount, e.Commission_Rate AS CommissionRate, e.Commission_Amount AS CommissionAmount
    INTO #R
    FROM dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, NULL) e
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = e.Doctor_ID
    JOIN dbo.LabOrder lo ON lo.LabOrderId = e.LabOrderId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = e.PatientId
    LEFT JOIN dbo.vw_DoctorIp_Item i ON i.Item_ID = e.Test_ID AND i.IsPackage = CASE WHEN e.Item_Type = 'Package' THEN 1 ELSE 0 END
    WHERE (@ItemType IS NULL OR e.Item_Type = @ItemType)
      AND (@Frequency IS NULL OR e.Frequency_Of_Disbursal = @Frequency)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR i.Item_Name LIKE '%' + @Search + '%' OR i.Item_Code LIKE '%' + @Search + '%');

    SELECT COUNT(DISTINCT DoctorId) AS DoctorCount, COUNT(DISTINCT LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           ISNULL(SUM(BilledAmount), 0) AS BilledAmount, ISNULL(SUM(CommissionAmount), 0) AS CommissionAmount,
           ISNULL(MAX(DaysPending), 0) AS OldestDays
    FROM #R;

    SELECT g.GroupKey, g.GroupId, g.GroupName, 0 AS SortOrder, COUNT(DISTINCT g.LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           SUM(g.BilledAmount) AS BilledAmount, SUM(g.CommissionAmount) AS CommissionAmount, MAX(g.DaysPending) AS OldestDays
    FROM (SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byFrequency', NULL, ISNULL(Frequency, 'Not set'), LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byItemType', NULL, ItemType, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R
          UNION ALL SELECT 'byDate', NULL, OrderDay, LabOrderId, BilledAmount, CommissionAmount, DaysPending FROM #R) g
    GROUP BY g.GroupKey, g.GroupId, g.GroupName
    ORDER BY g.GroupKey, g.GroupName;

    SELECT * FROM #R ORDER BY DoctorName, OrderDate, BillNo, ItemLabel;

    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(10)) AS Value, DoctorName AS Text FROM #R ORDER BY Text;
    DROP TABLE #R;
END
GO

-- 3d. Referred order items that earn no commission because no rate applies to them.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpUnconfigured
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @Reason VARCHAR(20) = NULL,   -- NO_SETUP / NO_PERIOD / NOT_LISTED
    @Search NVARCHAR(100) = NULL, @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Reason = NULLIF(UPPER(LTRIM(RTRIM(@Reason))), '');

    SELECT loi.LabOrderItemId, lo.OrderDate, CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS OrderDay,
           lo.RefDoctorId AS DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName,
           lo.LabOrderId, lo.BillNo, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           ISNULL(i.Item_Type, CASE WHEN loi.Type = 'P' THEN 'Package' ELSE 'Test' END) AS ItemType,
           ISNULL(i.Item_Code + ' - ', '') + ISNULL(i.Item_Name, 'Unknown') AS ItemLabel,
           CAST(loi.Price AS DECIMAL(18,2)) AS BilledAmount,
           r.ReasonCode,
           CASE r.ReasonCode WHEN 'NO_SETUP' THEN 'Doctor has no Doctor IP' WHEN 'NO_PERIOD' THEN 'No active Doctor IP on the order date'
                             ELSE 'Item not in the Doctor IP' END AS ReasonLabel
    INTO #R
    FROM dbo.LabOrderItem loi
    JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = lo.RefDoctorId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT JOIN dbo.vw_DoctorIp_Item i ON i.Item_ID = loi.InvestigationId AND i.IsPackage = CASE WHEN loi.Type = 'P' THEN 1 ELSE 0 END
    CROSS APPLY (SELECT CASE
                     WHEN NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Hdr h WHERE h.Doctor_ID = lo.RefDoctorId AND h.Branch_ID = lo.BranchId AND h.IsDeleted = 0) THEN 'NO_SETUP'
                     WHEN NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Hdr h WHERE h.Doctor_ID = lo.RefDoctorId AND h.Branch_ID = lo.BranchId AND h.IsDeleted = 0 AND h.IsActive = 1
                                        AND CAST(lo.OrderDate AS DATE) BETWEEN h.Effective_From AND h.Effective_To) THEN 'NO_PERIOD'
                     ELSE 'NOT_LISTED' END AS ReasonCode) r
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND loi.IsActive = 1 AND lo.RefDoctorId IS NOT NULL
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Commission_Dtl cd WHERE cd.LabOrderItemId = loi.LabOrderItemId)
      AND NOT EXISTS (SELECT 1 FROM dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, NULL) e WHERE e.LabOrderItemId = loi.LabOrderItemId)
      AND (@Reason IS NULL OR r.ReasonCode = @Reason)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR i.Item_Name LIKE '%' + @Search + '%' OR i.Item_Code LIKE '%' + @Search + '%');

    SELECT COUNT(DISTINCT DoctorId) AS DoctorCount, COUNT(DISTINCT LabOrderId) AS BillCount, COUNT(1) AS ItemCount,
           ISNULL(SUM(BilledAmount), 0) AS BilledAmount,
           ISNULL(SUM(CASE WHEN ReasonCode = 'NO_SETUP' THEN BilledAmount END), 0) AS NoSetupAmount,
           ISNULL(SUM(CASE WHEN ReasonCode = 'NO_PERIOD' THEN BilledAmount END), 0) AS NoPeriodAmount,
           ISNULL(SUM(CASE WHEN ReasonCode = 'NOT_LISTED' THEN BilledAmount END), 0) AS NotListedAmount
    FROM #R;

    SELECT g.GroupKey, g.GroupId, g.GroupName, 0 AS SortOrder, COUNT(DISTINCT g.LabOrderId) AS BillCount, COUNT(1) AS ItemCount, SUM(g.BilledAmount) AS BilledAmount
    FROM (SELECT 'byDoctor' AS GroupKey, DoctorId AS GroupId, DoctorName AS GroupName, LabOrderId, BilledAmount FROM #R
          UNION ALL SELECT 'byReason', NULL, ReasonLabel, LabOrderId, BilledAmount FROM #R
          UNION ALL SELECT 'byItem', NULL, ItemLabel, LabOrderId, BilledAmount FROM #R
          UNION ALL SELECT 'byDate', NULL, OrderDay, LabOrderId, BilledAmount FROM #R) g
    GROUP BY g.GroupKey, g.GroupId, g.GroupName
    ORDER BY g.GroupKey, g.GroupName;

    SELECT * FROM #R ORDER BY DoctorName, OrderDate, BillNo, ItemLabel;

    SELECT DISTINCT 'doctorId' AS FilterKey, CAST(DoctorId AS VARCHAR(10)) AS Value, DoctorName AS Text FROM #R ORDER BY Text;
    DROP TABLE #R;
END
GO

-- 4. Authorization: pages under Reports > LAB ---------------------------------------
DECLARE @Pages TABLE (Code NVARCHAR(100), Title NVARCHAR(150), Action NVARCHAR(150), Sort INT, Icon NVARCHAR(100));
INSERT INTO @Pages VALUES
 (N'REPORTS.DOCTORIPBUSINESS',     N'Referral Doctor Business',            N'ReportBusiness',     230, N'bi bi-person-badge me-2'),
 (N'REPORTS.DOCTORIPSTATEMENT',    N'Doctor IP Commission Statement',      N'ReportStatement',    235, N'bi bi-receipt-cutoff me-2'),
 (N'REPORTS.DOCTORIPITEMWISE',     N'Test-wise Doctor IP Commission',      N'ReportItemWise',     240, N'bi bi-clipboard2-pulse me-2'),
 (N'REPORTS.DOCTORIPPENDING',      N'Doctor IP Commission Pending',        N'ReportPending',      245, N'bi bi-hourglass-split me-2'),
 (N'REPORTS.DOCTORIPUNCONFIGURED', N'Referrals without Commission Rate',   N'ReportUnconfigured', 250, N'bi bi-exclamation-diamond me-2');

DECLARE @co INT, @menu INT, @page INT, @view INT, @code NVARCHAR(100), @title NVARCHAR(150), @action NVARCHAR(150), @sort INT, @icon NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Action, Sort, Icon FROM @Pages;
        OPEN pg; FETCH NEXT FROM pg INTO @code, @title, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = @code, @Title = @title,
                 @Controller = N'DoctorIpCommission', @Action = @action, @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
            SET @view = NULL;
            SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'DoctorIpCommission', @Action = @action, @Source = 'SEED';
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
                 @Controller = N'DoctorIpCommission', @Action = N'GetReportData', @Source = 'SEED';
            FETCH NEXT FROM pg INTO @code, @title, @action, @sort, @icon;
        END
        CLOSE pg; DEALLOCATE pg;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

-- 5. Grant the Doctor IP reports to the Administrator role ------------------------
-- Super Admin (Users.IsSuperAdmin) bypasses permission checks and needs no grant.
DECLARE @role INT, @pageId INT, @companyId INT;
DECLARE gr CURSOR LOCAL FAST_FORWARD FOR
    SELECT r.Id, p.Page_ID, p.CompanyId
    FROM dbo.PageMaster p
    JOIN dbo.roles r ON r.Name = 'Administrator' AND ISNULL(r.CompanyId, p.CompanyId) = p.CompanyId
    WHERE p.Page_Code IN ('REPORTS.DOCTORIPBUSINESS', 'REPORTS.DOCTORIPSTATEMENT', 'REPORTS.DOCTORIPITEMWISE',
                          'REPORTS.DOCTORIPPENDING', 'REPORTS.DOCTORIPUNCONFIGURED');
OPEN gr; FETCH NEXT FROM gr INTO @role, @pageId, @companyId;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_RolePermission_Upsert @Role_ID = @role, @Page_ID = @pageId, @Permission = 'A', @CompanyId = @companyId,
         @Reason = N'Doctor IP reports granted to Administrator (script 2222)';
    FETCH NEXT FROM gr INTO @role, @pageId, @companyId;
END
CLOSE gr; DEALLOCATE gr;
GO
