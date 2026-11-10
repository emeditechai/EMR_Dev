-- 2445: the marketing executive is stored on the LAB bill (LabOrder.MarketingExecutiveId) when it is booked: the referral
-- doctor's executive at that moment. Changing a doctor's executive later in Doctor Master no longer moves old bills.
--   * LabOrder.MarketingExecutiveId (+ FK, index); existing bills filled once from the doctor's current executive
--   * usp_CreateLabOrder stores it; usp_LabOrder_GetDetail (B2C / B2B order view) and
--     usp_Api_LabReport_MarketingBusiness (Reports > LAB > Marketing Executive Business) read it from the bill
-- Run after 2440-2444. Safe to re-run.
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.LabOrder', 'MarketingExecutiveId') IS NULL
    ALTER TABLE dbo.LabOrder ADD MarketingExecutiveId INT NULL CONSTRAINT FK_LabOrder_MarketingExecutive REFERENCES dbo.MarketingExecutive (ExecutiveId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabOrder_MarketingExecutive' AND object_id = OBJECT_ID('dbo.LabOrder'))
    CREATE INDEX IX_LabOrder_MarketingExecutive ON dbo.LabOrder (MarketingExecutiveId, OrderDate) WHERE MarketingExecutiveId IS NOT NULL;
GO
-- existing bills: the executive their referral doctor has now (the best record there is)
UPDATE lo SET MarketingExecutiveId = d.MarketingExecutiveId
FROM dbo.LabOrder lo JOIN dbo.DoctorMaster d ON d.DoctorId = lo.RefDoctorId
WHERE lo.MarketingExecutiveId IS NULL AND d.MarketingExecutiveId IS NOT NULL;
PRINT CONCAT('Existing LAB bills tagged with an executive: ', @@ROWCOUNT);
GO

-- patch helper: replace one exact piece of a procedure (THROW when the piece is missing and the patch is not in yet)
CREATE OR ALTER PROCEDURE #Patch @Proc SYSNAME, @Old NVARCHAR(MAX), @New NVARCHAR(MAX), @Marker NVARCHAR(200),
    @Old2 NVARCHAR(MAX) = NULL, @New2 NVARCHAR(MAX) = NULL   -- a second piece changed together with the first
AS
BEGIN
    DECLARE @d NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(@Proc));
    IF @d IS NULL THROW 51450, 'Procedure missing.', 1;
    IF CHARINDEX(@Marker, @d) > 0 BEGIN PRINT @Proc + ': already patched'; RETURN; END;
    IF CHARINDEX(@Old, @d) = 0 BEGIN DECLARE @m NVARCHAR(400) = @Proc + N': the expected code was not found - not patched.'; THROW 51451, @m, 1; END;
    IF @Old2 IS NOT NULL AND CHARINDEX(@Old2, @d) = 0 BEGIN DECLARE @m2 NVARCHAR(400) = @Proc + N': the expected code was not found - not patched.'; THROW 51452, @m2, 1; END;
    SET @d = REPLACE(@d, @Old, @New);
    IF @Old2 IS NOT NULL SET @d = REPLACE(@d, @Old2, @New2);
    DECLARE @p INT = PATINDEX(N'%CREATE%PROC%', @d);
    SET @d = STUFF(@d, @p, CHARINDEX(N'PROC', @d, @p) - @p, N'CREATE OR ALTER ');
    EXEC sp_executesql @d;
    PRINT @Proc + ': patched';
END;
GO

-- 1. booking stores the referral doctor's executive on the bill
EXEC #Patch N'dbo.usp_CreateLabOrder',
    N'B2BAgentID, AgentType, B2BTotal, RefDoctorId)',
    N'B2BAgentID, AgentType, B2BTotal, RefDoctorId, MarketingExecutiveId /* 2445 */)',
    N'MarketingExecutiveId /* 2445 */',
    N'@B2BAgentID, @AgentType, @B2BTotal, @ReferralDoctorId);',
    N'@B2BAgentID, @AgentType, @B2BTotal, @ReferralDoctorId,
             (SELECT d.MarketingExecutiveId FROM dbo.DoctorMaster d WHERE d.DoctorId = @ReferralDoctorId) /* 2445 executive */);';
GO
-- 2. order view (B2C / B2B): the executive stored on the bill
EXEC #Patch N'dbo.usp_LabOrder_GetDetail',
    N'LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = rdoc.MarketingExecutiveId AND me.IsDeleted = 0',
    N'LEFT JOIN dbo.MarketingExecutive me ON me.ExecutiveId = o.MarketingExecutiveId /* 2445 */',
    N'o.MarketingExecutiveId /* 2445 */';
GO
-- 3. Marketing Executive Business report: the executive stored on the bill (LAB executives only)
EXEC #Patch N'dbo.usp_Api_LabReport_MarketingBusiness',
    N'LEFT  JOIN dbo.MarketingExecutive me ON me.ExecutiveId = rdoc.MarketingExecutiveId AND me.IsDeleted = 0 AND me.ExecutiveType = ''LAB''',
    N'LEFT  JOIN dbo.MarketingExecutive me ON me.ExecutiveId = lo.MarketingExecutiveId /* 2445 */ AND me.IsDeleted = 0 AND me.ExecutiveType = ''LAB''',
    N'lo.MarketingExecutiveId /* 2445 */';
GO
DROP PROCEDURE IF EXISTS #Patch;
GO
PRINT '2445 LAB bill marketing executive - done.';
GO
