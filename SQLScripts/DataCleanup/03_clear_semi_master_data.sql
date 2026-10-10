-- ============================================================================
-- DataCleanup / 03_clear_semi_master_data.sql
-- Semi-master data clean-up: Doctor Master and Lab Franchise Master
-- ----------------------------------------------------------------------------
--   Doctors (Master > Doctors): doctor and set-up - branch / department mapping, consulting fees, schedules and
--     exceptions, room assignment, commission, visit process, Doctor IP. Clinical units keep their record with the
--     consultant in charge cleared. Login users linked to a doctor are kept (deactivate them in User Master).
--   Lab Franchises (Master > Lab Franchises): franchise and set-up - credit limit, wallet and top-ups (with their
--     ledger vouchers), pre-printed barcode series and pool, franchise rate lists.
--   A doctor / franchise that any remaining bill, booking or invoice still refers to is KEPT and reported:
--   clear the transactions first (01 and 19).
--   Doctors and franchises belong to the whole company, so this script works per company (no branch).
--
--   HOW TO RUN
--     1. Select the database to clean, and run 00_install_cleanup_procedures.sql once.
--     2. Set the variables below and run this script as it is (@Execute = 0): a DRY RUN. Every delete is
--        performed and then rolled back; the result grid lists each table and how many rows WOULD go.
--     3. Take a full database backup.
--     4. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' (for example 'CLEAR EMR_Live') and run again.
--     5. Remove the files listed in the last grid from the server's upload folders, if any.
--   Any error rolls the whole run back: either everything listed is cleared, or nothing is.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @CompanyId       INT = NULL;   -- the company to clear
DECLARE @AllCompanies    BIT = 0;      -- 1 = every company (only when @CompanyId is NULL)
DECLARE @ClearDoctors    BIT = 1;      -- 1 = clear Doctor Master
DECLARE @ClearFranchises BIT = 1;      -- 1 = clear Lab Franchise Master

DECLARE @Areas NVARCHAR(100) = CONCAT(CASE WHEN @ClearFranchises = 1 THEN N'FRANCHISES,' END, CASE WHEN @ClearDoctors = 1 THEN N'DOCTORS' END);

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run 00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

EXEC cleanup.usp_Run @Areas = @Areas, @CompanyId = @CompanyId, @AllCompanies = @AllCompanies,
                     @Execute = @Execute, @Confirm = @Confirm;
