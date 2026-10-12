-- ====================================================================================================
-- Script: 2261_b2b_outstanding_franchise_scope.sql
-- LR-09 B2B Outstanding & Credit Use for a franchise login (Users.User_Type = 'F', ReferenceUserID = its franchise):
-- only its own franchise - its credit line, wallet, open bills and totals (as the partner billing register, 2260).
-- The partner list is cut to that franchise, and every bill / total of the report is joined to that list.
-- Every other login: unchanged. The login is the report's @UserId, which the web takes from the signed-in user.
-- Patches the live procedure in place (its other logic untouched). Safe to re-run. Run after 2260.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2BOutstanding'));
IF @def IS NULL THROW 55130, 'usp_Api_LabReport_B2BOutstanding not found.', 1;
IF CHARINDEX(N'@OwnFranchiseId', @def) = 0
BEGIN
    DECLARE @a NVARCHAR(200) = N'DELETE FROM #P WHERE @PartnerType IS NOT NULL AND AgentType <> @PartnerType;';
    IF CHARINDEX(@a, @def) = 0 THROW 55131, 'usp_Api_LabReport_B2BOutstanding: anchor not found; not changed.', 1;
    SET @def = STUFF(@def, CHARINDEX(@a, @def), LEN(@a), @a + N'
    -- 2261: a franchise login sees only its own franchise
    DECLARE @OwnFranchiseId INT = (SELECT u.ReferenceUserID FROM dbo.Users u WHERE u.Id = @UserId AND u.User_Type = ''F'');
    DELETE FROM #P WHERE @OwnFranchiseId IS NOT NULL AND NOT (AgentType = ''F'' AND AgentId = @OwnFranchiseId);');
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2261 applied: B2B Outstanding - a franchise login sees only its own franchise.';
GO
