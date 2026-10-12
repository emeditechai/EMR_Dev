-- ====================================================================================================
-- Script: 2260_b2b_partner_billing_franchise_scope.sql
-- LR-07 B2B Partner Billing Register for a franchise login (Users.User_Type = 'F', ReferenceUserID = its franchise):
-- only the bills that login created, or that are for its own franchise (as the B2B order list 2258 and the report
-- dispatch 2259). The Partner filter offers only its own franchise. Every other login: unchanged.
-- The login is the report's @UserId, which the web always takes from the signed-in user.
-- Patches the live procedure in place (its other logic untouched). Safe to re-run. Run after 2259.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabReport_B2BPartnerBilling'));
IF @def IS NULL THROW 55120, 'usp_Api_LabReport_B2BPartnerBilling not found.', 1;
IF CHARINDEX(N'@OwnFranchiseId', @def) = 0
BEGIN
    DECLARE @a1 NVARCHAR(200) = N'SET @PaymentMethod = NULLIF(UPPER(LTRIM(RTRIM(@PaymentMethod))), '''');';
    DECLARE @a2 NVARCHAR(300) = N'AND (@Partner IS NULL OR lo.AgentType + ''-'' + CAST(lo.B2BAgentID AS VARCHAR(10)) = @Partner)';
    DECLARE @a3 NVARCHAR(300) = N'FROM dbo.LabFranchiseMaster f WHERE f.Parent_Branch_ID = @BranchId AND ISNULL(f.IsDeleted, 0) = 0';
    DECLARE @a4 NVARCHAR(300) = N'FROM dbo.CorporateMaster c WHERE c.Branch_ID = @BranchId';
    IF CHARINDEX(@a1, @def) = 0 OR CHARINDEX(@a2, @def) = 0 OR CHARINDEX(@a3, @def) = 0 OR CHARINDEX(@a4, @def) = 0
        THROW 55121, 'usp_Api_LabReport_B2BPartnerBilling: an anchor was not found; not changed.', 1;

    SET @def = STUFF(@def, CHARINDEX(@a1, @def), LEN(@a1), @a1 + N'
    -- 2260: a franchise login sees the bills it created or that are for its own franchise
    DECLARE @OwnFranchiseId INT = (SELECT u.ReferenceUserID FROM dbo.Users u WHERE u.Id = @UserId AND u.User_Type = ''F'');');
    SET @def = STUFF(@def, CHARINDEX(@a2, @def), LEN(@a2), @a2 + N'
      AND (@OwnFranchiseId IS NULL OR lo.CreatedBy = @UserId OR (lo.AgentType = ''F'' AND lo.B2BAgentID = @OwnFranchiseId))');
    SET @def = STUFF(@def, CHARINDEX(@a3, @def), LEN(@a3), @a3 + N' AND (@OwnFranchiseId IS NULL OR f.Franchise_ID = @OwnFranchiseId)');
    SET @def = STUFF(@def, CHARINDEX(@a4, @def), LEN(@a4), @a4 + N' AND @OwnFranchiseId IS NULL');
    SET @def = STUFF(@def, PATINDEX(N'%CREATE%PROCEDURE%', @def), CHARINDEX(N'PROCEDURE', @def) + 9 - PATINDEX(N'%CREATE%PROCEDURE%', @def), N'CREATE OR ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
END
GO

PRINT 'Script 2260 applied: B2B Partner Billing Register - a franchise login sees the bills it created or that are for its franchise.';
GO
