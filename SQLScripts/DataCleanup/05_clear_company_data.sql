-- ============================================================================
-- DataCleanup / 05_clear_company_data.sql
-- Company-wise clean-up: everything recorded for one company
-- ----------------------------------------------------------------------------
--   For the chosen company and all its branches:
--     all LAB and OPD transactions, lab rate lists, Patient Master, Doctor Master, Lab Franchise Master,
--     activity logs (page views, module audit, e-mail and WhatsApp send logs - security history is kept),
--     and every number series.
--   Kept: the company and its branches, users, roles and permissions, departments, investigation / profile /
--   reference-range and other lab masters, services, settings, IPD masters, ledger masters.
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

DECLARE @CompanyId         INT = NULL;   -- required: Company Master > CompanyId
DECLARE @ClearActivityLogs BIT = 1;      -- 1 = also the company's activity / e-mail / WhatsApp logs

IF @CompanyId IS NULL THROW 50121, 'Set @CompanyId: this script clears one company.', 1;
DECLARE @Areas NVARCHAR(200) = CONCAT(N'LAB,OPD,RATELISTS,FRANCHISES,PATIENTS,DOCTORS,', CASE WHEN @ClearActivityLogs = 1 THEN N'LOGS,' END, N'SEQUENCES');

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run 00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

EXEC cleanup.usp_Run @Areas = @Areas, @CompanyId = @CompanyId, @Execute = @Execute, @Confirm = @Confirm;
