-- ============================================================================
-- DataCleanup / 02_clear_semi_transaction_data.sql
-- Semi-transaction data clean-up: lab rate lists and Patient Master
-- ----------------------------------------------------------------------------
--   Lab rate lists (Master > Lab Rate List B2C / Franchise / Corporate): header and every test / profile rate.
--   Patient Master (OPD > Outpatient Department > Patient Master): patients and their vitals.
--     A patient is removed only when nothing refers to them any more (no LAB bill, OPD booking, payment, sample,
--     consultation or video consultation). Clear the transactions first (01 / 19), otherwise those patients are
--     reported as KEPT. Patient codes restart at 1 for a branch left without patients.
--   Photos / ID documents of removed patients are listed for removal from the server.
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

DECLARE @CompanyId      INT = NULL;   -- the company to clear ...
DECLARE @BranchId       INT = NULL;   -- ... or one branch
DECLARE @AllCompanies   BIT = 0;      -- 1 = every company
DECLARE @ClearRateLists BIT = 1;      -- 1 = clear lab rate lists
DECLARE @RateTypes      NVARCHAR(100) = N'B2C,Franchise,Corporate';   -- which rate lists
DECLARE @ClearPatients  BIT = 1;      -- 1 = clear Patient Master

DECLARE @Areas NVARCHAR(100) = CONCAT(CASE WHEN @ClearRateLists = 1 THEN N'RATELISTS,' END, CASE WHEN @ClearPatients = 1 THEN N'PATIENTS,SEQUENCES' END);

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run 00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

EXEC cleanup.usp_Run @Areas = @Areas, @CompanyId = @CompanyId, @BranchId = @BranchId, @AllCompanies = @AllCompanies,
                     @RateTypes = @RateTypes, @Execute = @Execute, @Confirm = @Confirm;
