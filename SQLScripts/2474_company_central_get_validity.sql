-- ============================================================================================================
-- Migration: 2474_company_central_get_validity.sql   (application database)
-- usp_Company_CentralGet (2471) also returns the company's Valid From / Valid To (2472), so every push to the central
-- company register (central script 2473) carries them - Create / Edit / New Company / Push to Central and a company
-- registered by a user sync alike. Columns are only added at the end. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Company_CentralGet
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CompanyId, c.CompanyCode, c.CompanyName, c.ValidFrom, c.ValidTo
      FROM dbo.CompanyMaster c WHERE c.CompanyId = @CompanyId;
END
GO

PRINT 'Script 2474 applied: usp_Company_CentralGet returns the validity dates.';
GO
