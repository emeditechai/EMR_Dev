-- ============================================================================
-- Migration: 2450_doctor_ip_omit_tests.sql
-- Description: Doctor IP commission - tests can be omitted before the IP calculation.
--   * Doctor_IP_Commission_Omitted: one active row per lab order item left out of the commission
--     (with the rate and amount it would have earned, who omitted it, when and why). Restoring an
--     item closes the row (IsActive = 0); the history stays.
--   * fn_DoctorIpCommission_Candidates: every pending item with a rate, with Is_Omitted.
--     fn_DoctorIpCommission_Eligible now returns only the items not omitted, so the manual Calculate,
--     the scheduled (automatic) run, the Pending report and the pending totals all skip omitted tests.
--   * usp_DoctorIpCommission_GetPending: adds Omitted_Items / Omitted_Amount / Omitted_Commission.
--   * usp_DoctorIpCommission_GetPendingTests: a doctor's pending tests for the period, omitted ones flagged.
--   * usp_DoctorIpCommission_SetOmitted: omits / restores pending items (computed items cannot change).
--   * Reports: Referral Doctor Business shows status 'Omitted from IP'; omitted items are not
--     listed as unconfigured.
--   * Authorization: control OMIT on MASTER.DOCTORIP_COMMISSION (page-level grants cover it).
--   Run after 2222. Re-runnable.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Omitted items -----------------------------------------------------------------
IF OBJECT_ID('dbo.Doctor_IP_Commission_Omitted', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Doctor_IP_Commission_Omitted
    (
        Omitted_ID        BIGINT IDENTITY(1,1) PRIMARY KEY,
        CompanyId         INT NOT NULL,
        Branch_ID         INT NOT NULL,
        Doctor_ID         INT NOT NULL,
        Doctor_IP_Hdr_ID  INT NOT NULL,
        LabOrderId        INT NOT NULL,
        LabOrderItemId    INT NOT NULL,
        Item_Type         VARCHAR(10) NOT NULL,
        Test_ID           BIGINT NOT NULL,
        Billed_Amount     DECIMAL(18,2) NOT NULL,
        Commission_Rate   DECIMAL(18,2) NOT NULL,
        Commission_Amount DECIMAL(18,2) NOT NULL,
        Reason            NVARCHAR(250) NULL,
        Omitted_By        INT NULL,
        Omitted_On        DATETIME NOT NULL CONSTRAINT DF_Doctor_IP_Commission_Omitted_On DEFAULT GETDATE(),
        IsActive          BIT NOT NULL CONSTRAINT DF_Doctor_IP_Commission_Omitted_Active DEFAULT 1,
        Restored_By       INT NULL,
        Restored_On       DATETIME NULL
    );
    -- An order item is omitted at most once at a time.
    CREATE UNIQUE INDEX UX_Doctor_IP_Commission_Omitted_Item ON dbo.Doctor_IP_Commission_Omitted (LabOrderItemId) WHERE IsActive = 1;
    CREATE INDEX IX_Doctor_IP_Commission_Omitted_Doctor ON dbo.Doctor_IP_Commission_Omitted (Branch_ID, Doctor_ID, IsActive);
END
GO

-- descriptions (picked up by the data dictionary)
DECLARE @d TABLE (c SYSNAME NULL, v NVARCHAR(400));
INSERT @d VALUES
 (NULL, N'Lab order items left out of the Doctor IP commission before it was calculated (manual or scheduled run). Restoring an item sets IsActive = 0.'),
 (N'LabOrderItemId', N'Order item left out of the commission (LabOrderItem.LabOrderItemId); at most one active row per item.'),
 (N'Doctor_IP_Hdr_ID', N'Doctor IP set-up whose rate applied to the item (Doctor_IP_Hdr).'),
 (N'Commission_Amount', N'Commission the item would have earned at the time it was omitted.'),
 (N'Reason', N'Why the item was omitted (optional).'),
 (N'IsActive', N'1 = omitted now; 0 = restored (Restored_By / Restored_On), the item is pending again.');
DECLARE @c SYSNAME, @v NVARCHAR(400);
DECLARE dc CURSOR LOCAL FAST_FORWARD FOR SELECT c, v FROM @d;
OPEN dc;
FETCH NEXT FROM dc INTO @c, @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @c IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.Doctor_IP_Commission_Omitted') AND minor_id = 0 AND name = 'MS_Description')
            EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', 'Doctor_IP_Commission_Omitted';
        ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', 'Doctor_IP_Commission_Omitted';
    END
    ELSE IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.Doctor_IP_Commission_Omitted')
                     AND minor_id = COLUMNPROPERTY(OBJECT_ID('dbo.Doctor_IP_Commission_Omitted'), @c, 'ColumnId') AND name = 'MS_Description')
        EXEC sys.sp_updateextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', 'Doctor_IP_Commission_Omitted', 'COLUMN', @c;
    ELSE EXEC sys.sp_addextendedproperty 'MS_Description', @v, 'SCHEMA', 'dbo', 'TABLE', 'Doctor_IP_Commission_Omitted', 'COLUMN', @c;
    FETCH NEXT FROM dc INTO @c, @v;
END
CLOSE dc; DEALLOCATE dc;
GO

-- 2. Candidate / eligible items ------------------------------------------------------
-- Every pending order item that has a commission rate, with Is_Omitted.
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
      AND lo.BranchId = @BranchId
      AND (@DoctorId IS NULL OR lo.RefDoctorId = @DoctorId)
      AND (@CompanyId IS NULL OR h.CompanyId = @CompanyId)
      AND (@FromDate IS NULL OR CAST(lo.OrderDate AS DATE) >= @FromDate)
      AND (@ToDate IS NULL OR CAST(lo.OrderDate AS DATE) <= @ToDate);
GO

-- Items the commission is calculated on (manual and scheduled runs): candidates not omitted.
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

-- 3. Procedures ----------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetPending
    @BranchId INT, @DoctorId INT = NULL, @FromDate DATE = NULL, @ToDate DATE = NULL, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.Doctor_ID, dm.FullName AS Doctor_Name, MAX(c.Frequency_Of_Disbursal) AS Frequency_Of_Disbursal,
           COUNT(DISTINCT CASE WHEN c.Is_Omitted = 0 THEN c.LabOrderId END) AS Pending_Orders,
           SUM(CASE WHEN c.Is_Omitted = 0 THEN 1 ELSE 0 END) AS Pending_Items,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 0 THEN c.Billed_Amount END), 0) AS Pending_Amount,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 0 THEN c.Commission_Amount END), 0) AS Estimated_Commission,
           SUM(CASE WHEN c.Is_Omitted = 1 THEN 1 ELSE 0 END) AS Omitted_Items,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 1 THEN c.Billed_Amount END), 0) AS Omitted_Amount,
           ISNULL(SUM(CASE WHEN c.Is_Omitted = 1 THEN c.Commission_Amount END), 0) AS Omitted_Commission,
           MIN(c.Order_Date) AS First_Order_Date, MAX(c.Order_Date) AS Last_Order_Date
    FROM dbo.fn_DoctorIpCommission_Candidates(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId) c
    JOIN dbo.DoctorMaster dm ON dm.DoctorId = c.Doctor_ID
    GROUP BY c.Doctor_ID, dm.FullName
    ORDER BY dm.FullName;
END
GO

-- A doctor's pending tests for the period (included and omitted), for the selection before calculating.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_GetPendingTests
    @BranchId INT, @DoctorId INT, @FromDate DATE, @ToDate DATE, @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.LabOrderItemId, c.LabOrderId, lo.BillNo, c.Order_Date,
           LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS Patient_Name,
           c.Item_Type, c.Test_ID, i.Item_Code AS Test_Code, ISNULL(i.Item_Name, 'Unknown') AS Test_Name,
           c.Billed_Amount, c.Commission_Rate, c.Commission_Amount, c.Is_Omitted,
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

-- Omits (@OmitIds) and restores (@IncludeIds) pending items of a doctor in the period; comma-separated
-- LabOrderItemIds. Items already computed, or not pending for this doctor / branch / period, are ignored.
CREATE OR ALTER PROCEDURE dbo.usp_DoctorIpCommission_SetOmitted
    @BranchId INT, @DoctorId INT, @FromDate DATE, @ToDate DATE, @CompanyId INT = NULL, @UserId INT = NULL,
    @OmitIds NVARCHAR(MAX) = NULL, @IncludeIds NVARCHAR(MAX) = NULL, @Reason NVARCHAR(250) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), '');
    DECLARE @Omit TABLE (Id INT PRIMARY KEY);
    DECLARE @Incl TABLE (Id INT PRIMARY KEY);
    INSERT @Omit SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@OmitIds, ''), ',') WHERE TRY_CAST(value AS INT) IS NOT NULL;
    INSERT @Incl SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@IncludeIds, ''), ',') WHERE TRY_CAST(value AS INT) IS NOT NULL
                  AND TRY_CAST(value AS INT) NOT IN (SELECT Id FROM @Omit);

    SELECT * INTO #C FROM dbo.fn_DoctorIpCommission_Candidates(@BranchId, @DoctorId, @FromDate, @ToDate, @CompanyId);
    DECLARE @Restored INT = 0, @Omitted INT = 0;

    BEGIN TRANSACTION;
    UPDATE x SET IsActive = 0, Restored_By = @UserId, Restored_On = GETDATE()
      FROM dbo.Doctor_IP_Commission_Omitted x
      JOIN #C c ON c.Omitted_ID = x.Omitted_ID
      JOIN @Incl i ON i.Id = c.LabOrderItemId
     WHERE x.IsActive = 1;
    SET @Restored = @@ROWCOUNT;

    INSERT dbo.Doctor_IP_Commission_Omitted
        (CompanyId, Branch_ID, Doctor_ID, Doctor_IP_Hdr_ID, LabOrderId, LabOrderItemId, Item_Type, Test_ID,
         Billed_Amount, Commission_Rate, Commission_Amount, Reason, Omitted_By)
    SELECT c.CompanyId, c.Branch_ID, c.Doctor_ID, c.Doctor_IP_Hdr_ID, c.LabOrderId, c.LabOrderItemId, c.Item_Type, c.Test_ID,
           c.Billed_Amount, c.Commission_Rate, c.Commission_Amount, @Reason, @UserId
      FROM #C c
      JOIN @Omit o ON o.Id = c.LabOrderItemId
     WHERE c.Is_Omitted = 0;
    SET @Omitted = @@ROWCOUNT;
    COMMIT TRANSACTION;

    SELECT @Omitted AS Omitted_Count, @Restored AS Restored_Count;
END
GO

-- 4. Reports -------------------------------------------------------------------------
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
    WHERE lo.BranchId = @BranchId AND lo.IsActive = 1 AND loi.IsActive = 1 AND lo.RefDoctorId IS NOT NULL
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

-- 5. Authorization: OMIT control on the commission page -----------------------------
DECLARE @co INT, @page INT, @ctl INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.DOCTORIP_COMMISSION' AND CompanyId = @co;
    IF @page IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'OMIT', @Title = N'Omit tests from commission', @Sort_Order = 25, @Control_ID = @ctl OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'DoctorIpCommission', @Action = N'PendingTests', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
             @Controller = N'DoctorIpCommission', @Action = N'SaveOmitted', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
