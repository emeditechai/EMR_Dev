-- ============================================================================================================
-- Migration: 2569_lab_b2c_discount_reason_desc.sql
-- LAB B2C billing, discount approval in the payment pop-up:
--   dbo.PaymentHeader.DiscountReason     the reason tag chosen, saved exactly as shown (e.g. "Referred by doctor")
--   dbo.PaymentHeader.ReasonDesc         NEW: what the user wrote in the reason box (optional, may be NULL)
--   dbo.LabOrder.DiscDeductedFromDoctor  NEW: reason "Referred by doctor" only - is the discount deducted from the
--                                        referral doctor's share? 1 = Yes, 0 = No, NULL = not a doctor-referral discount
-- "Referred by doctor" is offered only when the B2C bill has a Referral Doctor.
-- Other screens (OPD, IPD, B2B, registration) are unchanged: their reason stays in DiscountReason, ReasonDesc NULL.
--
-- usp_Api_LabOrder_SetDiscDeductedFromDoctor @LabOrderId, @Value: sets / clears the flag on a B2C bill
--   (refused with 56620 when the bill is B2B or has no referral doctor and @Value is not NULL).
-- The B2C screen's Referral Doctor (Doctor Master) is LabOrder.RefDoctorId (2127); old bills may have ReferralDoctorId.
-- Needs 2121, 2127. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.PaymentHeader', 'ReasonDesc') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD ReasonDesc NVARCHAR(500) NULL;
GO
IF COL_LENGTH('dbo.LabOrder', 'DiscDeductedFromDoctor') IS NULL
    ALTER TABLE dbo.LabOrder ADD DiscDeductedFromDoctor BIT NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrder_SetDiscDeductedFromDoctor
    @LabOrderId INT,
    @Value      BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Value IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabOrder
                                         WHERE LabOrderId = @LabOrderId AND ISNULL(IsB2B, 0) = 0
                                           AND (RefDoctorId IS NOT NULL OR ReferralDoctorId IS NOT NULL))   -- the screen's Referral Doctor is RefDoctorId (2127)
        THROW 56620, 'The discount can be deducted from the referral doctor only on a B2C bill that has a Referral Doctor.', 1;

    UPDATE dbo.LabOrder SET DiscDeductedFromDoctor = @Value WHERE LabOrderId = @LabOrderId;
    SELECT @@ROWCOUNT AS Updated;
END
GO
