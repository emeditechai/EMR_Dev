-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2442  LAB order view (B2C and B2B): the marketing executive of the bill's referral doctor
--   usp_LabOrder_GetDetail returns MarketingExecutiveName / MarketingExecutiveType: the executive tagged on the referral
--   doctor in Doctor Master (DoctorMaster.MarketingExecutiveId, SQLScripts/2441). Shown under "Referred By" on the B2C Order
--   List and B2B order views. Nothing else changes. Needs 2440, 2441. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_LabOrder_GetDetail'));
IF @def NOT LIKE '%MarketingExecutiveName%'
BEGIN
    DECLARE @name NVARCHAR(400) = N' AS ReferralDoctorName,', @join NVARCHAR(200) = N'    LEFT JOIN dbo.DoctorMaster rdoc ON rdoc.DoctorId = o.RefDoctorId';
    IF CHARINDEX(@name, @def) = 0 OR CHARINDEX(@join, @def) = 0 THROW 51420, 'usp_LabOrder_GetDetail has changed: add the marketing executive by hand.', 1;
    SET @def = STUFF(@def, CHARINDEX(@name, @def) + LEN(@name), 0, N'
        me.ExecutiveName AS MarketingExecutiveName, me.ExecutiveType AS MarketingExecutiveType,   -- SQLScripts/2442');
    SET @def = STUFF(@def, CHARINDEX(@join, @def) + LEN(@join), 0, N'
    LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = rdoc.MarketingExecutiveId AND me.IsDeleted = 0');
    SET @def = REPLACE(REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE'), 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO
PRINT '2442 LAB order marketing executive - done.';
GO
