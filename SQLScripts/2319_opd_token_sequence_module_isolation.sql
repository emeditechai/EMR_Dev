-- 2319: OPD, B2C LAB and B2B LAB tokens use separate daily sequences.
-- Bug: usp_OPD_GetNextTokenNo updated dbo.OPDTokenSequence without a ModuleCode filter, so every OPD token
-- also advanced the LAB / B2B_LAB counters of the same branch + day (gaps such as LAB-HO-0001, 0004, 0006) and
-- OPD took its number from whichever row was updated last.
-- Fix: OPD reads / writes only ModuleCode = 'OPD'. Then the counters are re-synced from the tokens actually issued:
--   * every branch + day that has OPD tokens gets an OPD row at least as high as its highest OPD token (no duplicates);
--   * from today onward, OPD / LAB / B2B_LAB counters are set to the highest token issued in that module (closes gaps
--     for the rest of the day). Tokens already issued are never renumbered (they are printed on bills).
-- Re-runnable.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
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
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq)
            VALUES (@BranchId, @TokenDate, 'OPD', 1);

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

-- ── Re-sync counters from issued tokens ──────────────────────────────────────────────────────────────────
BEGIN TRANSACTION;

DECLARE @Issued TABLE (BranchId INT, TokenDate DATE, ModuleCode NVARCHAR(10), MaxSeq INT,
                       PRIMARY KEY (BranchId, TokenDate, ModuleCode));

INSERT INTO @Issued (BranchId, TokenDate, ModuleCode, MaxSeq)
SELECT BranchId, CAST(VisitDate AS DATE), 'OPD',
       MAX(TRY_CAST(RIGHT(TokenNo, CHARINDEX('-', REVERSE(TokenNo)) - 1) AS INT))
FROM   dbo.PatientOPDService
WHERE  TokenNo IS NOT NULL AND CHARINDEX('-', TokenNo) > 0 AND VisitDate IS NOT NULL
GROUP BY BranchId, CAST(VisitDate AS DATE);

INSERT INTO @Issued (BranchId, TokenDate, ModuleCode, MaxSeq)
SELECT BranchId, CAST(ISNULL(BookingDate, OrderDate) AS DATE),
       CASE WHEN TokenNo LIKE 'B2B-%' THEN 'B2B_LAB' ELSE 'LAB' END,
       MAX(TRY_CAST(RIGHT(TokenNo, CHARINDEX('-', REVERSE(TokenNo)) - 1) AS INT))
FROM   dbo.LabOrder
WHERE  TokenNo IS NOT NULL AND CHARINDEX('-', TokenNo) > 0
GROUP BY BranchId, CAST(ISNULL(BookingDate, OrderDate) AS DATE),
         CASE WHEN TokenNo LIKE 'B2B-%' THEN 'B2B_LAB' ELSE 'LAB' END;

DELETE FROM @Issued WHERE MaxSeq IS NULL;

-- 1. OPD rows missing (OPD had been using the LAB row): create them at the highest OPD token.
INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, ModuleCode, LastSeq)
SELECT i.BranchId, i.TokenDate, 'OPD', i.MaxSeq
FROM   @Issued i
WHERE  i.ModuleCode = 'OPD'
  AND  NOT EXISTS (SELECT 1 FROM dbo.OPDTokenSequence s
                   WHERE s.BranchId = i.BranchId AND s.TokenDate = i.TokenDate AND s.ModuleCode = 'OPD');
PRINT CONCAT('OPD counter rows created: ', @@ROWCOUNT);

-- 2. Any counter below its highest issued token is raised (never hand out a duplicate).
UPDATE s SET LastSeq = i.MaxSeq
FROM   dbo.OPDTokenSequence s
JOIN   @Issued i ON i.BranchId = s.BranchId AND i.TokenDate = s.TokenDate AND i.ModuleCode = s.ModuleCode
WHERE  s.LastSeq < i.MaxSeq;
PRINT CONCAT('Counters raised: ', @@ROWCOUNT);

-- 3. From today onward, inflated counters are brought back to the module's own highest token.
UPDATE s SET LastSeq = ISNULL(i.MaxSeq, 0)
FROM   dbo.OPDTokenSequence s
LEFT JOIN @Issued i ON i.BranchId = s.BranchId AND i.TokenDate = s.TokenDate AND i.ModuleCode = s.ModuleCode
WHERE  s.TokenDate >= CAST(GETDATE() AS DATE)
  AND  s.ModuleCode IN ('OPD', 'LAB', 'B2B_LAB')
  AND  s.LastSeq > ISNULL(i.MaxSeq, 0);
PRINT CONCAT('Counters from today re-synced: ', @@ROWCOUNT);

COMMIT TRANSACTION;
GO
