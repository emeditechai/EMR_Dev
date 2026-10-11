-- ============================================================================
-- Migration: 2236_membership_points_b2c_lab.sql
-- Description: Membership card points - earn and redeem on B2C LAB bills (industry pattern, "Patient Membership Card"
--   plan, phase 3). Builds on the membership module (MembershipPlan / MembershipCard / MembershipCardMember /
--   MembershipLedger, script 2224 of the membership work).
--
--   Card for a bill: the active, in-date card whose member is the bill's patient or has the bill patient's phone
--   number. Points belong to the card (a family card shares one pool); the running totals are also kept on the card's
--   primary patient: PatientMaster.MembershipPoints and MembershipPointsValue (Rs).
--
--   Redeem (payment mode "Membership Points"): with an OTP sent to the primary member's mobile; capped by the plan's
--     Max Redeem % of the bill, the bill's Min Redeem Bill Amount, what is still due and the card balance; points are
--     taken from the oldest earned first. The bill keeps its amount and revenue; the points line is a receipt.
--   Earn: when the bill is fully paid - the plan's Points Earn % of what was paid in money (not with points), at
--     Point Value Rs per point, expiring after the plan's Points Expiry Days.
--   Cancellation / refund: earned points are brought in line with what is paid on the bill as it stands (REVERSE),
--     and points used beyond the reduced bill are given back (RESTORE, a negative points line on the bill).
--   Expiry: points not used by their expiry date are taken out (EXPIRE).
--   History: MembershipLedger (EARN / REDEEM / RESTORE / REVERSE / EXPIRE besides ISSUE / RENEW ...), each credit row
--     keeps what is left of it (RemainingPoints) for oldest-first use; every row carries the bill (PaymentHeaderId).
--   Bill: PaymentHeader.MembershipCardId, PointsRedeemed, PointsRedeemedAmount, PointsEarned.
--   Accounting: earn  Dr Membership Points Expense / Cr Membership Points Liability; redeem  Dr Liability / Cr Patient
--     Receivable (the points receipt); restore the reverse; expire / reverse  Dr Liability / Cr Expense.
--   Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ── columns ─────────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.PatientMaster', 'MembershipPoints') IS NULL
    ALTER TABLE dbo.PatientMaster ADD MembershipPoints DECIMAL(12,2) NOT NULL CONSTRAINT DF_PatientMaster_MembershipPoints DEFAULT (0);
IF COL_LENGTH('dbo.PatientMaster', 'MembershipPointsValue') IS NULL
    ALTER TABLE dbo.PatientMaster ADD MembershipPointsValue DECIMAL(12,2) NOT NULL CONSTRAINT DF_PatientMaster_MembershipPointsValue DEFAULT (0);

IF COL_LENGTH('dbo.PaymentHeader', 'MembershipCardId') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD MembershipCardId INT NULL;
IF COL_LENGTH('dbo.PaymentHeader', 'PointsRedeemed') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD PointsRedeemed DECIMAL(12,2) NOT NULL CONSTRAINT DF_PaymentHeader_PointsRedeemed DEFAULT (0);
IF COL_LENGTH('dbo.PaymentHeader', 'PointsRedeemedAmount') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD PointsRedeemedAmount DECIMAL(12,2) NOT NULL CONSTRAINT DF_PaymentHeader_PointsRedeemedAmount DEFAULT (0);
IF COL_LENGTH('dbo.PaymentHeader', 'PointsEarned') IS NULL
    ALTER TABLE dbo.PaymentHeader ADD PointsEarned DECIMAL(12,2) NOT NULL CONSTRAINT DF_PaymentHeader_PointsEarned DEFAULT (0);

IF COL_LENGTH('dbo.MembershipLedger', 'RemainingPoints') IS NULL
    ALTER TABLE dbo.MembershipLedger ADD RemainingPoints DECIMAL(12,2) NULL;   -- credit rows: points not yet used / expired
IF COL_LENGTH('dbo.MembershipLedger', 'PaymentDetailId') IS NULL
    ALTER TABLE dbo.MembershipLedger ADD PaymentDetailId INT NULL;             -- the points line of a bill (REDEEM / RESTORE)
GO

-- RESTORE (points given back after a bill is cancelled) joins the card ledger's transaction types
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipLedger_TxnType' AND parent_object_id = OBJECT_ID('dbo.MembershipLedger')
               AND definition LIKE '%RESTORE%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MembershipLedger_TxnType' AND parent_object_id = OBJECT_ID('dbo.MembershipLedger'))
        ALTER TABLE dbo.MembershipLedger DROP CONSTRAINT CK_MembershipLedger_TxnType;
    ALTER TABLE dbo.MembershipLedger ADD CONSTRAINT CK_MembershipLedger_TxnType CHECK (TxnType IN
        ('ISSUE', 'RENEW', 'EARN', 'REDEEM', 'EXPIRE', 'REVERSE', 'ADJUST', 'DISCOUNT', 'MEMBER', 'STATUS', 'REMINDER', 'RESTORE'));
END
GO

-- credit rows written before this script: what is left of them is all of them
UPDATE dbo.MembershipLedger SET RemainingPoints = Points WHERE RemainingPoints IS NULL AND Points > 0 AND TxnType IN ('ISSUE', 'RENEW', 'WELCOME', 'ADJUST', 'BONUS');
GO

IF OBJECT_ID('dbo.MembershipRedeemOtp') IS NULL
CREATE TABLE dbo.MembershipRedeemOtp (
    OtpId               INT IDENTITY(1,1) CONSTRAINT PK_MembershipRedeemOtp PRIMARY KEY,
    CardId              INT           NOT NULL,
    Points              DECIMAL(12,2) NOT NULL,           -- the OTP authorises this many points
    SentTo              NVARCHAR(30)  NULL,               -- primary member's mobile
    CodeHash            VARBINARY(32) NULL,               -- SHA2_256 of 'OtpId:code'; the code itself is never stored
    ExpiresOn           DATETIME      NOT NULL,
    Attempts            INT           NOT NULL CONSTRAINT DF_MembershipRedeemOtp_Attempts DEFAULT (0),
    VerifiedOn          DATETIME      NULL,
    UsedOn              DATETIME      NULL,
    UsedPaymentHeaderId INT           NULL,
    Status              VARCHAR(12)   NOT NULL CONSTRAINT DF_MembershipRedeemOtp_Status DEFAULT ('SENT'),  -- SENT / VERIFIED / USED / SUPERSEDED / EXPIRED / LOCKED
    BranchId            INT           NULL,
    CreatedBy           INT           NULL,
    CreatedDate         DATETIME      NOT NULL CONSTRAINT DF_MembershipRedeemOtp_CreatedDate DEFAULT (GETDATE()));
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MembershipRedeemOtp_Card' AND object_id = OBJECT_ID('dbo.MembershipRedeemOtp'))
    CREATE INDEX IX_MembershipRedeemOtp_Card ON dbo.MembershipRedeemOtp (CardId, CreatedDate);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MembershipLedger_Remaining' AND object_id = OBJECT_ID('dbo.MembershipLedger'))
    CREATE INDEX IX_MembershipLedger_Remaining ON dbo.MembershipLedger (CardId, ExpiresOn) INCLUDE (RemainingPoints) WHERE RemainingPoints > 0;
GO

-- ── payment method & ledgers ────────────────────────────────────────────────
-- internal mode: never offered as a tile (IsActive = 0); the points line of a bill is written by the server only
IF NOT EXISTS (SELECT 1 FROM dbo.PaymentMethodMaster WHERE MethodCode = 'POINTS')
    INSERT INTO dbo.PaymentMethodMaster (MethodName, MethodCode, RequiresRef, RequiresChequeNo, RequiresBankName, RequiresUPIRef, RequiresCardLast4, DisplayOrder, IsActive, CreatedDate, CompanyId)
    VALUES ('Membership Points', 'POINTS', 0, 0, 0, 0, 0, 99, 0, GETDATE(), 1);
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    SELECT 'Membership Points Liability', LedgerGroupId, 0, 'Cr', 1, GETDATE() FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Current Liabilities';
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses')
    INSERT INTO dbo.Acc_LedgerGroup (GroupName, GroupType) VALUES ('Indirect Expenses', 'Expense');
IF NOT EXISTS (SELECT 1 FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Expense')
    INSERT INTO dbo.Acc_LedgerMaster (LedgerName, LedgerGroupId, OpeningBalance, OpeningBalanceType, IsActive, CreatedDate)
    SELECT 'Membership Points Expense', LedgerGroupId, 0, 'Dr', 1, GETDATE() FROM dbo.Acc_LedgerGroup WHERE GroupName = 'Indirect Expenses';
GO

-- ── running totals on the primary patient ───────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Membership_SyncPatientTotals
    @CardId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Primary INT = (SELECT PrimaryPatientId FROM dbo.MembershipCard WHERE CardId = @CardId);
    IF @Primary IS NULL RETURN;
    -- every live card the patient is the primary member of (a renewed card has handed its points on)
    UPDATE p SET
        MembershipPoints      = ISNULL(x.Points, 0),
        MembershipPointsValue = ISNULL(x.PointsValue, 0)
    FROM dbo.PatientMaster p
    OUTER APPLY (SELECT SUM(c.PointsBalance) AS Points, SUM(ROUND(c.PointsBalance * ISNULL(pl.PointValue, 1), 2)) AS PointsValue
                 FROM dbo.MembershipCard c INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
                 WHERE c.PrimaryPatientId = p.PatientId AND c.Status IN ('Active', 'Blocked')) x
    WHERE p.PatientId = @Primary;
END;
GO

-- ── take points out of a card, oldest (earliest expiry) first ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_Membership_ConsumePoints
    @CardId INT,
    @Points DECIMAL(12,2),
    @PreferLedgerId BIGINT = NULL,      -- use this credit row first (reversing an earn takes back those points)
    @Taken DECIMAL(12,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Taken = 0;
    DECLARE @left DECIMAL(12,2) = @Points, @id BIGINT, @rem DECIMAL(12,2), @use DECIMAL(12,2);
    WHILE @left > 0
    BEGIN
        SET @id = NULL;
        SELECT TOP 1 @id = LedgerId, @rem = RemainingPoints
        FROM dbo.MembershipLedger WITH (UPDLOCK, ROWLOCK)
        WHERE CardId = @CardId AND RemainingPoints > 0
        ORDER BY CASE WHEN LedgerId = @PreferLedgerId THEN 0 ELSE 1 END, ISNULL(ExpiresOn, '9999-12-31'), LedgerId;
        IF @id IS NULL BREAK;
        SET @use = CASE WHEN @rem < @left THEN @rem ELSE @left END;
        UPDATE dbo.MembershipLedger SET RemainingPoints = RemainingPoints - @use WHERE LedgerId = @id;
        SET @left -= @use; SET @Taken += @use;
    END
END;
GO

-- ── the card of a bill's patient: by patient, or by the bill patient's phone ─
CREATE OR ALTER PROCEDURE dbo.usp_Membership_CardForPatient
    @PatientId INT = NULL,
    @Phone     NVARCHAR(30) = NULL,
    @CompanyId INT = NULL,
    @CardId    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Phone = NULLIF(LTRIM(RTRIM(@Phone)), '');
    IF @Phone IS NULL AND @PatientId IS NOT NULL
        SELECT @Phone = NULLIF(LTRIM(RTRIM(PhoneNumber)), '') FROM dbo.PatientMaster WHERE PatientId = @PatientId;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT TOP 1 @CardId = c.CardId
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId AND pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0
    INNER JOIN dbo.MembershipCardMember m ON m.CardId = c.CardId AND m.IsActive = 1
    INNER JOIN dbo.PatientMaster mp ON mp.PatientId = m.PatientId
    WHERE c.Status = 'Active' AND @Today BETWEEN c.ValidFrom AND c.ValidTo
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND ((@PatientId IS NOT NULL AND m.PatientId = @PatientId)
           OR (@Phone IS NOT NULL AND LTRIM(RTRIM(mp.PhoneNumber)) = @Phone))
    ORDER BY CASE WHEN m.PatientId = @PatientId THEN 0 ELSE 1 END, CASE WHEN m.IsPrimary = 1 THEN 0 ELSE 1 END, c.ValidTo DESC, c.CardId DESC;
END;
GO

-- ── card details for the payment screen ─────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Membership_CardForBilling
    @PatientId INT = NULL,
    @Phone     NVARCHAR(30) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CardId INT;
    EXEC dbo.usp_Membership_CardForPatient @PatientId = @PatientId, @Phone = @Phone, @CompanyId = @CompanyId, @CardId = @CardId OUTPUT;
    SELECT c.CardId, c.CardNo, c.ValidFrom, c.ValidTo, c.Status,
           pl.PlanCode, pl.PlanName, pl.PlanType,
           CAST(c.PointsBalance AS DECIMAL(12,2)) AS PointsBalance,
           CAST(ISNULL(pl.PointValue, 1) AS DECIMAL(12,2)) AS PointValue,
           CAST(ROUND(c.PointsBalance * ISNULL(pl.PointValue, 1), 2) AS DECIMAL(12,2)) AS PointsValue,
           CAST(ISNULL(pl.PointsEarnPercent, 0) AS DECIMAL(6,2)) AS PointsEarnPercent,
           CAST(ISNULL(pl.MaxRedeemPercent, 0) AS DECIMAL(6,2)) AS MaxRedeemPercent,
           CAST(ISNULL(pl.MinRedeemBillAmount, 0) AS DECIMAL(12,2)) AS MinRedeemBillAmount,
           ISNULL(pl.PointsExpiryDays, 365) AS PointsExpiryDays,
           LTRIM(RTRIM(ISNULL(pp.FirstName, '') + ' ' + ISNULL(pp.LastName, ''))) AS PrimaryName,
           -- the OTP goes to this mobile; shown masked
           CASE WHEN LEN(LTRIM(RTRIM(pp.PhoneNumber))) >= 4 THEN REPLICATE('x', LEN(LTRIM(RTRIM(pp.PhoneNumber))) - 4) + RIGHT(LTRIM(RTRIM(pp.PhoneNumber)), 4) END AS PrimaryPhoneMasked
    FROM dbo.MembershipCard c
    INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
    LEFT JOIN dbo.PatientMaster pp ON pp.PatientId = c.PrimaryPatientId
    WHERE c.CardId = @CardId;
END;
GO

-- ── OTP: create (the code is returned once, to be sent) and verify ──────────
CREATE OR ALTER PROCEDURE dbo.usp_Membership_RedeemOtpCreate
    @CardId   INT,
    @Points   DECIMAL(12,2),
    @BranchId INT = NULL,
    @UserId   INT = NULL,
    @OtpId    INT OUTPUT,
    @Code     VARCHAR(6) OUTPUT,
    @SentTo   NVARCHAR(30) OUTPUT,
    @Email    NVARCHAR(200) OUTPUT,
    @Name     NVARCHAR(200) OUTPUT,
    @CardNo   NVARCHAR(50) OUTPUT,
    @ValueRs  DECIMAL(12,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;   -- checks first; the OTP row is written in its own short transaction below
    DECLARE @Bal DECIMAL(12,2), @Status VARCHAR(20), @From DATE, @To DATE, @Pv DECIMAL(12,2), @Msg NVARCHAR(300), @Today DATE = CAST(GETDATE() AS DATE),
            @MaxPct DECIMAL(6,2), @PlanOn BIT;
    SELECT @Bal = c.PointsBalance, @Status = c.Status, @From = c.ValidFrom, @To = c.ValidTo, @CardNo = c.CardNo, @Pv = ISNULL(pl.PointValue, 0),
           @MaxPct = ISNULL(pl.MaxRedeemPercent, 0), @PlanOn = CASE WHEN pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0 THEN 1 ELSE 0 END,
           @SentTo = NULLIF(LTRIM(RTRIM(pp.PhoneNumber)), ''), @Email = NULLIF(LTRIM(RTRIM(pp.EmailId)), ''),
           @Name = LTRIM(RTRIM(ISNULL(pp.FirstName, '') + ' ' + ISNULL(pp.LastName, '')))
    FROM dbo.MembershipCard c INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId
    LEFT JOIN dbo.PatientMaster pp ON pp.PatientId = c.PrimaryPatientId
    WHERE c.CardId = @CardId;
    IF @Status IS NULL THROW 50300, 'Membership card not found.', 1;
    IF @Status <> 'Active' OR @Today NOT BETWEEN @From AND @To THROW 50301, 'The membership card is not active or not valid today.', 1;
    -- plan settings (Membership Plan configuration): the plan must be active and allow redemption
    IF @PlanOn = 0 THROW 50305, 'The membership plan of this card is not active.', 1;
    IF @MaxPct <= 0 THROW 50306, 'This membership plan does not allow redeeming points (Max Redeem percent is 0).', 1;
    IF @Pv <= 0 THROW 50307, 'This membership plan has no point value set, so points cannot be redeemed.', 1;
    IF @Points IS NULL OR @Points <= 0 OR @Points <> FLOOR(@Points) THROW 50302, 'Enter the points to redeem as a whole number.', 1;
    IF @Points > @Bal
    BEGIN
        SET @Msg = CONCAT(N'The card has only ', CAST(@Bal AS VARCHAR(20)), N' points.'); THROW 50302, @Msg, 1;
    END
    IF @SentTo IS NULL THROW 50303, 'The card holder has no mobile number to send the OTP to.', 1;
    IF (SELECT COUNT(*) FROM dbo.MembershipRedeemOtp WHERE CardId = @CardId AND CreatedDate > DATEADD(MINUTE, -10, GETDATE())) >= 5
        THROW 50304, 'Too many OTPs for this card in the last 10 minutes. Please wait and try again.', 1;

    BEGIN TRAN;
        UPDATE dbo.MembershipRedeemOtp SET Status = 'SUPERSEDED' WHERE CardId = @CardId AND Status IN ('SENT', 'VERIFIED');
        SET @Code = RIGHT('000000' + CAST(ABS(CAST(CRYPT_GEN_RANDOM(4) AS INT)) % 1000000 AS VARCHAR(10)), 6);
        INSERT INTO dbo.MembershipRedeemOtp (CardId, Points, SentTo, ExpiresOn, BranchId, CreatedBy)
        VALUES (@CardId, @Points, @SentTo, DATEADD(MINUTE, 10, GETDATE()), @BranchId, @UserId);
        SET @OtpId = SCOPE_IDENTITY();
        UPDATE dbo.MembershipRedeemOtp SET CodeHash = HASHBYTES('SHA2_256', CONCAT(@OtpId, ':', @Code)) WHERE OtpId = @OtpId;
    COMMIT;
    SET @ValueRs = ROUND(@Points * @Pv, 2);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Membership_RedeemOtpVerify
    @OtpId  INT,
    @CardId INT,
    @Points DECIMAL(12,2),
    @Code   VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @row INT, @status VARCHAR(12), @exp DATETIME, @att INT, @hash VARBINARY(32), @pts DECIMAL(12,2);
    SELECT @row = OtpId, @status = Status, @exp = ExpiresOn, @att = Attempts, @hash = CodeHash, @pts = Points
    FROM dbo.MembershipRedeemOtp WITH (UPDLOCK, ROWLOCK) WHERE OtpId = @OtpId AND CardId = @CardId;
    IF @row IS NULL THROW 50310, 'OTP not found. Send a new OTP.', 1;
    IF @status = 'VERIFIED' AND @pts = @Points AND @exp > GETDATE() RETURN;   -- already verified (a retried save)
    IF @status <> 'SENT' THROW 50311, 'This OTP is no longer valid. Send a new OTP.', 1;
    IF @exp <= GETDATE() BEGIN UPDATE dbo.MembershipRedeemOtp SET Status = 'EXPIRED' WHERE OtpId = @OtpId; THROW 50312, 'The OTP has expired. Send a new OTP.', 1; END
    IF @pts <> @Points THROW 50313, 'The OTP was sent for a different number of points. Send a new OTP for these points.', 1;
    IF @hash IS NULL OR @hash <> HASHBYTES('SHA2_256', CONCAT(@OtpId, ':', LTRIM(RTRIM(@Code))))
    BEGIN
        UPDATE dbo.MembershipRedeemOtp SET Attempts = Attempts + 1, Status = CASE WHEN Attempts + 1 >= 5 THEN 'LOCKED' ELSE Status END WHERE OtpId = @OtpId;
        IF @att + 1 >= 5 THROW 50314, 'Wrong OTP entered too many times. Send a new OTP.', 1;
        THROW 50315, 'The OTP is not correct.', 1;
    END
    UPDATE dbo.MembershipRedeemOtp SET Status = 'VERIFIED', VerifiedOn = GETDATE(), Attempts = Attempts + 1 WHERE OtpId = @OtpId;
END;
GO

-- ── redeem points on a bill (inside the payment transaction) ────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Membership_RedeemOnBill
    @PaymentHeaderId INT,
    @CardId          INT,
    @Points          DECIMAL(12,2),
    @OtpId           INT,
    @ReceiptNo       NVARCHAR(50),
    @BranchId        INT,
    @UserId          INT,
    @RedeemAmount    DECIMAL(12,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Msg NVARCHAR(400), @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @Module VARCHAR(5), @RefId INT, @Net DECIMAL(18,2), @Received DECIMAL(18,2), @Redeemed DECIMAL(18,2), @PatientId INT, @IsB2B BIT, @Active BIT, @BillNo NVARCHAR(60);
    SELECT @Module = RTRIM(ph.ModuleCode), @RefId = ph.ModuleRefId, @Net = ph.NetAmount, @Redeemed = ph.PointsRedeemedAmount
    FROM dbo.PaymentHeader ph WITH (UPDLOCK, ROWLOCK) WHERE ph.PaymentHeaderId = @PaymentHeaderId AND ph.IsActive = 1;
    IF @Module IS NULL OR @Module <> 'LAB' THROW 50320, 'Membership points can be redeemed on LAB bills only.', 1;
    SELECT @PatientId = PatientId, @IsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @Active = CAST(ISNULL(IsActive, 0) AS BIT), @BillNo = BillNo FROM dbo.LabOrder WHERE LabOrderId = @RefId;
    IF @IsB2B = 1 THROW 50320, 'Membership points can be redeemed on B2C bills only.', 1;
    IF @Active = 0 THROW 50320, 'This bill has been cancelled.', 1;

    -- the card must be the card of this bill's patient (by patient or phone), active and valid today
    DECLARE @BillCard INT;
    EXEC dbo.usp_Membership_CardForPatient @PatientId = @PatientId, @CardId = @BillCard OUTPUT;
    IF @BillCard IS NULL OR @BillCard <> @CardId THROW 50321, 'This membership card does not belong to the bill''s patient, or is not active today.', 1;

    -- the OTP was verified for exactly these points and is used once
    IF NOT EXISTS (SELECT 1 FROM dbo.MembershipRedeemOtp WITH (UPDLOCK) WHERE OtpId = @OtpId AND CardId = @CardId AND Status = 'VERIFIED' AND Points = @Points AND ExpiresOn > GETDATE())
        THROW 50322, 'The OTP is not verified for these points. Send and enter a new OTP.', 1;

    DECLARE @Bal DECIMAL(12,2), @Pv DECIMAL(12,2), @MaxPct DECIMAL(6,2), @MinBill DECIMAL(12,2), @CardNo NVARCHAR(50), @PlanOn BIT;
    SELECT @Bal = c.PointsBalance, @Pv = ISNULL(pl.PointValue, 0), @MaxPct = ISNULL(pl.MaxRedeemPercent, 0), @MinBill = ISNULL(pl.MinRedeemBillAmount, 0), @CardNo = c.CardNo,
           @PlanOn = CASE WHEN pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0 THEN 1 ELSE 0 END
    FROM dbo.MembershipCard c WITH (UPDLOCK, ROWLOCK) INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId WHERE c.CardId = @CardId;
    -- every plan setting (Membership Plan configuration) is checked here, whatever the screen sent
    IF @PlanOn = 0 THROW 50305, 'The membership plan of this card is not active.', 1;
    IF @MaxPct <= 0 THROW 50306, 'This membership plan does not allow redeeming points (Max Redeem percent is 0).', 1;
    IF @Pv <= 0 THROW 50307, 'This membership plan has no point value set, so points cannot be redeemed.', 1;
    IF @Points <= 0 OR @Points <> FLOOR(@Points) THROW 50323, 'Points to redeem must be a whole number.', 1;
    IF @Points > @Bal BEGIN SET @Msg = CONCAT(N'The card has only ', CAST(@Bal AS VARCHAR(20)), N' points.'); THROW 50323, @Msg, 1; END
    IF @Net < @MinBill BEGIN SET @Msg = CONCAT(N'Points can be redeemed on bills of Rs ', CAST(@MinBill AS VARCHAR(20)), N' or more.'); THROW 50324, @Msg, 1; END

    SET @RedeemAmount = ROUND(@Points * @Pv, 2);
    DECLARE @Cap DECIMAL(18,2) = ROUND(@Net * @MaxPct / 100.0, 2);
    IF @Redeemed + @RedeemAmount > @Cap + 0.001
    BEGIN
        SET @Msg = CONCAT(N'Points can pay at most ', CAST(@MaxPct AS VARCHAR(10)), N' percent of this bill (Rs ', CAST(@Cap AS VARCHAR(20)), N')',
                          CASE WHEN @Redeemed > 0 THEN CONCAT(N'; Rs ', CAST(@Redeemed AS VARCHAR(20)), N' already paid with points') ELSE N'' END, N'.');
        THROW 50325, @Msg, 1;
    END
    SELECT @Received = ISNULL((SELECT SUM(PaidAmount) FROM dbo.PaymentDetail WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1), 0)
                     - ISNULL((SELECT SUM(RefundAmount) FROM dbo.BillRefund WHERE ModuleCode = 'LAB' AND ModuleRefId = @RefId AND IsActive = 1), 0);
    IF @RedeemAmount > @Net - @Received + 0.001
    BEGIN
        SET @Msg = CONCAT(N'Points worth Rs ', CAST(@RedeemAmount AS VARCHAR(20)), N' are more than the Rs ', CAST(@Net - @Received AS VARCHAR(20)), N' still due.');
        THROW 50326, @Msg, 1;
    END

    DECLARE @Taken DECIMAL(12,2), @DetailId INT, @MethodId INT = (SELECT TOP 1 PaymentMethodId FROM dbo.PaymentMethodMaster WHERE MethodCode = 'POINTS');
    EXEC dbo.usp_Membership_ConsumePoints @CardId = @CardId, @Points = @Points, @Taken = @Taken OUTPUT;
    IF @Taken < @Points THROW 50323, 'The card does not have enough points left.', 1;

    INSERT INTO dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
    VALUES (@PaymentHeaderId, @MethodId, @RedeemAmount, 'MC:' + @CardNo, GETDATE(),
            CONCAT('Membership points redeemed: ', CAST(@Points AS VARCHAR(20)), ' points, card ', @CardNo), GETDATE(), @UserId, 1, @ReceiptNo);
    SET @DetailId = SCOPE_IDENTITY();

    UPDATE dbo.MembershipCard SET PointsBalance = PointsBalance - @Points WHERE CardId = @CardId;
    INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy, PaymentDetailId)
    SELECT @CardId, @PatientId, ISNULL(@BranchId, 1), @PaymentHeaderId, @ReceiptNo, 'REDEEM', -@Points, @RedeemAmount, NULL, c.PointsBalance,
           CONCAT(CAST(@Points AS VARCHAR(20)), ' points (Rs ', CAST(@RedeemAmount AS VARCHAR(20)), ') redeemed on LAB bill ', @BillNo, ', receipt ', @ReceiptNo), @UserId, @DetailId
    FROM dbo.MembershipCard c WHERE c.CardId = @CardId;

    UPDATE dbo.PaymentHeader SET MembershipCardId = @CardId, PointsRedeemed = PointsRedeemed + @Points, PointsRedeemedAmount = PointsRedeemedAmount + @RedeemAmount
    WHERE PaymentHeaderId = @PaymentHeaderId;
    UPDATE dbo.MembershipRedeemOtp SET Status = 'USED', UsedOn = GETDATE(), UsedPaymentHeaderId = @PaymentHeaderId WHERE OtpId = @OtpId;

    -- accounting: Dr Membership Points Liability / Cr Patient Receivable (the points receipt)
    EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'RECEIPT', @RefId = @DetailId, @UserId = @UserId;
    EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @CardId;
END;
GO

-- ── bring a bill's points in line: earn when fully paid, reverse / restore after a cancellation or refund ──
CREATE OR ALTER PROCEDURE dbo.usp_Membership_SyncBill
    @PaymentHeaderId INT,
    @UserId          INT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Module VARCHAR(5), @RefId INT, @Net DECIMAL(18,2), @CardId INT, @Earned DECIMAL(12,2), @BranchId INT, @Today DATE = CAST(GETDATE() AS DATE), @NowDt DATETIME = GETDATE();
    SELECT @Module = RTRIM(ModuleCode), @RefId = ModuleRefId, @Net = ISNULL(NetAmount, 0), @CardId = MembershipCardId, @Earned = PointsEarned, @BranchId = ISNULL(BranchId, 1)
    FROM dbo.PaymentHeader WITH (UPDLOCK, ROWLOCK) WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1;
    IF @Module IS NULL OR @Module <> 'LAB' RETURN;
    DECLARE @PatientId INT, @IsB2B BIT, @BillNo NVARCHAR(60), @BillDate DATE;
    SELECT @PatientId = PatientId, @IsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @BillNo = BillNo, @BillDate = CAST(CreatedDate AS DATE) FROM dbo.LabOrder WHERE LabOrderId = @RefId;
    IF @IsB2B = 1 RETURN;

    DECLARE @PointsMethod INT = (SELECT TOP 1 PaymentMethodId FROM dbo.PaymentMethodMaster WHERE MethodCode = 'POINTS');
    DECLARE @PointsPaid DECIMAL(18,2) = ISNULL((SELECT SUM(PaidAmount) FROM dbo.PaymentDetail WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1 AND PaymentMethodId = @PointsMethod), 0);
    DECLARE @CashPaid DECIMAL(18,2) = ISNULL((SELECT SUM(PaidAmount) FROM dbo.PaymentDetail WHERE PaymentHeaderId = @PaymentHeaderId AND IsActive = 1 AND PaymentMethodId <> @PointsMethod), 0)
                                    - ISNULL((SELECT SUM(RefundAmount) FROM dbo.BillRefund WHERE ModuleCode = 'LAB' AND ModuleRefId = @RefId AND IsActive = 1), 0);

    -- the card: the one already on the bill, else the patient's active card (needed to earn)
    IF @CardId IS NULL
    BEGIN
        EXEC dbo.usp_Membership_CardForPatient @PatientId = @PatientId, @CardId = @CardId OUTPUT;
        IF @CardId IS NULL RETURN;
    END
    DECLARE @Pv DECIMAL(12,2), @EarnPct DECIMAL(6,2), @ExpDays INT, @CardStatus VARCHAR(20), @VFrom DATE, @VTo DATE, @PlanOn BIT;
    SELECT @Pv = ISNULL(pl.PointValue, 1), @EarnPct = ISNULL(pl.PointsEarnPercent, 0), @ExpDays = CASE WHEN ISNULL(pl.PointsExpiryDays, 0) > 0 THEN pl.PointsExpiryDays ELSE 365 END,
           @CardStatus = c.Status, @VFrom = c.ValidFrom, @VTo = c.ValidTo, @PlanOn = CASE WHEN pl.IsActive = 1 AND ISNULL(pl.IsDeleted, 0) = 0 THEN 1 ELSE 0 END
    FROM dbo.MembershipCard c WITH (UPDLOCK, ROWLOCK) INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId WHERE c.CardId = @CardId;
    IF ISNULL(@Pv, 0) <= 0 SET @Pv = 1;
    -- earning needs a live card on an active plan with Points Earn % above 0 (an earn already made can still be reduced)
    -- and a bill billed on or after the card's start (a bill paid before the card existed never earns)
    DECLARE @CardLive BIT = CASE WHEN @CardStatus = 'Active' AND @Today BETWEEN @VFrom AND @VTo AND @PlanOn = 1 AND @EarnPct > 0
                                  AND ISNULL(@BillDate, @Today) >= @VFrom THEN 1 ELSE 0 END;
    DECLARE @Bal DECIMAL(12,2), @Pts DECIMAL(12,2), @Amt DECIMAL(12,2), @Taken DECIMAL(12,2), @LedgerId BIGINT, @AccId BIGINT, @Narr NVARCHAR(500), @DetailId INT;
    DECLARE @Liab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
    DECLARE @Exp INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Expense');
    DECLARE @Jv INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');

    -- 1. points used beyond the bill as it stands (after a cancellation) go back to the card
    IF @PointsPaid > @Net + 0.001
    BEGIN
        SET @Amt = @PointsPaid - CASE WHEN @Net > 0 THEN @Net ELSE 0 END;
        SET @Pts = FLOOR(@Amt / @Pv);
        SET @Amt = ROUND(@Pts * @Pv, 2);
        IF @Pts > 0
        BEGIN
            INSERT INTO dbo.PaymentDetail (PaymentHeaderId, PaymentMethodId, PaidAmount, TransactionRef, PaymentDate, Notes, CreatedDate, CreatedBy, IsActive, ReceiptNo)
            SELECT @PaymentHeaderId, @PointsMethod, -@Amt, 'MC:' + CardNo, GETDATE(), CONCAT('Membership points restored: ', CAST(@Pts AS VARCHAR(20)), ' points to card ', CardNo), GETDATE(), @UserId, 1, NULL
            FROM dbo.MembershipCard WHERE CardId = @CardId;
            SET @DetailId = SCOPE_IDENTITY();
            UPDATE dbo.MembershipCard SET PointsBalance = PointsBalance + @Pts WHERE CardId = @CardId;
            SELECT @Bal = PointsBalance FROM dbo.MembershipCard WHERE CardId = @CardId;
            INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy, RemainingPoints, PaymentDetailId)
            VALUES (@CardId, @PatientId, @BranchId, @PaymentHeaderId, NULL, 'RESTORE', @Pts, @Amt, DATEADD(DAY, @ExpDays, @Today), @Bal,
                    CONCAT(CAST(@Pts AS VARCHAR(20)), ' points (Rs ', CAST(@Amt AS VARCHAR(20)), ') given back - LAB bill ', @BillNo, ' reduced by cancellation'), @UserId, @Pts, @DetailId);
            UPDATE dbo.PaymentHeader SET PointsRedeemed = CASE WHEN PointsRedeemed - @Pts < 0 THEN 0 ELSE PointsRedeemed - @Pts END,
                                         PointsRedeemedAmount = CASE WHEN PointsRedeemedAmount - @Amt < 0 THEN 0 ELSE PointsRedeemedAmount - @Amt END
            WHERE PaymentHeaderId = @PaymentHeaderId;
            -- accounting: Dr Patient Receivable / Cr Membership Points Liability
            EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'RECEIPT', @RefId = @DetailId, @UserId = @UserId;
            SET @PointsPaid = @PointsPaid - @Amt;
            -- the bill's paid / due / status follow what it has received now
            DECLARE @Recv DECIMAL(18,2) = @CashPaid + @PointsPaid;
            UPDATE dbo.PaymentHeader SET TotalPaid = @Recv,
                   BalanceDue = CASE WHEN @Net - @Recv > 0 THEN @Net - @Recv ELSE 0 END,
                   PaymentStatus = CASE WHEN @Recv >= @Net THEN 'P' WHEN @Recv > 0 THEN 'R' ELSE 'U' END,
                   LastModifiedDate = GETDATE()
            WHERE PaymentHeaderId = @PaymentHeaderId;
        END
    END

    -- 2. earned points: the plan's % of what was paid in money, once the bill is fully paid
    DECLARE @FullyPaid BIT = CASE WHEN @Net > 0 AND @CashPaid + @PointsPaid >= @Net - 0.001 THEN 1 ELSE 0 END;
    DECLARE @Base DECIMAL(18,2) = CASE WHEN @FullyPaid = 1 THEN
                                     CASE WHEN @CashPaid < @Net - @PointsPaid THEN @CashPaid ELSE @Net - @PointsPaid END ELSE 0 END;
    IF @Base < 0 SET @Base = 0;
    DECLARE @Target DECIMAL(12,2) = FLOOR(@Base * @EarnPct / 100.0 / @Pv);
    -- a bill earns while its card is live; an earn already made is only ever reduced
    IF @Target > @Earned AND @CardLive = 0 SET @Target = @Earned;
    DECLARE @Diff DECIMAL(12,2) = @Target - @Earned;

    IF @Diff > 0
    BEGIN
        SET @Amt = ROUND(@Diff * @Pv, 2);
        UPDATE dbo.MembershipCard SET PointsBalance = PointsBalance + @Diff WHERE CardId = @CardId;
        SELECT @Bal = PointsBalance FROM dbo.MembershipCard WHERE CardId = @CardId;
        INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy, RemainingPoints)
        VALUES (@CardId, @PatientId, @BranchId, @PaymentHeaderId, NULL, 'EARN', @Diff, @Amt, DATEADD(DAY, @ExpDays, @Today), @Bal,
                CONCAT(CAST(@Diff AS VARCHAR(20)), ' points earned (', CAST(@EarnPct AS VARCHAR(10)), '% of Rs ', CAST(@Base AS VARCHAR(20)), ') on LAB bill ', @BillNo,
                       ', valid till ', CONVERT(VARCHAR(11), DATEADD(DAY, @ExpDays, @Today), 106)), @UserId, @Diff);
        SET @LedgerId = SCOPE_IDENTITY();
        UPDATE dbo.PaymentHeader SET MembershipCardId = @CardId, PointsEarned = PointsEarned + @Diff WHERE PaymentHeaderId = @PaymentHeaderId;
        IF @Liab IS NOT NULL AND @Exp IS NOT NULL AND @Jv IS NOT NULL AND @Amt > 0
        BEGIN
            SET @Narr = CONCAT('Membership points earned on LAB Bill ', @BillNo);
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Jv, @TransactionDate = @NowDt, @ReferenceType = 'MEM_EARN', @ReferenceId = @LedgerId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Exp, @CreditLedgerId = @Liab,
                 @CreatedBy = @UserId, @NewTransactionId = @AccId OUTPUT;
        END
    END
    ELSE IF @Diff < 0
    BEGIN
        -- take the points back (those earned on this bill first); never below what the card still has
        DECLARE @EarnRow BIGINT = (SELECT TOP 1 LedgerId FROM dbo.MembershipLedger WHERE PaymentHeaderId = @PaymentHeaderId AND TxnType = 'EARN' ORDER BY LedgerId DESC);
        DECLARE @TakeBack DECIMAL(12,2) = -@Diff;
        EXEC dbo.usp_Membership_ConsumePoints @CardId = @CardId, @Points = @TakeBack, @PreferLedgerId = @EarnRow, @Taken = @Taken OUTPUT;
        IF @Taken > 0
        BEGIN
            SET @Amt = ROUND(@Taken * @Pv, 2);
            UPDATE dbo.MembershipCard SET PointsBalance = PointsBalance - @Taken WHERE CardId = @CardId;
            SELECT @Bal = PointsBalance FROM dbo.MembershipCard WHERE CardId = @CardId;
            INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
            VALUES (@CardId, @PatientId, @BranchId, @PaymentHeaderId, NULL, 'REVERSE', -@Taken, @Amt, NULL, @Bal,
                    CONCAT(CAST(@Taken AS VARCHAR(20)), ' earned points taken back - LAB bill ', @BillNo, ' cancelled / refunded',
                           CASE WHEN @Taken < -@Diff THEN CONCAT(' (', CAST(-@Diff - @Taken AS VARCHAR(20)), ' already used)') ELSE '' END), @UserId);
            SET @LedgerId = SCOPE_IDENTITY();
            UPDATE dbo.PaymentHeader SET PointsEarned = PointsEarned - @Taken WHERE PaymentHeaderId = @PaymentHeaderId;
            IF @Liab IS NOT NULL AND @Exp IS NOT NULL AND @Jv IS NOT NULL AND @Amt > 0
            BEGIN
                SET @Narr = CONCAT('Membership points reversed on LAB Bill ', @BillNo);
                EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Jv, @TransactionDate = @NowDt, @ReferenceType = 'MEM_REVERSE', @ReferenceId = @LedgerId,
                     @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Liab, @CreditLedgerId = @Exp,
                     @CreatedBy = @UserId, @NewTransactionId = @AccId OUTPUT;
            END
        END
    END

    EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @CardId;
END;
GO

-- ── expiry: points not used by their expiry date ────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Membership_ExpirePoints
    @UserId INT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @NowDt DATETIME = GETDATE();
    DECLARE @Today DATE = CAST(GETDATE() AS DATE), @CardId INT, @Pts DECIMAL(12,2), @Pv DECIMAL(12,2), @Amt DECIMAL(12,2), @Bal DECIMAL(12,2),
            @Primary INT, @Branch INT, @LedgerId BIGINT, @AccId BIGINT, @Narr NVARCHAR(400), @n INT = 0;
    DECLARE @Liab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
    DECLARE @Exp INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Expense');
    DECLARE @Jv INT = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');

    DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT CardId FROM dbo.MembershipLedger WHERE RemainingPoints > 0 AND ExpiresOn < @Today;
    OPEN cc; FETCH NEXT FROM cc INTO @CardId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
            SELECT @Pts = ISNULL(SUM(RemainingPoints), 0) FROM dbo.MembershipLedger WITH (UPDLOCK) WHERE CardId = @CardId AND RemainingPoints > 0 AND ExpiresOn < @Today;
            IF @Pts > 0
            BEGIN
                UPDATE dbo.MembershipLedger SET RemainingPoints = 0 WHERE CardId = @CardId AND RemainingPoints > 0 AND ExpiresOn < @Today;
                SELECT @Pv = ISNULL(pl.PointValue, 1), @Primary = c.PrimaryPatientId, @Branch = c.IssueBranchId
                FROM dbo.MembershipCard c INNER JOIN dbo.MembershipPlan pl ON pl.PlanId = c.PlanId WHERE c.CardId = @CardId;
                UPDATE dbo.MembershipCard SET PointsBalance = CASE WHEN PointsBalance - @Pts < 0 THEN 0 ELSE PointsBalance - @Pts END WHERE CardId = @CardId;
                SELECT @Bal = PointsBalance FROM dbo.MembershipCard WHERE CardId = @CardId;
                SET @Amt = ROUND(@Pts * @Pv, 2);
                INSERT INTO dbo.MembershipLedger (CardId, PatientId, BranchId, PaymentHeaderId, ReceiptNo, TxnType, Points, Amount, ExpiresOn, BalanceAfter, Narration, CreatedBy)
                VALUES (@CardId, @Primary, ISNULL(@Branch, 1), NULL, NULL, 'EXPIRE', -@Pts, @Amt, NULL, @Bal,
                        CONCAT(CAST(@Pts AS VARCHAR(20)), ' points expired (not used by their expiry date)'), @UserId);
                SET @LedgerId = SCOPE_IDENTITY();
                IF @Liab IS NOT NULL AND @Exp IS NOT NULL AND @Jv IS NOT NULL AND @Amt > 0
                BEGIN
                    SET @Narr = CONCAT('Membership points expired - card ', (SELECT CardNo FROM dbo.MembershipCard WHERE CardId = @CardId));
                    SET @Branch = ISNULL(@Branch, 1);
                    EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Jv, @TransactionDate = @NowDt, @ReferenceType = 'MEM_EXPIRE', @ReferenceId = @LedgerId,
                         @BranchId = @Branch, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Liab, @CreditLedgerId = @Exp,
                         @CreatedBy = @UserId, @NewTransactionId = @AccId OUTPUT;
                END
                EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @CardId;
                SET @n += 1;
            END
        COMMIT;
        FETCH NEXT FROM cc INTO @CardId;
    END
    CLOSE cc; DEALLOCATE cc;
    SELECT @n AS CardsExpired;
END;
GO

-- running totals for the cards that exist today
DECLARE @c INT;
DECLARE cs CURSOR LOCAL FAST_FORWARD FOR SELECT CardId FROM dbo.MembershipCard;
OPEN cs; FETCH NEXT FROM cs INTO @c;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Membership_SyncPatientTotals @CardId = @c; FETCH NEXT FROM cs INTO @c; END
CLOSE cs; DEALLOCATE cs;
GO

-- ── accounting, cancellation and refund hooks ──────────────────────────────
-- ── the posting procedure ───────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Ledger_PostBillMoney
    @Kind     VARCHAR(10),          -- RECEIPT | ADJUST | REFUND | CANCEL
    @RefId    INT,                  -- PaymentDetailId | PaymentHeaderId | RefundId | CancellationId
    @UserId   INT = 1,
    @TxDate   DATETIME = NULL       -- default: when it happened (receipt / refund) or now (adjust)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Receivable INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Patient Receivable');
    DECLARE @Cash INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Cash Account');
    DECLARE @Bank INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Bank Account');
    DECLARE @Disc INT       = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Discount Allowed');
    DECLARE @RoundOff INT   = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Round Off');
    DECLARE @Receipt INT    = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Receipt');
    DECLARE @Journal INT    = (SELECT TOP 1 VoucherTypeId FROM dbo.Acc_VoucherType WHERE VoucherTypeName = 'Credit Note');
    IF @Receivable IS NULL OR @Cash IS NULL OR @Bank IS NULL OR @Receipt IS NULL RETURN;

    DECLARE @Module VARCHAR(5), @ModuleRefId INT, @HeaderId INT, @BranchId INT, @IsB2B BIT, @AgentType VARCHAR(5),
            @BillNo NVARCHAR(60), @Party INT, @NewId BIGINT, @Amt DECIMAL(18,2), @RefType NVARCHAR(50), @Narr NVARCHAR(500),
            @When DATETIME, @Dr INT, @Cr INT;

    IF @Kind = 'RECEIPT'
    BEGIN
        DECLARE @MethodCode NVARCHAR(30), @Ref NVARCHAR(200), @ReceiptNo NVARCHAR(50);
        SELECT @HeaderId = ph.PaymentHeaderId, @Module = RTRIM(ph.ModuleCode), @ModuleRefId = ph.ModuleRefId, @BranchId = ph.BranchId,
               @Amt = pd.PaidAmount, @When = COALESCE(pd.PaymentDate, pd.CreatedDate), @MethodCode = UPPER(pm.MethodCode),
               @Ref = pd.TransactionRef, @ReceiptNo = pd.ReceiptNo
        FROM dbo.PaymentDetail pd
        INNER JOIN dbo.PaymentHeader ph ON ph.PaymentHeaderId = pd.PaymentHeaderId
        LEFT JOIN dbo.PaymentMethodMaster pm ON pm.PaymentMethodId = pd.PaymentMethodId
        WHERE pd.PaymentDetailId = @RefId AND pd.IsActive = 1 AND (pd.PaidAmount > 0 OR (pd.PaidAmount < 0 AND pm.MethodCode = 'POINTS'));
        IF @HeaderId IS NULL OR @Module NOT IN ('LAB', 'OPD') RETURN;
        IF ISNULL(@Ref, '') LIKE 'WALLET-DEBIT-%' RETURN;                     -- franchise wallet: posted as B2B_WALLET_PAY
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction t                  -- B2B settlement: posted as B2B_SETTLEMENT
                   WHERE t.ReferenceType = 'B2B_SETTLEMENT' AND t.Narration LIKE '%Receipt: ' + @ReceiptNo + ')%') RETURN;
        SET @RefType = @Module + '_RECEIPT';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @RefId AND IsActive = 1) RETURN;
    END
    ELSE IF @Kind = 'REFUND'
    BEGIN
        DECLARE @Mode NVARCHAR(50);
        SELECT @Module = RTRIM(r.ModuleCode), @ModuleRefId = r.ModuleRefId, @Amt = r.RefundAmount, @When = r.RefundDate, @Mode = UPPER(LTRIM(RTRIM(r.RefundMode)))
        FROM dbo.BillRefund r WHERE r.RefundId = @RefId AND r.IsActive = 1;
        IF @Module IS NULL OR @Module NOT IN ('LAB', 'OPD') OR ISNULL(@Amt, 0) <= 0 RETURN;
        SELECT @HeaderId = PaymentHeaderId, @BranchId = BranchId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = @Module AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        SET @RefType = @Module + '_REFUND';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @RefId AND IsActive = 1) RETURN;
        SET @MethodCode = CASE WHEN @Mode = 'CASH' THEN 'CASH' ELSE 'BANK' END;
    END
    ELSE IF @Kind = 'CANCEL'
    BEGIN
        DECLARE @CnNo NVARCHAR(50);
        SELECT @Module = RTRIM(c.ModuleCode), @ModuleRefId = c.ModuleRefId, @Amt = c.CancelledAmount, @When = c.CancellationDate, @CnNo = c.CancellationNo
        FROM dbo.BillCancellation c WHERE c.CancellationId = @RefId AND c.IsActive = 1;
        IF @Module IS NULL OR @Module NOT IN ('LAB', 'OPD') OR ISNULL(@Amt, 0) <= 0 RETURN;
        SET @RefType = @Module + '_CANCEL';
        IF EXISTS (SELECT 1 FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @RefType AND ReferenceId = @ModuleRefId AND IsActive = 1
                   AND Narration LIKE '%' + @CnNo + '%') RETURN;
        SELECT @BranchId = BranchId FROM dbo.PaymentHeader WHERE RTRIM(ModuleCode) = @Module AND ModuleRefId = @ModuleRefId AND IsActive = 1;
    END
    ELSE IF @Kind = 'ADJUST'
    BEGIN
        SELECT @HeaderId = PaymentHeaderId, @Module = RTRIM(ModuleCode), @ModuleRefId = ModuleRefId, @BranchId = BranchId
        FROM dbo.PaymentHeader WHERE PaymentHeaderId = @RefId;
        IF @HeaderId IS NULL OR @Module NOT IN ('LAB', 'OPD') RETURN;
    END
    ELSE RETURN;

    -- whose receivable: the patient's, or the B2B partner's
    IF @Module = 'LAB'
        SELECT @IsB2B = CAST(ISNULL(IsB2B, 0) AS BIT), @AgentType = AgentType, @BillNo = BillNo FROM dbo.LabOrder WHERE LabOrderId = @ModuleRefId;
    ELSE
        SELECT @IsB2B = 0, @BillNo = OPDBillNo FROM dbo.PatientOPDService WHERE OPDServiceId = @ModuleRefId;
    SET @Party = @Receivable;
    IF @IsB2B = 1
        SET @Party = COALESCE((SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster
                               WHERE LedgerName = CASE WHEN @AgentType = 'C' THEN 'Corporate Receivable' ELSE 'Franchise Receivable' END), @Receivable);
    SET @BranchId = ISNULL(@BranchId, 1);
    SET @BillNo = ISNULL(@BillNo, CONVERT(NVARCHAR(20), @ModuleRefId));

    IF @Kind = 'RECEIPT' AND @MethodCode = 'POINTS'
    BEGIN
        -- 2236: membership points paid part of the bill - Dr Membership Points Liability / Cr the receivable;
        -- points given back (a negative line after a cancellation) the other way
        DECLARE @PtsLiab INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = 'Membership Points Liability');
        IF @PtsLiab IS NULL RETURN;
        SET @Narr = CASE WHEN @Amt > 0 THEN N'Membership points redeemed on ' ELSE N'Membership points given back on ' END + @Module + N' Bill ' + @BillNo
                  + N' (' + ISNULL(@ReceiptNo, 'no receipt') + N')';
        SET @When = ISNULL(@TxDate, @When);
        IF @Amt > 0
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @PtsLiab, @CreditLedgerId = @Party,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        ELSE
        BEGIN
            SET @Amt = -@Amt;
            EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
                 @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Party, @CreditLedgerId = @PtsLiab,
                 @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        END
        RETURN;
    END

    IF @Kind = 'RECEIPT'
    BEGIN
        SET @Dr = CASE WHEN @MethodCode = 'CASH' THEN @Cash ELSE @Bank END;
        SET @Narr = N'Payment received on ' + @Module + N' Bill ' + @BillNo + N' (Receipt: ' + ISNULL(@ReceiptNo, '-') + N')';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Party,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    IF @Kind = 'CANCEL'
    BEGIN
        -- Dr the revenue booked for the bill / Cr the receivable it was booked to (the gross of the cancelled lines)
        DECLARE @Revenue INT = (SELECT TOP 1 LedgerId FROM dbo.Acc_LedgerMaster WHERE LedgerName = CASE WHEN @Module = 'LAB' THEN 'LAB Revenue' ELSE 'OPD Revenue' END);
        IF @Revenue IS NULL OR @Journal IS NULL RETURN;
        SET @Narr = N'Cancellation reversal for ' + @Module + N' Bill ' + @BillNo + N' [' + @CnNo + N']';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @ModuleRefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Revenue, @CreditLedgerId = @Party,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    IF @Kind = 'REFUND'
    BEGIN
        SET @Cr = CASE WHEN @MethodCode = 'CASH' THEN @Cash ELSE @Bank END;
        SET @Narr = N'Refund on ' + @Module + N' Bill ' + @BillNo + N' (Refund #' + CONVERT(NVARCHAR(20), @RefId) + N')';
        SET @When = ISNULL(@TxDate, @When);
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Receipt, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @RefId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Party, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
        RETURN;
    END

    -- ADJUST: B2B bills are posted at their B2B total by usp_B2B_PostBillLedger (no patient discount / round-off)
    IF @IsB2B = 1 OR @Disc IS NULL OR @RoundOff IS NULL OR @Journal IS NULL RETURN;
    DECLARE @TargetDisc DECIMAL(18,2), @TargetRound DECIMAL(18,2), @PostedDisc DECIMAL(18,2), @PostedRound DECIMAL(18,2), @Diff DECIMAL(18,2);
    -- the discount still standing on the bill, from what is posted: bill - cancellations + round-off - bill now
    -- (a cancellation takes its share of the discount with it), so the receivable always equals what is due
    DECLARE @NetNow DECIMAL(18,2), @BillPosted DECIMAL(18,2), @CancelPosted DECIMAL(18,2);
    SELECT @NetNow = ISNULL(NetAmount, 0), @TargetRound = ISNULL(RoundOffAmount, 0), @When = ISNULL(@TxDate, GETDATE())
    FROM dbo.PaymentHeader WHERE PaymentHeaderId = @HeaderId;
    SELECT @BillPosted = ISNULL(SUM(TotalAmount), 0) FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @Module + '_BILL' AND ReferenceId = @ModuleRefId AND IsActive = 1;
    SELECT @CancelPosted = ISNULL(SUM(TotalAmount), 0) FROM dbo.Acc_LedgerTransaction WHERE ReferenceType = @Module + '_CANCEL' AND ReferenceId = @ModuleRefId AND IsActive = 1;
    IF @BillPosted <= 0 RETURN;                       -- bill never posted: nothing to adjust against
    SET @TargetDisc = @BillPosted - @CancelPosted + @TargetRound - @NetNow;

    SELECT @PostedDisc = ISNULL(SUM(d.DebitAmount - d.CreditAmount), 0)
    FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @Disc
    WHERE t.ReferenceType = @Module + '_DISCOUNT' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
    SET @Diff = @TargetDisc - @PostedDisc;
    IF ABS(@Diff) >= 0.01
    BEGIN
        SET @RefType = @Module + '_DISCOUNT';
        SET @Narr = N'Discount on ' + @Module + N' Bill ' + @BillNo + CASE WHEN @Diff < 0 THEN N' (reversed / reduced)' ELSE N'' END;
        SET @Amt = ABS(@Diff);
        SET @Dr = CASE WHEN @Diff > 0 THEN @Disc ELSE @Receivable END;
        SET @Cr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @Disc END;
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
    END

    -- round-off raises (+) or lowers (-) what the patient owes
    SELECT @PostedRound = ISNULL(SUM(d.CreditAmount - d.DebitAmount), 0)
    FROM dbo.Acc_LedgerTransaction t INNER JOIN dbo.Acc_LedgerTransactionDetail d ON d.TransactionId = t.TransactionId AND d.LedgerId = @RoundOff
    WHERE t.ReferenceType = @Module + '_ROUNDOFF' AND t.ReferenceId = @HeaderId AND t.IsActive = 1;
    SET @Diff = @TargetRound - @PostedRound;
    IF ABS(@Diff) >= 0.01
    BEGIN
        SET @RefType = @Module + '_ROUNDOFF';
        SET @Narr = N'Round-off on ' + @Module + N' Bill ' + @BillNo;
        SET @Amt = ABS(@Diff);
        SET @Dr = CASE WHEN @Diff > 0 THEN @Receivable ELSE @RoundOff END;
        SET @Cr = CASE WHEN @Diff > 0 THEN @RoundOff ELSE @Receivable END;
        EXEC dbo.usp_Ledger_PostEntry @VoucherTypeId = @Journal, @TransactionDate = @When, @ReferenceType = @RefType, @ReferenceId = @HeaderId,
             @BranchId = @BranchId, @CompanyId = 1, @TotalAmount = @Amt, @Narration = @Narr, @DebitLedgerId = @Dr, @CreditLedgerId = @Cr,
             @CreatedBy = @UserId, @NewTransactionId = @NewId OUTPUT;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_Cancel
    @ModuleCode          CHAR(3),
    @ModuleRefId         INT,
    @BranchId            INT,
    @LineItemsJson       NVARCHAR(MAX),
    @Reason              NVARCHAR(500),
    @DiscountAdjusted    DECIMAL(10,2),
    @UserId              INT,
    @CancellationId      INT OUTPUT,
    @CancellationNo      NVARCHAR(50) OUTPUT,
    @AcknowledgeLabWarnings BIT = 0      -- LAB: user confirmed that collected samples / draft results will be discarded
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate cancellation number
        EXEC dbo.usp_Bill_GetNextCancellationNo @ModuleCode, @BranchId, @CancellationNo OUTPUT;

        -- Parse line items from JSON
        DECLARE @Items TABLE (LineRefId INT, Amount DECIMAL(10,2));
        INSERT INTO @Items (LineRefId, Amount)
        SELECT 
            CAST(JSON_VALUE(j.value, '$.lineRefId') AS INT),
            CAST(JSON_VALUE(j.value, '$.amount') AS DECIMAL(10,2))
        FROM OPENJSON(@LineItemsJson) j;

        DECLARE @TotalItems INT = (SELECT COUNT(*) FROM @Items);
        IF @TotalItems = 0
            THROW 50001, 'No items selected for cancellation.', 1;

        -- 2235: every line must belong to this bill, and is valued from the bill itself (not from the screen):
        -- LAB B2C at its price, LAB B2B at the franchise / company contract rate (B2BRate), OPD at its charges
        IF @ModuleCode = 'LAB'
        BEGIN
            IF EXISTS (SELECT 1 FROM @Items i WHERE NOT EXISTS (SELECT 1 FROM dbo.LabOrderItem loi WHERE loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = CASE WHEN ISNULL(lo.IsB2B, 0) = 1 THEN ISNULL(loi.B2BRate, ISNULL(loi.Price, 0)) ELSE ISNULL(loi.Price, 0) END
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId
            INNER JOIN dbo.LabOrder lo ON lo.LabOrderId = loi.LabOrderId;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            IF EXISTS (SELECT 1 FROM @Items i WHERE NOT EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem si WHERE si.ItemId = i.LineRefId AND si.OPDServiceId = @ModuleRefId))
                THROW 50003, 'A selected item does not belong to this bill.', 1;
            UPDATE i SET Amount = ISNULL(si.ServiceCharges, 0)
            FROM @Items i INNER JOIN dbo.PatientOPDServiceItem si ON si.ItemId = i.LineRefId;
        END

        -- LAB: a test whose result is already submitted / validated / approved cannot be cancelled from billing;
        -- the lab has to withdraw the result first (reject the sample on Report Entry, or Un-Authorize an approved report).
        IF @ModuleCode = 'LAB'
        BEGIN
            DECLARE @LabMsg NVARCHAR(2048);

            SELECT @LabMsg = STRING_AGG(CAST(
                       ISNULL(pkg.Profile_Name, lm.Test_Name) + ' ('
                       + CASE WHEN cs.ApprovedCount > 0 THEN 'report approved'
                              WHEN cs.ValidatedCount > 0 THEN 'result validated'
                              ELSE 'result submitted' END + ')' AS NVARCHAR(MAX)), '; ')
            FROM @Items i
            INNER JOIN dbo.LabOrderItem loi ON loi.LabOrderItemId = i.LineRefId AND loi.LabOrderId = @ModuleRefId
            INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = loi.LabOrderItemId
            LEFT JOIN dbo.LabInvestigationProfileHeader pkg ON pkg.Profile_ID = loi.InvestigationId AND loi.Type = 'P'
            LEFT JOIN dbo.LabInvestigationMaster lm ON lm.Test_ID = loi.InvestigationId AND ISNULL(loi.Type, 'I') <> 'P'
            WHERE cs.CancelStage = 'BLOCKED';

            IF @LabMsg IS NOT NULL
            BEGIN
                SET @LabMsg = LEFT(N'Cannot cancel: ' + @LabMsg
                    + N'. The lab must first withdraw the result (reject the sample on Report Entry; an approved report has to be Un-Authorized first).', 2048);
                THROW 50003, @LabMsg, 1;
            END

            IF ISNULL(@AcknowledgeLabWarnings, 0) = 0
               AND EXISTS (SELECT 1 FROM @Items i
                           INNER JOIN dbo.ufn_LabOrderItemCancelState(@ModuleRefId) cs ON cs.LabOrderItemId = i.LineRefId
                           WHERE cs.CancelStage = 'WARN')
                THROW 50004, 'Some selected tests already have a collected sample or a draft result. Confirm that they will be discarded to continue.', 1;
        END

        -- Validate: check items are not already cancelled
        IF EXISTS (
            SELECT 1 FROM @Items i
            INNER JOIN dbo.BillCancellationItem bci ON bci.LineRefId = i.LineRefId
            INNER JOIN dbo.BillCancellation bc ON bc.CancellationId = bci.CancellationId
            WHERE bc.ModuleCode = @ModuleCode AND bc.IsActive = 1
        )
            THROW 50002, 'One or more selected items are already cancelled.', 1;

        DECLARE @CancelledAmount DECIMAL(10,2) = (SELECT SUM(Amount) FROM @Items);

        -- Determine full or partial
        DECLARE @TotalBillItems INT;
        DECLARE @CancellationType CHAR(1);

        IF @ModuleCode = 'LAB'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.LabOrderItem 
            WHERE LabOrderId = @ModuleRefId AND IsActive = 1;
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            SELECT @TotalBillItems = COUNT(*) FROM dbo.PatientOPDServiceItem 
            WHERE OPDServiceId = @ModuleRefId AND IsActive = 1;
        END

        SET @CancellationType = CASE WHEN @TotalItems >= @TotalBillItems THEN 'F' ELSE 'P' END;

        -- Insert BillCancellation header
        INSERT INTO dbo.BillCancellation 
            (ModuleCode, ModuleRefId, CancellationNo, CancellationType, CancellationDate,
             CancelledAmount, DiscountAdjusted, Reason, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@ModuleCode, @ModuleRefId, @CancellationNo, @CancellationType, GETDATE(),
             @CancelledAmount, ISNULL(@DiscountAdjusted, 0), @Reason, 'C', @UserId, GETDATE(), 1);

        SET @CancellationId = SCOPE_IDENTITY();

        -- Insert BillCancellationItem rows
        INSERT INTO dbo.BillCancellationItem (CancellationId, LineRefId, OriginalAmount, CancelledAmount, IsActive)
        SELECT @CancellationId, LineRefId, Amount, Amount, 1
        FROM @Items;

        -- Mark items as inactive in source table
        IF @ModuleCode = 'LAB'
        BEGIN
            -- the samples of the cancelled lines leave every lab worklist, and a draft result is discarded
            DECLARE @CancelledSamples TABLE (SampleCollectionId BIGINT PRIMARY KEY);
            INSERT INTO @CancelledSamples (SampleCollectionId)
            SELECT DISTINCT m.SampleCollectionId
            FROM dbo.ufn_LabOrderItemSamples(@ModuleRefId) m
            WHERE m.LabOrderItemId IN (SELECT LineRefId FROM @Items);

            UPDATE led SET led.IsActive = 0, led.ModifiedBy = @UserId, led.ModifiedDate = GETDATE()
            FROM dbo.labentrydetails led
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = led.SamplecollectionID
            WHERE led.IsActive = 1;

            UPDATE sc SET sc.Iscancelled = 1, sc.ModifiedBy = @UserId, sc.ModifiedDate = GETDATE()
            FROM dbo.SampleCollection sc
            INNER JOIN @CancelledSamples x ON x.SampleCollectionId = sc.samplecollectionID;

            UPDATE dbo.LabOrderItem 
            SET IsActive = 0
            WHERE LabOrderItemId IN (SELECT LineRefId FROM @Items);
        END
        IF @ModuleCode = 'OPD'
        BEGIN
            UPDATE dbo.PatientOPDServiceItem 
            SET IsActive = 0
            WHERE ItemId IN (SELECT LineRefId FROM @Items);
        END

        -- Update PaymentHeader
        IF @CancellationType = 'F'
        BEGIN
            -- Full cancellation: NetAmount and BalanceDue become 0
            UPDATE dbo.PaymentHeader
            SET NetAmount            = 0,
                BalanceDue           = 0,
                HeaderDiscountAmount = 0,
                RoundOffAmount       = 0,
                LineDiscountTotal    = 0,
                LastModifiedDate     = GETDATE(),
                LastModifiedBy       = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END
        ELSE
        BEGIN
            -- Partial cancellation: reduce NetAmount by (CancelledAmount - DiscountAdjusted)
            UPDATE dbo.PaymentHeader
            SET NetAmount    = CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0 ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END,
                -- 2230: due = the reduced bill - what has been paid (an overpayment stays visible for the refund)
                BalanceDue   = CASE WHEN (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                               ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) - TotalPaid > 0
                                    THEN (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                               ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) - TotalPaid
                                    ELSE 0 END,
                HeaderDiscountAmount = CASE WHEN (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) < 0 THEN 0 ELSE (HeaderDiscountAmount - ISNULL(@DiscountAdjusted, 0)) END,
                -- 2231: status follows the reduced bill: covered = Paid (any excess is for refund), else Partial / Unpaid
                PaymentStatus = CASE WHEN TotalPaid >= (CASE WHEN (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) < 0 THEN 0
                                                           ELSE (NetAmount - (@CancelledAmount - ISNULL(@DiscountAdjusted, 0))) END) THEN 'P'
                                     WHEN TotalPaid > 0 THEN 'R' ELSE 'U' END,
                LastModifiedDate = GETDATE(),
                LastModifiedBy   = @UserId
            WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        END

        -- 2232: the cancellation entry (Dr Revenue / Cr the bill's receivable), then discount / round-off follow the bill
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'CANCEL', @RefId = @CancellationId, @UserId = @UserId;
        DECLARE @AdjHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
        IF @AdjHeaderId IS NOT NULL
            EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'ADJUST', @RefId = @AdjHeaderId, @UserId = @UserId;
        -- 2236: membership points of a B2C LAB bill - points used beyond the reduced bill go back to the card,
        -- points earned follow what is paid on the bill as it stands
        IF @AdjHeaderId IS NOT NULL AND @ModuleCode = 'LAB'
            EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @AdjHeaderId, @UserId = @UserId;

        -- If full cancellation, mark LabOrder/OPDService as inactive
        IF @CancellationType = 'F'
        BEGIN
            IF @ModuleCode = 'LAB'
                UPDATE dbo.LabOrder SET IsActive = 0 WHERE LabOrderId = @ModuleRefId;
            IF @ModuleCode = 'OPD'
                UPDATE dbo.PatientOPDService SET IsActive = 0 WHERE OPDServiceId = @ModuleRefId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Bill_Refund
    @ModuleCode    CHAR(3),
    @ModuleRefId   INT,
    @CancellationId INT,
    @RefundAmount  DECIMAL(10,2),
    @RefundMode    NVARCHAR(50),
    @TransactionRef NVARCHAR(200),
    @Notes         NVARCHAR(500),
    @UserId        INT,
    @RefundId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validate cancellation exists for this bill
        IF NOT EXISTS (
            SELECT 1 FROM dbo.BillCancellation 
            WHERE CancellationId = @CancellationId 
              AND ModuleCode = @ModuleCode 
              AND ModuleRefId = @ModuleRefId 
              AND IsActive = 1
        )
            THROW 50010, 'No valid cancellation found. Please cancel the bill first.', 1;

        -- 2231: a refund gives back only what the patient paid over the bill as it stands now:
        --   refundable = (receipts - refunds already given) - bill amount after cancellations   (never negative)
        -- and never more than this cancellation's own (net) amount less what was already refunded against it.
        -- The bill's payment row is locked, so two refunds cannot both pass the check.
        IF ISNULL(@RefundAmount, 0) <= 0
            THROW 50013, 'Refund amount must be greater than zero.', 1;

        DECLARE @Net DECIMAL(18,2), @Receipts DECIMAL(18,2), @AlreadyRefunded DECIMAL(18,2), @Msg NVARCHAR(400);
        SELECT @Net = ISNULL(ph.NetAmount, 0),
               @Receipts = ISNULL((SELECT SUM(d.PaidAmount) FROM dbo.PaymentDetail d WHERE d.PaymentHeaderId = ph.PaymentHeaderId AND d.IsActive = 1), 0)
        FROM dbo.PaymentHeader ph WITH (UPDLOCK, HOLDLOCK)
        WHERE ph.ModuleCode = @ModuleCode AND ph.ModuleRefId = @ModuleRefId AND ph.IsActive = 1;
        SELECT @AlreadyRefunded = ISNULL(SUM(RefundAmount), 0)
        FROM dbo.BillRefund
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        DECLARE @Refundable DECIMAL(18,2) = ISNULL(@Receipts, 0) - @AlreadyRefunded - ISNULL(@Net, 0);
        IF @Refundable < 0 SET @Refundable = 0;
        IF @RefundAmount > @Refundable + 0.001
        BEGIN
            SET @Msg = N'Refund amount is more than the refundable Rs ' + CONVERT(NVARCHAR(30), @Refundable)
                     + N' (received Rs ' + CONVERT(NVARCHAR(30), ISNULL(@Receipts, 0) - @AlreadyRefunded)
                     + N' against a bill of Rs ' + CONVERT(NVARCHAR(30), ISNULL(@Net, 0)) + N').';
            THROW 50011, @Msg, 1;
        END

        DECLARE @CancelledAmount DECIMAL(18,2) = 0, @RefundedOnThis DECIMAL(18,2) = 0;
        SELECT @CancelledAmount = ISNULL(CancelledAmount, 0) - ISNULL(DiscountAdjusted, 0)
        FROM dbo.BillCancellation
        WHERE CancellationId = @CancellationId AND ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;
        SELECT @RefundedOnThis = ISNULL(SUM(RefundAmount), 0) FROM dbo.BillRefund WHERE CancellationId = @CancellationId AND IsActive = 1;
        IF @RefundedOnThis + @RefundAmount > @CancelledAmount + 0.001
            THROW 50012, 'Refund amount exceeds what is left of this cancellation.', 1;

        -- Insert BillRefund
        INSERT INTO dbo.BillRefund 
            (CancellationId, ModuleCode, ModuleRefId, RefundAmount, RefundMode, RefundDate, TransactionRef, Notes, Status, CreatedBy, CreatedDate, IsActive)
        VALUES 
            (@CancellationId, @ModuleCode, @ModuleRefId, @RefundAmount, @RefundMode, GETDATE(), @TransactionRef, @Notes, 'P', @UserId, GETDATE(), 1);

        SET @RefundId = SCOPE_IDENTITY();

        -- 2232: Dr Patient Receivable / Cr Cash or Bank
        EXEC dbo.usp_Ledger_PostBillMoney @Kind = 'REFUND', @RefId = @RefundId, @UserId = @UserId;

        -- 2236: money given back - the bill's earned membership points follow what is now paid
        IF @ModuleCode = 'LAB'
        BEGIN
            DECLARE @MemHeaderId INT = (SELECT TOP 1 PaymentHeaderId FROM dbo.PaymentHeader WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1);
            IF @MemHeaderId IS NOT NULL EXEC dbo.usp_Membership_SyncBill @PaymentHeaderId = @MemHeaderId, @UserId = @UserId;
        END

        -- Reduce TotalPaid in PaymentHeader
        UPDATE dbo.PaymentHeader
        SET TotalPaid = TotalPaid - @RefundAmount,
            -- 2230: a refund gives back money the patient paid over the (reduced) bill, so what is due stays
            -- "bill - what is kept", never "old balance + refund"
            BalanceDue = CASE WHEN NetAmount - (TotalPaid - @RefundAmount) > 0 THEN NetAmount - (TotalPaid - @RefundAmount) ELSE 0 END,
            PaymentStatus = CASE WHEN NetAmount - (TotalPaid - @RefundAmount) > 0
                                 THEN CASE WHEN TotalPaid - @RefundAmount > 0 THEN 'R' ELSE 'U' END ELSE 'P' END,
            LastModifiedDate = GETDATE(),
            LastModifiedBy   = @UserId
        WHERE ModuleCode = @ModuleCode AND ModuleRefId = @ModuleRefId AND IsActive = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── the payment screen's card look-up and OTP: VIEW of the two pages that collect a B2C LAB payment ──
DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code IN (N'LAB.LABORDERBOOKING.B2CBOOKING', N'LAB.LABORDERBOOKING.B2CORDERLIST');
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabOrderBooking', @Action = N'MembershipForBilling', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'MembershipSendRedeemOtp', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2236 applied: membership points earn / redeem on B2C LAB bills.';
GO
