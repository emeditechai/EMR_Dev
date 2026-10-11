-- ============================================================================
-- Migration: 2240_lab_misc_charges_billing_part4.sql   (run after part 3)
-- Description: Misc charges in the LAB registers' line detail (live definitions, only the 2240-marked changes):
--   * usp_Api_LabReport_DiscountRegister RS7 (test-wise): + the bills' misc charges and the discount they took.
--   * usp_Api_LabReport_CancellationRefund RS5 (test-wise): + cancelled misc charges (amount + GST).
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_DiscountRegister
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @BillingType   VARCHAR(3)    = NULL,   -- NULL / 'B2C' / 'B2B'
    @ApprovedBy    INT           = NULL,
    @EnteredBy     INT           = NULL,
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@BranchId, 0) <= 0
        THROW 50010, 'A branch is required for this report.', 1;
    IF ISNULL(@IsSuperAdmin, 0) = 0
    BEGIN
        IF ISNULL(@UserId, 0) <= 0
            THROW 50010, 'The signed-in user could not be identified.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.UserBranches ub
                        WHERE ub.UserId = @UserId AND ub.BranchID = @BranchId AND ISNULL(ub.IsActive, 1) = 1)
            THROW 50011, 'You do not have access to this branch''s discount register.', 1;
    END
    IF ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0
        SET @EnteredBy = @UserId;   -- a non-administrator sees only the discounts they entered

    IF @ToDate < @FromDate
    BEGIN
        DECLARE @Swap DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @Swap;
    END
    DECLARE @From DATETIME = CAST(@FromDate AS DATETIME);
    DECLARE @To   DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');

    SELECT
        lo.LabOrderId,
        lo.BillNo,
        lo.TokenNo,
        lo.OrderDate                                   AS BillDate,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        ISNULL(ph.SubTotal, lo.TotalAmount)            AS GrossAmount,
        ph.HeaderDiscountType                          AS DiscountType,
        ph.HeaderDiscountValue                         AS DiscountValue,
        CAST(CASE WHEN ISNULL(ph.HeaderDiscountAmount, 0) > 0 THEN ph.HeaderDiscountAmount ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        ISNULL(ph.NetAmount, 0)                        AS NetAmount,
        ISNULL(ph.TotalPaid, 0)                        AS PaidAmount,
        ISNULL(ph.BalanceDue, 0)                       AS BalanceDue,
        ISNULL(ph.PaymentStatus, 'U')                  AS PaymentStatus,
        CAST(lo.IsActive AS BIT)                       AS IsBillActive,
        NULLIF(LTRIM(RTRIM(ph.DiscountReason)), '')    AS DiscountReason,
        ph.DiscountApprovedBy                          AS ApprovedById,
        ISNULL(NULLIF(LTRIM(RTRIM(ua.FullName)), ''), ua.Username) AS ApprovedBy,
        ph.DiscountApprovedDate                        AS ApprovedDate,
        COALESCE(ph.DiscountEnteredBy, ph.CreatedBy)   AS EnteredById,
        ISNULL(NULLIF(LTRIM(RTRIM(ue.FullName)), ''), ISNULL(ue.Username, 'System')) AS EnteredBy
    INTO #D
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = ph.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.Users ua        ON ua.Id = ph.DiscountApprovedBy
    LEFT  JOIN dbo.Users ue        ON ue.Id = COALESCE(ph.DiscountEnteredBy, ph.CreatedBy)
    WHERE ph.ModuleCode = 'LAB'
      AND ph.IsActive = 1
      AND lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (ISNULL(ph.HeaderDiscountAmount, 0) > 0 OR ISNULL(ph.LineDiscountTotal, 0) > 0)
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@ApprovedBy IS NULL OR ph.DiscountApprovedBy = @ApprovedBy)
      AND (@EnteredBy IS NULL OR COALESCE(ph.DiscountEnteredBy, ph.CreatedBy) = @EnteredBy)
      AND (@Search IS NULL
           OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%'
           OR ph.DiscountReason LIKE '%' + @Search + '%');

    -- RS1: summary
    SELECT
        COUNT(1)                                    AS BillCount,
        ISNULL(SUM(DiscountAmount), 0)              AS TotalDiscount,
        ISNULL(SUM(GrossAmount), 0)                 AS GrossOfDiscountedBills,
        CAST(CASE WHEN SUM(GrossAmount) > 0 THEN SUM(DiscountAmount) * 100.0 / SUM(GrossAmount) ELSE 0 END AS DECIMAL(9, 2)) AS DiscountPercent,
        ISNULL(MAX(DiscountAmount), 0)              AS HighestDiscount,
        SUM(CASE WHEN DiscountReason IS NULL THEN 1 ELSE 0 END) AS WithoutReasonCount,
        ISNULL(SUM(CASE WHEN DiscountReason IS NULL THEN DiscountAmount END), 0) AS WithoutReasonAmount
    FROM #D;

    -- RS2: by approver
    SELECT ApprovedById, ISNULL(ApprovedBy, 'Not recorded') AS GroupName, COUNT(1) AS BillCount,
           SUM(DiscountAmount) AS DiscountAmount, SUM(GrossAmount) AS GrossAmount
    FROM #D GROUP BY ApprovedById, ApprovedBy ORDER BY SUM(DiscountAmount) DESC;

    -- RS3: by reason
    SELECT ISNULL(DiscountReason, 'Not recorded') AS GroupName, COUNT(1) AS BillCount,
           SUM(DiscountAmount) AS DiscountAmount, SUM(GrossAmount) AS GrossAmount
    FROM #D GROUP BY DiscountReason ORDER BY SUM(DiscountAmount) DESC;

    -- RS4: by entered-by user
    SELECT EnteredById, EnteredBy AS GroupName, COUNT(1) AS BillCount,
           SUM(DiscountAmount) AS DiscountAmount, SUM(GrossAmount) AS GrossAmount
    FROM #D GROUP BY EnteredById, EnteredBy ORDER BY SUM(DiscountAmount) DESC;

    -- RS5: by bill date
    SELECT CONVERT(VARCHAR(10), CAST(BillDate AS DATE), 23) AS GroupName, COUNT(1) AS BillCount,
           SUM(DiscountAmount) AS DiscountAmount, SUM(GrossAmount) AS GrossAmount
    FROM #D GROUP BY CAST(BillDate AS DATE) ORDER BY CAST(BillDate AS DATE);

    -- RS6: discounted bills
    SELECT *,
           CAST(CASE WHEN GrossAmount > 0 THEN DiscountAmount * 100.0 / GrossAmount ELSE 0 END AS DECIMAL(9, 2)) AS DiscountPercent
    FROM #D ORDER BY BillDate DESC, LabOrderId DESC;

    -- RS7: test-wise discount of those bills (2223): each billed test with its head - its department, or Packages -
    -- and the discount stored on its line (a department-wise % / ₹, or its share of an overall bill discount)
    SELECT d.LabOrderId,
           loi.LabOrderItemId,
           CASE WHEN loi.Type = 'P' THEN ISNULL(pkg.Profile_Name, '(Package)') ELSE ISNULL(lim.Test_Name, '(Test)') END AS ItemName,
           CASE WHEN loi.Type = 'P' THEN 'Package' WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           CASE WHEN loi.Type = 'P' THEN 'Packages' ELSE ISNULL(dm.DeptName, 'Other') END AS HeadName,
           CAST(ISNULL(loi.Price, 0) AS DECIMAL(18, 2)) AS Mrp,
           li.LineDiscountType,
           li.LineDiscountValue,
           CAST(ISNULL(li.LineDiscountAmount, 0) AS DECIMAL(18, 2)) AS DiscountAmount,
           CAST(ISNULL(li.NetLineAmount, ISNULL(loi.Price, 0) - ISNULL(li.LineDiscountAmount, 0)) AS DECIMAL(18, 2)) AS NetAmount,
           CAST(ISNULL(loi.IsActive, 1) AS BIT) AS IsActive,
           0 AS LineSort, loi.LabOrderItemId AS LineSortId
    FROM #D d
    INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderId = d.LabOrderId
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    OUTER APPLY (
        SELECT TOP 1 pli.LineDiscountType, pli.LineDiscountValue, pli.LineDiscountAmount, pli.NetLineAmount
        FROM dbo.PaymentHeader ph
        INNER JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId AND pli.IsActive = 1
        WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = d.LabOrderId AND ph.IsActive = 1
          AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
        ORDER BY CASE WHEN pli.ModuleLineRefId = loi.LabOrderItemId THEN 0 ELSE 1 END, pli.PaymentLineItemId) li
    -- 2240: misc charges of those bills (LabOrderItemId = - misc line id), with the discount they took
    UNION ALL
    SELECT d.LabOrderId, -m.LabOrderMiscChargeId,
           m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END,
           'Misc Charge', 'Misc Charges',
           CAST(m.Amount AS DECIMAL(18, 2)),
           CASE WHEN m.DiscountAmount > 0 THEN 'F' END, CAST(m.DiscountAmount AS DECIMAL(18, 2)),
           CAST(m.DiscountAmount AS DECIMAL(18, 2)), CAST(m.Amount - m.DiscountAmount AS DECIMAL(18, 2)),
           m.IsActive, 1, m.LabOrderMiscChargeId
    FROM #D d
    INNER JOIN dbo.LabOrderMiscCharge m ON m.LabOrderId = d.LabOrderId
    ORDER BY LabOrderId, LineSort, LineSortId;

    DROP TABLE #D;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CancellationRefund
    @BranchId         INT,
    @FromDate         DATE,
    @ToDate           DATE,
    @CancellationType CHAR(1)       = NULL,   -- F / P
    @RefundStatus     VARCHAR(10)   = NULL,   -- REFUNDED / PENDING / NOTDUE
    @CancelledBy      INT           = NULL,
    @Search           NVARCHAR(100) = NULL,
    @UserId           INT           = NULL,
    @IsAdmin          BIT           = 0,
    @IsSuperAdmin     BIT           = 0,
    @BillingType      VARCHAR(5)    = NULL    -- B2C / B2B (2235); NULL = both
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @OwnOnly BIT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN 1 ELSE 0 END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @RefundStatus = NULLIF(UPPER(LTRIM(RTRIM(@RefundStatus))), '');
    SET @CancellationType = NULLIF(UPPER(LTRIM(RTRIM(@CancellationType))), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');

    -- every active LAB cancellation of the branch's bills, with its net amount and what was refunded against it
    ;WITH c AS (
        SELECT bc.CancellationId, bc.ModuleRefId AS LabOrderId, bc.CancellationDate,
               CAST(bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS NetCancelled,
               CAST(ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.CancellationId = bc.CancellationId AND r.IsActive = 1), 0) AS DECIMAL(18, 2)) AS Refunded
        FROM dbo.BillCancellation bc
        INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = bc.ModuleRefId
        WHERE bc.ModuleCode = 'LAB' AND bc.IsActive = 1 AND lo.BranchId = @BranchId),
    -- what each bill still has to give back: received (receipts - refunds) over the bill as it stands now
    b AS (
        SELECT x.LabOrderId,
               CASE WHEN x.Received - x.BillNow > 0 THEN x.Received - x.BillNow ELSE 0 END AS Refundable
        FROM (SELECT lo.LabOrderId,
                     ISNULL(ph.NetAmount, 0) AS BillNow,
                     ISNULL((SELECT SUM(d.PaidAmount) FROM dbo.PaymentDetail d WHERE d.PaymentHeaderId = ph.PaymentHeaderId AND d.IsActive = 1), 0)
                   - ISNULL((SELECT SUM(r.RefundAmount) FROM dbo.BillRefund r WHERE r.ModuleCode = 'LAB' AND r.ModuleRefId = lo.LabOrderId AND r.IsActive = 1), 0) AS Received
              FROM dbo.LabOrder lo
              INNER JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
              WHERE lo.LabOrderId IN (SELECT LabOrderId FROM c)) x),
    -- shared out over the bill's cancellations, oldest first, each up to what it can still take back
    a AS (
        SELECT c.CancellationId,
               CASE WHEN c.NetCancelled - c.Refunded > 0 THEN c.NetCancelled - c.Refunded ELSE 0 END AS Capacity,
               ISNULL(b.Refundable, 0) AS BillRefundable,
               SUM(CASE WHEN c.NetCancelled - c.Refunded > 0 THEN c.NetCancelled - c.Refunded ELSE 0 END)
                   OVER (PARTITION BY c.LabOrderId ORDER BY c.CancellationDate, c.CancellationId ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS Before
        FROM c LEFT JOIN b ON b.LabOrderId = c.LabOrderId)
    SELECT
        bc.CancellationId, bc.CancellationNo, bc.CancellationDate,
        CONVERT(VARCHAR(10), CAST(bc.CancellationDate AS DATE), 23) AS CancellationDay,
        CASE bc.CancellationType WHEN 'F' THEN 'Full' ELSE 'Partial' END AS CancellationType,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        -- partner of a B2B bill only (a B2C bill can carry an agent type from its booking screen)
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN 'Franchise' WHEN lo.AgentType = 'C' THEN 'Company' END END AS PartnerType,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END END AS PartnerName,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Code WHEN lo.AgentType = 'C' THEN corp.Corporate_Code END END AS PartnerCode,
        lo.LabOrderId, lo.BillNo, lo.OrderDate AS BillDate,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        itm.ItemCount, itm.ItemNames, CAST(ISNULL(itm.MrpTotal, 0) AS DECIMAL(18, 2)) AS MrpTotal,
        CAST(bc.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS DiscountAdjusted,
        CAST(bc.CancelledAmount - ISNULL(bc.DiscountAdjusted, 0) AS DECIMAL(18, 2)) AS NetCancelled,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidOnBill,
        CAST(ISNULL(ph.NetAmount, 0) AS DECIMAL(18, 2)) AS BillNow,
        CAST(ISNULL(rf.RefundedAmount, 0) AS DECIMAL(18, 2)) AS RefundedAmount,
        rf.RefundModes, rf.LastRefundDate, rf.RefundedBy,
        CAST(CASE WHEN ISNULL(a.BillRefundable, 0) - ISNULL(a.Before, 0) <= 0 THEN 0
                  WHEN ISNULL(a.BillRefundable, 0) - ISNULL(a.Before, 0) < ISNULL(a.Capacity, 0) THEN ISNULL(a.BillRefundable, 0) - ISNULL(a.Before, 0)
                  ELSE ISNULL(a.Capacity, 0) END AS DECIMAL(18, 2)) AS PendingRefund,
        NULLIF(LTRIM(RTRIM(bc.Reason)), '') AS Reason,
        bc.CreatedBy AS CancelledById,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CancelledBy,
        rf.RefundUserIds
    INTO #R
    FROM dbo.BillCancellation bc
    INNER JOIN dbo.LabOrder lo     ON lo.LabOrderId = bc.ModuleRefId
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN a ON a.CancellationId = bc.CancellationId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    LEFT  JOIN dbo.Users u ON u.Id = bc.CreatedBy
    OUTER APPLY (SELECT COUNT(1) AS ItemCount, SUM(ISNULL(loi.Price, 0)) AS MrpTotal,
                        STRING_AGG(CAST(ISNULL(pkg.Profile_Name, lim.Test_Name) AS NVARCHAR(MAX)), ', ') AS ItemNames
                   FROM dbo.BillCancellationItem bci
                   INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = bci.LineRefId
                   LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
                   LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
                  WHERE bci.CancellationId = bc.CancellationId AND bci.IsActive = 1) itm
    OUTER APPLY (SELECT SUM(r.RefundAmount) AS RefundedAmount,
                        STRING_AGG(CAST(r.RefundMode AS NVARCHAR(MAX)), ', ') AS RefundModes,
                        MAX(r.RefundDate) AS LastRefundDate,
                        STRING_AGG(CAST(ISNULL(NULLIF(LTRIM(RTRIM(ru.FullName)), ''), ru.Username) AS NVARCHAR(MAX)), ', ') AS RefundedBy,
                        ',' + STRING_AGG(CAST(r.CreatedBy AS VARCHAR(MAX)), ',') + ',' AS RefundUserIds
                   FROM dbo.BillRefund r
                   LEFT JOIN dbo.Users ru ON ru.Id = r.CreatedBy
                  WHERE r.CancellationId = bc.CancellationId AND r.IsActive = 1) rf
    WHERE bc.ModuleCode = 'LAB'
      AND bc.IsActive = 1
      AND lo.BranchId = @BranchId
      AND bc.CancellationDate >= @From AND bc.CancellationDate < @To
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CancellationType IS NULL OR bc.CancellationType = @CancellationType)
      AND (@CancelledBy IS NULL OR bc.CreatedBy = @CancelledBy)
      AND (@Search IS NULL OR bc.CancellationNo LIKE '%' + @Search + '%' OR lo.BillNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%' OR bc.Reason LIKE '%' + @Search + '%'
           OR f.Franchise_Name LIKE '%' + @Search + '%' OR corp.Corporate_Name LIKE '%' + @Search + '%');

    -- own data: cancellations they made, or refunds they processed
    IF @OwnOnly = 1
        DELETE FROM #R WHERE ISNULL(CancelledById, 0) <> @UserId
                         AND ISNULL(RefundUserIds, '') NOT LIKE '%,' + CAST(@UserId AS VARCHAR(20)) + ',%';
    IF @RefundStatus = 'REFUNDED' DELETE FROM #R WHERE NOT (RefundedAmount > 0 AND PendingRefund = 0);
    IF @RefundStatus = 'PENDING'  DELETE FROM #R WHERE PendingRefund <= 0;
    IF @RefundStatus = 'NOTDUE'   DELETE FROM #R WHERE NOT (RefundedAmount = 0 AND PendingRefund = 0);

    -- RS1 summary
    SELECT COUNT(1) AS CancellationCount,
           SUM(CASE WHEN CancellationType = 'Full' THEN 1 ELSE 0 END) AS FullCount,
           SUM(CASE WHEN CancellationType = 'Partial' THEN 1 ELSE 0 END) AS PartialCount,
           COUNT(DISTINCT LabOrderId) AS BillCount,
           ISNULL(SUM(ItemCount), 0) AS ItemCount,
           ISNULL(SUM(MrpTotal), 0) AS MrpTotal,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(NetCancelled), 0) AS NetCancelled,
           ISNULL(SUM(RefundedAmount), 0) AS RefundedAmount, ISNULL(SUM(PendingRefund), 0) AS PendingRefund,
           SUM(CASE WHEN PendingRefund > 0 THEN 1 ELSE 0 END) AS PendingRefundCount
    FROM #R;

    -- RS2 groups
    SELECT 'byReason' AS GroupKey, NULL AS GroupId, ISNULL(Reason, 'Not recorded') AS GroupName, 0 AS SortOrder,
           COUNT(1) AS CancellationCount, SUM(ItemCount) AS ItemCount, SUM(NetCancelled) AS NetCancelled,
           SUM(RefundedAmount) AS RefundedAmount, SUM(PendingRefund) AS PendingRefund
    FROM #R GROUP BY Reason
    UNION ALL
    SELECT 'byCancelledBy', CancelledById, CancelledBy, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancelledById, CancelledBy
    UNION ALL
    SELECT 'byType', NULL, CancellationType, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationType
    UNION ALL
    SELECT 'byDate', NULL, CancellationDay, 0, COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY CancellationDay
    UNION ALL
    SELECT 'byPartner', NULL, ISNULL(PartnerName + ISNULL(' (' + PartnerCode + ')', ''), 'Walk-in (B2C)'), 0,
           COUNT(1), SUM(ItemCount), SUM(NetCancelled), SUM(RefundedAmount), SUM(PendingRefund)
    FROM #R GROUP BY PartnerName, PartnerCode
    ORDER BY GroupKey, SortOrder, GroupName;

    -- RS3 rows
    SELECT CancellationId, CancellationNo, CancellationDate, CancellationDay, CancellationType, BillingType, PartnerType, PartnerName, PartnerCode,
           ISNULL(PartnerName + ISNULL(' (' + PartnerCode + ')', ''), 'Walk-in (B2C)') AS PartnerLabel,
           LabOrderId, BillNo, BillDate, PatientCode, PatientName, PhoneNumber, ItemCount, ItemNames, MrpTotal, CancelledAmount, DiscountAdjusted,
           NetCancelled, PaidOnBill, BillNow, RefundedAmount, RefundModes, LastRefundDate, RefundedBy, PendingRefund,
           ISNULL(Reason, 'Not recorded') AS Reason, CancelledById, CancelledBy
    FROM #R ORDER BY CancellationDate DESC, CancellationId DESC;

    -- RS4 filter options
    SELECT DISTINCT 'cancelledBy' AS FilterKey, CAST(CancelledById AS VARCHAR(20)) AS Value, CancelledBy AS Text FROM #R WHERE CancelledById IS NOT NULL;

    -- RS5 test-wise: every test of the listed cancellations
    SELECT bci.CancellationId, bci.LineRefId AS LabOrderItemId,
           ISNULL(pkg.Profile_Name, lim.Test_Name) AS TestName,
           ISNULL(pkg.Profile_Code, lim.Test_Code) AS TestCode,
           CASE WHEN loi.Type = 'P' THEN 'Package' WHEN lim.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           CASE WHEN loi.Type = 'P' THEN 'Packages' ELSE dm.DeptName END AS Department,
           CAST(ISNULL(loi.Price, 0) AS DECIMAL(18, 2)) AS Mrp,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, loi.Price) END AS DECIMAL(18, 2)) AS ContractRate,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(pli.LineDiscountAmount, 0) END AS DECIMAL(18, 2)) AS LineDiscount,
           CAST(bci.CancelledAmount AS DECIMAL(18, 2)) AS CancelledAmount,
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN bci.CancelledAmount
                     ELSE bci.CancelledAmount - ISNULL(pli.LineDiscountAmount, 0) END AS DECIMAL(18, 2)) AS NetAmount,
           bci.LineRefId AS LineSortId
    FROM dbo.BillCancellationItem bci
    INNER JOIN #R r ON r.CancellationId = bci.CancellationId
    INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = bci.LineRefId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId AND pli.IsActive = 1
                                     AND (pli.ModuleLineRefId = loi.LabOrderItemId)
    WHERE bci.IsActive = 1
    -- 2240: cancelled misc charges (LineRefId = - misc line id), at what they were billed (amount + GST)
    UNION ALL
    SELECT bci.CancellationId, bci.LineRefId,
           m.ChargeName + CASE WHEN m.Quantity > 1 THEN ' x ' + CAST(m.Quantity AS NVARCHAR(5)) ELSE '' END
               + CASE WHEN m.IsGstRequired = 1 THEN ' (incl. GST ' + FORMAT(m.GstPercentage, '0.##') + '%)' ELSE '' END,
           CASE WHEN m.ChargeType = 'Home Collection' THEN 'HOME-COLL' ELSE 'MISC' END,
           'Misc Charge', 'Misc Charges',
           CAST(m.Amount + m.GstAmount AS DECIMAL(18, 2)),
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN m.Amount + m.GstAmount END AS DECIMAL(18, 2)),
           CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.DiscountAmount END AS DECIMAL(18, 2)),
           CAST(bci.CancelledAmount AS DECIMAL(18, 2)),
           CAST(bci.CancelledAmount - CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE m.DiscountAmount END AS DECIMAL(18, 2)),
           1000000 + m.LabOrderMiscChargeId
    FROM dbo.BillCancellationItem bci
    INNER JOIN #R r ON r.CancellationId = bci.CancellationId
    INNER JOIN dbo.LabOrderMiscCharge m ON m.LabOrderMiscChargeId = -bci.LineRefId
    INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = m.LabOrderId
    WHERE bci.IsActive = 1 AND bci.LineRefId < 0
    ORDER BY CancellationId, LineSortId;

    DROP TABLE #R;
END;
GO

PRINT 'Script 2240 part 4 applied: misc charges in the Discount and Cancellation & Refund registers.';
GO
