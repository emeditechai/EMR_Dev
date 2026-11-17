-- ============================================================================================================
-- Migration: 2472_company_validity_dates.sql   (application database)
-- Settings > Companies: Valid From / Valid To (mandatory). Web sign-in (and signed-in sessions) of a company's users is
-- refused outside these dates; the Super Admin is never refused. Mobile apps are not affected.
--   * existing companies: backfilled with one year from today (not from their creation date - that would lock out companies
--     older than a year the moment this script runs)
--   * a company created without dates (New Company wizard procedure, any other insert): one year from its creation day
--   * Valid To must not be before Valid From
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH(N'dbo.CompanyMaster', N'ValidFrom') IS NULL
    ALTER TABLE dbo.CompanyMaster ADD ValidFrom DATE NOT NULL
        CONSTRAINT DF_CompanyMaster_ValidFrom DEFAULT (CAST(GETDATE() AS DATE)) WITH VALUES;
GO
IF COL_LENGTH(N'dbo.CompanyMaster', N'ValidTo') IS NULL
    ALTER TABLE dbo.CompanyMaster ADD ValidTo DATE NOT NULL
        CONSTRAINT DF_CompanyMaster_ValidTo DEFAULT (DATEADD(YEAR, 1, CAST(GETDATE() AS DATE))) WITH VALUES;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_CompanyMaster_Validity')
    ALTER TABLE dbo.CompanyMaster ADD CONSTRAINT CK_CompanyMaster_Validity CHECK (ValidTo >= ValidFrom);
GO

PRINT 'Script 2472 applied: CompanyMaster Valid From / Valid To (existing companies: one year from today).';
GO
