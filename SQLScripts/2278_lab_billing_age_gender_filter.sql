-- ============================================================================================================
-- Migration: 2278_lab_billing_age_gender_filter.sql
-- LAB billing (B2C and B2B) > Search & Add Investigation / Profile: the list follows the patient's gender and age.
--   Bug: the masters (Lab Investigation, Profile / Package) save the Age Comparison Operator as Exact / GreaterEqual /
--   LessEqual, while usp_GetAvailableInvestigations compared it with '=' / '>=' / '<=' - so an age rule never filtered.
--   Now both spellings are understood. No restriction when: gender is All / empty; the operator is empty / "No Age
--   Limit"; the operator has no age; the patient's gender or age is not entered yet.
-- Patches the live procedure in place. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_GetAvailableInvestigations'));
IF @def IS NULL THROW 55280, 'usp_GetAvailableInvestigations not found.', 1;
IF CHARINDEX(N'GreaterEqual', @def) = 0
BEGIN
    DECLARE @a CHAR(1), @i INT = 0, @hits INT = 0;
    WHILE @i < 2
    BEGIN
        SET @a = CASE @i WHEN 0 THEN 'i' ELSE 'h' END;
        DECLARE @before INT = LEN(@def);
        SET @def = REPLACE(@def, @a + N'.Applicable_Gender = ''All''',
                           @a + N'.Applicable_Gender = ''All'' OR NULLIF(LTRIM(RTRIM(' + @a + N'.Applicable_Gender)), '''') IS NULL /* 2278 */');
        SET @def = REPLACE(@def, @a + N'.Age_Operator IS NULL',
                           @a + N'.Age_Operator IS NULL OR LTRIM(RTRIM(' + @a + N'.Age_Operator)) = '''' OR ' + @a + N'.Applicable_Age IS NULL');
        SET @def = REPLACE(@def, N'(' + @a + N'.Age_Operator = ''='' AND',  N'(' + @a + N'.Age_Operator IN (''='', ''Exact'') AND');
        SET @def = REPLACE(@def, N'(' + @a + N'.Age_Operator = ''>='' AND', N'(' + @a + N'.Age_Operator IN (''>='', ''GreaterEqual'') AND');
        SET @def = REPLACE(@def, N'(' + @a + N'.Age_Operator = ''<='' AND', N'(' + @a + N'.Age_Operator IN (''<='', ''LessEqual'') AND');
        IF LEN(@def) > @before SET @hits += 1;
        SET @i += 1;
    END
    IF @hits <> 2 OR CHARINDEX(N'GreaterEqual', @def) = 0
        THROW 55281, 'usp_GetAvailableInvestigations: the age / gender conditions were not found; not changed.', 1;
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55282, 'usp_GetAvailableInvestigations: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2278 applied: LAB billing list follows the patient''s gender and age.';
GO
