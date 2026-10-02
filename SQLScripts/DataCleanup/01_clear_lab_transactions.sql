-- ============================================================================
-- DataCleanup / 01_clear_lab_transactions.sql
-- LAB transaction clean-up (production go-live)
-- ----------------------------------------------------------------------------
--   Clears every LAB transaction of the chosen scope and everything that depends on it:
--     LAB > Lab Reporting Entry, Image Report Entry, Microbiology Report Entry  (result entry, remarks)
--     LAB > Sample Collection, Sample Transfer, outsourcing tracking, sample status history
--     LAB > Report Approval Dashboard (sign-off levels), Un-Authorize Report history
--     LAB > Report e-mail / WhatsApp delivery logs
--     LAB > Bill Cancellation & Refund (LAB)
--     LAB > B2C Order List and B2B Order List with their payments (receipts, bill lines)
--     LAB > B2B Invoices and B2B Multi-Bill Settlement (invoices, settlement ledger postings)
--     Franchise wallet debits of these bills (top-ups too when a whole company is cleared), wallet balances
--       recalculated; pre-printed franchise barcodes used by these bills become available again
--     Ledger vouchers of LAB bills / cancellations / B2B bills / wallet payments / settlements
--     LAB audit entries of these bills; LAB bill, token, receipt, barcode and cancellation numbers restart at 1
--       for each branch left without LAB bills (receipts only when the branch has no OPD payment either)
--   Kept: patients, doctors, franchises, rate lists, all masters and settings (see 02 / 03 for those).
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

DECLARE @CompanyId      INT = NULL;   -- the company to clear (all its branches) ...
DECLARE @BranchId       INT = NULL;   -- ... or one branch (Branch Master > BranchID)
DECLARE @AllCompanies   BIT = 0;      -- 1 = every company (only when both ids above are NULL)
DECLARE @ClearAuditLogs BIT = 1;      -- 1 = also the LAB audit entries of the cleared bills

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run 00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

EXEC cleanup.usp_Run @Areas = N'LAB,SEQUENCES', @CompanyId = @CompanyId, @BranchId = @BranchId, @AllCompanies = @AllCompanies,
                     @ClearAuditLogs = @ClearAuditLogs, @Execute = @Execute, @Confirm = @Confirm;
