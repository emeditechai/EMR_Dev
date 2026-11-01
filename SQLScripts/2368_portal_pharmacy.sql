-- ============================================================================================================
-- Migration: 2368_portal_pharmacy.sql
-- Patient Portal > Pharmacy: the patient's pharmacy bills (sold to the patient's ID at the counter) with what was bought.
--   Set 1 bills (saved and cancelled; held bills are not shown), set 2 the items of those bills.
-- Run after 2367. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_Portal_PharmacyBills @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.SaleId, s.CompanyId, s.BranchId, b.BranchName, s.SaleNo, s.SaleDate, s.Status, s.DoctorName, s.RxNo,
           s.MrpAmount, s.DiscountAmount, s.NetAmount, s.PaidAmount, s.ReturnedAmount, s.BalanceDue,
           (SELECT COUNT(*) FROM dbo.PhSaleDtl d WHERE d.SaleId = s.SaleId) AS Items
      FROM dbo.PhSale s JOIN dbo.BranchMaster b ON b.BranchID = s.BranchId
     WHERE s.PatientId = @PatientId AND s.Status IN ('POSTED', 'CANCELLED')
     ORDER BY s.SaleDate DESC, s.SaleId DESC;

    SELECT d.SaleId, i.ItemName, df.ShortName AS FormShort, i.Strength, g.GenericName, bt.BatchNo, bt.ExpiryDate,
           d.Qty, d.ReturnedQty, su.UomCode AS SaleUom, d.UnitMrp, d.DiscPercent, d.Amount
      FROM dbo.PhSaleDtl d JOIN dbo.PhSale s ON s.SaleId = d.SaleId JOIN dbo.PhItem i ON i.ItemId = d.ItemId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhBatch bt ON bt.BatchId = d.BatchId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId
     WHERE s.PatientId = @PatientId AND s.Status IN ('POSTED', 'CANCELLED')
     ORDER BY d.SaleId DESC, d.SaleDtlId;
END
GO

PRINT 'Script 2368 applied: patient portal pharmacy bills.';
GO
