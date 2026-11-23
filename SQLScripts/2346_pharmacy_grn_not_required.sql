-- ============================================================================================================
-- 2346  Pharmacy: Hospital Settings > MED > "GRN Not Required" (after 2345), per branch, default No.
--   No  = purchase order -> GRN -> stock (as before).
--   Yes = the purchase order carries the supplier bill and batch / expiry / MRP; approving it posts the stock
--         (a GRN is created and posted automatically, so payments, register and stock ledger stay the same).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyGrnNotRequired') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyGrnNotRequired BIT NOT NULL CONSTRAINT DF_HS_PhGrnNotRequired DEFAULT (0);
GO
IF COL_LENGTH('dbo.PhPurchaseOrder', 'InvoiceNo') IS NULL
    ALTER TABLE dbo.PhPurchaseOrder ADD InvoiceNo NVARCHAR(40) NULL, InvoiceDate DATE NULL, InvoiceAmount DECIMAL(14,2) NULL, OtherCharges DECIMAL(14,2) NOT NULL CONSTRAINT DF_PhPO_Other DEFAULT (0),
        IsDirect BIT NOT NULL CONSTRAINT DF_PhPO_IsDirect DEFAULT (0);   -- 1 = entered with GRN Not Required: approval posts the stock
GO
IF COL_LENGTH('dbo.PhPurchaseOrderDtl', 'BatchNo') IS NULL
    ALTER TABLE dbo.PhPurchaseOrderDtl ADD BatchNo NVARCHAR(30) NULL, ExpiryDate DATE NULL, Mrp DECIMAL(12,2) NULL;
GO
PRINT 'Script 2346 applied: Hospital Settings > MED > GRN Not Required (direct purchase to stock).';
GO
