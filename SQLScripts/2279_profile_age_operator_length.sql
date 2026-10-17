-- ============================================================================================================
-- Migration: 2279_profile_age_operator_length.sql
-- Investigation Profile / Package: the age rule ">= (Greater than or Equal)" was saved cut short as 'GreaterEqu'
-- (usp_Api_LabInvestigationProfile_Save declared @Age_Operator VARCHAR(10); the column is VARCHAR(20)), so the
-- package matched no age in B2C / B2B billing. The parameter is widened and the cut values are repaired.
-- Patches the live procedure in place. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabInvestigationProfile_Save'));
IF @def IS NULL THROW 55290, 'usp_Api_LabInvestigationProfile_Save not found.', 1;
DECLARE @p INT = PATINDEX(N'%@Age_Operator%VARCHAR(10)%', @def);
IF @p > 0 AND @p < CHARINDEX(N'AS', @def, CHARINDEX(N'@Age_Operator', @def))   -- in the parameter list
BEGIN
    DECLARE @v INT = CHARINDEX(N'VARCHAR(10)', @def, @p);
    SET @def = STUFF(@def, @v, LEN(N'VARCHAR(10)'), N'VARCHAR(20)');
    DECLARE @c INT = PATINDEX(N'%CREATE%PROCEDURE%', @def);
    SET @def = STUFF(@def, @c, CHARINDEX(N'PROCEDURE', @def, @c) + 9 - @c, N'CREATE OR ALTER PROCEDURE');
    IF @def IS NULL THROW 55291, 'usp_Api_LabInvestigationProfile_Save: the procedure text could not be prepared; not changed.', 1;
    EXEC sys.sp_executesql @def;
END
GO

-- values already cut short
UPDATE dbo.LabInvestigationProfileHeader SET Age_Operator = 'GreaterEqual' WHERE Age_Operator = 'GreaterEqu';
UPDATE dbo.LabInvestigationMaster        SET Age_Operator = 'GreaterEqual' WHERE Age_Operator = 'GreaterEqu';
GO

PRINT 'Script 2279 applied: profile / package age operator saved in full.';
GO
