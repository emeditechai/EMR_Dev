-- ====================================================================================================
-- Script: 2262_b2b_temporary_credit_limit.sql
-- Postpaid (Credit) franchise billing and the franchise's Temporary Limit Increase.
--   * The temporary increase counts only when BOTH are set: an amount above 0 and a "Temp Limit Valid Till" date of
--     today or later. A blank or past date: the regular credit limit alone (billing over it is blocked).
--   * The B2B Outstanding report (LR-09) reads it the same way (it used to count a blank date as no end date).
--   * dbo.usp_B2B_GetPartnerCreditStatus also returns BaseCreditLimit, TempLimitIncrease, TempLimitValidTill and
--     TempLimitActive, so billing can tell "over the base limit, within the temporary increase" (alert, may continue)
--     from "over the limit including the increase" (blocked). CreditLimit stays the limit in force (base + valid increase).
-- Patches the live procedure in place (its other logic untouched). Safe to re-run. Run after 2261.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_B2B_GetPartnerCreditStatus'));
IF @def IS NULL THROW 55140, 'usp_B2B_GetPartnerCreditStatus not found.', 1;
IF CHARINDEX(N'BaseCreditLimit', @def) = 0
BEGIN
    DECLARE @a1 NVARCHAR(300) = N'IF @TempValidTill IS NOT NULL AND @TempValidTill >= CAST(GETDATE() AS DATE)
            SET @CreditLimit = @CreditLimit + @TempLimit;';
    DECLARE @a2 NVARCHAR(100) = N'@BlockReason AS BlockReason;';
    DECLARE @a3 NVARCHAR(100) = N'@CorpBlockReason AS BlockReason;';
    IF CHARINDEX(@a1, @def) = 0 OR CHARINDEX(@a2, @def) = 0 OR CHARINDEX(@a3, @def) = 0
        THROW 55141, 'usp_B2B_GetPartnerCreditStatus: an anchor was not found; not changed.', 1;

    SET @def = STUFF(@def, CHARINDEX(@a1, @def), LEN(@a1), N'-- 2262: the temporary increase counts only with an amount and a valid-till date of today or later
        DECLARE @BaseCreditLimit DECIMAL(18,2) = @CreditLimit;
        DECLARE @TempLimitActive BIT = CASE WHEN @TempLimit > 0 AND @TempValidTill IS NOT NULL AND @TempValidTill >= CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END;
        IF @TempLimitActive = 1
            SET @CreditLimit = @CreditLimit + @TempLimit;');
    SET @def = STUFF(@def, CHARINDEX(@a2, @def), LEN(@a2), N'@BlockReason AS BlockReason,
            @BaseCreditLimit AS BaseCreditLimit,
            @TempLimit AS TempLimitIncrease,
            @TempValidTill AS TempLimitValidTill,
            @TempLimitActive AS TempLimitActive;');
    SET @def = STUFF(@def, CHARINDEX(@a3, @def), LEN(@a3), N'@CorpBlockReason AS BlockReason,
            @CorpCreditLimit AS BaseCreditLimit,
            CAST(0 AS DECIMAL(18,2)) AS TempLimitIncrease,
            CAST(NULL AS DATE) AS TempLimitValidTill,
            CAST(0 AS BIT) AS TempLimitActive;');
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
ELSE IF CHARINDEX(N'(@TempValidTill IS NULL OR @TempValidTill >= CAST(GETDATE() AS DATE))', @def) > 0
BEGIN
    -- patched by the first version of this script (blank date = no end date): a valid-till date is now required
    SET @def = REPLACE(@def, N'(@TempValidTill IS NULL OR @TempValidTill >= CAST(GETDATE() AS DATE))',
                             N'@TempValidTill IS NOT NULL AND @TempValidTill >= CAST(GETDATE() AS DATE)');
    SET @def = REPLACE(@def, N'-- 2262: the temporary increase counts while it is valid - till its date, or with no end date when blank',
                             N'-- 2262: the temporary increase counts only with an amount and a valid-till date of today or later');
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
GO

-- B2B Outstanding & Credit Use: the same reading of the temporary increase
DECLARE @rep NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2BOutstanding'));
DECLARE @old NVARCHAR(400) = N'(cl.Temp_Limit_Valid_Till IS NULL OR cl.Temp_Limit_Valid_Till >= CAST(GETDATE() AS DATE))';
IF @rep IS NOT NULL AND CHARINDEX(@old, @rep) > 0
BEGIN
    SET @rep = REPLACE(@rep, @old, N'cl.Temp_Limit_Valid_Till IS NOT NULL AND cl.Temp_Limit_Valid_Till >= CAST(GETDATE() AS DATE)');
    SET @rep = STUFF(@rep, PATINDEX(N'%CREATE%PROCEDURE%', @rep), CHARINDEX(N'PROCEDURE', @rep) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @rep), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @rep;
END
GO

PRINT 'Script 2262 applied: B2B credit status - temporary limit increase only with an amount and a valid-till date.';
GO
