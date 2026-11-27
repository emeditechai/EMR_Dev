-- ============================================================================================================
-- 2567  Ask eMedi data answers: IPD, pharmacy and collection by payment mode (application database)
--   usp_HelpData_Ipd         "how many patients are admitted", "bed occupancy", "admissions / discharges today",
--                            "patients in ICU", "pending discharges", "list admitted patients" - live census, beds and money
--   usp_HelpData_Pharmacy    @Kind SALES (sales of a period), STOCK (stock of a medicine), EXPIRY (near-expiry batches),
--                            LOW (items at or below the reorder level)
--   usp_HelpData_Collection  money received in a period by module and payment mode (cash, UPI, card ...), refunds out
--   Read only. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── IPD census ──
CREATE OR ALTER PROCEDURE dbo.usp_HelpData_Ipd @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start DATETIME = CAST(@From AS DATETIME), @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @now DATETIME = GETDATE();
    DECLARE @adm TABLE (AdmissionId INT PRIMARY KEY, Status VARCHAR(20), BedId INT);
    INSERT @adm SELECT a.AdmissionId, a.Status, a.CurrentBedId FROM dbo.IpdAdmission a
    WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId) AND a.IsOpen = 1 AND a.Status IN ('ADMITTED', 'DISCHARGE_ADVISED', 'BILL_FINAL');

    -- 0 facts
    SELECT (SELECT COUNT(*) FROM @adm) AS InHospital,
           (SELECT COUNT(*) FROM @adm WHERE Status = 'DISCHARGE_ADVISED') AS DischargeAdvised,
           (SELECT COUNT(*) FROM @adm WHERE Status = 'BILL_FINAL') AS BillFinal,
           (SELECT COUNT(*) FROM @adm x JOIN dbo.BedMaster b ON b.BedId = x.BedId WHERE ISNULL(b.IsICU, 0) = 1) AS InIcu,
           (SELECT COUNT(*) FROM dbo.IpdAdmission a WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId)
                AND a.Status <> 'CANCELLED' AND a.AdmissionAt >= @start AND a.AdmissionAt < @end) AS Admitted,
           (SELECT COUNT(*) FROM dbo.IpdAdmission a WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId)
                AND a.Status = 'DISCHARGED' AND a.DischargeAt >= @start AND a.DischargeAt < @end) AS Discharged,
           b.Beds, b.Occupied, b.Available, b.Reserved, b.Cleaning, b.Blocked,
           (SELECT ISNULL(SUM(v.Amount), 0) FROM dbo.IpdAdvance v JOIN dbo.IpdAdmission a ON a.AdmissionId = v.AdmissionId
             WHERE a.CompanyId = @CompanyId AND (@BranchId IS NULL OR a.BranchId = @BranchId) AND v.IsActive = 1 AND v.Kind IN ('ADVANCE', 'SETTLE')
               AND v.CreatedDate >= @start AND v.CreatedDate < @end) AS Received
    FROM (SELECT COUNT(*) AS Beds,
                 SUM(CASE WHEN BedStatus = 'Occupied' THEN 1 ELSE 0 END) AS Occupied,
                 SUM(CASE WHEN BedStatus = 'Available' THEN 1 ELSE 0 END) AS Available,
                 SUM(CASE WHEN BedStatus = 'Reserved' THEN 1 ELSE 0 END) AS Reserved,
                 SUM(CASE WHEN BedStatus = 'Cleaning' THEN 1 ELSE 0 END) AS Cleaning,
                 SUM(CASE WHEN BedStatus IN ('Blocked', 'Maintenance') THEN 1 ELSE 0 END) AS Blocked
          FROM dbo.BedMaster WHERE CompanyId = @CompanyId AND (@BranchId IS NULL OR BranchId = @BranchId) AND IsActive = 1) b;

    -- 1 patients in hospital now, with the bill so far and the advance
    SELECT a.AdmissionId, a.IpNo, bd.BedNumber, w.WardName,
           LTRIM(RTRIM(CONCAT(p.Salutation, N' ', p.FirstName, N' ', p.LastName))) AS PatientName,
           a.AdmissionAt, DATEDIFF(DAY, a.AdmissionAt, @now) + 1 AS DayNo, d.FullName AS ConsultantName, a.Status,
           ISNULL(bill.Net, 0) AS BillSoFar, ISNULL(m.NetAdvance, 0) AS NetAdvance
    FROM @adm x
    JOIN dbo.IpdAdmission a ON a.AdmissionId = x.AdmissionId
    JOIN dbo.PatientMaster p ON p.PatientId = a.PatientId
    LEFT JOIN dbo.BedMaster bd ON bd.BedId = a.CurrentBedId
    LEFT JOIN dbo.WardMaster w ON w.WardId = bd.WardId
    LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = a.ConsultantDoctorId
    OUTER APPLY (SELECT SUM(l.Net) AS Net FROM dbo.fn_Ipd_BillLines(a.AdmissionId, @now) l WHERE l.Status <> 'CANCELLED') bill
    OUTER APPLY dbo.fn_Ipd_Money(a.AdmissionId) m
    ORDER BY w.WardName, bd.BedNumber;
END
GO

-- ── pharmacy ──
CREATE OR ALTER PROCEDURE dbo.usp_HelpData_Pharmacy
    @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Kind VARCHAR(10) = 'SALES', @Q NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start DATETIME = CAST(@From AS DATETIME), @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME)), @today DATE = CAST(GETDATE() AS DATE);
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');

    IF @Kind = 'SALES'
        SELECT COUNT(*) AS Bills, ISNULL(SUM(s.NetAmount), 0) AS NetAmount, ISNULL(SUM(s.PaidAmount), 0) AS Paid,
               ISNULL(SUM(s.BalanceDue), 0) AS Due, ISNULL(SUM(s.ReturnedAmount), 0) AS Returned, ISNULL(SUM(s.DiscountAmount), 0) AS Discount,
               ISNULL(SUM(s.NetAmount - s.ReturnedAmount - s.CostAmount), 0) AS GrossProfit,
               COUNT(DISTINCT COALESCE(CAST(s.PatientId AS NVARCHAR(20)), s.Mobile, s.CustomerName)) AS Customers
        FROM dbo.PhSale s
        WHERE s.CompanyId = @CompanyId AND (@BranchId IS NULL OR s.BranchId = @BranchId) AND s.Status = 'POSTED'
          AND s.SaleDate >= @start AND s.SaleDate < @end;
    ELSE IF @Kind = 'STOCK'
        SELECT TOP (30) i.ItemName, b.BatchNo, b.ExpiryDate, st.StoreName, ss.QtyOnHand, b.Mrp
        FROM dbo.PhItem i
        JOIN dbo.PhStoreStock ss ON ss.ItemId = i.ItemId AND ss.QtyOnHand > 0 AND (@BranchId IS NULL OR ss.BranchId = @BranchId)
        JOIN dbo.PhBatch b ON b.BatchId = ss.BatchId
        JOIN dbo.PhStore st ON st.StoreId = ss.StoreId
        WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND (@Q IS NULL OR i.ItemName LIKE N'%' + @Q + N'%' OR i.ItemCode LIKE N'%' + @Q + N'%')
        ORDER BY i.ItemName, b.ExpiryDate;
    ELSE IF @Kind = 'EXPIRY'
        SELECT TOP (30) i.ItemName, b.BatchNo, b.ExpiryDate, st.StoreName, ss.QtyOnHand, DATEDIFF(DAY, @today, b.ExpiryDate) AS DaysLeft
        FROM dbo.PhStoreStock ss
        JOIN dbo.PhBatch b ON b.BatchId = ss.BatchId
        JOIN dbo.PhItem i ON i.ItemId = ss.ItemId
        JOIN dbo.PhStore st ON st.StoreId = ss.StoreId
        WHERE i.CompanyId = @CompanyId AND (@BranchId IS NULL OR ss.BranchId = @BranchId) AND ss.QtyOnHand > 0 AND b.ExpiryDate <= DATEADD(DAY, 90, @today)
        ORDER BY b.ExpiryDate;
    ELSE IF @Kind = 'LOW'
        SELECT TOP (30) i.ItemName, ISNULL(s.Qty, 0) AS QtyOnHand, i.ReorderLevel, i.MinQty
        FROM dbo.PhItem i
        OUTER APPLY (SELECT SUM(ss.QtyOnHand) AS Qty FROM dbo.PhStoreStock ss JOIN dbo.PhBatch b ON b.BatchId = ss.BatchId AND b.IsBlocked = 0 AND b.ExpiryDate > @today
                     WHERE ss.ItemId = i.ItemId AND (@BranchId IS NULL OR ss.BranchId = @BranchId)) s
        WHERE i.CompanyId = @CompanyId AND i.IsActive = 1 AND ISNULL(i.ReorderLevel, 0) > 0 AND ISNULL(s.Qty, 0) <= i.ReorderLevel
        ORDER BY ISNULL(s.Qty, 0), i.ItemName;
END
GO

-- ── collection by module and payment mode ──
CREATE OR ALTER PROCEDURE dbo.usp_HelpData_Collection @CompanyId INT, @BranchId INT = NULL, @From DATE, @To DATE, @Modules VARCHAR(40) = 'LAB,OPD,IPD,PHR,MEM'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start DATETIME = CAST(@From AS DATETIME), @end DATETIME = DATEADD(DAY, 1, CAST(@To AS DATETIME));
    SELECT h.ModuleCode AS Module, ISNULL(m.MethodName, N'Other') AS Mode, COUNT(*) AS Receipts, SUM(d.PaidAmount) AS Amount
    FROM dbo.PaymentDetail d
    JOIN dbo.PaymentHeader h ON h.PaymentHeaderId = d.PaymentHeaderId
    JOIN dbo.BranchMaster br ON br.BranchID = h.BranchId AND br.CompanyId = @CompanyId
    LEFT JOIN dbo.PaymentMethodMaster m ON m.PaymentMethodId = d.PaymentMethodId
    WHERE ISNULL(d.IsActive, 1) = 1 AND ISNULL(h.IsActive, 1) = 1 AND d.PaidAmount <> 0
      AND (@BranchId IS NULL OR h.BranchId = @BranchId) AND CHARINDEX(h.ModuleCode, @Modules) > 0
      AND ISNULL(d.PaymentDate, d.CreatedDate) >= @start AND ISNULL(d.PaymentDate, d.CreatedDate) < @end
    GROUP BY h.ModuleCode, ISNULL(m.MethodName, N'Other')
    ORDER BY h.ModuleCode, SUM(d.PaidAmount) DESC;
END
GO

PRINT 'Script 2567 applied: Ask eMedi - IPD, pharmacy and payment-mode data answers.';
GO
