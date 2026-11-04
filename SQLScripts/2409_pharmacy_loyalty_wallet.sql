-- ============================================================================================================
-- 2409  Pharmacy loyalty WALLET (after 2408) - Apollo-style health credits. Hospital Settings > MED > Customer.
--   Loyalty Type WALLET (stored value 'POINTS'): a credit % of each bill goes into the member's wallet as points;
--   they are used on a LATER bill (never on the bill that earned them). Type DISCOUNT = instant member discount (2407/2408).
--   Members: hospital patients, pharmacy customers and (setting) walk-ins identified by mobile number.
--   Earning rules : credit % of bill, earn basis (net bill / discount-allowed items only), min bill to earn, max per bill,
--                   earn on a bill that used points (yes/no), lock-in days (pending until the return window is over),
--                   expiry days (from when they become usable).
--   Using rules   : min balance, min bill, max % of bill, optional WhatsApp OTP, whole points.
--   Returns       : points earned are taken back and points used are given back, in proportion to the value returned;
--                   a cancelled bill's points (earned and used) stop counting.
--   Wallet        : Pharmacy > Sales > Loyalty Wallet (PHARMACY.LOYALTYWALLET: VIEW, ADJUST): members, balance
--                   (available / pending / expiring), statement, manual credit / debit with reason, total liability.
--   Notices       : WhatsApp after a bill (EMR.Web) and before points expire (usp_PhLoyalty_ExpiryDue, EMR.Web job).
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyEarnPercent') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyEarnPercent DECIMAL(5,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyEarnPercent DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyEarnBasis') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyEarnBasis VARCHAR(12) NOT NULL CONSTRAINT DF_HS_PhLoyaltyEarnBasis DEFAULT ('NET');
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyMinBillToEarn') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyMinBillToEarn DECIMAL(12,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyMinBillToEarn DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyMaxEarnPerBill') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyMaxEarnPerBill DECIMAL(12,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyMaxEarnPerBill DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyEarnOnRedeemBill') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyEarnOnRedeemBill BIT NOT NULL CONSTRAINT DF_HS_PhLoyaltyEarnOnRedeemBill DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyLockInDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyLockInDays INT NOT NULL CONSTRAINT DF_HS_PhLoyaltyLockInDays DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyMinBillToRedeem') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyMinBillToRedeem DECIMAL(12,2) NOT NULL CONSTRAINT DF_HS_PhLoyaltyMinBillToRedeem DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyRedeemOtp') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyRedeemOtp BIT NOT NULL CONSTRAINT DF_HS_PhLoyaltyRedeemOtp DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyWalkinByMobile') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyWalkinByMobile BIT NOT NULL CONSTRAINT DF_HS_PhLoyaltyWalkinByMobile DEFAULT (0);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyNotifyWhatsApp') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyNotifyWhatsApp BIT NOT NULL CONSTRAINT DF_HS_PhLoyaltyNotifyWhatsApp DEFAULT (1);
GO
IF COL_LENGTH('dbo.HospitalSettings', 'PharmacyLoyaltyExpiryReminderDays') IS NULL
    ALTER TABLE dbo.HospitalSettings ADD PharmacyLoyaltyExpiryReminderDays INT NOT NULL CONSTRAINT DF_HS_PhLoyaltyExpiryReminderDays DEFAULT (7);
GO
-- the old "points per Rs.100" becomes the wallet credit % (1 point = Rs.1 by default)
UPDATE dbo.HospitalSettings SET PharmacyLoyaltyEarnPercent = CASE WHEN PharmacyLoyaltyEarnPer100 * PharmacyLoyaltyPointValue > 100 THEN 100 ELSE PharmacyLoyaltyEarnPer100 * PharmacyLoyaltyPointValue END
 WHERE PharmacyLoyaltyEarnPercent = 1 AND PharmacyLoyaltyEarnPer100 <> 1;
GO
IF COL_LENGTH('dbo.PhLoyaltyLedger', 'Mobile') IS NULL
    ALTER TABLE dbo.PhLoyaltyLedger ADD Mobile NVARCHAR(15) NULL, AvailableOn DATE NULL, ExpiryNotifiedOn DATETIME NULL;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_PhLoyaltyLedger_Member' AND definition NOT LIKE '%Mobile%')
    ALTER TABLE dbo.PhLoyaltyLedger DROP CONSTRAINT CK_PhLoyaltyLedger_Member;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_PhLoyaltyLedger_Member')
    ALTER TABLE dbo.PhLoyaltyLedger ADD CONSTRAINT CK_PhLoyaltyLedger_Member CHECK (PatientId IS NOT NULL OR CustomerId IS NOT NULL OR Mobile IS NOT NULL);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PhLoyaltyLedger_Mobile')
    CREATE INDEX IX_PhLoyaltyLedger_Mobile ON dbo.PhLoyaltyLedger (CompanyId, Mobile) INCLUDE (Points, Kind, AvailableOn, ExpiresOn, SaleId) WHERE Mobile IS NOT NULL;
GO
IF OBJECT_ID('dbo.PhLoyaltyOtp') IS NULL
CREATE TABLE dbo.PhLoyaltyOtp (
    OtpId      INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId  INT NOT NULL,
    MemberKey  NVARCHAR(40) NOT NULL,             -- P<patientId> | C<customerId> | M<mobile>
    CodeHash   VARBINARY(32) NOT NULL,
    ExpiresAt  DATETIME NOT NULL,
    Attempts   INT NOT NULL DEFAULT 0,
    UsedAt     DATETIME NULL,
    CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO

-- ── the wallet of a member: usable now / pending (lock-in) / expiring in 30 days ──────────────────────────
-- a row counts when it has no bill or its bill is POSTED (a cancelled bill's points, earned and used, drop out)
CREATE OR ALTER FUNCTION dbo.fn_PhLoyaltyWallet (@CompanyId INT, @PatientId INT, @CustomerId INT, @Mobile NVARCHAR(15))
RETURNS TABLE
AS
RETURN
    SELECT CAST(CASE WHEN x.Avail < 0 THEN 0 ELSE x.Avail END AS DECIMAL(12,2)) AS Available, CAST(x.Pending AS DECIMAL(12,2)) AS Pending,
           CAST(CASE WHEN x.Expiring > CASE WHEN x.Avail < 0 THEN 0 ELSE x.Avail END THEN CASE WHEN x.Avail < 0 THEN 0 ELSE x.Avail END ELSE x.Expiring END AS DECIMAL(12,2)) AS ExpiringSoon,
           x.NextExpiry, CAST(x.Earned AS DECIMAL(12,2)) AS Earned, CAST(x.Used AS DECIMAL(12,2)) AS Used, CAST(x.Expired AS DECIMAL(12,2)) AS Expired
      -- a take-back of points still in lock-in carries their AvailableOn and comes off Pending, not off the usable balance
      FROM (SELECT ISNULL(SUM(CASE WHEN l.Points < 0 AND l.AvailableOn > CAST(GETDATE() AS DATE) THEN 0
                                   WHEN l.Points < 0 THEN l.Points
                                   WHEN (l.AvailableOn IS NULL OR l.AvailableOn <= CAST(GETDATE() AS DATE)) AND (l.ExpiresOn IS NULL OR l.ExpiresOn >= CAST(GETDATE() AS DATE)) THEN l.Points ELSE 0 END), 0) AS Avail,
                   ISNULL(SUM(CASE WHEN l.AvailableOn > CAST(GETDATE() AS DATE) THEN l.Points ELSE 0 END), 0) AS Pending,
                   ISNULL(SUM(CASE WHEN l.Points > 0 AND (l.AvailableOn IS NULL OR l.AvailableOn <= CAST(GETDATE() AS DATE))
                                    AND l.ExpiresOn BETWEEN CAST(GETDATE() AS DATE) AND DATEADD(DAY, 30, CAST(GETDATE() AS DATE)) THEN l.Points ELSE 0 END), 0) AS Expiring,
                   MIN(CASE WHEN l.Points > 0 AND l.ExpiresOn >= CAST(GETDATE() AS DATE) THEN l.ExpiresOn END) AS NextExpiry,
                   ISNULL(SUM(CASE WHEN l.Kind = 'EARN' THEN l.Points ELSE 0 END), 0) AS Earned,
                   ISNULL(-SUM(CASE WHEN l.Kind IN ('REDEEM') THEN l.Points ELSE 0 END), 0) AS Used,
                   ISNULL(SUM(CASE WHEN l.Points > 0 AND l.ExpiresOn < CAST(GETDATE() AS DATE) THEN l.Points ELSE 0 END), 0) AS Expired
              FROM dbo.PhLoyaltyLedger l LEFT JOIN dbo.PhSale s ON s.SaleId = l.SaleId
             WHERE l.CompanyId = @CompanyId AND (s.SaleId IS NULL OR s.Status = 'POSTED')
               AND ((@PatientId IS NOT NULL AND l.PatientId = @PatientId) OR (@CustomerId IS NOT NULL AND l.CustomerId = @CustomerId)
                    OR (@PatientId IS NULL AND @CustomerId IS NULL AND @Mobile IS NOT NULL AND l.Mobile = @Mobile AND l.PatientId IS NULL AND l.CustomerId IS NULL))) x;
GO
-- kept for 2406 callers
CREATE OR ALTER FUNCTION dbo.fn_PhLoyaltyBalance (@CompanyId INT, @PatientId INT, @CustomerId INT)
RETURNS TABLE
AS
RETURN
    SELECT Available AS Points, Earned, Used FROM dbo.fn_PhLoyaltyWallet(@CompanyId, @PatientId, @CustomerId, NULL);
GO

-- wallet and rules for the counter
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_LoyaltyBalance @CompanyId INT, @BranchId INT, @PatientId INT = NULL, @CustomerId INT = NULL, @Mobile NVARCHAR(15) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @PatientId IS NULL AND @CustomerId IS NULL AND ISNULL((SELECT TOP 1 PharmacyLoyaltyWalkinByMobile FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0) = 0
        SET @Mobile = NULL;
    SELECT w.Available AS Points, w.Pending, w.ExpiringSoon, w.NextExpiry, w.Earned, w.Used,
           ISNULL(h.PharmacyLoyaltyPointValue, 1) AS PointValue, ISNULL(h.PharmacyLoyaltyMinRedeem, 0) AS MinRedeem,
           ISNULL(h.PharmacyLoyaltyMaxRedeemPercent, 0) AS MaxRedeemPercent, ISNULL(h.PharmacyLoyaltyEnabled, 0) AS Enabled,
           ISNULL(h.PharmacyLoyaltyType, 'POINTS') AS LoyaltyType, ISNULL(h.PharmacyLoyaltyDiscountPercent, 0) AS DiscountPercent,
           ISNULL(h.PharmacyLoyaltyEarnPercent, 0) AS EarnPercent, ISNULL(h.PharmacyLoyaltyMinBillToRedeem, 0) AS MinBillToRedeem,
           ISNULL(h.PharmacyLoyaltyRedeemOtp, 0) AS RedeemOtp, ISNULL(h.PharmacyLoyaltyEarnOnRedeemBill, 1) AS EarnOnRedeemBill,
           ISNULL(h.PharmacyLoyaltyMinBillToEarn, 0) AS MinBillToEarn,
           CAST(CASE WHEN @PatientId IS NULL AND @CustomerId IS NULL AND @Mobile IS NULL THEN 0 ELSE 1 END AS BIT) AS IsMember,
           -- the member's own number (OTP and messages go only here)
           CASE WHEN @PatientId IS NOT NULL THEN (SELECT PhoneNumber FROM dbo.PatientMaster WHERE PatientId = @PatientId AND CompanyId = @CompanyId)
                WHEN @CustomerId IS NOT NULL THEN (SELECT Mobile FROM dbo.PhCustomer WHERE CustomerId = @CustomerId AND CompanyId = @CompanyId)
                ELSE @Mobile END AS Phone
      FROM dbo.fn_PhLoyaltyWallet(@CompanyId, @PatientId, @CustomerId, @Mobile) w
      OUTER APPLY (SELECT TOP 1 * FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC) h;
END
GO

-- OTP before using points (the code is made and sent by EMR.Web; only its hash is kept, valid 10 minutes)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhLoyalty_OtpCreate @CompanyId INT, @MemberKey NVARCHAR(40), @Code NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    IF (SELECT COUNT(*) FROM dbo.PhLoyaltyOtp WHERE CompanyId = @CompanyId AND MemberKey = @MemberKey AND CreatedDate > DATEADD(MINUTE, -10, GETDATE())) >= 5
    BEGIN SELECT N'Too many codes asked for in 10 minutes. Try again later.' AS Error; RETURN; END;
    UPDATE dbo.PhLoyaltyOtp SET UsedAt = GETDATE() WHERE CompanyId = @CompanyId AND MemberKey = @MemberKey AND UsedAt IS NULL;   -- older codes stop working
    INSERT dbo.PhLoyaltyOtp (CompanyId, MemberKey, CodeHash, ExpiresAt) VALUES (@CompanyId, @MemberKey, HASHBYTES('SHA2_256', @MemberKey + N':' + @Code), DATEADD(MINUTE, 10, GETDATE()));
    SELECT CAST(NULL AS NVARCHAR(200)) AS Error;
END
GO

-- ── counter sale: loyalty wallet ──
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
        IF @CustomerKind IN ('PATIENT', 'CUSTOMER')
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
            IF @CustomerKind IN ('PATIENT', 'CUSTOMER') AND @loyShare > 0
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

-- ── sale return: loyalty wallet ──
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhSale_SaveReturn
    @CompanyId INT, @BranchId INT, @UserId INT, @SaleId INT, @ReasonId INT, @RefundMode VARCHAR(10), @RefundRef NVARCHAR(4000) = NULL, @Remarks NVARCHAR(4000) = NULL, @Lines NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @days INT = 7, @loose BIT = 0, @roundOff BIT = 1;
    SELECT TOP 1 @days = PharmacySaleReturnDays, @loose = PharmacyLooseReturnAllowed, @roundOff = PharmacyRoundOffBill FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
    DECLARE @In TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, Qty DECIMAL(18,6), BatchNo NVARCHAR(60));
    INSERT @In SELECT CAST([key] AS INT), JSON_VALUE(value, '$.SaleDtlId'), JSON_VALUE(value, '$.Qty'), NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.BatchNo'))), N'') FROM OPENJSON(@Lines);
    DECLARE @R TABLE (Seq INT PRIMARY KEY, SaleDtlId INT, ItemId INT, BatchId INT, Q DECIMAL(18,6), Amt DECIMAL(18,2), Tax DECIMAL(18,2), G DECIMAL(18,2), UnitCost DECIMAL(12,4));
    BEGIN TRY
        BEGIN TRAN;
        DECLARE @status VARCHAR(10), @saleDate DATETIME, @balance DECIMAL(18,2);
        DECLARE @saleStore INT = (SELECT StoreId FROM dbo.PhSale WHERE SaleId = @SaleId AND BranchId = @BranchId);
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
            DECLARE @packBatch NVARCHAR(60) = NULL;
            SELECT @dtlId = SaleDtlId, @q = Qty, @packBatch = BatchNo FROM @In WHERE Seq = @seq;
            SET @found = 0;
            SELECT @found = 1, @nm = ItemName, @sch = ScheduleCode, @ret = IsReturnable, @cold = IsColdChain, @exp = ExpiryDate, @lq = Qty, @rq = ReturnedQty, @conv = ConversionQty,
                   @lamt = Amount, @ltax = TaxableAmount FROM @L WHERE SaleDtlId = @dtlId;
            IF @found = 0 BEGIN ROLLBACK; SELECT 0 AS Id, N'An item is not on this bill.' AS Error; RETURN; END;
            IF @ret = 0 OR @sch IN ('X', 'NDPS') BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N' is not returnable.' AS Error; RETURN; END;
            -- SQLScripts/2406: the batch printed on the pack brought back must be the batch sold on this bill
            IF @packBatch IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @L l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId WHERE l.SaleDtlId = @dtlId AND UPPER(b.BatchNo) = UPPER(@packBatch))
            BEGIN ROLLBACK; SELECT 0 AS Id, @nm + N': batch ' + @packBatch + N' on the pack is not the batch sold on this bill (' +
                       (SELECT b.BatchNo FROM @L l JOIN dbo.PhBatch b ON b.BatchId = l.BatchId WHERE l.SaleDtlId = @dtlId) + N'). Not taken back.' AS Error; RETURN; END;
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
            EXEC dbo.usp_PhStock_Move @BranchId = @BranchId, @BatchId = @rBatch, @Qty = @q, @DocType = 'SRET', @DocId = @rid, @DocNo = @no, @UserId = @UserId, @AllowNegative = 1,
                 @StoreId = @saleStore;
            SET @rs = (SELECT MIN(Seq) FROM @R WHERE Seq > @rs);
        END
        UPDATE dbo.PhSale SET ReturnedAmount = ReturnedAmount + @net, BalanceDue = BalanceDue - @adjusted, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE SaleId = @SaleId;
        UPDATE dbo.PaymentHeader SET BalanceDue = (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId),
               PaymentStatus = CASE WHEN (SELECT BalanceDue FROM dbo.PhSale WHERE SaleId = @SaleId) > 0 THEN 'U' ELSE 'P' END,
               LastModifiedDate = GETDATE(), LastModifiedBy = @UserId
         WHERE RTRIM(ModuleCode) = 'PHR' AND ModuleRefId = @SaleId;
        EXEC dbo.usp_Ph_PostSaleLedger @Kind = 'SRET', @RefId = @rid, @UserId = @UserId;
        -- loyalty wallet (SQLScripts/2409): in proportion to the value returned, points earned on the bill are taken back and
        -- points used on it are given back
        DECLARE @earnedOnBill DECIMAL(12,2), @usedOnBill DECIMAL(12,2), @billNet DECIMAL(18,2), @lp INT, @lc INT, @lm NVARCHAR(15);
        SELECT @earnedOnBill = LoyaltyEarnedPoints, @usedOnBill = LoyaltyRedeemPoints, @billNet = NetAmount, @lp = PatientId, @lc = CustomerId FROM dbo.PhSale WHERE SaleId = @SaleId;
        SET @lm = (SELECT TOP 1 Mobile FROM dbo.PhLoyaltyLedger WHERE SaleId = @SaleId AND PatientId IS NULL AND CustomerId IS NULL AND Mobile IS NOT NULL);
        IF @billNet > 0 AND (@lp IS NOT NULL OR @lc IS NOT NULL OR @lm IS NOT NULL)
        BEGIN
            DECLARE @lExp INT = ISNULL((SELECT TOP 1 PharmacyLoyaltyExpiryDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0);
            IF ISNULL(@earnedOnBill, 0) > 0
            BEGIN
                DECLARE @back DECIMAL(12,2) = CEILING(@earnedOnBill * @net / @billNet);
                DECLARE @alreadyBack DECIMAL(12,2) = ISNULL((SELECT -SUM(Points) FROM dbo.PhLoyaltyLedger WHERE SaleId = @SaleId AND Kind = 'REVERSE'), 0);
                IF @back > @earnedOnBill - @alreadyBack SET @back = @earnedOnBill - @alreadyBack;
                IF @back > 0
                    INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Mobile, Kind, Points, SaleId, ReturnId, AvailableOn, Remarks, CreatedBy)
                    VALUES (@CompanyId, @BranchId, @lp, @lc, @lm, 'REVERSE', -@back, @SaleId, @rid,
                            (SELECT MAX(AvailableOn) FROM dbo.PhLoyaltyLedger WHERE SaleId = @SaleId AND Kind = 'EARN'), N'Taken back - return ' + @no, @UserId);
            END
            IF ISNULL(@usedOnBill, 0) > 0
            BEGIN
                DECLARE @give DECIMAL(12,2) = FLOOR(@usedOnBill * @net / @billNet);
                DECLARE @alreadyGiven DECIMAL(12,2) = ISNULL((SELECT SUM(Points) FROM dbo.PhLoyaltyLedger WHERE SaleId = @SaleId AND Kind = 'REFUND'), 0);
                IF @give > @usedOnBill - @alreadyGiven SET @give = @usedOnBill - @alreadyGiven;
                IF @give > 0
                    INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Mobile, Kind, Points, SaleId, ReturnId, AvailableOn, ExpiresOn, Remarks, CreatedBy)
                    VALUES (@CompanyId, @BranchId, @lp, @lc, @lm, 'REFUND', @give, @SaleId, @rid, @today, CASE WHEN @lExp > 0 THEN DATEADD(DAY, @lExp, @today) END,
                            N'Points used given back - return ' + @no, @UserId);
            END
        END
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

-- counter settings: + wallet rules the POS needs
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
           PharmacyRefillReminderEnabled RefillReminderEnabled,
           PharmacyLoyaltyType LoyaltyType, PharmacyLoyaltyDiscountPercent LoyaltyDiscountPercent,
           PharmacyLoyaltyEarnPercent LoyaltyEarnPercent, PharmacyLoyaltyWalkinByMobile LoyaltyWalkinByMobile, PharmacyLoyaltyRedeemOtp LoyaltyRedeemOtp,
           PharmacyLoyaltyNotifyWhatsApp LoyaltyNotifyWhatsApp, PharmacyLoyaltyLockInDays LoyaltyLockInDays
      FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC;
END
GO

-- ── Loyalty Wallet page ──────────────────────────────────────────────────────────────────────────────────
-- members with a wallet: 1 the members (search by name / mobile / UHID), 2 totals (liability)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhLoyalty_Members @CompanyId INT, @BranchId INT, @Q NVARCHAR(100) = NULL, @Take INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    DECLARE @like NVARCHAR(110) = N'%' + @Q + N'%', @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @pv DECIMAL(8,2) = ISNULL((SELECT TOP 1 PharmacyLoyaltyPointValue FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 1);
    ;WITH l AS (
        SELECT CASE WHEN l.PatientId IS NOT NULL THEN 'PATIENT' WHEN l.CustomerId IS NOT NULL THEN 'CUSTOMER' ELSE 'MOBILE' END AS MemberType,
               l.PatientId, l.CustomerId, CASE WHEN l.PatientId IS NULL AND l.CustomerId IS NULL THEN l.Mobile END AS Mobile, l.Points, l.Kind, l.AvailableOn, l.ExpiresOn, l.CreatedDate
          FROM dbo.PhLoyaltyLedger l LEFT JOIN dbo.PhSale s ON s.SaleId = l.SaleId
         WHERE l.CompanyId = @CompanyId AND (s.SaleId IS NULL OR s.Status = 'POSTED')
    ), m AS (
        SELECT MemberType, PatientId, CustomerId, Mobile,
               SUM(CASE WHEN Points < 0 AND AvailableOn > @today THEN 0 WHEN Points < 0 THEN Points
                        WHEN (AvailableOn IS NULL OR AvailableOn <= @today) AND (ExpiresOn IS NULL OR ExpiresOn >= @today) THEN Points ELSE 0 END) AS Avail,
               SUM(CASE WHEN AvailableOn > @today THEN Points ELSE 0 END) AS Pending,
               SUM(CASE WHEN Kind = 'EARN' THEN Points ELSE 0 END) AS Earned, -SUM(CASE WHEN Kind = 'REDEEM' THEN Points ELSE 0 END) AS Used,
               MAX(CreatedDate) AS LastActivity
          FROM l GROUP BY MemberType, PatientId, CustomerId, Mobile
    ), n AS (
        SELECT m.*, CAST(CASE WHEN m.Avail < 0 THEN 0 ELSE m.Avail END AS DECIMAL(12,2)) AS Available,
               COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, ''))), ''), c.CustomerName,
                        (SELECT TOP 1 s.CustomerName FROM dbo.PhSale s WHERE s.CompanyId = @CompanyId AND s.Mobile = m.Mobile AND s.CustomerName IS NOT NULL ORDER BY s.SaleId DESC)) AS Name,
               COALESCE(p.PhoneNumber, c.Mobile, m.Mobile) AS Phone, p.PatientCode AS Uhid
          FROM m LEFT JOIN dbo.PatientMaster p ON p.PatientId = m.PatientId LEFT JOIN dbo.PhCustomer c ON c.CustomerId = m.CustomerId
    )
    SELECT * INTO #N FROM n;
    SELECT TOP (@Take) MemberType, PatientId, CustomerId, Mobile, Name, Phone, Uhid, Available, CAST(Pending AS DECIMAL(12,2)) AS Pending,
           CAST(Earned AS DECIMAL(12,2)) AS Earned, CAST(Used AS DECIMAL(12,2)) AS Used, CAST(Available * @pv AS DECIMAL(14,2)) AS Value, LastActivity
      FROM #N WHERE @Q IS NULL OR Name LIKE @like OR Phone LIKE @like OR Uhid = @Q
     ORDER BY LastActivity DESC;
    SELECT COUNT(*) AS Members, ISNULL(SUM(Available), 0) AS Points, CAST(ISNULL(SUM(Available), 0) * @pv AS DECIMAL(14,2)) AS Liability,
           ISNULL(SUM(Pending), 0) AS PendingPoints, ISNULL(SUM(Earned), 0) AS Earned, ISNULL(SUM(Used), 0) AS Used, @pv AS PointValue
      FROM #N;
END
GO

-- one member's wallet: 1 balance, 2 statement (newest first)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhLoyalty_Statement @CompanyId INT, @PatientId INT = NULL, @CustomerId INT = NULL, @Mobile NVARCHAR(15) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM dbo.fn_PhLoyaltyWallet(@CompanyId, @PatientId, @CustomerId, @Mobile);
    SELECT l.LoyaltyId, l.CreatedDate, l.Kind, l.Points, l.AvailableOn, l.ExpiresOn, l.Remarks, s.SaleNo, s.Status AS SaleStatus, r.ReturnNo,
           b.BranchName, (SELECT TOP 1 ISNULL(NULLIF(FullName, ''), Username) FROM dbo.Users WHERE Id = l.CreatedBy) AS ByName,
           CASE WHEN s.SaleId IS NOT NULL AND s.Status <> 'POSTED' THEN N'Bill cancelled - not counted'
                WHEN l.Points > 0 AND l.AvailableOn > CAST(GETDATE() AS DATE) THEN N'Pending until ' + FORMAT(l.AvailableOn, 'dd-MMM-yyyy', 'en-US')
                WHEN l.Points > 0 AND l.ExpiresOn < CAST(GETDATE() AS DATE) THEN N'Expired'
                ELSE N'' END AS State
      FROM dbo.PhLoyaltyLedger l
      LEFT JOIN dbo.PhSale s ON s.SaleId = l.SaleId LEFT JOIN dbo.PhSaleReturn r ON r.ReturnId = l.ReturnId
      LEFT JOIN dbo.BranchMaster b ON b.BranchID = l.BranchId
     WHERE l.CompanyId = @CompanyId
       AND ((@PatientId IS NOT NULL AND l.PatientId = @PatientId) OR (@CustomerId IS NOT NULL AND l.CustomerId = @CustomerId)
            OR (@PatientId IS NULL AND @CustomerId IS NULL AND l.Mobile = @Mobile AND l.PatientId IS NULL AND l.CustomerId IS NULL))
     ORDER BY l.LoyaltyId DESC;
END
GO

-- manual credit (+) / debit (-) with a reason (goodwill, correction, campaign)
CREATE OR ALTER PROCEDURE dbo.usp_Api_PhLoyalty_Adjust
    @CompanyId INT, @BranchId INT, @UserId INT, @PatientId INT = NULL, @CustomerId INT = NULL, @Mobile NVARCHAR(15) = NULL, @Points DECIMAL(12,2), @Reason NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @PatientId IS NULL AND @CustomerId IS NULL AND ISNULL(@Mobile, N'') NOT LIKE '[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
    BEGIN SELECT N'Pick the member.' AS Error; RETURN; END;
    IF ISNULL(@Points, 0) = 0 OR @Points <> FLOOR(@Points) OR ABS(@Points) > 100000 BEGIN SELECT N'Enter whole points (+ to credit, - to debit).' AS Error; RETURN; END;
    IF LEN(LTRIM(RTRIM(ISNULL(@Reason, N'')))) < 3 BEGIN SELECT N'Give the reason for the adjustment.' AS Error; RETURN; END;
    IF @PatientId IS NOT NULL SELECT @CustomerId = NULL, @Mobile = NULL;
    IF @CustomerId IS NOT NULL SET @Mobile = NULL;
    BEGIN TRAN;
    IF @Points < 0 AND -@Points > (SELECT Available FROM dbo.fn_PhLoyaltyWallet(@CompanyId, @PatientId, @CustomerId, @Mobile))
    BEGIN ROLLBACK; SELECT N'Cannot debit more than the points available.' AS Error; RETURN; END;
    DECLARE @exp INT = ISNULL((SELECT TOP 1 PharmacyLoyaltyExpiryDays FROM dbo.HospitalSettings WHERE BranchId = @BranchId ORDER BY IsActive DESC), 0);
    INSERT dbo.PhLoyaltyLedger (CompanyId, BranchId, PatientId, CustomerId, Mobile, Kind, Points, AvailableOn, ExpiresOn, Remarks, CreatedBy)
    VALUES (@CompanyId, @BranchId, @PatientId, @CustomerId, @Mobile, 'ADJUST', @Points, CASE WHEN @Points > 0 THEN CAST(GETDATE() AS DATE) END,
            CASE WHEN @Points > 0 AND @exp > 0 THEN DATEADD(DAY, @exp, CAST(GETDATE() AS DATE)) END, LTRIM(RTRIM(@Reason)), @UserId);
    COMMIT;
    SELECT CAST(NULL AS NVARCHAR(200)) AS Error;
END
GO

-- points about to expire (once per credited row): claimed here, sent by EMR.Web
CREATE OR ALTER PROCEDURE dbo.usp_PhLoyalty_ExpiryDue @Take INT = 50
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @C TABLE (LoyaltyId BIGINT PRIMARY KEY);
    UPDATE TOP (@Take * 4) l SET ExpiryNotifiedOn = GETDATE()
    OUTPUT inserted.LoyaltyId INTO @C
      FROM dbo.PhLoyaltyLedger l WITH (READPAST, UPDLOCK)
      LEFT JOIN dbo.PhSale s ON s.SaleId = l.SaleId
     CROSS APPLY (SELECT TOP 1 h.PharmacyLoyaltyEnabled, h.PharmacyLoyaltyNotifyWhatsApp, h.PharmacyLoyaltyExpiryReminderDays, h.PharmacyLoyaltyType
                    FROM dbo.HospitalSettings h WHERE h.BranchId = l.BranchId ORDER BY h.IsActive DESC) h
     WHERE l.Points > 0 AND l.ExpiryNotifiedOn IS NULL AND l.ExpiresOn >= @today AND (s.SaleId IS NULL OR s.Status = 'POSTED')
       AND h.PharmacyLoyaltyEnabled = 1 AND h.PharmacyLoyaltyNotifyWhatsApp = 1 AND h.PharmacyLoyaltyType <> 'DISCOUNT' AND h.PharmacyLoyaltyExpiryReminderDays > 0
       AND l.ExpiresOn <= DATEADD(DAY, h.PharmacyLoyaltyExpiryReminderDays, @today);
    -- one message per member: points still usable that expire by the latest of the claimed dates
    SELECT x.CompanyId, x.BranchId, x.PatientId, x.CustomerId, x.Mobile, MAX(x.ExpiresOn) AS ExpiresOn,
           COALESCE(MAX(p.PhoneNumber), MAX(c.Mobile), x.Mobile) AS Phone,
           COALESCE(NULLIF(MAX(LTRIM(RTRIM(ISNULL(p.FirstName, '') + ' ' + ISNULL(p.LastName, '')))), ''), MAX(c.CustomerName),
                    (SELECT TOP 1 s2.CustomerName FROM dbo.PhSale s2 WHERE s2.CompanyId = x.CompanyId AND s2.Mobile = x.Mobile AND s2.CustomerName IS NOT NULL ORDER BY s2.SaleId DESC)) AS Name,
           MAX(w.Available) AS Available, MAX(w.ExpiringSoon) AS Expiring,
           MAX(ISNULL(NULLIF(h.PharmacyName, N''), h.HotelName)) AS PharmacyName, MAX(h.PharmacyLoyaltyPointValue) AS PointValue
      FROM @C k JOIN dbo.PhLoyaltyLedger x ON x.LoyaltyId = k.LoyaltyId
      LEFT JOIN dbo.PatientMaster p ON p.PatientId = x.PatientId LEFT JOIN dbo.PhCustomer c ON c.CustomerId = x.CustomerId
     CROSS APPLY dbo.fn_PhLoyaltyWallet(x.CompanyId, x.PatientId, x.CustomerId, CASE WHEN x.PatientId IS NULL AND x.CustomerId IS NULL THEN x.Mobile END) w
     OUTER APPLY (SELECT TOP 1 * FROM dbo.HospitalSettings WHERE BranchId = x.BranchId ORDER BY IsActive DESC) h
     GROUP BY x.CompanyId, x.BranchId, x.PatientId, x.CustomerId, x.Mobile
    HAVING MAX(w.Available) > 0;
END
GO

-- ── pages: Pharmacy > Sales > Loyalty Wallet; POS: wallet by mobile, OTP ─────────────────────────────────
DECLARE @co INT, @menu INT, @page INT, @view INT, @adj INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'PHARMACY.SALES' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'PHARMACY.LOYALTYWALLET', @Title = N'Loyalty Wallet',
             @Controller = N'PhLoyalty', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 60, @Icon = N'bi bi-wallet2 me-2', @Page_ID = @page OUTPUT;
        SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
        SET @adj = NULL;
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ADJUST', @Title = N'Credit / debit points manually', @Sort_Order = 20, @Control_ID = @adj OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhLoyalty', @Action = N'Index', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhLoyalty', @Action = N'Members', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'PhLoyalty', @Action = N'Statement', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @adj, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhLoyalty', @Action = N'Adjust', @Source = 'SEED';
    END
    SET @page = NULL; SET @view = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'PHARMACY.POS' AND CompanyId = @co;
    SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @view IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'POST', @Controller = N'PhSales', @Action = N'LoyaltyOtp', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2409 applied: Pharmacy loyalty wallet.';
GO
