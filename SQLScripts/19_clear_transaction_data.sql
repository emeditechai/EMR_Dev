-- ============================================================================
-- Script 19: OPD transaction clean-up (production go-live / test reset)
-- ----------------------------------------------------------------------------
-- Uses the clean-up procedures in SQLScripts/DataCleanup (run DataCleanup/00_install_cleanup_procedures.sql once
-- first). Safe by default: as it stands the script is a DRY RUN - it performs every delete, shows how many rows
-- each table would lose, and rolls everything back. Nothing is deleted until @Execute = 1 and @Confirm are set.
--
-- Clears, for the chosen company / branch:
--   OPD bookings and bills (Patient Registration / Service Booking / Doctor Dashboard): booked services,
--     payments (receipts, bill lines), Bill Cancellation & Refund (OPD), doctor consultations (EMR),
--     video consultations, vitals, doctor disbursal and bill adjustments, ledger vouchers of OPD bills and
--     cancellations, OPD / video WhatsApp messages and OPD audit entries of these bills;
--   optionally Patient Master (OPD > Patient Master) - only patients nothing refers to any more; a patient
--     with a LAB bill is kept until the LAB transactions are cleared too (DataCleanup/01).
--   OPD bill numbers, tokens and cancellation numbers restart at 1 for each branch left without OPD bills;
--   receipt numbers (shared with LAB) and patient codes when the branch has no payment / patient left.
-- Kept: doctors, services, schedules, fees, all masters and settings; LAB data (see DataCleanup/01).
--
--   HOW TO RUN
--     1. Select the database, run DataCleanup/00_install_cleanup_procedures.sql once.
--     2. Set the scope below, run as it is (dry run) and read the result grid.
--     3. Take a full database backup.
--     4. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' and run again.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @CompanyId      INT = NULL;   -- the company to clear (all its branches) ...
DECLARE @BranchId       INT = NULL;   -- ... or one branch
DECLARE @AllCompanies   BIT = 0;      -- 1 = every company (only when both ids above are NULL)
DECLARE @ClearPatients  BIT = 1;      -- 1 = also Patient Master (patients nothing refers to any more)
DECLARE @ClearAuditLogs BIT = 1;      -- 1 = also the OPD audit entries of the cleared bills

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run SQLScripts/DataCleanup/00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

DECLARE @Areas NVARCHAR(100) = CONCAT(N'OPD,', CASE WHEN @ClearPatients = 1 THEN N'PATIENTS,' END, N'SEQUENCES');
EXEC cleanup.usp_Run @Areas = @Areas, @CompanyId = @CompanyId, @BranchId = @BranchId, @AllCompanies = @AllCompanies,
                     @ClearAuditLogs = @ClearAuditLogs, @Execute = @Execute, @Confirm = @Confirm;
GO
