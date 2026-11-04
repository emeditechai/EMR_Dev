-- ============================================================================================================
-- 2410  Pharmacy loyalty for walk-ins (after 2409): with Hospital Settings > MED > "Walk-ins are Members by Mobile",
--       a walk-in with a 10-digit mobile gets the loyalty benefit in BOTH loyalty types - the instant member discount
--       (default bill discount, not a manual discount) as well as the wallet (2409). Re-runnable.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_Save
    @CompanyId INT, @BranchId INT, @UserId INT, @Hold BIT, @CanDiscount BIT, @CanCredit BIT, @HoldId INT = NULL,
    @CustomerKind VARCHAR(10), @PatientId INT = NULL, @CustomerId INT = NULL, @CustomerName NVARCHAR(4000) = NULL, @Mobile NVARCHAR(4000) = NULL,
    @Email NVARCHAR(4000) = NULL, @Address NVARCHAR(4000) = NULL, @DoctorId INT = NULL, @DoctorName NVARCHAR(4000) = NULL, @DoctorRegNo NVARCHAR(4000) = NULL,
    @RxNo NVARCHAR(4000) = NULL, @RxDate DATE = NULL, @BillDiscPercent DECIMAL(9,4) = 0, @Remarks NVARCHAR(4000) = NULL, @HoldLabel NVARCHAR(4000) = NULL,
    @Lines NVARCHAR(MAX), @Payments NVARCHAR(MAX) = N'[]', @StoreId INT = NULL,
    -- SQLScripts/2406: OPD prescription, clinical alerts, loyalty, credit reference
    @ConsultationId INT = NULL, @RxLines NVARCHAR(MAX) = NULL, @Alerts NVARCHAR(MAX) = NULL, @RedeemPoints DECIMAL(12,2) = 0, @CreditRefNo NVARCHAR(60) = NULL,
    @RedeemOtp NVARCHAR(10) = NULL   -- SQLScripts/2409: WhatsApp OTP when the branch asks for it
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @StoreId = ISNULL(@StoreId, dbo.fn_PhDefaultStore(@BranchId, 'SELL'));
    IF @StoreId IS NULL OR dbo.fn_PhStoreOk(@BranchId, @StoreId, 'SELL') = 0
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'Choose a selling store (counter) of this branch.' AS Error; RETURN; END;
    DECLARE @today DATE = CAST(GETDATE() AS DATE), @err NVARCHAR(500);
    DECLARE @enabled BIT = 0, @lic DATE, @ndps NVARCHAR(100), @shelf INT = 30, @neg BIT = 0, @maxDisc DECIMAL(9,4) = 10, @roundOff BIT = 1;
    SELECT TOP 1 @enabled = PharmacyEnabled, @lic = PharmacyDrugLicence20BValidTo, @ndps = PharmacyNdpsLicenceNo, @shelf = PharmacyMinShelfLifeSaleDays,
           @neg = PharmacyAllowNegativeStock, @maxDisc = PharmacyMaxManualDiscountPercent, @roundOff = PharmacyRoundOffBill
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    IF ISNULL(@enabled, 0) = 0 BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy is not enabled for this branch (Hospital Settings > Pharmacy & Drug Licence).' AS Error; RETURN; END;
    IF @Hold = 0 AND @lic < @today
    BEGIN SELECT CAST(0 AS BIT) AS Success, N'The pharmacy''s drug licence expired on ' + FORMAT(@lic, 'dd-MMM-yyyy', 'en-US') + N'; sales are stopped until it is renewed in Hospital Settings.' AS Error; RETURN; END;

    DECLARE @In TABLE (Seq INT PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4), DaysSupply INT);
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.ItemId'), JSON_VALUE(value, '$.BatchId'), JSON_VALUE(value, '$.Qty'), ISNULL(JSON_VALUE(value, '$.DiscPercent'), 0),
                      NULLIF(TRY_CAST(JSON_VALUE(value, '$.DaysSupply') AS INT), 0)
                 FROM OPENJSON(@Lines);
    IF EXISTS (SELECT 1 FROM @In WHERE DaysSupply < 0 OR DaysSupply > 365) BEGIN SELECT CAST(0 AS BIT) AS Success, N'Days of supply must be between 1 and 365.' AS Error; RETURN; END;
    DECLARE @Pay TABLE (Seq INT PRIMARY KEY, Method VARCHAR(10), Amount DECIMAL(18,2), Ref NVARCHAR(200));
    INSERT @Pay SELECT CAST([key] AS INT), JSON_VALUE(value, '$.Method'), JSON_VALUE(value, '$.Amount'), JSON_VALUE(value, '$.Ref') FROM OPENJSON(ISNULL(@Payments, N'[]'));
    DECLARE @P TABLE (Seq INT IDENTITY PRIMARY KEY, ItemId INT, BatchId INT, Qty DECIMAL(18,6), Disc DECIMAL(9,4), UnitMrp DECIMAL(12,4), UnitPrice DECIMAL(12,4),
                      Amount DECIMAL(18,2), Gst DECIMAL(5,2), Taxable DECIMAL(18,2), GstAmt DECIMAL(18,2), Cost DECIMAL(12,4), Schedule VARCHAR(10), Register BIT, Narcotic BIT, ItemName NVARCHAR(200), DaysSupply INT);

    BEGIN TRY
        BEGIN TRAN;
        -- customer
        DECLARE @priceType VARCHAR(20) = 'WALKIN', @custFound BIT = 0, @custCredit BIT = 0, @custLimit DECIMAL(14,2) = 0, @custType VARCHAR(20) = NULL, @custDays INT = 30;
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
            SELECT @custFound = 1, @cn = CustomerName, @cm = Mobile, @ce = Email, @ca = Address, @ct = CustomerType, @custCredit = CreditAllowed, @custLimit = CreditLimit,
                   @custType = CustomerType, @custDays = CreditDays
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
            DECLARE @days INT = NULL;
            SELECT @item = ItemId, @batch = BatchId, @qty = Qty, @disc = Disc, @days = DaysSupply FROM @In WHERE Seq = @seq;
            SELECT @name = NULL, @active = NULL;
            SELECT @name = ItemName, @conv = Conv, @loose = Loose, @narc = Narc, @reg = Reg, @sch = Schedule, @active = Active FROM @It WHERE ItemId = @item;
            IF @name IS NULL OR @active = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item is not in the Item Master or is inactive.' AS Error; RETURN; END;
            IF @loose = 0 AND @qty % @conv <> 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is sold in full packs of ' + CAST(@conv AS NVARCHAR(10)) + N' only.' AS Error; RETURN; END;
            IF @narc = 1 AND NULLIF(LTRIM(RTRIM(@ndps)), N'') IS NULL
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, @name + N' is a Schedule X / NDPS drug: the branch has no NDPS licence in Hospital Settings.' AS Error; RETURN; END;
            DELETE @B;
            INSERT @B (BatchId, Stock, Expiry, Blocked)
            SELECT b.BatchId, s.QtyOnHand, b.ExpiryDate, b.IsBlocked FROM dbo.PhStoreStock s WITH (UPDLOCK, HOLDLOCK) JOIN dbo.PhBatch b ON b.BatchId = s.BatchId
             WHERE s.StoreId = @StoreId AND s.ItemId = @item AND (@batch IS NULL OR b.BatchId = @batch) ORDER BY b.ExpiryDate, b.BatchId;
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
                        INSERT @P (ItemId, BatchId, Qty, Disc, Schedule, Register, Narcotic, ItemName, DaysSupply) VALUES (@item, @bId, @take, @disc, @sch, @reg, @narc, @name, @days);
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
        -- SQLScripts/2408: in Discount loyalty, the member's loyalty % is part of the bill discount and is not a manual discount
        DECLARE @loyShare DECIMAL(9,4) = 0;
        -- SQLScripts/2410: a walk-in with a mobile number is a member too when the branch says so
        IF @CustomerKind IN ('PATIENT', 'CUSTOMER')
           OR (@CustomerKind = 'WALKIN' AND @Mobile LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
               AND ISNULL((SELECT TOP 1 PharmacyLoyaltyWalkinByMobile FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) = 1)
            SELECT TOP 1 @loyShare = CASE WHEN PharmacyLoyaltyEnabled = 1 AND PharmacyLoyaltyType = 'DISCOUNT'
                                          THEN CASE WHEN PharmacyLoyaltyDiscountPercent < @BillDiscPercent THEN PharmacyLoyaltyDiscountPercent ELSE @BillDiscPercent END ELSE 0 END
              FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
        SET @manualDisc = @manualDisc - ISNULL(@loyShare, 0);
        IF @Hold = 0 AND @manualDisc > @maxDisc AND @CanDiscount = 0
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Discount ' + FORMAT(@manualDisc, '0.##') + N'% is above the ' + FORMAT(@maxDisc, '0.##') + N'% allowed at the counter; a user with the Discount permission must bill it.' AS Error; RETURN; END;

        -- prescription and register
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P p JOIN @It it ON it.ItemId = p.ItemId WHERE it.Rx = 1)
           AND (LTRIM(RTRIM(ISNULL(@DoctorName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@RxNo, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'An item that needs a prescription is on the bill: enter the doctor and the prescription number.' AS Error; RETURN; END;
        IF @Hold = 0 AND EXISTS (SELECT 1 FROM @P WHERE Register = 1)
           AND (LTRIM(RTRIM(ISNULL(@CustomerName, N''))) = N'' OR LTRIM(RTRIM(ISNULL(@Address, N''))) = N'')
        BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'A Schedule H1 / X drug is on the bill: the patient''s name and address are needed for the register.' AS Error; RETURN; END;

        -- loyalty points (SQLScripts/2406): the value redeemed is a discount spread over the lines before GST
        DECLARE @loyOn BIT = 0, @loyEarn DECIMAL(8,2) = 0, @loyValue DECIMAL(8,2) = 1, @loyMin INT = 0, @loyMaxPct DECIMAL(5,2) = 0, @loyExpiry INT = 365,
                @redeemValue DECIMAL(18,2) = 0, @earned DECIMAL(12,2) = 0, @loyType VARCHAR(10) = 'POINTS', @loyPct DECIMAL(5,2) = 0, @loyDiscValue DECIMAL(18,2) = 0;
        SELECT TOP 1 @loyOn = PharmacyLoyaltyEnabled, @loyEarn = PharmacyLoyaltyEarnPer100, @loyValue = PharmacyLoyaltyPointValue, @loyMin = PharmacyLoyaltyMinRedeem,
               @loyMaxPct = PharmacyLoyaltyMaxRedeemPercent, @loyExpiry = PharmacyLoyaltyExpiryDays, @loyType = PharmacyLoyaltyType, @loyPct = PharmacyLoyaltyDiscountPercent
          FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
        -- SQLScripts/2409: wallet rules and the member (patient / customer / walk-in by mobile)
        DECLARE @wEarnPct DECIMAL(5,2) = 0, @wBasis VARCHAR(12) = 'NET', @wMinEarn DECIMAL(12,2) = 0, @wMaxEarn DECIMAL(12,2) = 0, @wEarnOnRedeem BIT = 1,
                @wLock INT = 0, @wMinBillRedeem DECIMAL(12,2) = 0, @wOtp BIT = 0, @wWalkin BIT = 0;
        SELECT TOP 1 @wEarnPct = PharmacyLoyaltyEarnPercent, @wBasis = PharmacyLoyaltyEarnBasis, @wMinEarn = PharmacyLoyaltyMinBillToEarn, @wMaxEarn = PharmacyLoyaltyMaxEarnPerBill,
               @wEarnOnRedeem = PharmacyLoyaltyEarnOnRedeemBill, @wLock = PharmacyLoyaltyLockInDays, @wMinBillRedeem = PharmacyLoyaltyMinBillToRedeem,
               @wOtp = PharmacyLoyaltyRedeemOtp, @wWalkin = PharmacyLoyaltyWalkinByMobile
          FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
        DECLARE @memMobile NVARCHAR(15) = CASE WHEN @CustomerKind = 'WALKIN' AND @wWalkin = 1 AND @Mobile LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN @Mobile END;
        DECLARE @isMember BIT = CASE WHEN @CustomerKind IN ('PATIENT', 'CUSTOMER') OR @memMobile IS NOT NULL THEN 1 ELSE 0 END;
        DECLARE @memKey NVARCHAR(40) = CASE WHEN @CustomerKind = 'PATIENT' THEN N'P' + CAST(@PatientId AS NVARCHAR(12)) WHEN @CustomerKind = 'CUSTOMER' THEN N'C' + CAST(@CustomerId AS NVARCHAR(12)) ELSE N'M' + @memMobile END;
        -- SQLScripts/2407: loyalty as a fixed discount for members (no points)
        IF @loyOn = 1 AND @loyType = 'DISCOUNT'
        BEGIN
            IF @RedeemPoints > 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Loyalty is a discount at this branch: there are no points to use.' AS Error; RETURN; END;
            -- the loyalty share of the bill discount (filled in by the counter) and the rupees it saved
            IF @loyShare > 0
            BEGIN
                SET @loyPct = @loyShare;
                SET @loyDiscValue = ISNULL((SELECT SUM(ROUND(CAST(p.Qty AS DECIMAL(38,18)) * p.UnitPrice * (1 - CAST(CASE WHEN p.Disc - @loyShare < 0 THEN 0 ELSE p.Disc - @loyShare END AS DECIMAL(38,18)) / 100), 2) - p.Amount)
                                               FROM @P p JOIN @It it ON it.ItemId = p.ItemId WHERE it.DiscOk = 1), 0);
            END
            ELSE SET @loyPct = 0;
        END
        ELSE SET @loyPct = 0;
        SET @RedeemPoints = ISNULL(@RedeemPoints, 0);
        IF @Hold = 0 AND @RedeemPoints > 0 AND @loyType <> 'DISCOUNT'
        BEGIN
            IF @loyOn = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Loyalty points are off for this branch.' AS Error; RETURN; END;
            IF @isMember = 0 BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can be used only by a loyalty member (patient, pharmacy customer' + CASE WHEN @wWalkin = 1 THEN N', or a walk-in with a mobile number' ELSE N'' END + N').' AS Error; RETURN; END;
            IF @RedeemPoints <> FLOOR(@RedeemPoints) BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Redeem whole points.' AS Error; RETURN; END;
            DECLARE @have DECIMAL(12,2) = (SELECT Available FROM dbo.fn_PhLoyaltyWallet(@CompanyId, CASE WHEN @CustomerKind = 'PATIENT' THEN @PatientId END,
                                                CASE WHEN @CustomerKind = 'CUSTOMER' THEN @CustomerId END, @memMobile));
            IF @RedeemPoints > @have BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Only ' + FORMAT(@have, '0') + N' points are available.' AS Error; RETURN; END;
            IF @have < @loyMin BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can be used from ' + CAST(@loyMin AS NVARCHAR(10)) + N' points on.' AS Error; RETURN; END;
            SET @redeemValue = ROUND(@RedeemPoints * @loyValue, 2);
            DECLARE @billBefore DECIMAL(18,2) = (SELECT SUM(Amount) FROM @P);
            IF @billBefore < @wMinBillRedeem
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can be used on a bill of ₹' + FORMAT(@wMinBillRedeem, '0.00') + N' or more.' AS Error; RETURN; END;
            IF @wOtp = 1
            BEGIN
                DECLARE @otpId INT, @otpHash VARBINARY(32), @otpTries INT;
                SELECT TOP 1 @otpId = OtpId, @otpHash = CodeHash, @otpTries = Attempts FROM dbo.PhLoyaltyOtp WITH (UPDLOCK)
                 WHERE CompanyId = @CompanyId AND MemberKey = @memKey AND UsedAt IS NULL AND ExpiresAt > GETDATE() ORDER BY OtpId DESC;
                IF @otpId IS NULL BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Send the OTP to the member''s WhatsApp and enter it to use points.' AS Error; RETURN; END;
                IF @otpTries >= 5 OR @otpHash <> HASHBYTES('SHA2_256', @memKey + N':' + ISNULL(@RedeemOtp, N''))
                BEGIN
                    UPDATE dbo.PhLoyaltyOtp SET Attempts = Attempts + 1 WHERE OtpId = @otpId;
                    COMMIT; SELECT CAST(0 AS BIT) AS Success, N'The OTP is not right.' AS Error; RETURN;
                END
                UPDATE dbo.PhLoyaltyOtp SET UsedAt = GETDATE() WHERE OtpId = @otpId;
            END
            IF @redeemValue > ROUND(@billBefore * @loyMaxPct / 100, 2)
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'Points can pay up to ' + FORMAT(@loyMaxPct, '0.##') + N'% of the bill (₹' + FORMAT(ROUND(@billBefore * @loyMaxPct / 100, 2), '0.00') + N').' AS Error; RETURN; END;
            -- spread over the lines by amount; the last line takes the paise left over
            UPDATE @P SET Amount = Amount - ROUND(CAST(Amount AS DECIMAL(38,18)) * @redeemValue / @billBefore, 2);
            UPDATE @P SET Amount = Amount - (@redeemValue - (@billBefore - (SELECT SUM(Amount) FROM @P))) WHERE Seq = (SELECT MAX(Seq) FROM @P);
            UPDATE @P SET Taxable = ROUND(CAST(Amount AS DECIMAL(38,18)) * 100 / (100 + Gst), 2);
            UPDATE @P SET GstAmt = Amount - Taxable;
        END

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
            IF @custType IN ('CORPORATE', 'INSURANCE') AND LTRIM(RTRIM(ISNULL(@CreditRefNo, N''))) = N''
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, CASE WHEN @custType = 'INSURANCE' THEN N'Enter the policy / claim number for the insurance credit bill.' ELSE N'Enter the employee ID / authorisation number for the corporate credit bill.' END AS Error; RETURN; END;
            DECLARE @overdue DATETIME = (SELECT MIN(SaleDate) FROM dbo.PhSale WHERE CustomerId = @CustomerId AND Status = 'POSTED' AND BalanceDue > 0
                                           AND SaleDate < DATEADD(DAY, -ISNULL(@custDays, 30), CAST(@today AS DATETIME)));
            IF @overdue IS NOT NULL
            BEGIN ROLLBACK; SELECT CAST(0 AS BIT) AS Success, N'This customer has a credit bill of ' + FORMAT(@overdue, 'dd-MMM-yyyy', 'en-US') + N' unpaid beyond ' + CAST(ISNULL(@custDays, 30) AS NVARCHAR(10)) + N' credit days: collect it before new credit.' AS Error; RETURN; END;
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

        UPDATE dbo.PhSale SET StoreId = @StoreId, ConsultationId = @ConsultationId, CreditRefNo = NULLIF(LTRIM(RTRIM(@CreditRefNo)), N''),
               LoyaltyRedeemPoints = CASE WHEN @Hold = 1 THEN 0 ELSE @RedeemPoints END, LoyaltyRedeemValue = CASE WHEN @Hold = 1 THEN 0 ELSE @redeemValue END,
               LoyaltyDiscountPercent = @loyPct, LoyaltyDiscountValue = @loyDiscValue
         WHERE SaleId = @saleId;
        DECLARE @ps INT = (SELECT MIN(Seq) FROM @P), @dtl INT;
        DECLARE @pItem INT, @pBatch INT, @pQty DECIMAL(18,6), @pReg BIT, @pSch VARCHAR(10);
        WHILE @ps IS NOT NULL
        BEGIN
            INSERT dbo.PhSaleDtl (SaleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, DiscPercent, Amount, GstPercent, TaxableAmount, GstAmount, UnitCost, DaysSupply)
            SELECT @saleId, ItemId, BatchId, Qty, UnitMrp, UnitPrice, Disc, Amount, Gst, Taxable, GstAmt, Cost, DaysSupply FROM @P WHERE Seq = @ps;
            SET @dtl = CAST(SCOPE_IDENTITY() AS INT);
            IF @Hold = 0
            BEGIN
                SELECT @pItem = ItemId, @pBatch = BatchId, @pQty = Qty, @pReg = Register, @pSch = Schedule FROM @P WHERE Seq = @ps;
                SET @pQty = -@pQty;
                EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @pBatch, @Qty = @pQty, @DocType = 'SALE', @DocId = @saleId, @DocNo = @saleNo, @UserId = @UserId, @AllowNegative = @neg, @StoreId = @StoreId;
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

        -- OPD prescription: what was prescribed and what was given (SQLScripts/2406)
        IF @ConsultationId IS NOT NULL AND ISJSON(@RxLines) = 1
            INSERT dbo.PhSaleRx (SaleId, ConsultationId, Seq, MedicationId, MedicationName, GenericId, Dose, Frequency, Instructions, Status, ItemId, Reason)
            SELECT @saleId, @ConsultationId, j.Seq, j.MedicationId, LEFT(ISNULL(j.MedicationName, N''), 200), j.GenericId, LEFT(j.Dose, 50), LEFT(j.Frequency, 50), LEFT(j.Instructions, 100),
                   CASE WHEN j.Status = 'DISPENSED' THEN 'DISPENSED' ELSE 'NOT_DISPENSED' END, j.ItemId, LEFT(NULLIF(LTRIM(RTRIM(j.Reason)), N''), 200)
              FROM OPENJSON(@RxLines) WITH (Seq INT, MedicationId INT, MedicationName NVARCHAR(400), GenericId INT, Dose NVARCHAR(100), Frequency NVARCHAR(100),
                                            Instructions NVARCHAR(200), Status VARCHAR(20), ItemId INT, Reason NVARCHAR(400)) j;
        -- clinical alerts shown at the counter and the reason to go ahead
        IF ISJSON(@Alerts) = 1
            INSERT dbo.PhSaleClinicalAlert (SaleId, Kind, Severity, Message, Reason, OverriddenBy)
            SELECT @saleId, LEFT(j.Kind, 15), LEFT(j.Severity, 10), LEFT(ISNULL(j.Message, N''), 500), LEFT(j.Reason, 300), @UserId
              FROM OPENJSON(@Alerts) WITH (Kind VARCHAR(20), Severity VARCHAR(20), Message NVARCHAR(1000), Reason NVARCHAR(600)) j;
        -- loyalty wallet (SQLScripts/2409): points used, then the credit % of this bill into the wallet - usable after the lock-in
        IF @loyOn = 1 AND @loyType <> 'DISCOUNT' AND @isMember = 1
        BEGIN
            DECLARE @lP INT = CASE WHEN @CustomerKind = 'PATIENT' THEN @PatientId END, @lC INT = CASE WHEN @CustomerKind = 'CUSTOMER' THEN @CustomerId END,
                    @lM NVARCHAR(15) = CASE WHEN @CustomerKind = 'WALKIN' THEN @memMobile END;
            IF @RedeemPoints > 0
                INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Mobile, Kind, Points, SaleId, Remarks, CreatedBy)
                VALUES (@CompanyId, @BranchId, @lP, @lC, @lM, 'REDEEM', -@RedeemPoints, @saleId, N'Used on bill ' + @saleNo + N' (₹' + FORMAT(@redeemValue, '0.00') + N')', @UserId);
            DECLARE @base DECIMAL(18,2) = CASE WHEN @wBasis = 'DISCOUNTABLE'
                                               THEN ISNULL((SELECT SUM(p.Amount) FROM @P p JOIN @It it ON it.ItemId = p.ItemId WHERE it.DiscOk = 1), 0) ELSE @net END;
            SET @earned = CASE WHEN @base < @wMinEarn OR (@RedeemPoints > 0 AND @wEarnOnRedeem = 0) OR @loyValue <= 0 THEN 0
                               ELSE FLOOR(@base * @wEarnPct / 100 / @loyValue) END;
            IF @wMaxEarn > 0 AND @earned > @wMaxEarn SET @earned = @wMaxEarn;
            IF @earned > 0
            BEGIN
                DECLARE @availOn DATE = DATEADD(DAY, ISNULL(@wLock, 0), @today);
                INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Mobile, Kind, Points, SaleId, AvailableOn, ExpiresOn, Remarks, CreatedBy)
                VALUES (@CompanyId, @BranchId, @lP, @lC, @lM, 'EARN', @earned, @saleId, @availOn, CASE WHEN @loyExpiry > 0 THEN DATEADD(DAY, @loyExpiry, @availOn) END,
                        N'Credited for bill ' + @saleNo + N' (' + FORMAT(@wEarnPct, '0.##') + N'% of ₹' + FORMAT(@base, '0.00') + N')', @UserId);
                UPDATE dbo.PhSale SET LoyaltyEarnedPoints = @earned WHERE SaleId = @saleId;
            END
        END
        -- refill reminders: lines with days of supply, for a buyer with a mobile number
        IF ISNULL((SELECT TOP 1 PharmacyRefillReminderEnabled FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) = 1
           AND @Mobile LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        BEGIN
            DECLARE @before INT = ISNULL((SELECT TOP 1 PharmacyRefillReminderDaysBefore FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 2);
            INSERT dbo.PhRefillReminder (CompanyId, BranchId, SaleId, SaleDtlId, ItemId, PatientId, CustomerId, Name, Mobile, RunOutDate, RemindOn)
            SELECT @CompanyId, @BranchId, @saleId, MIN(d.SaleDtlId), d.ItemId, @PatientId, @CustomerId, @CustomerName, @Mobile,
                   DATEADD(DAY, MAX(d.DaysSupply), @today),
                   CASE WHEN DATEADD(DAY, MAX(d.DaysSupply) - @before, @today) > @today THEN DATEADD(DAY, MAX(d.DaysSupply) - @before, @today) ELSE DATEADD(DAY, 1, @today) END
              FROM dbo.PhSaleDtl d WHERE d.SaleId = @saleId AND d.DaysSupply > 0 GROUP BY d.ItemId;
        END
        COMMIT;
        SELECT CAST(1 AS BIT) AS Success, CAST(NULL AS NVARCHAR(500)) AS Error, @saleId AS SaleId, @saleNo AS SaleNo, @receiptNo AS ReceiptNo, @net AS NetAmount, @change AS Change, @due AS BalanceDue,
               @earned AS PointsEarned, @RedeemPoints AS PointsRedeemed, @loyDiscValue AS LoyaltyDiscount;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() BETWEEN 51000 AND 54999 BEGIN SELECT CAST(0 AS BIT) AS Success, ERROR_MESSAGE() AS Error; RETURN; END;
        THROW;
    END CATCH
END
GO
PRINT 'Script 2410 applied: loyalty for walk-ins by mobile.';
GO
