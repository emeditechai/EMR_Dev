-- ============================================================================================================
-- Migration: 2379_lab_report_referral_doctor_billing.sql
-- Reports > LAB > Referral Doctor Billing: B2C and B2B LAB bills by referral doctor, each bill with its test lines.
--   usp_Api_LabReport_RefDoctorBilling (shape of SQLScripts/2124: summary, groups, rows, options, lines)
--     Bill: referral doctor, bill no, token, patient, gender / age, bill amount, discount, cancelled, refund, net, paid, due
--     Lines: every test / profile / package (cancelled ones marked) and misc charge, with rate, discount and net
--     Filters: date range, referral doctors (multi, @DoctorIds = 'D12,R3,SELF'), billing type, payment status, search
--   The doctor is the Doctor Master doctor of the bill (LabOrder.RefDoctorId, key D<id>), else the old referral
--   doctor list (LabOrder.ReferralDoctorId, key R<id>), else Self / Direct (SELF).
--   Visibility as the Daily Billing Register: an administrator sees the branch, others their own bills.
--   Page REPORTS.LABREFDOCTORBILLING under Reports > LAB (VIEW). No role is granted here.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_RefDoctorBilling
    @BranchId      INT,
    @FromDate      DATE,
    @ToDate        DATE,
    @DoctorIds     VARCHAR(1000) = NULL,   -- D<DoctorId> / R<ReferralDoctorId> / SELF, comma separated; NULL = all
    @BillingType   VARCHAR(3)    = NULL,   -- B2C / B2B
    @PaymentStatus VARCHAR(10)   = NULL,   -- PAID / PARTIAL / UNPAID / CANCELLED
    @Search        NVARCHAR(100) = NULL,
    @UserId        INT           = NULL,
    @IsAdmin       BIT           = 0,
    @IsSuperAdmin  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CreatedBy INT = CASE WHEN ISNULL(@IsAdmin, 0) = 0 AND ISNULL(@IsSuperAdmin, 0) = 0 THEN @UserId END;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @BillingType = NULLIF(UPPER(LTRIM(RTRIM(@BillingType))), '');
    SET @PaymentStatus = NULLIF(UPPER(LTRIM(RTRIM(@PaymentStatus))), '');

    DECLARE @Docs TABLE (DoctorKey VARCHAR(20) PRIMARY KEY);
    INSERT INTO @Docs (DoctorKey)
    SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) FROM STRING_SPLIT(ISNULL(@DoctorIds, ''), ',') WHERE LTRIM(RTRIM(value)) <> '';
    DECLARE @AnyDoc BIT = CASE WHEN EXISTS (SELECT 1 FROM @Docs) THEN 0 ELSE 1 END;

    SELECT
        lo.LabOrderId, lo.BillNo, lo.TokenNo, lo.OrderDate AS BillDate,
        CONVERT(VARCHAR(10), CAST(lo.OrderDate AS DATE), 23) AS BillDay,
        CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 'B2B' ELSE 'B2C' END AS BillingType,
        CASE WHEN lo.AgentType = 'F' THEN f.Franchise_Name WHEN lo.AgentType = 'C' THEN corp.Corporate_Name END AS PartnerName,
        dk.DoctorKey,
        ISNULL(dk.DoctorName, 'Self / Direct') AS RefDoctorName,
        p.PatientCode,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        NULLIF(LTRIM(RTRIM(p.Gender)), '') AS Gender,
        CASE WHEN p.DateOfBirth IS NULL THEN NULL
             WHEN ag.Y > 0 THEN CAST(ag.Y AS VARCHAR(5)) + 'Y'
             WHEN DATEDIFF(DAY, p.DateOfBirth, lo.OrderDate) >= 31 THEN CAST(DATEDIFF(MONTH, p.DateOfBirth, lo.OrderDate) - CASE WHEN DAY(p.DateOfBirth) > DAY(lo.OrderDate) THEN 1 ELSE 0 END AS VARCHAR(5)) + 'M'
             ELSE CAST(DATEDIFF(DAY, p.DateOfBirth, lo.OrderDate) AS VARCHAR(5)) + 'D' END AS PatientAge,
        ISNULL(items.TestCount, 0) AS TestCount,
        -- bill amount as billed: B2C at its price + misc charges with GST; B2B at the partner total (misc already in it)
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(lo.B2BTotal, lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0))
                  ELSE lo.TotalAmount + ISNULL(lo.MiscAmount, 0) + ISNULL(lo.MiscGstAmount, 0) END AS DECIMAL(18, 2)) AS BillAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0
                  WHEN ISNULL(ph.HeaderDiscountAmount, 0) > ISNULL(ph.LineDiscountTotal, 0) THEN ph.HeaderDiscountAmount
                  ELSE ISNULL(ph.LineDiscountTotal, 0) END AS DECIMAL(18, 2)) AS DiscountAmount,
        CAST(ISNULL(canc.CancelledAmount, 0) AS DECIMAL(18, 2)) AS CancelledAmount,
        CAST(ISNULL(rf.RefundAmount, 0) AS DECIMAL(18, 2)) AS RefundAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN CASE WHEN lo.IsActive = 0 THEN 0 ELSE ISNULL(lo.B2BTotal, lo.TotalAmount) END
                  ELSE ISNULL(ph.NetAmount, lo.TotalAmount) END AS DECIMAL(18, 2)) AS NetAmount,
        CAST(CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN 0 ELSE ISNULL(ph.RoundOffAmount, 0) END AS DECIMAL(18, 2)) AS RoundOffAmount,
        CAST(ISNULL(ph.TotalPaid, 0) AS DECIMAL(18, 2)) AS PaidAmount,
        CAST(0 AS DECIMAL(18, 2)) AS DueAmount,
        CASE WHEN lo.IsActive = 0 THEN 'CANCELLED'
             WHEN ISNULL(lo.IsB2B, 0) = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(lo.B2BTotal, lo.TotalAmount) THEN 'PAID'
             WHEN ISNULL(lo.IsB2B, 0) = 0 AND ph.PaymentStatus = 'P' THEN 'PAID'
             WHEN ISNULL(ph.TotalPaid, 0) > 0 THEN 'PARTIAL'
             ELSE 'UNPAID' END AS PaymentStatus,
        CAST(CASE WHEN lo.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled,
        CAST(CASE WHEN canc.CancelledAmount > 0 AND lo.IsActive = 1 THEN 1 ELSE 0 END AS BIT) AS IsPartlyCancelled,
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, 'System')) AS CreatedBy
    INTO #R
    FROM dbo.LabOrder lo
    INNER JOIN dbo.PatientMaster p ON p.PatientId = lo.PatientId
    LEFT  JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = lo.LabOrderId AND ph.IsActive = 1
    LEFT  JOIN dbo.Users u ON u.Id = lo.CreatedBy
    LEFT  JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    LEFT  JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = lo.RefDoctorId
    LEFT  JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = lo.B2BAgentID AND lo.AgentType = 'F'
    LEFT  JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = lo.B2BAgentID AND lo.AgentType = 'C'
    CROSS APPLY (SELECT
        CASE WHEN rdoc.DoctorId IS NOT NULL THEN 'D' + CAST(rdoc.DoctorId AS VARCHAR(10))
             WHEN rd.ReferralDoctorId IS NOT NULL THEN 'R' + CAST(rd.ReferralDoctorId AS VARCHAR(10)) ELSE 'SELF' END AS DoctorKey,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''),
                 NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS DoctorName) dk
    CROSS APPLY (SELECT DATEDIFF(YEAR, p.DateOfBirth, lo.OrderDate)
                        - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, lo.OrderDate), p.DateOfBirth) > lo.OrderDate THEN 1 ELSE 0 END AS Y) ag
    OUTER APPLY (SELECT COUNT(1) AS TestCount FROM dbo.LabOrderItem loi
                  WHERE loi.LabOrderId = lo.LabOrderId AND (loi.IsActive = 1 OR lo.IsActive = 0)) items
    -- cancelled tests net of the discount taken back, so Bill - Discount - Cancelled (+ round off) = Net
    OUTER APPLY (SELECT SUM(ISNULL(bc.CancelledAmount, 0) - ISNULL(bc.DiscountAdjusted, 0)) AS CancelledAmount FROM dbo.BillCancellation bc
                  WHERE bc.ModuleCode = 'LAB' AND bc.ModuleRefId = lo.LabOrderId AND bc.IsActive = 1) canc
    OUTER APPLY (SELECT SUM(r.RefundAmount) AS RefundAmount FROM dbo.BillRefund r
                  WHERE r.ModuleCode = 'LAB' AND r.ModuleRefId = lo.LabOrderId AND r.IsActive = 1 AND ISNULL(r.Status, 'P') = 'P') rf
    WHERE lo.BranchId = @BranchId
      AND lo.OrderDate >= @From AND lo.OrderDate < @To
      AND (@AnyDoc = 1 OR dk.DoctorKey IN (SELECT DoctorKey FROM @Docs))
      AND (@BillingType IS NULL OR (@BillingType = 'B2B' AND ISNULL(lo.IsB2B, 0) = 1) OR (@BillingType = 'B2C' AND ISNULL(lo.IsB2B, 0) = 0))
      AND (@CreatedBy IS NULL OR lo.CreatedBy = @CreatedBy)
      AND (@Search IS NULL OR lo.BillNo LIKE '%' + @Search + '%' OR lo.TokenNo LIKE '%' + @Search + '%'
           OR p.PatientCode LIKE '%' + @Search + '%' OR p.PhoneNumber LIKE '%' + @Search + '%'
           OR p.FirstName LIKE '%' + @Search + '%' OR p.LastName LIKE '%' + @Search + '%');

    IF @PaymentStatus IS NOT NULL DELETE FROM #R WHERE PaymentStatus <> @PaymentStatus;
    UPDATE #R SET DueAmount = CASE WHEN IsCancelled = 0 AND NetAmount - PaidAmount > 0 THEN NetAmount - PaidAmount ELSE 0 END;

    -- RS1 summary
    SELECT COUNT(1) AS BillCount, COUNT(DISTINCT DoctorKey) AS DoctorCount, COUNT(DISTINCT PatientCode) AS PatientCount,
           SUM(CASE WHEN BillingType = 'B2C' THEN 1 ELSE 0 END) AS B2CBills, SUM(CASE WHEN BillingType = 'B2B' THEN 1 ELSE 0 END) AS B2BBills,
           ISNULL(SUM(TestCount), 0) AS TestCount,
           ISNULL(SUM(BillAmount), 0) AS BillAmount, ISNULL(SUM(DiscountAmount), 0) AS DiscountAmount,
           ISNULL(SUM(CancelledAmount), 0) AS CancelledAmount, ISNULL(SUM(RefundAmount), 0) AS RefundAmount,
           ISNULL(SUM(NetAmount), 0) AS NetAmount, ISNULL(SUM(PaidAmount), 0) AS PaidAmount, ISNULL(SUM(DueAmount), 0) AS DueAmount,
           SUM(CASE WHEN DoctorKey = 'SELF' THEN 1 ELSE 0 END) AS SelfBills
    FROM #R;

    -- RS2 groups
    SELECT 'byDoctor' AS GroupKey, NULL AS GroupId, RefDoctorName AS GroupName, CASE WHEN DoctorKey = 'SELF' THEN 1 ELSE 0 END AS SortOrder,
           COUNT(1) AS BillCount, SUM(TestCount) AS TestCount, SUM(BillAmount) AS BillAmount, SUM(DiscountAmount) AS DiscountAmount,
           SUM(CancelledAmount) AS CancelledAmount, SUM(RefundAmount) AS RefundAmount, SUM(NetAmount) AS NetAmount, SUM(PaidAmount) AS PaidAmount, SUM(DueAmount) AS DueAmount
    FROM #R GROUP BY DoctorKey, RefDoctorName
    UNION ALL
    SELECT 'byBillingType', NULL, BillingType, 0, COUNT(1), SUM(TestCount), SUM(BillAmount), SUM(DiscountAmount), SUM(CancelledAmount), SUM(RefundAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillingType
    UNION ALL
    SELECT 'byDate', NULL, BillDay, 0, COUNT(1), SUM(TestCount), SUM(BillAmount), SUM(DiscountAmount), SUM(CancelledAmount), SUM(RefundAmount), SUM(NetAmount), SUM(PaidAmount), SUM(DueAmount)
    FROM #R GROUP BY BillDay
    ORDER BY GroupKey, SortOrder, BillAmount DESC;

    -- RS3 rows (doctor, then bill date)
    SELECT * FROM #R ORDER BY CASE WHEN DoctorKey = 'SELF' THEN 1 ELSE 0 END, RefDoctorName, BillDate, LabOrderId;

    -- RS4 options: referral doctors of the branch's LAB bills (any date), and Self / Direct
    SELECT DISTINCT 'doctor' AS FilterKey, 'D' + CAST(d.DoctorId AS VARCHAR(10)) AS Value,
           LTRIM(RTRIM(ISNULL(d.NamePrefix + ' ', '') + d.FullName)) AS Text
    FROM dbo.LabOrder lo JOIN dbo.DoctorMaster d ON d.DoctorId = lo.RefDoctorId
    WHERE lo.BranchId = @BranchId
    UNION
    SELECT DISTINCT 'doctor', 'R' + CAST(rd.ReferralDoctorId AS VARCHAR(10)), LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, '')))
    FROM dbo.LabOrder lo JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = lo.ReferralDoctorId
    WHERE lo.BranchId = @BranchId AND lo.RefDoctorId IS NULL
    UNION
    SELECT 'doctor', 'SELF', 'Self / Direct'
    ORDER BY 3;

    -- RS5 lines: every test / profile / package of the bills (cancelled ones marked) and misc charges
    SELECT x.LabOrderId, ROW_NUMBER() OVER (PARTITION BY x.LabOrderId ORDER BY x.Kind, x.ItemId) AS LineSeq,
           x.TestCode, x.TestName, x.ItemType, x.Department, x.Rate, x.Discount, x.NetAmount, x.IsCancelled
      FROM (
    SELECT loi.LabOrderId, 0 AS Kind, loi.LabOrderItemId AS ItemId,
           CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
           ISNULL(CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END, 'Unknown test') AS TestName,
           CASE WHEN loi.Type = 'P' THEN 'Package' WHEN ISNULL(lim.Is_Profile_Test, 0) = 1 THEN 'Profile' ELSE 'Test' END AS ItemType,
           dm.DeptName AS Department,
           CAST(CASE WHEN r.BillingType = 'B2B' THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END AS DECIMAL(18, 2)) AS Rate,
           CAST(CASE WHEN r.BillingType = 'B2B' THEN 0 ELSE ISNULL(pli.LineDiscountAmount, 0) END AS DECIMAL(18, 2)) AS Discount,
           CAST(CASE WHEN r.BillingType = 'B2B' THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0))
                     ELSE ISNULL(pli.NetLineAmount, ISNULL(loi.Price, 0) - ISNULL(pli.LineDiscountAmount, 0)) END AS DECIMAL(18, 2)) AS NetAmount,
           CAST(CASE WHEN loi.IsActive = 0 THEN 1 ELSE 0 END AS BIT) AS IsCancelled
      FROM #R r
      JOIN dbo.LabOrderItem loi ON loi.LabOrderId = r.LabOrderId
      LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
      LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
      LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
      OUTER APPLY (SELECT TOP 1 x.LineDiscountAmount, x.NetLineAmount FROM dbo.PaymentLineItem x
                    JOIN dbo.PaymentHeader h ON h.PaymentHeaderId = x.PaymentHeaderId AND h.ModuleCode = 'LAB' AND h.ModuleRefId = r.LabOrderId AND h.IsActive = 1
                   WHERE x.ModuleLineRefId = loi.LabOrderItemId AND ISNULL(x.LabOrderMiscChargeId, 0) = 0
                   ORDER BY x.IsActive DESC) pli
    UNION ALL
    SELECT mc.LabOrderId, 1, mc.LabOrderMiscChargeId, 'MISC', mc.ChargeName, 'Misc', ISNULL(mc.ChargeType, 'Misc Charge'),
           CAST(ISNULL(mc.Amount, 0) + ISNULL(mc.GstAmount, 0) AS DECIMAL(18, 2)), CAST(ISNULL(mc.DiscountAmount, 0) AS DECIMAL(18, 2)),
           CAST(ISNULL(mc.NetAmount, mc.Amount) AS DECIMAL(18, 2)), CAST(CASE WHEN mc.IsActive = 0 THEN 1 ELSE 0 END AS BIT)
      FROM #R r
      JOIN dbo.LabOrderMiscCharge mc ON mc.LabOrderId = r.LabOrderId
      ) x
     ORDER BY x.LabOrderId, LineSeq;

    DROP TABLE #R;
END;
GO

-- ── menu page and endpoints: Reports > LAB > Referral Doctor Billing ──
DECLARE @co INT, @menu INT, @page INT, @view INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'REPORTS.LABREFDOCTORBILLING',
             @Title = N'Referral Doctor Billing', @Controller = N'Reports', @Action = N'LabRefDoctorBilling',
             @Show_In_Menu = 1, @Sort_Order = 15, @Icon = N'bi bi-person-badge me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL;
        SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'LabRefDoctorBilling', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'Reports', @Action = N'GetLabReportData', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'LabOrderBooking', @Action = N'PrintBill', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2379 applied: Referral Doctor Billing (Reports > LAB).';
GO
