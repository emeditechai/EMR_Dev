-- 2333 Number counters store the branch's company (they were saved with company 1; numbering itself is per branch
--   and does not change). Also corrects existing counter rows.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ─── 2.  usp_Patient_GetNextCode  ────────────────────────────────────────────
-- Returns the next patient code for a given branch in the current financial year.
-- Format :  P<BranchCode><FY><6-digit-seq>    e.g.  PKOL2526000001
CREATE OR ALTER PROCEDURE dbo.usp_Patient_GetNextCode
    @BranchId       INT,
    @PatientCode    NVARCHAR(30)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Resolve branch code
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster
    WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL
        SET @BranchCode = 'BR';   -- fallback

    -- Financial year: Apr–Mar  →  e.g. Apr 2025 – Mar 2026 = '2526'
    DECLARE @Today   DATE = CAST(GETDATE() AS DATE);
    DECLARE @Month   INT  = MONTH(@Today);
    DECLARE @CalYear INT  = YEAR(@Today);

    DECLARE @FYStart INT       = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd   INT       = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY      NVARCHAR(4) =
        RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) +
        RIGHT(CAST(@FYEnd   AS NVARCHAR(4)), 2);

    -- Upsert counter row (branch + FY)
    IF NOT EXISTS (
        SELECT 1 FROM dbo.PatientCodeCounter
        WHERE BranchId = @BranchId AND FinancialYear = @FY
    )
        INSERT INTO dbo.PatientCodeCounter (BranchId, FinancialYear, LastSeq, CompanyId)
        VALUES (@BranchId, @FY, 0, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));

    -- Atomic increment (UPDLOCK prevents race conditions)
    UPDATE dbo.PatientCodeCounter WITH (UPDLOCK)
        SET LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY;

    DECLARE @Seq INT;
    SELECT @Seq = LastSeq
    FROM dbo.PatientCodeCounter
    WHERE BranchId = @BranchId AND FinancialYear = @FY;

    -- Build code:  P + BranchCode + FY + 000001
    SET @PatientCode =
        'P' + @BranchCode + @FY +
        RIGHT('000000' + CAST(@Seq AS NVARCHAR(10)), 6);
END
GO

-- ── 2. Stored Procedure: usp_OPD_GetNextBillNo ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_OPD_GetNextBillNo
    @BranchId  INT,
    @BillNo    NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Look up the branch code (UPPER, trimmed)
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL OR @BranchCode = ''
        SET @BranchCode = 'BR';

    -- Financial year: Apr–Mar e.g. Apr 2026 → Mar 2027 = '2627'
    DECLARE @Today     DATE = CAST(GETDATE() AS DATE);
    DECLARE @CalYear   INT  = YEAR(@Today);
    DECLARE @Month     INT  = MONTH(@Today);

    DECLARE @FYStart   INT  = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd     INT  = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY        NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

    DECLARE @NewSeq INT = 0;

    -- Atomically update sequence for OPD
    UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'OPD';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @FY, 'OPD', 1, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'OPD';
            END
            ELSE THROW;
        END CATCH
    END

    -- Format: OPD/<BranchCode><FY><6-digit seq> e.g. OPD/HO2627000001
    SET @BillNo = 'OPD/' + @BranchCode + @FY + RIGHT('000000' + CAST(@NewSeq AS NVARCHAR(10)), 6);
END
GO

-- ── 3. Stored Procedure: usp_LAB_GetNextBillNo ─────────────────
CREATE OR ALTER PROCEDURE dbo.usp_LAB_GetNextBillNo
    @BranchId  INT,
    @BillNo    NVARCHAR(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Look up the branch code (UPPER, trimmed)
    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM dbo.Branchmaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL OR @BranchCode = ''
        SET @BranchCode = 'BR';

    -- Financial year: Apr–Mar e.g. Apr 2026 → Mar 2027 = '2627'
    DECLARE @Today     DATE = CAST(GETDATE() AS DATE);
    DECLARE @CalYear   INT  = YEAR(@Today);
    DECLARE @Month     INT  = MONTH(@Today);

    DECLARE @FYStart   INT  = CASE WHEN @Month >= 4 THEN @CalYear     ELSE @CalYear - 1 END;
    DECLARE @FYEnd     INT  = CASE WHEN @Month >= 4 THEN @CalYear + 1 ELSE @CalYear     END;
    DECLARE @FY        NVARCHAR(4) = RIGHT(CAST(@FYStart AS NVARCHAR(4)), 2) + RIGHT(CAST(@FYEnd AS NVARCHAR(4)), 2);

    DECLARE @NewSeq INT = 0;

    -- Atomically update sequence for LAB
    UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDBillSequence (BranchId, FinancialYear, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @FY, 'LAB', 1, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDBillSequence WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND FinancialYear = @FY AND ModuleCode = 'LAB';
            END
            ELSE THROW;
        END CATCH
    END

    -- Format: LAB/<BranchCode><FY><6-digit seq> e.g. LAB/HO2627000001
    SET @BillNo = 'LAB/' + @BranchCode + @FY + RIGHT('000000' + CAST(@NewSeq AS NVARCHAR(10)), 6);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_OPD_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode)))
    FROM   dbo.BranchMaster WHERE BranchID = @BranchId;

    IF @BranchCode IS NULL
        SET @BranchCode = 'BR';

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'OPD';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @TokenDate, 'OPD', 1, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));

            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 2627 OR ERROR_NUMBER() = 2601
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'OPD';
            END
            ELSE THROW;
        END CATCH
    END

    -- BR-0001
    SET @TokenNo = @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END
GO

-- 4. Create Token Generation for LAB (e.g., LAB-HO-0001)
CREATE OR ALTER PROCEDURE dbo.usp_LAB_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(20)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;
    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.BranchMaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL SET @BranchCode = 'BR';

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @TokenDate, 'LAB', 1, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 2627 OR ERROR_NUMBER() = 2601
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'LAB';
            END
            ELSE THROW;
        END CATCH
    END

    SET @TokenNo = 'LAB-' + @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END
GO

-- ==============================================================================
-- Migration: 2053_b2b_token_generation_and_backfill.sql
-- Description: Implement dedicated Day-Wise B2B Laboratory Token No generation pattern:
--              Pattern: B2B-LAB-{BranchCode}-{Seq:D4} (e.g., B2B-LAB-HO-0001).
--              Maintains separate daily sequence from B2C LAB tokens via ModuleCode = 'B2B_LAB'.
--              Generates immediately on each B2B billing/order creation.
--              Backfills all existing B2B LabOrders and SampleCollection records day-wise.
-- ==============================================================================

-- 1. Create B2B Token Generator Procedure
CREATE OR ALTER PROCEDURE dbo.usp_B2B_LAB_GetNextTokenNo
    @BranchId  INT,
    @TokenDate DATE          = NULL,
    @TokenNo   NVARCHAR(50)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET ANSI_NULLS ON;
    SET QUOTED_IDENTIFIER ON;

    SET @TokenDate = ISNULL(@TokenDate, CAST(GETDATE() AS DATE));

    DECLARE @BranchCode NVARCHAR(20);
    SELECT @BranchCode = UPPER(LTRIM(RTRIM(BranchCode))) FROM dbo.BranchMaster WHERE BranchID = @BranchId;
    IF @BranchCode IS NULL SET @BranchCode = 'HO';

    DECLARE @NewSeq INT = 0;

    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'B2B_LAB';

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq, CompanyId)
            VALUES (@BranchId, @TokenDate, 'B2B_LAB', 1, ISNULL((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1));
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate AND ModuleCode = 'B2B_LAB';
            END
            ELSE THROW;
        END CATCH
    END

    SET @TokenNo = 'B2B-LAB-' + @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END;
GO

-- existing rows of a branch saved under another company
UPDATE x SET CompanyId = b.CompanyId FROM dbo.PatientCodeCounter x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.OPDBillSequence x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.OPDTokenSequence x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.PaymentHeader x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.DoctorBranchMap x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.SampleCollection x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.Acc_LedgerTransaction x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
UPDATE x SET CompanyId = b.CompanyId FROM dbo.AuditLogs x JOIN dbo.BranchMaster b ON b.BranchId = x.BranchId WHERE x.CompanyId <> b.CompanyId;
GO

-- voucher counters are keyed by company: move a branch's counter to its company (no row there yet), so numbering continues
UPDATE s SET CompanyId = b.CompanyId
FROM dbo.Acc_VoucherSequence s JOIN dbo.BranchMaster b ON b.BranchId = s.BranchId
WHERE s.CompanyId <> b.CompanyId
  AND NOT EXISTS (SELECT 1 FROM dbo.Acc_VoucherSequence z WHERE z.CompanyId = b.CompanyId AND z.BranchId = s.BranchId
                    AND z.VoucherTypeId = s.VoucherTypeId AND z.FinancialYear = s.FinancialYear);
GO
PRINT 'Script 2333 applied: counters and postings keep the branch''s company.';
GO
