-- ============================================================================================================
-- Migration: 2534_patient_beneficiary_id.sql
-- Beneficiary ID of the patient (e.g. a WBHS / health-scheme beneficiary number), optional free text up to 50 characters.
--   1. PatientMaster.BeneficiaryId - typed beside ABHA Address on OPD Patient Registration, LAB B2C / B2B booking and IPD
--      admission (saved by the web registration flow, like the ABHA fields of 2355).
--   2. Printed in Patient Information of the bills, when set: the three procedures the bills read now return it
--      (altered from their live definitions, nothing else changed):
--        usp_Api_ServiceBooking_GetById  OPD bill
--        usp_LabOrder_GetDetail          LAB bill (B2C and B2B)
--        usp_Api_IpdBill_Get             IPD final bill (admission header result set)
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.PatientMaster', 'BeneficiaryId') IS NULL
    ALTER TABLE dbo.PatientMaster ADD BeneficiaryId NVARCHAR(50) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.PatientMaster') AND name = N'MS_Description'
           AND minor_id = COLUMNPROPERTY(OBJECT_ID(N'dbo.PatientMaster'), N'BeneficiaryId', 'ColumnId'))
    EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = N'Beneficiary ID (e.g. WBHS / health-scheme beneficiary number), optional; typed by the desk, printed on the bills.',
         @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'PatientMaster', @level2type = N'COLUMN', @level2name = N'BeneficiaryId';
ELSE
    EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Beneficiary ID (e.g. WBHS / health-scheme beneficiary number), optional; typed by the desk, printed on the bills.',
         @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'PatientMaster', @level2type = N'COLUMN', @level2name = N'BeneficiaryId';
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_ServiceBooking_GetById
    @OPDServiceId INT
AS
BEGIN
    SET NOCOUNT ON;

    -- RS1: Header
    SELECT
        s.OPDServiceId,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.BeneficiaryId,          /* 2534 */
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                        AS PatientName,
        p.PhoneNumber,
        p.Gender,
        p.DateOfBirth,
        d.FullName                AS ConsultingDoctorName,
        s.VisitDate,
        ISNULL(s.TotalAmount, 0)  AS TotalAmount,
        s.Status,
        s.AppointmentTime,
        s.CreatedDate
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT  JOIN DoctorMaster  d ON d.DoctorId  = s.ConsultingDoctorId
    WHERE s.OPDServiceId = @OPDServiceId;

    -- RS2: Line items
    SELECT
        si.ItemId,
        si.ServiceType,
        ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
        ISNULL(si.ServiceCharges, 0)     AS ServiceCharges,
        ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
        sm.GstPercentage                 AS GstPercentage
    FROM PatientOPDServiceItem si
    LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
    WHERE si.OPDServiceId = @OPDServiceId AND si.IsActive = 1
    ORDER BY si.ItemId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_GetDetail
(
    @LabOrderId INT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    -- RS1: Order Header & Patient Info
    SELECT 
        o.LabOrderId,
        o.PatientId,
        o.BranchId,
        b.BranchName,
        o.OrderDate,
        o.BillNo,
        o.TokenNo,
        o.BookingNo,                                             -- 2384
        CAST(ISNULL(o.IsBookingRequired, 0) AS BIT) AS IsBookingRequired,
        o.TotalAmount,
        o.CollectionType,
        o.PhlebotomistId,
        o.IsUrgent,
        phleb.FullName AS PhlebotomistName,
        ISNULL(o.RefDoctorId, o.ReferralDoctorId) AS ReferralDoctorId,
        COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(rdoc.NamePrefix + ' ', '') + rdoc.FullName)), ''), NULLIF(LTRIM(RTRIM(ISNULL(rd.Salutation, '') + ' ' + ISNULL(rd.DoctorName, ''))), '')) AS ReferralDoctorName,
        me.ExecutiveName AS MarketingExecutiveName, me.ExecutiveType AS MarketingExecutiveType,   -- SQLScripts/2442
        o.BookingDate,
        o.IsActive,
        o.CreatedDate,
        ISNULL(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
        u.Username AS CreatedByUsername,
        o.IsB2B,
        o.B2BAgentID,
        o.AgentType,
        o.B2BTotal,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Name
            WHEN o.AgentType = 'C' THEN corp.Corporate_Name
            ELSE NULL
        END AS AgentName,
        CASE 
            WHEN o.AgentType = 'F' THEN f.Franchise_Code
            WHEN o.AgentType = 'C' THEN corp.Corporate_Code
            ELSE NULL
        END AS AgentCode,
        p.PatientCode,
        p.BeneficiaryId /* 2534 */,
        LTRIM(RTRIM(ISNULL(p.Salutation, '') + ' ' + ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))) AS PatientName,
        p.PhoneNumber,
        p.EmailId,
        p.Gender, o.LmpDate /* 2453 */,
        p.DateOfBirth,
        DATEDIFF(YEAR, p.DateOfBirth, GETDATE()) - 
            CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END AS Age,
        p.Address,
        ph.PaymentHeaderId,
        CASE 
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) >= ISNULL(o.B2BTotal, o.TotalAmount) THEN 'P'
            WHEN o.IsB2B = 1 AND ISNULL(ph.TotalPaid, 0) > 0 THEN 'R'
            WHEN o.IsB2B = 1 THEN 'U'
            ELSE ISNULL(ph.PaymentStatus, 'U')
        END AS PaymentStatus,
        ISNULL(ph.TotalPaid, 0)       AS TotalPaid,
        CASE 
            WHEN o.IsB2B = 1 THEN 
                CASE WHEN ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) < 0 THEN 0.00 
                     ELSE ISNULL(o.B2BTotal, o.TotalAmount) - ISNULL(ph.TotalPaid, 0.00) END
            ELSE ISNULL(ph.BalanceDue, o.TotalAmount)
        END AS BalanceDue,
        ISNULL(ph.NetAmount, o.TotalAmount)  AS NetAmount,
        ISNULL(ph.HeaderDiscountAmount, 0)   AS DiscountAmount,
        ISNULL(ph.RoundOffAmount, 0)         AS RoundOffAmount,
        -- why the discount was given and who approved / entered it (asked at billing since 2121)
        NULLIF(LTRIM(RTRIM(ph.DiscountReason)), '') AS DiscountReason,
        ph.DiscountApprovedDate,
        (SELECT ISNULL(NULLIF(LTRIM(RTRIM(x.FullName)), ''), x.Username) FROM dbo.Users x WHERE x.Id = ph.DiscountApprovedBy) AS DiscountApprovedByName,
        (SELECT ISNULL(NULLIF(LTRIM(RTRIM(x.FullName)), ''), x.Username) FROM dbo.Users x WHERE x.Id = ph.DiscountEnteredBy)  AS DiscountEnteredByName
    FROM dbo.LabOrder o
    INNER JOIN dbo.PatientMaster p ON p.PatientId = o.PatientId
    LEFT JOIN dbo.BranchMaster b ON b.BranchID = o.BranchId
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = o.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.Users u ON u.Id = o.CreatedBy
    LEFT JOIN dbo.Users phleb ON phleb.Id = o.PhlebotomistId
    LEFT JOIN dbo.ReferralDoctorMaster rd ON rd.ReferralDoctorId = o.ReferralDoctorId
    LEFT JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = o.RefDoctorId
    LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = o.MarketingExecutiveId /* 2445 */
    LEFT JOIN dbo.LabFranchiseMaster f ON f.Franchise_ID = o.B2BAgentID AND o.AgentType = 'F'
    LEFT JOIN dbo.CorporateMaster corp ON corp.Corporate_ID = o.B2BAgentID AND o.AgentType = 'C'
    WHERE o.LabOrderId = @LabOrderId;

    -- RS2: Line Items
    SELECT 
        loi.LabOrderItemId,
        loi.LabOrderId,
        loi.InvestigationId,
        ISNULL(loi.Type, 'I') AS Type,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Code ELSE lim.Test_Code END AS TestCode,
        CASE WHEN loi.Type = 'P' THEN pkg.Profile_Name ELSE lim.Test_Name END AS TestName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE stm.Sample_Name END AS SampleType,
        CASE WHEN loi.Type = 'P' THEN CAST(ISNULL(pkg.Profile_TAT_Hours, 24) AS NVARCHAR(50)) ELSE CAST(lim.TAT_Hours AS NVARCHAR(50)) END AS TATHours,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE dm.DeptName END AS DepartmentName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE cm.Category_Name END AS CategoryName,
        CASE WHEN loi.Type = 'P' THEN 'Package' ELSE scm.SubCategory_Name END AS SubCategoryName,
        loi.Price,
        loi.B2BRate,
        loi.IsUrgent,
        ISNULL(pli.LineDiscountAmount, 0) AS DiscountAmount,
        ISNULL(pli.NetLineAmount, loi.Price) AS NetAmount,
        loi.IsActive
    FROM dbo.LabOrderItem loi
    LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
    LEFT JOIN dbo.LabInvestigationMaster lim ON lim.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
    LEFT JOIN dbo.DepartmentMaster dm ON dm.DeptId = lim.Department_ID
    LEFT JOIN dbo.LabTestCategoryMaster cm ON cm.Category_ID = lim.Category_ID
    LEFT JOIN dbo.LabTestSubCategoryMaster scm ON scm.SubCategory_ID = lim.SubCategory_ID
    LEFT JOIN dbo.LabSampleTypeMaster stm ON stm.Sample_Type_ID = lim.Sample_Type_ID
    LEFT JOIN dbo.PaymentHeader ph ON ph.ModuleCode = 'LAB' AND ph.ModuleRefId = loi.LabOrderId AND ph.IsActive = 1
    LEFT JOIN dbo.PaymentLineItem pli ON pli.PaymentHeaderId = ph.PaymentHeaderId 
        AND (pli.ModuleLineRefId = loi.LabOrderItemId OR pli.ModuleLineRefId = loi.InvestigationId)
        AND pli.IsActive = 1
    WHERE loi.LabOrderId = @LabOrderId
    ORDER BY loi.LabOrderItemId;

    -- RS3: Payments Recorded
    SELECT 
        pd.PaymentDetailId,
        pm.MethodName,
        pm.MethodCode,
        pd.PaidAmount,
        pd.PaymentDate,
        pd.ReceiptNo,
        pd.TransactionRef,
        pd.ChequeNo,
        pd.BankName,
        pd.UPIRefNo,
        pd.CardLast4,
        pd.Notes,
        -- 2205: who received it, and whether it was collected later against the balance due (same rule as
        -- usp_MoneyReceipt_Get: the bill's PaymentHeader existed before the payment)
        ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), N''), u.Username) AS ReceivedByName,
        CAST(CASE WHEN DATEDIFF(SECOND, ph.CreatedDate, pd.CreatedDate) > 5 THEN 1 ELSE 0 END AS BIT) AS IsDueCollection
    FROM dbo.PaymentHeader ph
    INNER JOIN dbo.PaymentDetail pd ON pd.PaymentHeaderId = ph.PaymentHeaderId AND pd.IsActive = 1
    LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
    LEFT JOIN dbo.Users u ON u.Id = pd.CreatedBy
    WHERE ph.ModuleCode = 'LAB' AND ph.ModuleRefId = @LabOrderId AND ph.IsActive = 1
    ORDER BY pd.PaymentDate, pd.PaymentDetailId;
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
    SELECT h.*, pbm.BeneficiaryId /* 2534 */ FROM dbo.fn_Ipd_AdmissionHeader(@CompanyId, @adm) h
    LEFT JOIN dbo.PatientMaster pbm ON pbm.PatientId = h.PatientId;
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

PRINT 'Script 2534 applied: PatientMaster.BeneficiaryId and the bill procedures.';
GO
