-- ============================================================================================================
-- Migration: 2359_pharmacy_sales_api.sql
-- Pharmacy > Sales through EMR.Api (API + stored procedures, like LAB / OPD): counter sale (POS), hold / recall,
-- sale return, cancellation, credit collection, receipts, Schedule register, customer / patient / doctor search.
-- Replaces the SQL that EMR.Web/Services/PharmacySaleService.cs and PhSalesController ran directly. The checks that
-- need no data (quantities, discount range, mobile, payment modes) stay in EMR.Web; everything that reads or locks
-- data runs here, each save in one transaction as before. Error texts are the same as before.
-- Money stays as in 2348 (PaymentHeader / PaymentDetail 'PHR', BillCancellation / BillRefund, usp_Ph_PostSaleLedger).
-- No table changes. Run after 2358. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── settings and look-ups ────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Settings @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 PharmacyEnabled, PharmacyDrugLicence20BValidTo Licence20BValidTo, PharmacyNdpsLicenceNo NdpsLicenceNo,
           PharmacyMinShelfLifeSaleDays MinShelfLifeSaleDays, PharmacyAllowNegativeStock AllowNegativeStock, PharmacyMaxManualDiscountPercent MaxManualDiscountPercent,
           PharmacyRoundOffBill RoundOffBill, PharmacySaleReturnDays SaleReturnDays, PharmacyLooseReturnAllowed LooseReturnAllowed, PharmacyBillPrintFormat BillPrintFormat,
           PharmacyBillNotificationRequired BillNotificationRequired
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
END
GO

-- price per sale unit (GST inclusive) by the Price Rule master, never above the batch MRP
CREATE OR ALTER FUNCTION dbo.fn_PhSaleUnitPrice (@CompanyId INT, @ItemId INT, @BatchId INT, @PriceType VARCHAR(20))
RETURNS TABLE
AS
RETURN
    SELECT CAST(ROUND(CASE WHEN p.Price < x.UnitMrp THEN p.Price ELSE x.UnitMrp END, 4) AS DECIMAL(12,4)) AS UnitPrice
      FROM (SELECT CAST(b.Mrp AS DECIMAL(38,18)) / i.ConversionQty AS UnitMrp, CAST(b.LandedCost AS DECIMAL(38,18)) AS Cost, b.GstPercent AS Gst,
                   i.CategoryId, c.ParentCategoryId
              FROM dbo.PhBatch b JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN dbo.PhCategory c ON c.CategoryId = i.CategoryId
             WHERE b.BatchId = @BatchId AND b.ItemId = @ItemId) x
      OUTER APPLY (SELECT TOP 1 r.PriceBasis, r.RatePercent FROM dbo.PhPriceRule r
                    WHERE r.CompanyId = @CompanyId AND r.IsActive = 1 AND r.PatientType = @PriceType
                      AND (r.CategoryId IS NULL OR r.CategoryId IN (x.CategoryId, ISNULL(x.ParentCategoryId, -1)))
                    ORDER BY CASE WHEN r.CategoryId = x.CategoryId THEN 0 WHEN r.CategoryId = ISNULL(x.ParentCategoryId, -1) THEN 1 ELSE 2 END, r.Priority) rule_
      CROSS APPLY (SELECT CASE rule_.PriceBasis
                            WHEN 'MRP_LESS'  THEN x.UnitMrp * (1 - CAST(rule_.RatePercent AS DECIMAL(38,18)) / 100)
                            WHEN 'COST_PLUS' THEN x.Cost * (1 + CAST(rule_.RatePercent AS DECIMAL(38,18)) / 100) * (1 + CAST(x.Gst AS DECIMAL(38,18)) / 100)
                            ELSE x.UnitMrp END AS Price) p;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_UnitPrice @CompanyId INT, @ItemId INT, @BatchId INT, @PriceType VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UnitPrice FROM dbo.fn_PhSaleUnitPrice(@CompanyId, @ItemId, @BatchId, @PriceType);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_ItemSearch
    @CompanyId INT, @BranchId INT, @Q NVARCHAR(200) = NULL, @GenericId INT = NULL, @ItemId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
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
                          (SELECT TOP 1 b2.Mrp FROM dbo.PhStock s2 JOIN dbo.PhBatch b2 ON b2.BatchId = s2.BatchId
                            WHERE s2.BranchId = @BranchId AND s2.ItemId = i.ItemId AND s2.QtyOnHand > 0 AND b2.IsBlocked = 0
                              AND b2.ExpiryDate > @minExp ORDER BY b2.ExpiryDate, b2.BatchId) PackMrp
                     FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
                    WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.IsBlocked = 0 AND b.ExpiryDate > @minExp AND s.ItemId = i.ItemId) st
     WHERE i.CompanyId = @CompanyId AND i.IsActive = 1
       AND (@GenericId IS NULL OR i.GenericId = @GenericId) AND (@ItemId IS NULL OR i.ItemId = @ItemId)
       AND (@Q IS NULL OR i.ItemName LIKE @like OR g.GenericName LIKE @like OR i.ItemCode = @Q OR i.Barcode = @Q)
     ORDER BY CASE WHEN i.Barcode = @Q OR i.ItemCode = @Q THEN 0 WHEN ISNULL(st.Qty, 0) > 0 THEN 1 ELSE 2 END,
              CASE WHEN i.ItemName LIKE @starts THEN 0 ELSE 1 END, i.ItemName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Batches @CompanyId INT, @BranchId INT, @ItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @shelf INT = ISNULL((SELECT TOP 1 PharmacyMinShelfLifeSaleDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 30);
    SELECT b.BatchId, b.ItemId, b.BatchNo, b.ExpiryDate, b.Mrp PackMrp, b.Mrp / i.ConversionQty UnitMrp, b.LandedCost, b.GstPercent, s.QtyOnHand Stock
      FROM dbo.PhStock s JOIN dbo.PhBatch b ON b.BatchId = s.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId
     WHERE s.BranchId = @BranchId AND s.QtyOnHand > 0 AND b.IsBlocked = 0 AND b.ExpiryDate > DATEADD(DAY, @shelf, CAST(GETDATE() AS DATE))
       AND s.ItemId = @ItemId AND EXISTS (SELECT 1 FROM dbo.PhItem i0 WHERE i0.ItemId = @ItemId AND i0.CompanyId = @CompanyId)
     ORDER BY b.ExpiryDate, b.BatchId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_PaymentMethods
AS
BEGIN
    SET NOCOUNT ON;
    SELECT UPPER(MethodCode) Value, MethodName Text FROM dbo.PaymentMethodMaster
     WHERE IsActive = 1 AND UPPER(MethodCode) IN ('CASH', 'CARD', 'UPI', 'NEFT', 'CHEQUE') ORDER BY PaymentMethodId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Customers @CompanyId INT, @Q NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + LTRIM(RTRIM(ISNULL(@Q, N''))) + N'%';
    SELECT TOP 15 c.CustomerId id, c.CustomerName name, c.Mobile mobile, c.Email email, c.Address address, c.CustomerType type, c.CreditAllowed credit, c.CreditLimit creditLimit,
           ISNULL((SELECT SUM(s.BalanceDue) FROM dbo.PhSale s WHERE s.CustomerId = c.CustomerId AND s.Status = 'POSTED'), 0) outstanding
      FROM dbo.PhCustomer c WHERE c.CompanyId = @CompanyId AND c.IsActive = 1 AND (c.CustomerName LIKE @like OR c.Mobile LIKE @like) ORDER BY c.CustomerName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Patients @CompanyId INT, @Q NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Q = LTRIM(RTRIM(@Q));
    DECLARE @like NVARCHAR(210) = N'%' + @Q + N'%';
    SELECT TOP 15 pm.PatientId id, pm.PatientCode uhid, LTRIM(RTRIM(ISNULL(pm.FirstName, '') + ' ' + ISNULL(pm.LastName, ''))) name, pm.PhoneNumber mobile,
           pm.EmailId email, pm.Address address, pm.Gender gender,
           (SELECT TOP 1 ISNULL(d.NamePrefix + ' ', '') + d.FullName FROM dbo.PatientOPDService v JOIN dbo.DoctorMaster d ON d.DoctorId = v.ConsultingDoctorId WHERE v.PatientId = pm.PatientId ORDER BY v.OPDServiceId DESC) lastDoctor,
           (SELECT TOP 1 v.ConsultingDoctorId FROM dbo.PatientOPDService v WHERE v.PatientId = pm.PatientId ORDER BY v.OPDServiceId DESC) lastDoctorId
      FROM dbo.PatientMaster pm WHERE pm.CompanyId = @CompanyId AND pm.IsActive = 1
       AND (pm.PatientCode LIKE @like OR pm.PhoneNumber LIKE @like OR pm.FirstName LIKE @like OR pm.LastName LIKE @like OR (pm.FirstName + ' ' + pm.LastName) LIKE @like)
     ORDER BY CASE WHEN pm.PatientCode = @Q OR pm.PhoneNumber = @Q THEN 0 ELSE 1 END, pm.FirstName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Doctors @CompanyId INT, @Q NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @like NVARCHAR(210) = N'%' + LTRIM(RTRIM(ISNULL(@Q, N''))) + N'%';
    SELECT TOP 15 DoctorId id, ISNULL(NamePrefix + ' ', '') + FullName name, MedicalLicenseNo regNo FROM dbo.DoctorMaster
     WHERE CompanyId = @CompanyId AND IsActive = 1 AND FullName LIKE @like ORDER BY FullName;
END
GO

-- ── save a bill (or hold it) ─────────────────────────────────────────────────────────────────────────────
-- @Lines:    [{ "ItemId", "BatchId" (null = first expiry first, split over batches), "Qty" (sale units), "DiscPercent" }]
-- @Payments: [{ "Method" (CASH|CARD|UPI|NEFT|CHEQUE, checked in EMR.Web), "Amount", "Ref" }]  - empty when held
-- Answers one row: Success, Error, SaleId, SaleNo, ReceiptNo, NetAmount, Change, BalanceDue
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @Hold BIT, @CanDiscount BIT, @CanCredit BIT, @HoldId INT = NULL,
    @CustomerKind VARCHAR(10), @PatientId INT = NULL, @CustomerId INT = NULL, @CustomerName NVARCHAR(4000) = NULL, @Mobile NVARCHAR(4000) = NULL,
    @Email NVARCHAR(4000) = NULL, @Address NVARCHAR(4000) = NULL, @DoctorId INT = NULL, @DoctorName NVARCHAR(4000) = NULL, @DoctorRegNo NVARCHAR(4000) = NULL,
    @RxNo NVARCHAR(4000) = NULL, @RxDate DATE = NULL, @BillDiscPercent DECIMAL(9,4) = 0, @Remarks NVARCHAR(4000) = NULL, @HoldLabel NVARCHAR(4000) = NULL,
    @Lines NVARCHAR(MAX), @Payments NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @err NVARCHAR(500);
    DECLARE @enabled BIT = 0, @lic DATE, @ndps NVARCHAR(100), @shelf INT = 30, @neg BIT = 0, @maxDisc DECIMAL(9,4) = 10, @roundOff BIT = 1;
    SELECT TOP 1 @enabled = PharmacyEnabled, @lic = PharmacyDrugLicence20BValidTo, @ndps = PharmacyNdpsLicenceNo, @shelf = PharmacyMinShelfLifeSaleDays,
           @neg = PharmacyAllowNegativeStock, @maxDisc = PharmacyMaxManualDiscountPercent, @roundOff = PharmacyRoundOffBill
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    IF ISNULL(@enabled, 0) = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy is not enabled for this branch (Hospital Settings > Pharmacy & Drug Licence).' AS Error; RETURN; END;
    IF @Hold = 0 AND @lic < @today
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy''s drug licence expired on ' + FORMAT(@lic, 'dd-MMM-yyyy', 'en-US') + N'; sales are stopped until it is renewed in Hospital Settings.' AS Error; RETURN; END;

    DECLARE @In TABLE (Seq INT PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4));
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.ItemId'), JSON_VALUE(value, '$.BatchId'), JSON_VALUE(value, '$.Qty'), ISNULL(JSON_VALUE(value, '$.DiscPercent'), 0)
                 FROM OPENJSON(@Lines);
    DECLARE @Pay TABLE (Seq INT PRIMARY KEY, Method VARCHAR(10), Amount DECIMAL(18,2), Ref NVARCHAR(200));
    INSERT @Pay SELECT CAST([key] AS INT), JSON_VALUE(value, '$.Method'), JSON_VALUE(value, '$.Amount'), JSON_VALUE(value, '$.Ref') FROM OPENJSON(ISNULL(@Payments, N'[]'));
    DECLARE @P TABLE (Seq INT IDENTITY PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4), UnitMrp DECIMAL(12,4), UnitPrice DECIMAL(12,4),
                      Amount DECIMAL(18,2), Gst DECIMAL(5,2), Taxable DECIMAL(18,2), GstAmt DECIMAL(18,2), Cost DECIMAL(12,4), Schedule VARCHAR(10), Register BIT, Narcotic BIT, ItemName NVARCHAR(200));

    BEGIN TRY
        BEGIN TRAN;
        -- customer
        DECLARE @priceType VARCHAR(20) = 'WALKIN', @custFound BIT = 0, @custCredit BIT = 0, @custLimit DECIMAL(14,2) = 0;
        IF @CustomerKind = 'PATIENT'
        BEGIN
            DECLARE @pn NVARCHAR(300), @pp NVARCHAR(50), @pa NVARCHAR(500), @pe NVARCHAR(150), @pf BIT = 0;
            SELECT @pf = 1, @pn = LTRIM(RTRIM(ISNULL(FirstName, '') + ' ' + ISNULL(LastName, ''))), @pp = PhoneNumber, @pa = Address, @pe = EmailId
              FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId AND IsActive = 1;
            IF @pf = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Pick the patient (UHID).' AS Error; RETURN; END;
            SET @CustomerName = ISNULL(@CustomerName, @pn); SET @Mobile = ISNULL(@Mobile, @pp); SET @Address = ISNULL(@Address, @pa); SET @Email = ISNULL(@Email, @pe);
            SET @CustomerId = NULL;
        END
        ELSE IF @CustomerKind = 'CUSTOMER'
        BEGIN
            DECLARE @cn NVARCHAR(150), @cm NVARCHAR(15), @ce NVARCHAR(150), @ca NVARCHAR(300), @ct VARCHAR(20);
            SELECT @custFound = 1, @cn = CustomerName, @cm = Mobile, @ce = Email, @ca = Address, @ct = CustomerType, @custCredit = CreditAllowed, @custLimit = CreditLimit
              FROM dbo.PhCustomer WHERE CustomerId = @CustomerId AND CompanyId = @CompanyId AND IsActive = 1;
            IF @custFound = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Pick the pharmacy customer.' AS Error; RETURN; END;
            SET @CustomerName = @cn; SET @Mobile = @cm; SET @Email = ISNULL(@Email, @ce); SET @Address = ISNULL(@Address, @ca); SET @PatientId = NULL;
            IF @ct = 'STAFF' SET @priceType = 'STAFF';
        END
        ELSE BEGIN SET @PatientId = NULL; SET @CustomerId = NULL; END;

        -- items and batches: first expiry first, split over batches; a chosen batch is used as it is
        DECLARE @It TABLE (ItemId INT PRIMARY KEY, ItemName NVARCHAR(200), Conv INT, Loose BIT, DiscOk BIT, Schedule VARCHAR(10), Rx BIT, Reg BIT, Narc BIT, Active BIT);
        INSERT @It SELECT i.ItemId, i.ItemName, i.ConversionQty, i.AllowLooseSale, i.IsDiscountAllowed, i.ScheduleCode, i.PrescriptionRequired, sc.RegisterRequired, sc.IsNarcotic, i.IsActive
                     FROM dbo.PhItem i JOIN dbo.PhDrugSchedule sc ON sc.ScheduleCode = i.ScheduleCode
                    WHERE i.CompanyId = @CompanyId AND i.ItemId IN (SELECT ItemId FROM @In);
        DECLARE @minExpiry DATE = DATEADD(DAY, @shelf, @today);
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @In), @item INT, @batch INT, @qty DECIMAL(18,6), @disc DECIMAL(9,4), @left DECIMAL(18,6),
                @name NVARCHAR(200), @conv INT, @loose BIT, @narc BIT, @reg BIT, @sch VARCHAR(10), @active BIT;
        DECLARE @B TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Stock DECIMAL(14,3), Expiry DATE, Blocked BIT);
        DECLARE @bn INT, @bId INT, @bStock DECIMAL(14,3), @bExp DATE, @bBlocked BIT, @take DECIMAL(18,6), @last INT;
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @item = ItemId, @batch = BatchId, @qty = Qty, @disc = Disc FROM @In WHERE Seq = @seq;
            SELECT @name = NULL, @active = NULL;
            SELECT @name = ItemName, @conv = Conv, @loose = Loose, @narc = Narc, @reg = Reg, @sch = Schedule, @active = Active FROM @It WHERE ItemId = @item;
            IF @name IS NULL OR @active = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item is not in the Item Master or is inactive.' AS Error; RETURN; END;
            IF @loose = 0 AND @qty % @conv <> 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is sold in full packs of ' + CAST(@conv AS NVARCHAR(10)) + N' only.' AS Error; RETURN; END;
            IF @narc = 1 AND NULLIF(LTRIM(RTRIM(@ndps)), N'') IS NULL
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is a Schedule X / NDPS drug: the branch has no NDPS licence in Hospital Settings.' AS Error; RETURN; END;
            DELETE @B;
            INSERT @B (BatchId, Stock, Expiry, Blocked)
            SELECT b.BatchId, s.QtyOnHand, b.ExpiryDate, b.IsBlocked FROM dbo.PhStock s WITH (UPDLOCK, HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
             WHERE s.BranchId = @BranchId AND s.ItemId = @item AND (@batch IS NULL OR b.BatchId = @batch) ORDER BY b.ExpiryDate, b.BatchId;
            IF @batch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @B) BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch has no stock here.' AS Error; RETURN; END;
            SET @left = @qty;
            SET @bn = (SELECT MIN(Rn) FROM @B);
            WHILE @bn IS NOT NULL AND @left > 0
            BEGIN
                SELECT @bId = BatchId, @bStock = Stock, @bExp = Expiry, @bBlocked = Blocked FROM @B WHERE Rn = @bn;
                IF @bBlocked = 1 OR @bExp <= @today
                BEGIN
                    IF @batch IS NOT NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch is expired or blocked.' AS Error; RETURN; END;
                END
                ELSE IF @bExp <= @minExpiry
                BEGIN
                    IF @batch IS NOT NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N': the chosen batch expires within ' + CAST(@shelf AS NVARCHAR(10)) + N' days and cannot be sold.' AS Error; RETURN; END;
                END
                ELSE
                BEGIN
                    SET @take = CASE WHEN @Hold = 1 OR @batch IS NOT NULL THEN @left
                                     WHEN @left < (CASE WHEN @bStock > 0 THEN @bStock ELSE 0 END) THEN @left
                                     ELSE (CASE WHEN @bStock > 0 THEN @bStock ELSE 0 END) END;
                    IF @take > 0
                    BEGIN
                        INSERT @P (ItemId, BatchId, Qty, Disc, Schedule, Register, Narcotic, ItemName) VALUES (@item, @bId, @take, @disc, @sch, @reg, @narc, @name);
                        SET @left = @left - @take;
                    END
                END
                SET @bn = (SELECT MIN(Rn) FROM @B WHERE Rn > @bn);
            END
            IF @left > 0
            BEGIN
                IF @neg = 0 AND @Hold = 0
                BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Not enough sellable stock of ' + @name + N': short by ' + FORMAT(@left, '0.##') + N'.' AS Error; RETURN; END;
                SET @last = (SELECT MAX(Seq) FROM @P WHERE ItemId = @item);
                IF @last IS NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' has no sellable batch.' AS Error; RETURN; END;
                UPDATE @P SET Qty = Qty + @left WHERE Seq = @last;
            END
            SET @seq = (SELECT MIN(Seq) FROM @In WHERE Seq > @seq);
        END

        -- prices and amounts (MRP inclusive of GST)
        UPDATE p SET UnitMrp = ROUND(CAST(b.Mrp AS DECIMAL(38,18)) / i.ConversionQty, 4), Cost = b.LandedCost, Gst = b.GstPercent,
                     UnitPrice = pr.UnitPrice,
                     Disc = CASE WHEN it.DiscOk = 1 THEN CASE WHEN p.Disc + @BillDiscPercent > 100 THEN 100 ELSE p.Disc + @BillDiscPercent END ELSE 0 END
          FROM @P p JOIN dbo.PhBatch b ON b.BatchId = p.BatchId JOIN dbo.PhItem i ON i.ItemId = b.ItemId JOIN @It it ON it.ItemId = p.ItemId
          CROSS APPLY dbo.fn_PhSaleUnitPrice(@CompanyId, p.ItemId, p.BatchId, @priceType) pr;
        UPDATE @P SET Amount = ROUND(CAST(Qty AS DECIMAL(38,18)) * UnitPrice * (1 - CAST(Disc AS DECIMAL(38,18)) / 100), 2);
        UPDATE @P SET Taxable = ROUND(CAST(Amount AS DECIMAL(38,18)) * 100 / (100 + Gst), 2);
        UPDATE @P SET GstAmt = Amount - Taxable;
        DECLARE @manualDisc DECIMAL(9,4) = ISNULL((SELECT MAX(Disc) FROM @P), 0);
        IF @Hold = 0 AND @manualDisc > @maxDisc AND @CanDiscount = 0
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Discount ' + FORMAT(@manualDisc, '0.##') + N'% is above the ' + FORMAT(@maxDisc, '0.##') + N'% allowed at the counter; a user with the Discount permission must bill it.' AS Error; RETURN; END;

        -- prescription and register
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P p JOIN @It it ON it.ItemId = p.ItemId WHERE it.Rx = 1)
           AND (LTRIM(RTRIM(ISNULL(@DoctorName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@RxNo, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item that needs a prescription is on the bill: enter the doctor and the prescription number.' AS Error; RETURN; END;
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P WHERE Register = 1)
           AND (LTRIM(RTRIM(ISNULL(@CustomerName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@Address, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'A Schedule H1 / X drug is on the bill: the patient''s name and address are needed for the register.' AS Error; RETURN; END;

        DECLARE @mrpAmt DECIMAL(18,2) = (SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * UnitMrp), 2) FROM @P);
        DECLARE @lineTotal DECIMAL(18,2) = (SELECT SUM(Amount) FROM @P);
        DECLARE @net DECIMAL(18,2) = CASE WHEN @roundOff = 1 THEN ROUND(@lineTotal, 0) ELSE @lineTotal END;
        DECLARE @taxable DECIMAL(18,2) = (SELECT SUM(Taxable) FROM @P), @gst DECIMAL(18,2) = (SELECT SUM(GstAmt) FROM @P);
        DECLARE @cgst DECIMAL(18,2) = ROUND(@gst / 2, 2);
        DECLARE @sgst DECIMAL(18,2) = @gst - @cgst;
        DECLARE @cost DECIMAL(18,2) = (SELECT ROUND(SUM(CAST(Qty AS DECIMAL(38,18)) * Cost), 2) FROM @P);

        -- payments: full payment, or the balance on credit for a credit customer
        DELETE @Pay WHERE Amount <= 0;
        DECLARE @tendered DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay), 0);
        DECLARE @nonCash DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay WHERE Method <> 'CASH'), 0);
        IF @nonCash > @net BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Card / UPI / bank amount is more than the bill.' AS Error; RETURN; END;
        DECLARE @change DECIMAL(18,2) = CASE WHEN @tendered - @net > 0 THEN @tendered - @net ELSE 0 END;
        IF @change > 0 UPDATE @Pay SET Amount = Amount - @change WHERE Seq = (SELECT MIN(Seq) FROM @Pay WHERE Method = 'CASH');   -- change returned from the cash given
        DECLARE @paid DECIMAL(18,2) = ISNULL((SELECT SUM(Amount) FROM @Pay), 0);
        DECLARE @due DECIMAL(18,2) = CASE WHEN @Hold = 1 THEN 0 ELSE @net - @paid END;
        IF @Hold = 0 AND @due > 0
        BEGIN
            IF @custFound = 0 OR @custCredit = 0
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'₹' + FORMAT(@due, '0.00') + N' is not paid. Only a credit customer can take a bill on credit.' AS Error; RETURN; END;
            IF @CanCredit = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'You do not have permission to bill on credit.' AS Error; RETURN; END;
            DECLARE @outstanding DECIMAL(18,2) = ISNULL((SELECT SUM(BalanceDue) FROM dbo.PhSale WHERE CustomerId = @CustomerId AND Status = 'POSTED'), 0);
            IF @outstanding + @due > @custLimit
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Credit limit ₹' + FORMAT(@custLimit, '0.00') + N' would be crossed (outstanding ₹' + FORMAT(@outstanding, '0.00') + N' + this bill ₹' + FORMAT(@due, '0.00') + N').' AS Error; RETURN; END;
        END

        -- header
        DECLARE @saleNo NVARCHAR(40) = NULL, @saleId INT;
        IF @Hold = 0 EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SALE', @DocDate = @today, @DocNo = @saleNo OUTPUT;
        IF ISNULL(@HoldId, 0) > 0
        BEGIN
            UPDATE dbo.PhSale SET SaleNo = @saleNo, SaleDate = GETDATE(), Status = CASE WHEN @Hold = 1 THEN 'HOLD' ELSE 'POSTED' END, CustomerKind = @CustomerKind, PatientId = @PatientId,
                   CustomerId = @CustomerId, CustomerName = @CustomerName, Mobile = @Mobile, Email = @Email, Address = @Address, DoctorId = @DoctorId, DoctorName = @DoctorName,
                   DoctorRegNo = @DoctorRegNo, RxNo = @RxNo, RxDate = @RxDate, PriceType = @priceType, BillDiscPercent = @BillDiscPercent, MrpAmount = @mrpAmt,
                   DiscountAmount = @mrpAmt - @lineTotal, TaxableAmount = @taxable, CgstAmount = @cgst, SgstAmount = @sgst, RoundOff = @net - @lineTotal, NetAmount = @net,
                   PaidAmount = @paid, BalanceDue = @due, CostAmount = @cost, HoldLabel = @HoldLabel, Remarks = @Remarks, ModifiedBy = @UserId, ModifiedDate = GETDATE()
             WHERE SaleId = @HoldId AND CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'HOLD';
            IF @@ROWCOUNT = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'The held bill was already finished or discarded.' AS Error; RETURN; END;
            DELETE dbo.PhSaleDtl WHERE SaleId = @HoldId;
            SET @saleId = @HoldId;
        END
        ELSE
        BEGIN
            INSERT dbo.PhSale (CompanyId, BranchId, SaleNo, Status, CustomerKind, PatientId, CustomerId, CustomerName, Mobile, Email, Address,
                   DoctorId, DoctorName, DoctorRegNo, RxNo, RxDate, PriceType, BillDiscPercent, MrpAmount, DiscountAmount, TaxableAmount, CgstAmount, SgstAmount, RoundOff,
                   NetAmount, PaidAmount, BalanceDue, CostAmount, HoldLabel, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, @saleNo, CASE WHEN @Hold = 1 THEN 'HOLD' ELSE 'POSTED' END, @CustomerKind, @PatientId, @CustomerId, @CustomerName, @Mobile, @Email, @Address,
                   @DoctorId, @DoctorName, @DoctorRegNo, @RxNo, @RxDate, @priceType, @BillDiscPercent, @mrpAmt, @mrpAmt - @lineTotal, @taxable, @cgst, @sgst, @net - @lineTotal,
                   @net, @paid, @due, @cost, @HoldLabel, @Remarks, @UserId);
            SET @saleId = CAST(SCOPE_IDENTITY() AS INT);
        END

        DECLARE @ps INT = (SELECT MIN(Seq) FROM @P), @dtl INT;
        DECLARE @pItem INT, @pBatch INT, @pQty DECIMAL(18,6), @pReg BIT, @pSch VARCHAR(10);
        WHILE @ps IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleDtl (SaleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, DiscPercent, Amount, GstPercent, TaxableAmount, GstAmount, UnitCost)
            SELECT @saleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, Disc, Amount, Gst, Taxable, GstAmt, Cost FROM @P WHERE Seq = @ps;
            SET @dtl = CAST(SCOPE_IDENTITY() AS INT);
            IF @Hold = 0
            BEGIN
                SELECT @pItem = ItemId, @pBatch = BatchId, @pQty = Qty, @pReg = Register, @pSch = Schedule FROM @P WHERE Seq = @ps;
                SET @pQty = -@pQty;
                EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @pBatch, @Qty = @pQty, @DocType = 'SALE', @DocId = @saleId, @DocNo = @saleNo, @UserId = @UserId, @AllowNegative = @neg;
                IF @pReg = 1
                    INSERT dbo.PhScheduleRegister (CompanyId, BranchId, SaleId, SaleDtlId, EntryDate, ScheduleCode, ItemId, BatchId, Qty, PatientName, PatientAddress, PrescriberName, PrescriberRegNo, RxNo, DispensedBy)
                    VALUES (@CompanyId, @BranchId, @saleId, @dtl, GETDATE(), @pSch, @pItem, @pBatch, -@pQty, @CustomerName, @Address, @DoctorName, @DoctorRegNo, @RxNo, @UserId);
            END
            SET @ps = (SELECT MIN(Seq) FROM @P WHERE Seq > @ps);
        END
        IF @Hold = 1
        BEGIN
            COMMIT;
            SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, CAST(NULL AS NVARCHAR(40)) AS SaleNo, CAST(NULL AS NVARCHAR(50)) AS ReceiptNo,
                   @net AS NetAmount, CAST(0 AS DECIMAL(18,2)) AS Change, CAST(0 AS DECIMAL(18,2)) AS BalanceDue;
            RETURN;
        END

        -- money: like OPD / LAB (PaymentHeader / PaymentDetail, module PHR)
        DECLARE @patient INT = @PatientId;
        IF @patient IS NULL EXEC dbo.usp_Ph_WalkinPatient @CompanyId = @CompanyId, @BranchId = @BranchId, @PatientId = @patient OUTPUT;
        INSERT dbo.PaymentHeader (ModuleCode, ModuleRefId, BranchId, PatientId, SubTotal, LineDiscountTotal, HeaderDiscountType, HeaderDiscountValue,
               HeaderDiscountAmount, NetAmount, TotalPaid, BalanceDue, PaymentStatus, Notes, CreatedDate, CreatedBy, IsActive, TotalCgstAmount, TotalSgstAmount, TotalIgstAmount, CompanyId, RoundOffAmount)
        VALUES ('PHR', @saleId, @BranchId, @patient, @mrpAmt, @mrpAmt - @lineTotal, 'P', 0, 0, @net, @paid, @due, CASE WHEN @due > 0 THEN 'U' ELSE 'P' END,
               N'Pharmacy bill ' + @saleNo, GETDATE(), @UserId, 1, @cgst, @sgst, 0, @CompanyId, @net - @lineTotal);
        DECLARE @headerId INT = CAST(SCOPE_IDENTITY() AS INT), @receiptNo NVARCHAR(50) = NULL, @pd INT;
        IF @paid > 0
        BEGIN
            EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @receiptNo OUTPUT;
            DECLARE @py INT = (SELECT MIN(Seq) FROM @Pay WHERE Amount > 0), @pm VARCHAR(10), @pamt DECIMAL(18,2), @pref NVARCHAR(200);
            WHILE @py IS NOT NULL
            BEGIN
                SELECT @pm = Method, @pamt = Amount, @pref = Ref FROM @Pay WHERE Seq = @py;
                INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
                SELECT @headerId, PaymentMethodId, @pamt, @pref, CASE WHEN @pm = 'UPI' THEN @pref END, CASE WHEN @pm = 'CARD' THEN RIGHT(@pref, 4) END, CASE WHEN @pm = 'CHEQUE' THEN @pref END,
                       GETDATE(), N'Pharmacy bill ' + @saleNo, GETDATE(), @UserId, 1, @receiptNo, @CompanyId
                  FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = @pm;
                SET @pd = CAST(SCOPE_IDENTITY() AS INT);
                EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRCPT', @RefId = @pd, @UserId = @UserId;
                SET @py = (SELECT MIN(Seq) FROM @Pay WHERE Amount > 0 AND Seq > @py);
            END
        END
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SALE', @RefId = @saleId, @UserId = @UserId;
        COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, @saleNo AS SaleNo, @receiptNo AS ReceiptNo, @net AS NetAmount, @change AS Change, @due AS BalanceDue;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_DiscardHold @CompanyId INT, @BranchId INT, @SaleId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @n INT;
    BEGIN TRAN;
    DELETE d FROM dbo.PhSaleDtl d JOIN dbo.PhSale s ON s.SaleId = d.SaleId WHERE s.SaleId = @SaleId AND s.Status = 'HOLD' AND s.CompanyId = @CompanyId AND s.BranchId = @BranchId;
    DELETE dbo.PhSale WHERE SaleId = @SaleId AND Status = 'HOLD' AND CompanyId = @CompanyId AND BranchId = @BranchId;
    SET @n = @@ROWCOUNT;
    COMMIT;
    SELECT CASE WHEN @n = 0 THEN N'Held bill not found.' END AS Error;
END
GO

-- ── bills ────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_List
    @CompanyId INT, @BranchId INT, @Status VARCHAR(10), @Search NVARCHAR(200) = NULL, @From DATE = NULL, @To DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%';
    SELECT TOP 500 s.SaleId, s.SaleNo, s.SaleDate, s.Status, s.CustomerName, s.Mobile, s.DoctorName,
           (SELECT COUNT(*) FROM dbo.PhSaleDtl d WHERE d.SaleId = s.SaleId) Lines, s.NetAmount, s.PaidAmount, s.ReturnedAmount, s.BalanceDue,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CreatedBy) CreatedByName, s.HoldLabel
      FROM dbo.PhSale s
     WHERE s.CompanyId = @CompanyId AND s.BranchId = @BranchId
       AND (@Status = 'ALL' OR s.Status = @Status OR (@Status = 'DUE' AND s.Status = 'POSTED' AND s.BalanceDue > 0))
       AND (@From IS NULL OR s.SaleDate >= @From) AND (@To IS NULL OR s.SaleDate < DATEADD(DAY, 1, @To))
       AND (@Search IS NULL OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.Mobile LIKE @like OR s.DoctorName LIKE @like)
     ORDER BY s.SaleDate DESC;
END
GO

-- one bill: 1 bill (no row = not found), 2 lines, 3 payments, 4 returns
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Get @CompanyId INT, @BranchId INT, @SaleId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PhSale WHERE SaleId = @SaleId AND CompanyId = @CompanyId AND BranchId = @BranchId) SET @SaleId = -1;
    SELECT s.*, pm.PatientCode, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = s.CreatedBy) CreatedByName
      FROM dbo.PhSale s LEFT JOIN dbo.PatientMaster pm ON pm.PatientId = s.PatientId WHERE s.SaleId = @SaleId;
    SELECT d.SaleDtlId, d.ItemId, i.ItemName, df.ShortName FormShort, i.ScheduleCode, h.HsnCode, d.BatchId, bt.BatchNo, bt.ExpiryDate, su.UomCode SaleUom,
           i.ConversionQty, i.IsReturnable, i.IsColdChain, d.Qty, d.UnitMrp, d.UnitPrice, d.DiscPercent, d.Amount, d.GstPercent, d.TaxableAmount, d.GstAmount, d.UnitCost, d.ReturnedQty
      FROM dbo.PhSaleDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch bt ON bt.BatchId = d.BatchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhHsn h ON h.HsnId = i.HsnId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
     WHERE d.SaleId = @SaleId ORDER BY d.SaleDtlId;
    SELECT pd.ReceiptNo, COALESCE(pd.PaymentDate, pd.CreatedDate) PaymentDate, pm.MethodName, COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) Ref, pd.PaidAmount Amount
      FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
     WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = @SaleId AND pd.IsActive = 1 ORDER BY pd.PaymentDetailId;
    SELECT r.ReturnId, r.ReturnNo, r.ReturnDate, rs.ReasonName, r.RefundMode, r.NetAmount, r.AdjustedAmount, r.RefundAmount,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = r.CreatedBy) CreatedByName
      FROM dbo.PhSaleReturn r LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId WHERE r.SaleId = @SaleId ORDER BY r.ReturnId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_FindForReturn @CompanyId INT, @BranchId INT, @Q NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SET @Q = LTRIM(RTRIM(@Q));
    SELECT TOP 1 SaleId FROM dbo.PhSale WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND Status = 'POSTED'
       AND (SaleNo = @Q OR SaleNo LIKE '%/' + @Q) ORDER BY SaleDate DESC;
END
GO

-- ── sale return ──────────────────────────────────────────────────────────────────────────────────────────
-- @Lines: [{ "SaleDtlId", "Qty" }] (quantities above zero, checked in EMR.Web). Answers Id, DocNo, Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_SaveReturn
    @CompanyId INT, @BranchId INT, @UserId INT, @SaleId INT, @ReasonId INT, @RefundMode VARCHAR(10), @RefundRef NVARCHAR(4000) = NULL, @Remarks NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @days INT = 7, @loose BIT = 0, @roundOff BIT = 1;
    SELECT TOP 1 @days = PharmacySaleReturnDays, @loose = PharmacyLooseReturnAllowed, @roundOff = PharmacyRoundOffBill FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    DECLARE @In TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, Qty DECIMAL(18,6));
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.SaleDtlId'), JSON_VALUE(value, '$.Qty') FROM OPENJSON(@Lines);
    DECLARE @R TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, ItemId INT, BatchId INT, Q DECIMAL(18,6), Amt DECIMAL(18,2), Tax DECIMAL(18,2), G DECIMAL(18,2), UnitCost DECIMAL(12,4));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @saleDate DATETIME, @balance DECIMAL(18,2);
        SELECT @status = Status, @saleDate = SaleDate, @balance = BalanceDue FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @SaleId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'POSTED' BEGIN ROLLBACK; SELECT 0 AS Id, N'Only a saved, not cancelled, bill can take a return.' AS Error; RETURN; END;
        IF DATEADD(DAY, @days, CAST(@saleDate AS DATE)) < @today
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Returns are taken within ' + CAST(@days AS NVARCHAR(10)) + N' days of the bill; this bill is of ' + FORMAT(@saleDate, 'dd-MMM-yyyy', 'en-US') + N'.' AS Error; RETURN; END;

        DECLARE @L TABLE (SaleDtlId INT PRIMARY KEY, ItemId INT, ItemName NVARCHAR(200), ScheduleCode VARCHAR(10), BatchId INT, ExpiryDate DATE, ConversionQty INT,
                          IsReturnable BIT, IsColdChain BIT, Qty DECIMAL(14,3), Amount DECIMAL(14,2), TaxableAmount DECIMAL(14,2), UnitCost DECIMAL(12,4), ReturnedQty DECIMAL(14,3));
        INSERT @L SELECT d.SaleDtlId, d.ItemId, i.ItemName, i.ScheduleCode, d.BatchId, b.ExpiryDate, i.ConversionQty, i.IsReturnable, i.IsColdChain, d.Qty, d.Amount, d.TaxableAmount, d.UnitCost, d.ReturnedQty
                    FROM dbo.PhSaleDtl d WITH (UPDLOCK) JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId
                   WHERE d.SaleId = @SaleId AND d.SaleDtlId IN (SELECT SaleDtlId FROM @In);
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @In), @dtlId INT, @q DECIMAL(18,6), @found BIT, @nm NVARCHAR(200), @sch VARCHAR(10), @ret BIT, @cold BIT,
                @exp DATE, @lq DECIMAL(14,3), @rq DECIMAL(14,3), @conv INT, @lamt DECIMAL(14,2), @ltax DECIMAL(14,2), @amt DECIMAL(18,2), @tax DECIMAL(18,2);
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @dtlId = SaleDtlId, @q = Qty FROM @In WHERE Seq = @seq;
            SET @found = 0;
            SELECT @found = 1, @nm = ItemName, @sch = ScheduleCode, @ret = IsReturnable, @cold = IsColdChain, @exp = ExpiryDate, @lq = Qty, @rq = ReturnedQty, @conv = ConversionQty,
                   @lamt = Amount, @ltax = TaxableAmount FROM @L WHERE SaleDtlId = @dtlId;
            IF @found = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'An item is not on this bill.' AS Error; RETURN; END;
            IF @ret = 0 OR @sch IN ('X', 'NDPS') BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is not returnable.' AS Error; RETURN; END;
            IF @cold = 1 BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is a cold-chain item and cannot be taken back.' AS Error; RETURN; END;
            IF @exp <= @today BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': the batch has expired.' AS Error; RETURN; END;
            IF @q > @lq - @rq BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': only ' + FORMAT(@lq - @rq, '0.##') + N' can still be returned.' AS Error; RETURN; END;
            IF @loose = 0 AND @q % @conv <> 0
            BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': loose / cut strips are not taken back (full packs of ' + CAST(@conv AS NVARCHAR(10)) + N').' AS Error; RETURN; END;
            SET @amt = ROUND(CAST(@lamt AS DECIMAL(38,18)) * @q / @lq, 2);
            SET @tax = ROUND(CAST(@ltax AS DECIMAL(38,18)) * @q / @lq, 2);
            INSERT @R SELECT @seq, @dtlId, ItemId, BatchId, @q, @amt, @tax, @amt - @tax, UnitCost FROM @L WHERE SaleDtlId = @dtlId;
            SET @seq = (SELECT MIN(Seq) FROM @In WHERE Seq > @seq);
        END
        DECLARE @amount DECIMAL(18,2) = (SELECT SUM(Amt) FROM @R), @taxable DECIMAL(18,2) = (SELECT SUM(Tax) FROM @R), @gst DECIMAL(18,2) = (SELECT SUM(G) FROM @R);
        DECLARE @cost DECIMAL(18,2) = (SELECT SUM(ROUND(CAST(UnitCost AS DECIMAL(38,18)) * Q, 2)) FROM @R);
        DECLARE @net DECIMAL(18,2) = CASE WHEN @roundOff = 1 THEN ROUND(@amount, 0) ELSE @amount END;
        DECLARE @adjusted DECIMAL(18,2) = CASE WHEN @net < @balance THEN @net ELSE @balance END;
        DECLARE @refund DECIMAL(18,2) = @net - @adjusted;
        SET @RefundMode = UPPER(@RefundMode);
        IF @refund > 0 AND ISNULL(@RefundMode, '') NOT IN ('CASH', 'CARD', 'UPI', 'NEFT', 'CHEQUE')
        BEGIN ROLLBACK; SELECT 0 AS Id, N'Pick how the money is paid back.' AS Error; RETURN; END;
        IF @refund = 0 SET @RefundMode = 'ADJUST';

        DECLARE @no NVARCHAR(40), @refundId INT = NULL, @cnId INT, @rid INT;
        EXEC dbo.usp_Ph_NextNumber @BranchId = @BranchId, @DocType = 'SRET', @DocDate = @today, @DocNo = @no OUTPUT;
        IF @refund > 0
        BEGIN
            -- money paid back is recorded like an OPD / LAB partial cancellation: BillCancellation (P) + BillRefund
            INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
            VALUES ('PHR', @SaleId, N'CN-PHR/' + @no, 'P', GETDATE(), @net, 0, N'Sale return ' + @no + CASE WHEN LTRIM(RTRIM(ISNULL(@Remarks, N''))) = N'' THEN N'' ELSE N': ' + @Remarks END, 'C', @UserId, GETDATE(), 1);
            SET @cnId = CAST(SCOPE_IDENTITY() AS INT);
            INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
            VALUES (@cnId, 'PHR', @SaleId, @refund, @RefundMode, GETDATE(), @RefundRef, N'Pharmacy sale return ' + @no, 'P', @UserId, GETDATE(), 1);
            SET @refundId = CAST(SCOPE_IDENTITY() AS INT);
        END
        INSERT dbo.PhSaleReturn (CompanyId, BranchId, ReturnNo, SaleId, ReasonId, RefundMode, RefundRef, TaxableAmount, GstAmount, RoundOff, NetAmount, AdjustedAmount, RefundAmount, CostAmount, RefundId, Remarks, CreatedBy)
        VALUES (@CompanyId, @BranchId, @no, @SaleId, @ReasonId, @RefundMode, @RefundRef, @taxable, @gst, @net - @amount, @net, @adjusted, @refund, @cost, @refundId, @Remarks, @UserId);
        SET @rid = CAST(SCOPE_IDENTITY() AS INT);
        DECLARE @rs INT = (SELECT MIN(Seq) FROM @R), @rBatch INT;
        WHILE @rs IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleReturnDtl (ReturnId, SaleDtlId, ItemId, BatchId, Qty, Amount, TaxableAmount, GstAmount, UnitCost)
            SELECT @rid, SaleDtlId, ItemId, BatchId, Q, Amt, Tax, G, UnitCost FROM @R WHERE Seq = @rs;
            SELECT @dtlId = SaleDtlId, @q = Q, @rBatch = BatchId FROM @R WHERE Seq = @rs;
            UPDATE dbo.PhSaleDtl SET ReturnedQty = ReturnedQty + @q WHERE SaleDtlId = @dtlId;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @rBatch, @Qty = @q, @DocType = 'SRET', @DocId = @rid, @DocNo = @no, @UserId = @UserId, @AllowNegative = 1;
            SET @rs = (SELECT MIN(Seq) FROM @R WHERE Seq > @rs);
        END
        UPDATE dbo.PhSale SET ReturnedAmount = ReturnedAmount + @net, BalanceDue = BalanceDue - @adjusted, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE SaleId = @SaleId;
        UPDATE dbo.PaymentHeader SET BalanceDue = (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId),
               PaymentStatus = CASE WHEN (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId) > 0 THEN 'U' ELSE 'P' END,
               LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
         WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @SaleId;
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRET', @RefId = @rid, @UserId = @UserId;
        IF @refundId IS NOT NULL EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SREFUND', @RefId = @refundId, @UserId = @UserId;
        COMMIT;
        SELECT @rid AS Id, @no AS DocNo, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT 0 AS Id, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Returns @CompanyId INT, @BranchId INT, @From DATE, @To DATE, @Search NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    DECLARE @like NVARCHAR(210) = N'%' + @Search + N'%';
    SELECT TOP 500 r.ReturnId, r.ReturnNo, r.ReturnDate, s.SaleNo, s.CustomerName, rs.ReasonName, r.RefundMode, r.NetAmount, r.AdjustedAmount, r.RefundAmount,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = r.CreatedBy) CreatedByName
      FROM dbo.PhSaleReturn r JOIN dbo.PhSale s ON s.SaleId = r.SaleId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
     WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.ReturnDate >= @From AND r.ReturnDate < DATEADD(DAY, 1, @To)
       AND (@Search IS NULL OR r.ReturnNo LIKE @like OR s.SaleNo LIKE @like OR s.CustomerName LIKE @like OR s.Mobile LIKE @like)
     ORDER BY r.ReturnDate DESC;
END
GO

-- one return: 1 return (no row = not found), 2 its sale id, 3 lines
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_GetReturn @CompanyId INT, @BranchId INT, @ReturnId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.ReturnId, r.ReturnNo, r.ReturnDate, s.SaleNo, s.CustomerName, rs.ReasonName, r.RefundMode, r.NetAmount, r.AdjustedAmount, r.RefundAmount,
           (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = r.CreatedBy) CreatedByName
      FROM dbo.PhSaleReturn r JOIN dbo.PhSale s ON s.SaleId = r.SaleId LEFT JOIN dbo.PhReason rs ON rs.ReasonId = r.ReasonId
     WHERE r.ReturnId = @ReturnId AND r.CompanyId = @CompanyId AND r.BranchId = @BranchId;
    SELECT SaleId FROM dbo.PhSaleReturn WHERE ReturnId = @ReturnId AND CompanyId = @CompanyId AND BranchId = @BranchId;
    SELECT d.SaleDtlId, d.ItemId, i.ItemName, df.ShortName FormShort, b.BatchNo, b.ExpiryDate, su.UomCode SaleUom, d.Qty, d.Amount, d.TaxableAmount, d.GstAmount, sd.GstPercent
      FROM dbo.PhSaleReturnDtl d JOIN dbo.PhItem i ON i.ItemId = d.ItemId JOIN dbo.PhBatch b ON b.BatchId = d.BatchId JOIN dbo.PhUom su ON su.UomId = i.SaleUomId
      JOIN dbo.PhSaleDtl sd ON sd.SaleDtlId = d.SaleDtlId LEFT JOIN dbo.PhDosageForm df ON df.DosageFormId = i.DosageFormId
      JOIN dbo.PhSaleReturn r ON r.ReturnId = d.ReturnId AND r.CompanyId = @CompanyId AND r.BranchId = @BranchId
     WHERE d.ReturnId = @ReturnId;
END
GO

-- ── cancellation ─────────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Cancel @CompanyId INT, @BranchId INT, @UserId INT, @SaleId INT, @Reason NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @saleDate DATETIME, @createdBy INT, @returned DECIMAL(18,2), @saleNo NVARCHAR(40), @net DECIMAL(18,2);
        SELECT @status = Status, @saleDate = SaleDate, @createdBy = CreatedBy, @returned = ReturnedAmount, @saleNo = SaleNo, @net = NetAmount
          FROM dbo.PhSale WITH (UPDLOCK) WHERE SaleId = @SaleId AND CompanyId = @CompanyId AND BranchId = @BranchId;
        IF ISNULL(@status, '') <> 'POSTED' BEGIN ROLLBACK; SELECT N'Only a saved bill can be cancelled.' AS Error; RETURN; END;
        IF CAST(@saleDate AS DATE) <> CAST(GETDATE() AS DATE) BEGIN ROLLBACK; SELECT N'A bill can be cancelled only on the day it was made; take a sale return instead.' AS Error; RETURN; END;
        IF @returned > 0 BEGIN ROLLBACK; SELECT N'Medicines of this bill were already returned; take a sale return for the rest.' AS Error; RETURN; END;
        IF EXISTS (SELECT 1 FROM dbo.CashClosing WHERE BranchId = @BranchId AND UserId = @createdBy AND Module = 'PHR' AND BusinessDate = CAST(@saleDate AS DATE) AND CutoffAt >= @saleDate)
        BEGIN ROLLBACK; SELECT N'The cashier has already closed the day for this bill; it cannot be cancelled. Take a sale return instead.' AS Error; RETURN; END;

        DECLARE @l TABLE (Rn INT IDENTITY PRIMARY KEY, BatchId INT, Qty DECIMAL(14,3));
        INSERT @l (BatchId, Qty) SELECT BatchId, Qty FROM dbo.PhSaleDtl WHERE SaleId = @SaleId;
        DECLARE @rn INT = (SELECT MIN(Rn) FROM @l), @b INT, @q DECIMAL(14,3);
        WHILE @rn IS NOT NULL
        BEGIN
            SELECT @b = BatchId, @q = Qty FROM @l WHERE Rn = @rn;
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @b, @Qty = @q, @DocType = 'SCAN', @DocId = @SaleId, @DocNo = @saleNo, @UserId = @UserId, @AllowNegative = 1;
            SET @rn = (SELECT MIN(Rn) FROM @l WHERE Rn > @rn);
        END
        INSERT dbo.BillCancellation (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate, CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES ('PHR', @SaleId, N'CN-PHR/' + @saleNo, 'F', GETDATE(), @net, 0, @Reason, 'C', @UserId, GETDATE(), 1);
        DECLARE @cnId INT = CAST(SCOPE_IDENTITY() AS INT);
        -- the money taken goes back the way it came (counted as refunds in the cashier's day closing)
        INSERT dbo.BillRefund (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, Notes, Status, CreatedBy, CreatedDate, IsActive)
        SELECT @cnId, 'PHR', @SaleId, x.Amount, x.Mode, GETDATE(), N'Pharmacy bill cancelled ' + @saleNo, 'P', @UserId, GETDATE(), 1
          FROM (SELECT UPPER(pm.MethodCode) Mode, SUM(pd.PaidAmount) Amount FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
                  JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
                 WHERE RTRIM(ph.ModuleCode) = 'PHR' AND ph.ModuleRefId = @SaleId AND pd.IsActive = 1 GROUP BY pm.MethodCode) x
         WHERE x.Amount > 0;
        UPDATE dbo.PhSale SET Status = 'CANCELLED', BalanceDue = 0, CancelReason = @Reason, CancelledBy = @UserId, CancelledDate = GETDATE() WHERE SaleId = @SaleId;
        UPDATE dbo.PhScheduleRegister SET IsCancelled = 1 WHERE SaleId = @SaleId;
        UPDATE dbo.PaymentHeader SET BalanceDue = 0, LastModifiedDate = GETDATE(), LastModifiedBy = @UserId WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @SaleId;
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SCANCEL', @RefId = @SaleId, @UserId = @UserId;
        COMMIT;
        SELECT CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- ── credit collection ────────────────────────────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_CreditCustomers @CompanyId INT, @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CustomerId, c.CustomerName, c.Mobile, c.CreditLimit, SUM(s.BalanceDue) Outstanding, COUNT(*) OpenBills, MIN(s.SaleDate) OldestBill
      FROM dbo.PhSale s JOIN dbo.PhCustomer c ON c.CustomerId = s.CustomerId
     WHERE s.CompanyId = @CompanyId AND s.BranchId = @BranchId AND s.Status = 'POSTED' AND s.BalanceDue > 0
     GROUP BY c.CustomerId, c.CustomerName, c.Mobile, c.CreditLimit ORDER BY c.CustomerName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_OpenBills @CompanyId INT, @BranchId INT, @CustomerId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SaleId, SaleNo, SaleDate, Status, CustomerName, Mobile, NetAmount, PaidAmount, ReturnedAmount, BalanceDue
      FROM dbo.PhSale WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND CustomerId = @CustomerId AND Status = 'POSTED' AND BalanceDue > 0 ORDER BY SaleDate;
END
GO

-- @Alloc: [{ "SaleId", "Amount" }] (amounts above zero, mode and reference checked in EMR.Web). Answers DocNo (receipt no.), Error.
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Collect
    @CompanyId INT, @BranchId INT, @UserId INT, @CustomerId INT, @Method VARCHAR(10), @Reference NVARCHAR(4000) = NULL, @Alloc NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @A TABLE (Seq INT PRIMARY KEY, SaleId INT, Amount DECIMAL(18,2), Due DECIMAL(18,2), SaleNo NVARCHAR(40));
    SET @Reference = LTRIM(RTRIM(@Reference));
    BEGIN TRY
        BEGIN TRAN;
        INSERT @A (Seq, SaleId, Amount, Due, SaleNo)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.value, '$.SaleId'), JSON_VALUE(j.value, '$.Amount'), s.BalanceDue, s.SaleNo
          FROM OPENJSON(@Alloc) j
          LEFT JOIN dbo.PhSale s WITH (UPDLOCK) ON s.SaleId = JSON_VALUE(j.value, '$.SaleId') AND s.CompanyId = @CompanyId AND s.BranchId = @BranchId
                                              AND s.CustomerId = @CustomerId AND s.Status = 'POSTED';
        IF EXISTS (SELECT 1 FROM @A WHERE Due IS NULL OR Amount > Due) BEGIN ROLLBACK; SELECT CAST(NULL AS NVARCHAR(50)) AS DocNo, N'An amount is more than the bill''s balance.' AS Error; RETURN; END;
        DECLARE @receiptNo NVARCHAR(50);
        EXEC dbo.usp_Receipt_GetNextNo @BranchId = @BranchId, @ReceiptNo = @receiptNo OUTPUT;
        DECLARE @seq INT = (SELECT MIN(Seq) FROM @A), @sale INT, @v DECIMAL(18,2), @no NVARCHAR(40), @headerId INT, @pd INT;
        WHILE @seq IS NOT NULL
        BEGIN
            SELECT @sale = SaleId, @v = Amount, @no = SaleNo FROM @A WHERE Seq = @seq;
            SET @headerId = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @sale AND IsActive = 1);
            INSERT dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, UPIRefNo, CardLast4, ChequeNo, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo, CompanyId)
            SELECT @headerId, PaymentMethodId, @v, @Reference, CASE WHEN @Method = 'UPI' THEN @Reference END, CASE WHEN @Method = 'CARD' THEN RIGHT(@Reference, 4) END, CASE WHEN @Method = 'CHEQUE' THEN @Reference END,
                   GETDATE(), N'Pharmacy credit collection ' + @no, GETDATE(), @UserId, 1, @receiptNo, @CompanyId
              FROM dbo.PaymentMethodMaster WHERE UPPER(MethodCode) = @Method;
            SET @pd = CAST(SCOPE_IDENTITY() AS INT);
            UPDATE dbo.PhSale SET PaidAmount = PaidAmount + @v, BalanceDue = BalanceDue - @v, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE SaleId = @sale;
            UPDATE dbo.PaymentHeader SET TotalPaid = TotalPaid + @v, BalanceDue = BalanceDue - @v, PaymentStatus = CASE WHEN BalanceDue - @v > 0 THEN 'U' ELSE 'P' END,
                   LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
             WHERE PaymentHeaderId = @headerId;
            EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRCPT', @RefId = @pd, @UserId = @UserId;
            SET @seq = (SELECT MIN(Seq) FROM @A WHERE Seq > @seq);
        END
        COMMIT;
        SELECT @receiptNo AS DocNo, CAST(NULL AS NVARCHAR(500)) AS Error;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT CAST(NULL AS NVARCHAR(50)) AS DocNo, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO

-- a receipt: 1 its payments, 2 who paid
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Receipt @CompanyId INT, @BranchId INT, @ReceiptNo NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT pd.ReceiptNo, COALESCE(pd.PaymentDate, pd.CreatedDate) PaymentDate, pm.MethodName,
           LTRIM(ISNULL(COALESCE(NULLIF(pd.UPIRefNo, ''), NULLIF(pd.TransactionRef, ''), pd.ChequeNo) + N' · ', N'') + N'Bill ' + s.SaleNo) Ref, pd.PaidAmount Amount
      FROM dbo.PaymentDetail pd JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
      LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
     WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.ReceiptNo = @ReceiptNo AND s.CompanyId = @CompanyId AND s.BranchId = @BranchId AND pd.IsActive = 1
     ORDER BY pd.PaymentDetailId;
    SELECT TOP 1 s.CustomerName AS Name, s.Mobile FROM dbo.PaymentDetail pd
      JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId JOIN dbo.PhSale s ON s.SaleId = ph.ModuleRefId
     WHERE RTRIM(ph.ModuleCode) = 'PHR' AND pd.ReceiptNo = @ReceiptNo AND s.CompanyId = @CompanyId AND s.BranchId = @BranchId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_ScheduleRegister @CompanyId INT, @BranchId INT, @From DATE, @To DATE, @Schedule VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.EntryDate, s.SaleNo, r.ScheduleCode, i.ItemName, b.BatchNo, b.ExpiryDate, r.Qty, su.UomCode SaleUom, m.ManufacturerName,
           r.PatientName, r.PatientAddress, r.PrescriberName, r.PrescriberRegNo, r.RxNo, ISNULL(NULLIF(u.FullName, ''), u.Username) DispensedBy, r.IsCancelled
      FROM dbo.PhScheduleRegister r JOIN dbo.PhSale s ON s.SaleId = r.SaleId JOIN dbo.PhItem i ON i.ItemId = r.ItemId JOIN dbo.PhBatch b ON b.BatchId = r.BatchId
      JOIN dbo.PhUom su ON su.UomId = i.SaleUomId LEFT JOIN dbo.PhManufacturer m ON m.ManufacturerId = i.ManufacturerId LEFT JOIN dbo.Users u ON u.Id = r.DispensedBy
     WHERE r.CompanyId = @CompanyId AND r.BranchId = @BranchId AND r.EntryDate >= @From AND r.EntryDate < DATEADD(DAY, 1, @To) AND (@Schedule IS NULL OR r.ScheduleCode = @Schedule)
     ORDER BY r.EntryDate;
END
GO

PRINT 'Script 2359 applied: pharmacy sales - API stored procedures.';
GO
