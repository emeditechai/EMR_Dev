-- ============================================================================================================
-- 2351  Two new roles for the pharmacy (global roles, CompanyId 1 - SQLScripts/2334). No permissions are granted here:
--       the administrator ticks their pages / controls in Security, as for every role.
--   Med-Biller     pharmacy counter: sale (POS), returns, credit collection, day closing
--   Store Manager  pharmacy store: purchase, GRN, stock, transfers, adjustments, verification
--                  (the name contains "Manager", so Store Managers can be named approvers in the Approval Matrix)
-- Re-runnable.
-- ============================================================================================================
SET NOCOUNT ON;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE Name = N'Med-Biller')
    INSERT dbo.Roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
    VALUES (N'Med-Biller', N'Pharmacy counter: sale (POS), returns, credit collection and day closing', 0, GETDATE(), GETDATE(), N'fas fa-cash-register', 1);
IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE Name = N'Store Manager')
    INSERT dbo.Roles (Name, Description, IsSystemRole, CreatedDate, LastModifiedDate, IconClass, CompanyId)
    VALUES (N'Store Manager', N'Pharmacy store: purchase, GRN, stock, transfers, adjustments and stock verification', 0, GETDATE(), GETDATE(), N'fas fa-boxes', 1);
GO
PRINT 'Script 2351 applied: roles Med-Biller and Store Manager.';
GO
