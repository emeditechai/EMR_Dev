-- ============================================================================
-- Migration: 2121_payment_discount_reason_approver.sql
-- Description:
--   Every discount given at billing / payment (the shared payment pop-up, OPD and LAB) records WHY it was given
--   and WHO approved it. The billing user is asked for both whenever a discount is entered or changed.
--
--   dbo.PaymentHeader.DiscountReason       reason entered by the billing user
--   dbo.PaymentHeader.DiscountApprovedBy   approving user (dbo.Users.Id)
--   dbo.PaymentHeader.DiscountApprovedDate when the discount was recorded / last changed
--   dbo.PaymentHeader.DiscountEnteredBy    billing user who entered the discount
--   Existing discounted bills keep NULL (no reason was ever captured for them).
--   dbo.usp_Api_PaymentSummary_GetByBill   + DiscountReason / DiscountApprovedBy / DiscountApprovedByName
-- ============================================================================

USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.PaymentHeader', 'DiscountReason') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD DiscountReason NVARCHAR(250) NULL;
GO
IF COL_LENGTH('dbo.PaymentHeader', 'DiscountApprovedBy') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD DiscountApprovedBy INT NULL;
GO
IF COL_LENGTH('dbo.PaymentHeader', 'DiscountApprovedDate') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD DiscountApprovedDate DATETIME NULL;
GO
IF COL_LENGTH('dbo.PaymentHeader', 'DiscountEnteredBy') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD DiscountEnteredBy INT NULL;   -- the billing user who entered the discount
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_PaymentHeader_DiscountApprovedBy')
    ALTER TABLE dbo.PaymentHeader WITH CHECK ADD CONSTRAINT FK_PaymentHeader_DiscountApprovedBy
        FOREIGN KEY (DiscountApprovedBy) REFERENCES dbo.Users (Id);
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
            ISNULL(pli.IgstAmount, 0)        AS IgstAmount
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
            0                                AS IgstAmount
        FROM LabOrderItem si
        LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = si.InvestigationId AND si.Type = 'P'
        LEFT JOIN dbo.LabInvestigationMaster im ON im.Test_ID = si.InvestigationId AND ISNULL(si.Type, 'I') <> 'P'
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

PRINT 'PaymentHeader: discount reason / approver columns ready.';
GO
