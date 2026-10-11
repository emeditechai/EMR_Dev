-- ============================================================================
-- Migration: 2228_payment_summary_discount_allowed.sql
-- Description: The payment screen's bill summary (usp_Api_PaymentSummary_GetByBill) says for every item whether a
--   discount may be given on it - OPD: Service Master "Is Discountable"; LAB: the branch's B2C rate card "Discount
--   Allowed" - the same sources the payment save uses, so the screen and the server calculate a discount the same way
--   (at due collection: % of the balance due, at most the discountable amount). Other columns unchanged. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- The payment pop-up's bill summary also returns the recorded reason / approver (pre-filled on a later collection).
CREATE OR ALTER PROCEDURE [dbo].[usp_Api_PaymentSummary_GetByBill]
    @ModuleCode  NVARCHAR(20),
    @ModuleRefId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    IF @ModuleCode = 'OPD'
    BEGIN
        SELECT
            s.OPDServiceId          AS ModuleRefId,
            'OPD'                   AS ModuleCode,
            s.OPDServiceId,
            s.OPDBillNo,
            s.TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)  AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM PatientOPDService s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.OPDServiceId = @ModuleRefId;

        DECLARE @PaymentHeaderId_OPD INT;
        SELECT @PaymentHeaderId_OPD = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.ItemId                        AS LineRefId,
            si.ServiceType,
            ISNULL(sm.ItemName, '(Unknown)') AS ItemName,
            ISNULL(si.ServiceCharges, 0)     AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.ServiceCharges, 0)) AS NetLineAmount,
            ISNULL(sm.IsGstRequired, 0)      AS IsGstRequired,
            sm.GstPercentage                 AS GstPercentage,
            ISNULL(pli.CgstAmount, 0)        AS CgstAmount,
            ISNULL(pli.SgstAmount, 0)        AS SgstAmount,
            ISNULL(pli.IgstAmount, 0)        AS IgstAmount,
            CAST(ISNULL(sm.IsDiscountable, 1) AS BIT) AS IsDiscountAllowed   -- 2228: Service Master "Is Discountable"
        FROM PatientOPDServiceItem si
        LEFT JOIN ServiceMaster sm ON sm.ServiceId = si.ServiceId
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_OPD AND pli.ModuleLineRefId = si.ItemId AND pli.IsActive = 1
        WHERE si.OPDServiceId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.ItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus,
            DiscountReason,
            DiscountApprovedBy,
            (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_OPD;
    END
    ELSE IF @ModuleCode = 'LAB'
    BEGIN
        SELECT
            s.LabOrderId            AS ModuleRefId,
            'LAB'                   AS ModuleCode,
            s.LabOrderId            AS OPDServiceId, 
            s.BillNo                AS OPDBillNo,
            s.TokenNo               AS TokenNo,
            p.PatientId,
            p.PatientCode,
            (p.FirstName + ' ' + ISNULL(p.LastName, '')) AS PatientName,
            p.PhoneNumber           AS PatientPhone,
            ISNULL(s.BranchId, 0)   AS BranchId,
            ISNULL(s.TotalAmount, 0) AS SubTotal
        FROM LabOrder s
        INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
        WHERE s.LabOrderId = @ModuleRefId;

        DECLARE @PaymentHeaderId_LAB INT;
        SELECT @PaymentHeaderId_LAB = PaymentHeaderId 
        FROM PaymentHeader 
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        SELECT
            si.LabOrderItemId                AS LineRefId,
            CASE WHEN si.Type = 'P' THEN 'Package' ELSE 'Test' END AS ServiceType,
            CASE WHEN si.Type = 'P' THEN ISNULL(pkg.Profile_Name, '(Unknown Package)') ELSE ISNULL(im.Test_Name, '(Unknown)') END AS ItemName,
            ISNULL(si.Price, 0)              AS OriginalAmount,
            ISNULL(pli.LineDiscountAmount, 0) AS LineDiscountAmount,
            ISNULL(pli.NetLineAmount, ISNULL(si.Price, 0)) AS NetLineAmount,
            0                                AS IsGstRequired,
            0                                AS GstPercentage,
            0                                AS CgstAmount,
            0                                AS SgstAmount,
            0                                AS IgstAmount,
            CAST(ISNULL(e.Allowed, 0) AS BIT) AS IsDiscountAllowed           -- 2228: branch B2C rate card "Discount Allowed"
        FROM LabOrderItem si
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster im ON im.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
        OUTER APPLY (
            SELECT TOP 1 CAST(ISNULL(d.Is_Discount_Allowed, 0) AS BIT) AS Allowed
            FROM dbo.LabRateCardMaster m
            INNER JOIN dbo.LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID AND d.IsDeleted = 0
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = si.LabOrderId
            WHERE m.Branch_ID = lo.BranchId AND m.Rate_Type = 'B2C' AND m.Status = 1 AND m.IsDeleted = 0
              AND CAST(GETDATE() AS DATE) BETWEEN m.Effective_From AND m.Effective_To
              AND d.Item_ID = si.InvestigationId
              AND d.Item_Type = CASE WHEN si.Type = 'P' THEN 'Package' WHEN im.Is_Profile_Test = 1 THEN 'Profile' ELSE 'Test' END
            ORDER BY m.Effective_From DESC, m.RateCard_ID DESC) e
        LEFT JOIN PaymentLineItem pli ON pli.PaymentHeaderId = @PaymentHeaderId_LAB AND pli.ModuleLineRefId = si.LabOrderItemId AND pli.IsActive = 1
        WHERE si.LabOrderId = @ModuleRefId AND si.IsActive = 1
        ORDER BY si.LabOrderItemId;

        SELECT
            PaymentHeaderId,
            ISNULL(LineDiscountTotal, 0)      AS LineDiscountTotal,
            HeaderDiscountType,
            HeaderDiscountValue,
            ISNULL(HeaderDiscountAmount, 0)   AS HeaderDiscountAmount,
            ISNULL(NetAmount, 0)              AS NetAmount,
            ISNULL(TotalPaid, 0)              AS TotalPaid,
            ISNULL(BalanceDue, 0)             AS BalanceDue,
            ISNULL(PaymentStatus, 'U')        AS PaymentStatus,
            DiscountReason,
            DiscountApprovedBy,
            (SELECT ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) FROM Users u WHERE u.Id = PaymentHeader.DiscountApprovedBy) AS DiscountApprovedByName
        FROM PaymentHeader
        WHERE PaymentHeaderId = @PaymentHeaderId_LAB;
    END
END;
GO

PRINT 'Script 2228 applied: payment summary returns IsDiscountAllowed per item.';
GO
