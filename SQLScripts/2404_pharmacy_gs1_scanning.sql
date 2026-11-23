-- ============================================================================================================
-- 2404  Pharmacy: GS1 DataMatrix scanning (after 2403). Hospital Settings > MED > GS1 DataMatrix Scanning.
--   A 2D pack code carries the GTIN (AI 01), expiry (17), batch (10) and serial (21). The page reads it
--   (wwwroot/js/ph-gs1.js) and searches by GTIN: the item search procedures below now also match the Item
--   Master barcode as a GTIN - an EAN-13 / 12-digit UPC / GTIN-14 of the same pack match each other
--   (left-padded to 14 digits). No table changes. Re-runnable.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_ItemSearch
    @CompanyId INT, @BranchId INT, @Q NVARCHAR(200) = NULL, @GenericId INT = NULL, @ItemId INT = NULL, @StoreId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0 SET @StoreId = dbo.fn_PhDefaultStore(@BranchId, 'SELL');
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @gtin VARCHAR(14) = CASE WHEN @Q IS NOT NULL AND @Q NOT LIKE N'%[^0-9]%' AND LEN(@Q) BETWEEN 8 AND 14 THEN RIGHT('00000000000000' + CAST(@Q AS VARCHAR(14)), 14) END;
    DECLARE @like NVARCHAR(210) = N'%' + ISNULL(@Q, N'') + N'%', @starts NVARCHAR(210) = ISNULL(@Q, N'') + N'%';
    DECLARE @minExp DATE = DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE));
    SELECT TOP 25 i.ItemId, i.ItemCode, i.ItemName, df.ShortName FormShort, i.Strength, i.PackSize, i.GenericId, g.GenericName, m.ManufacturerName, i.CategoryId,
           i.ScheduleCode, i.PrescriptionRequired RxRequired, sc.RegisterRequired, sc.IsNarcotic, sc.LabelWarning, su.UomCode SaleUom, pu.UomCode PurchaseUom, i.ConversionQty,
           i.AllowLooseSale, i.IsDiscountAllowed, i.IsReturnable, i.IsHighAlert, i.IsLasa, i.IsColdChain, h.GstPercent, ib.RackNo,
           ISNULL(st.Qty, 0) Stock, st.NearestExpiry, st.PackMrp
      FROM dbo.PhItem i
      JOIN dbo.PhHsn h ON h.HsnId = i.HsnId JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId JOIN dbo.PhUom pu ON pu.UomId = i.PurchaseUomId
      LEFT JOIN dbo.PhGeneric g ON g.GenericId = i.GenericId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId
      LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      LEFT JOIN dbo.PhItemBranch ib ON ib.ItemId = i.ItemId AND ib.BranchId = @BranchId
      OUTER APPLY (SELECT SUM(s.QtyOnHand) Qty, MIN(b.ExpiryDate) NearestExpiry,
                          (SELECT TOP 1 b2.Mrp FROM dbo.PhStoreStock s2 JOIN dbo.PhBatch b2 ON b2.BatchId = s2.BatchId
                            WHERE s2.StoreId = @StoreId AND s2.ItemId = i.ItemId AND s2.QtyOnHand > 0 AND b2.IsBlocked = 0
                              AND b2.ExpiryDate > @minExp ORDER BY b2.ExpiryDate, b2.BatchId) PackMrp
                     FROM dbo.PhStoreStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.StoreId = @StoreId AND s.QtyOnHand > 0 AND b.IsBlocked = 0 AND b.ExpiryDate > @minExp AND s.ItemId = i.ItemId) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1
       AND (@GenericId IS NULL OR i.GenericId = @GenericId) AND (@ItemId IS NULL OR i.ItemId = @ItemId)
       AND (@Q IS NULL OR i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @Q OR i.Barcode = @Q OR (@gtin IS NOT NULL AND i.Barcode NOT LIKE N'%[^0-9]%' AND RIGHT('00000000000000' + i.Barcode, 14) = @gtin))
     ORDER BY CASE WHEN i.Barcode = @Q OR (@gtin IS NOT NULL AND i.Barcode NOT LIKE N'%[^0-9]%' AND RIGHT('00000000000000' + i.Barcode, 14) = @gtin) OR i.ItemCode = @Q THEN 0 WHEN ISNULL(st.Qty, 0) > 0 THEN 1 ELSE 2 END,
              CASE WHEN i.ItemName LIKE @starts THEN 0 ELSE 1 END, i.ItemName;
END
GO

-- ── lookups and settings ─────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_ItemSearch @CompanyId INT, @BranchId INT, @Q NVARCHAR(200), @Take INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gtin VARCHAR(14) = CASE WHEN @Q IS NOT NULL AND @Q NOT LIKE N'%[^0-9]%' AND LEN(@Q) BETWEEN 8 AND 14 THEN RIGHT('00000000000000' + CAST(@Q AS VARCHAR(14)), 14) END;
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%', @starts NVARCHAR(210) = @Q + N'%';
    SELECT TOP (@Take) f.* FROM dbo.fn_PhTxnItemInfo(@CompanyId, @BranchId) f
     WHERE f.IsActive = 1 AND f.IsStocked = 1 AND (f.ItemName LIKE @like OR f.GenericName LIKE @like OR f.ItemCode = @Q OR f.Barcode = @Q OR (@gtin IS NOT NULL AND f.Barcode NOT LIKE N'%[^0-9]%' AND RIGHT('00000000000000' + f.Barcode, 14) = @gtin))
     ORDER BY CASE WHEN f.Barcode = @Q OR (@gtin IS NOT NULL AND f.Barcode NOT LIKE N'%[^0-9]%' AND RIGHT('00000000000000' + f.Barcode, 14) = @gtin) OR f.ItemCode = @Q THEN 0 WHEN f.ItemName LIKE @starts THEN 1 ELSE 2 END, f.ItemName;
END
GO

-- counter settings now also carry the round-2 switches (2402) the POS needs
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Settings @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 PharmacyEnabled, PharmacyDrugLicence20BValidTo Licence20BValidTo, PharmacyNdpsLicenceNo NdpsLicenceNo,
           PharmacyMinShelfLifeSaleDays MinShelfLifeSaleDays, PharmacyAllowNegativeStock AllowNegativeStock, PharmacyMaxManualDiscountPercent MaxManualDiscountPercent,
           PharmacyRoundOffBill RoundOffBill, PharmacySaleReturnDays SaleReturnDays, PharmacyLooseReturnAllowed LooseReturnAllowed, PharmacyBillPrintFormat BillPrintFormat,
           PharmacyBillNotificationRequired BillNotificationRequired,
           PharmacyGs1ScanEnabled Gs1ScanEnabled, PharmacySplitPaymentEnabled SplitPaymentEnabled, PharmacySubstituteSuggest SubstituteSuggest,
           PharmacyRxLinkEnabled RxLinkEnabled, PharmacyClinicalChecksEnabled ClinicalChecksEnabled, PharmacyMajorInteractionBlock MajorInteractionBlock,
           PharmacyLoyaltyEnabled LoyaltyEnabled, PharmacyLoyaltyEarnPer100 LoyaltyEarnPer100, PharmacyLoyaltyPointValue LoyaltyPointValue,
           PharmacyLoyaltyMinRedeem LoyaltyMinRedeem, PharmacyLoyaltyMaxRedeemPercent LoyaltyMaxRedeemPercent, PharmacyLoyaltyExpiryDays LoyaltyExpiryDays,
           PharmacyRefillReminderEnabled RefillReminderEnabled
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
END
GO

-- purchase settings: + GS1 scanning switch
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhPur_Settings @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL((SELECT TOP 1 PharmacyGrnNotRequired FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) AS GrnNotRequired,
           ISNULL((SELECT TOP 1 PharmacyMinShelfLifeGrnDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 90) AS MinShelfLifeGrnDays,
           ISNULL((SELECT TOP 1 PharmacyGs1ScanEnabled FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) AS Gs1ScanEnabled;
END
GO

PRINT 'Script 2404 applied: GS1 DataMatrix - GTIN match in pharmacy item search.';
GO
