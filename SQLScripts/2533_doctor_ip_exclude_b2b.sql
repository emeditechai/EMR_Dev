-- ============================================================================
-- Migration: 2533_doctor_ip_exclude_b2b.sql
-- Description: Doctor IP commission is earned on B2C lab bills only. B2B (partner / franchise)
--   bills, LabOrder.IsB2B = 1, are left out of the calculation, the pending lists, the scheduled
--   run and the Doctor IP reports. Commission already computed is not changed.
--   Re-creates the 2450 versions of fn_DoctorIpCommission_Candidates / _Eligible and the Business /
--   Unconfigured report procedures with the B2B filter added; omitted-test handling is unchanged.
--   Run after 2450. Re-runnable.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

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
           x.Omitted_ID
    FROM dbo.LabOrderItem loi
    JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    JOIN dbo.Doctor_IP_Hdr h ON h.Doctor_ID = lo.RefDoctorId AND h.Branch_ID = lo.BranchId
                            AND h.IsActive = 1 AND h.IsDeleted = 0
                            AND CAST(lo.OrderDate AS DATE) BETWEEN h.Effective_From AND h.Effective_To
    JOIN dbo.Doctor_IP_Dtl d ON d.Doctor_IP_Hdr_ID = h.Doctor_IP_Hdr_ID AND d.Test_ID = loi.InvestigationId
                            AND ((loi.Type = 'P' AND d.Item_Type = 'Package') OR (loi.Type = 'I' AND d.Item_Type <> 'Package'))
    LEFT JOIN dbo.Doctor_IP_Commission_Omitted x ON x.LabOrderItemId = loi.LabOrderItemId AND x.IsActive = 1
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
    WHERE c.Is_Omitted = 0;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DoctorIpBusiness
    @BranchId INT, @FromDate DATE, @ToDate DATE,
    @DoctorId INT = NULL, @CommissionStatus VARCHAR(20) = NULL,   -- COMPUTED / PENDING / PARTLY / OMITTED / NONE
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
           COUNT(cd.LabOrderItemId) AS ComputedItems, COUNT(e.LabOrderItemId) AS PendingItems,
           COUNT(CASE WHEN cd.LabOrderItemId IS NULL THEN x.LabOrderItemId END) AS OmittedItems
    INTO #B
    FROM dbo.LabOrder lo
    JOIN dbo.LabOrderItem loi ON loi.LabOrderId = lo.LabOrderId AND loi.IsActive = 1
    LEFT JOIN dbo.Doctor_IP_Commission_Dtl cd ON cd.LabOrderItemId = loi.LabOrderItemId
    LEFT JOIN dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, NULL) e ON e.LabOrderItemId = loi.LabOrderItemId
    LEFT JOIN dbo.Doctor_IP_Commission_Omitted x ON x.LabOrderItemId = loi.LabOrderItemId AND x.IsActive = 1
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND ISNULL(lo.IsB2B, 0) = 0 AND lo.RefDoctorId IS NOT NULL
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
    GROUP BY lo.LabOrderId;

    SELECT b.LabOrderId, b.OrderDate, CONVERT(VARCHAR(10), CAST(b.OrderDate AS DATE), 23) AS OrderDay, CONVERT(VARCHAR(7), b.OrderDate, 126) AS OrderMonth,
           b.BillNo, b.PatientId, LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
           b.DoctorId, ISNULL(dm.NamePrefix + ' ', '') + dm.FullName AS DoctorName,
           b.ItemCount, b.BilledAmount, b.EligibleAmount, b.CommissionComputed, b.CommissionPending,
           b.CommissionComputed + b.CommissionPending AS CommissionTotal,
           x.StatusCode,
           CASE x.StatusCode WHEN 'COMPUTED' THEN 'Computed' WHEN 'PENDING' THEN 'Pending' WHEN 'PARTLY' THEN 'Partly computed' WHEN 'OMITTED' THEN 'Omitted from IP' ELSE 'No commission rate' END AS StatusLabel
    INTO #R
    FROM #B b
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = b.DoctorId
    LEFT JOIN dbo.PatientMaster p ON p.PatientId = b.PatientId
    CROSS APPLY (SELECT CASE WHEN b.ComputedItems > 0 AND b.PendingItems > 0 THEN 'PARTLY' WHEN b.ComputedItems > 0 THEN 'COMPUTED'
                             WHEN b.PendingItems > 0 THEN 'PENDING' WHEN b.OmittedItems > 0 THEN 'OMITTED' ELSE 'NONE' END AS StatusCode) x
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
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND ISNULL(lo.IsB2B, 0) = 0 AND loi.IsActive = 1 AND lo.RefDoctorId IS NOT NULL
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Commission_Dtl cd WHERE cd.LabOrderItemId = loi.LabOrderItemId)
      AND NOT EXISTS (SELECT 1 FROM dbo.fn_DoctorIpCommission_Eligible(@BranchId, @DoctorId, @FromDate, @ToDate, NULL) e WHERE e.LabOrderItemId = loi.LabOrderItemId)
      AND NOT EXISTS (SELECT 1 FROM dbo.Doctor_IP_Commission_Omitted x WHERE x.LabOrderItemId = loi.LabOrderItemId AND x.IsActive = 1)
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
