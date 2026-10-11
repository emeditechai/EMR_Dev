-- ============================================================================
-- Migration: 2223_lab_discount_register_test_wise.sql
-- Description: Reports > LAB > Discount Register, Detail tab: bill-wise, test-wise discount. The register procedure
--   returns one more result set (RS7): every test of the discounted bills with its head (department or Packages),
--   MRP, the line's discount (department-wise % / ₹, or its share of an overall discount) and net. The first six
--   result sets are unchanged. Safe to re-run.
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
           CAST(ISNULL(loi.IsActive, 1) AS BIT) AS IsActive
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
    ORDER BY d.LabOrderId, loi.LabOrderItemId;

    DROP TABLE #D;
END;
GO

PRINT 'Script 2223: Discount Register returns test-wise discount (RS7).';
GO
