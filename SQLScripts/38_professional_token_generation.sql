-- ── Enterprise Grade Token Generation ───────────────────────────────────────
-- This procedure safely generates gapless daily tokens per branch.
-- Uses UPDLOCK, ROWLOCK, and SERIALIZABLE isolation to completely prevent
-- race conditions and duplicate tokens under heavy concurrent loads.
-- It strictly maintains backwards compatibility with existing application code.

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

    -- Attempt to atomic-update existing daily sequence securely
    UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
    SET @NewSeq = LastSeq = LastSeq + 1
    WHERE BranchId = @BranchId AND TokenDate = @TokenDate;

    -- If no record exists for today, safely insert starting at 1
    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.OPDTokenSequence (BranchId, TokenDate, LastSeq)
            VALUES (@BranchId, @TokenDate, 1);
            
            SET @NewSeq = 1;
        END TRY
        BEGIN CATCH
            -- Handle exact millisecond race condition on the INSERT itself
            IF ERROR_NUMBER() = 2627 OR ERROR_NUMBER() = 2601 -- Primary Key / Unique Constraint Violation
            BEGIN
                UPDATE dbo.OPDTokenSequence WITH (UPDLOCK, ROWLOCK, SERIALIZABLE)
                SET @NewSeq = LastSeq = LastSeq + 1
                WHERE BranchId = @BranchId AND TokenDate = @TokenDate;
            END
            ELSE THROW;
        END CATCH
    END

    -- Construct Final Token Output: BR-0001
    SET @TokenNo = @BranchCode + '-' + RIGHT('0000' + CAST(@NewSeq AS VARCHAR(10)), 4);
END
GO
