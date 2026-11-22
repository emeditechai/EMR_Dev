-- ============================================================================================================
-- Migration: 2525_doctor_payout_from_fund.sql   (application database; needs 2213 and 2522)
-- OPD > Doctor Commission & Disbursals: a doctor share settlement is paid FROM a fund (Utility > Accounts > Fund Master).
--   DoctorSettlement.FundId         : the fund it was paid from
--   FundTransaction.RefType / RefId : what a fund movement belongs to ('DOCTOR_SETTLEMENT' + SettlementId)
--   usp_DoctorPayout_Action (PAY, new @FundId):
--     * when the company has an active fund, choosing one is required; the fund must be active and of the company
--     * the fund cannot go below zero: its balance must cover the net payable (it is moved under the fund's row lock)
--     * the mode suits the fund: a BANK fund pays by UPI / NEFT / RTGS / IMPS / Cheque (not Cash); a WALLET by Cash / UPI
--     * in the same transaction as the payment: Fund.CurrentBalance - net payable, and a PAYOUT entry in the fund's
--       history (negative amount, balance after, mode, reference, "Doctor payout <no> - Dr <name>")
--     A company without an active fund pays as before (no fund).
--   usp_DoctorPayout_Settlements / _SettlementGet : also return FundId, FundName, FundType
--   usp_DoctorPayout_PayFunds : the active funds to pay from, with balance (the payment window)
-- Each change is guarded: a procedure that does not read as expected is left as it is and reported. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.Fund', N'U') IS NULL
BEGIN
    RAISERROR('Script 2525 needs script 2522 (Fund Master) first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
IF COL_LENGTH('dbo.DoctorSettlement', 'FundId') IS NULL
    ALTER TABLE dbo.DoctorSettlement ADD FundId INT NULL CONSTRAINT FK_DoctorSettlement_Fund REFERENCES dbo.Fund (FundId);
GO
IF COL_LENGTH('dbo.FundTransaction', 'RefType') IS NULL ALTER TABLE dbo.FundTransaction ADD RefType VARCHAR(30) NULL;
IF COL_LENGTH('dbo.FundTransaction', 'RefId') IS NULL   ALTER TABLE dbo.FundTransaction ADD RefId INT NULL;
GO

-- ── the payment: from a fund ─────────────────────────────────────────────────────────────────────────────────
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_DoctorPayout_Action'));
IF @def LIKE N'%@FundId%' PRINT '2525: usp_DoctorPayout_Action already pays from a fund.';
ELSE IF CHARINDEX(N'@PaymentReference NVARCHAR(100) = NULL,', @def) = 0
     OR CHARINDEX(N'            UPDATE dbo.DoctorSettlement SET Status = ''PAID'', PaymentDate = @PaymentDate, PaymentMode = @PaymentMode, PaymentReference = @PaymentReference,', @def) = 0
    PRINT '2525: usp_DoctorPayout_Action has changed - paying from a fund was NOT added. Add it by hand.';
ELSE
BEGIN
    SET @def = REPLACE(@def, N'@PaymentReference NVARCHAR(100) = NULL,',
        N'@PaymentReference NVARCHAR(100) = NULL,
    @FundId           INT           = NULL, -- 2525: the fund the payment is made from (required when the company has one)');
    SET @def = REPLACE(@def,
        N'            UPDATE dbo.DoctorSettlement SET Status = ''PAID'', PaymentDate = @PaymentDate, PaymentMode = @PaymentMode, PaymentReference = @PaymentReference,',
        N'            -- 2525: paid from a fund - required when the company has an active fund; the fund must cover the net payable
            DECLARE @co INT, @net DECIMAL(18, 2), @sno NVARCHAR(30), @doc NVARCHAR(200), @fType VARCHAR(10), @fBal DECIMAL(18, 2), @fName NVARCHAR(150), @fMsg NVARCHAR(400);
            SELECT @co = ds.CompanyId, @net = ds.NetPayable, @sno = ds.SettlementNo,
                   @doc = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(d.NamePrefix + '' '', '''') + ISNULL(d.FullName, ''''))), ''''), ''Doctor'')
              FROM dbo.DoctorSettlement ds LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = ds.DoctorId WHERE ds.SettlementId = @SettlementId;
            SET @FundId = NULLIF(@FundId, 0);
            IF @FundId IS NULL AND EXISTS (SELECT 1 FROM dbo.Fund WHERE CompanyId = @co AND IsActive = 1 AND IsDeleted = 0)
                THROW 50020, ''Choose the fund the payment is made from (Utility > Accounts > Fund Master).'', 1;
            IF @FundId IS NOT NULL
            BEGIN
                SELECT @fType = FundType, @fBal = CurrentBalance, @fName = FundName FROM dbo.Fund WITH (UPDLOCK, ROWLOCK)
                 WHERE FundId = @FundId AND CompanyId = @co AND IsActive = 1 AND IsDeleted = 0;
                IF @fType IS NULL THROW 50020, ''The fund was not found or is inactive.'', 1;
                IF @fType = ''BANK'' AND @PaymentMode = ''Cash'' THROW 50020, ''A bank fund pays by UPI, NEFT, RTGS, IMPS or Cheque - not cash. Choose a wallet fund for cash.'', 1;
                IF @fType = ''WALLET'' AND @PaymentMode NOT IN (''Cash'', ''UPI'') THROW 50020, ''A wallet fund pays by Cash or UPI. Choose a bank fund for NEFT, RTGS, IMPS or Cheque.'', 1;
                IF @fBal < @net
                BEGIN
                    SET @fMsg = N''Not enough balance in '' + @fName + N'': it has '' + FORMAT(@fBal, ''N2'', ''en-IN'') + N'', the payment is ''
                              + FORMAT(@net, ''N2'', ''en-IN'') + N''. Top up the fund (Utility > Accounts > Fund Master) or choose another fund.'';
                    THROW 50020, @fMsg, 1;
                END
                IF @net > 0
                BEGIN
                    UPDATE dbo.Fund SET CurrentBalance = CurrentBalance - @net, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE FundId = @FundId;
                    INSERT dbo.FundTransaction (FundId, CompanyId, BranchId, TxnType, TxnDate, Amount, BalanceAfter, PaymentMode, ReferenceNo, Remarks, CreatedBy, RefType, RefId)
                    SELECT @FundId, @co, @BranchId, ''PAYOUT'', @PaymentDate, -@net, f.CurrentBalance, UPPER(@PaymentMode), @PaymentReference,
                           LEFT(N''Doctor payout '' + ISNULL(@sno, N'''') + N'' - '' + @doc + ISNULL(N'' · '' + @Remarks, N''''), 500), @UserId, ''DOCTOR_SETTLEMENT'', @SettlementId
                      FROM dbo.Fund f WHERE f.FundId = @FundId;
                END
            END
            UPDATE dbo.DoctorSettlement SET FundId = @FundId WHERE SettlementId = @SettlementId;
            UPDATE dbo.DoctorSettlement SET Status = ''PAID'', PaymentDate = @PaymentDate, PaymentMode = @PaymentMode, PaymentReference = @PaymentReference,');
    SET @def = REPLACE(@def, N'CREATE   PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, N'CREATE PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2525: usp_DoctorPayout_Action pays from a fund.';
END
GO

-- ── the settlement list / one settlement: the fund it was paid from ─────────────────────────────────────────
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_DoctorPayout_Settlements'));
IF @def LIKE N'%FundName%' PRINT '2525: usp_DoctorPayout_Settlements already returns the fund.';
ELSE IF CHARINDEX(N'           CAST(CASE WHEN ds.PreparedBy = @UserId THEN 1 ELSE 0 END AS BIT) AS PreparedByMe', @def) = 0
     OR CHARINDEX(N'    LEFT JOIN dbo.Users uc ON uc.Id = ds.ClosedBy', @def) = 0
    PRINT '2525: usp_DoctorPayout_Settlements has changed - the fund was NOT added.';
ELSE
BEGIN
    SET @def = REPLACE(@def, N'           CAST(CASE WHEN ds.PreparedBy = @UserId THEN 1 ELSE 0 END AS BIT) AS PreparedByMe',
                             N'           CAST(CASE WHEN ds.PreparedBy = @UserId THEN 1 ELSE 0 END AS BIT) AS PreparedByMe,
           ds.FundId, fu.FundName, fu.FundType');
    SET @def = REPLACE(@def, N'    LEFT JOIN dbo.Users uc ON uc.Id = ds.ClosedBy', N'    LEFT JOIN dbo.Users uc ON uc.Id = ds.ClosedBy
    LEFT JOIN dbo.Fund fu ON fu.FundId = ds.FundId');
    SET @def = REPLACE(@def, N'CREATE   PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2525: usp_DoctorPayout_Settlements returns the fund.';
END
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_DoctorPayout_SettlementGet'));
IF @def LIKE N'%FundName%' PRINT '2525: usp_DoctorPayout_SettlementGet already returns the fund.';
ELSE IF CHARINDEX(N'    SELECT ds.*,', @def) = 0 PRINT '2525: usp_DoctorPayout_SettlementGet has changed - the fund was NOT added.';
ELSE
BEGIN
    SET @def = REPLACE(@def, N'    SELECT ds.*,', N'    SELECT ds.*, (SELECT f.FundName FROM dbo.Fund f WHERE f.FundId = ds.FundId) AS FundName,
           (SELECT f.FundType FROM dbo.Fund f WHERE f.FundId = ds.FundId) AS FundType,');
    SET @def = REPLACE(@def, N'CREATE   PROCEDURE', N'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
    PRINT '2525: usp_DoctorPayout_SettlementGet returns the fund.';
END
GO

-- ── the funds to pay from (payment window): active, with balance and bank account ───────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_DoctorPayout_PayFunds @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.FundId, f.FundCode, f.FundName, f.FundType, f.CurrentBalance, b.BankName, b.AccountNumber, b.IFSCCode
      FROM dbo.Fund f LEFT JOIN dbo.BankMaster b ON b.Id = f.BankId
     WHERE f.CompanyId = @CompanyId AND f.IsActive = 1 AND f.IsDeleted = 0
     ORDER BY f.CurrentBalance DESC, f.FundName;
END
GO
-- the payment window's fund list is part of paying (control PAYOUT of the disbursal page)
DECLARE @p INT = (SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'OPD.DOCTORDISBURSAL'), @c INT;
SELECT @c = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = 'PAYOUT';
IF @p IS NOT NULL
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @c, @App = 'WEB', @Http_Method = 'GET', @Controller = N'DoctorDisbursal', @Action = N'PayFunds', @Source = 'SEED';
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2525 applied: doctor payout from a fund.';
GO
SET NOEXEC OFF;
GO
