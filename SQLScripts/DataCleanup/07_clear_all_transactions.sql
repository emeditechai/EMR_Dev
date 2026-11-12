-- ============================================================================
-- DataCleanup / 07_clear_all_transactions.sql
-- COMPLETE transaction clean-up for production go-live: every transaction of the chosen company / branch, so the
-- application starts with masters and settings only.
-- ----------------------------------------------------------------------------
--   Clears (in this order, in ONE transaction):
--     LAB         LAB bills (B2C / B2B) and everything hanging off them: sample collection, transfer, result entry,
--                 approval, report delivery, outsourcing, misc charges, critical value calls, BOM consumption, doctor
--                 IP commission, payments, cancellation & refund, B2B invoices & settlement, franchise wallet
--                 debits (top-ups too when the whole company is cleared), membership points of these bills
--     OPD         OPD bookings / bills, services, payments, cancellation & refund, consultations (EMR), video
--                 consultations, vitals, token history, doctor disbursal / adjustments / settlements
--                 (2026-11-12) home collection visits, phlebotomist attendance / GPS / travel / documents / cash /
--                 hand-overs, bill change requests, external report documents, reflex suggestions, tests omitted from
--                 doctor IP, B2C bill estimates; phlebotomist pre-printed barcodes made available again
--     IPD         (2026-11-12) admissions with every record hanging off them: charges, interim / final bills, advances and
--                 refunds, ward pharmacy issues, documents, MLC, attendants, consents, payers, bed movements and status
--                 logs, estimates, bed reservations / cleaning tasks, admission advice; beds back to Available
--     PHARMACY    (2026-11-12) sales and returns (Rx links, clinical alerts, schedule register, refill reminders, loyalty
--                 wallet), indents, purchase orders, GRNs, purchase returns, supplier payments, debit notes, stock
--                 adjustments, batch corrections, stock counts, store issues, branch transfers, stock and stock ledger,
--                 batches no longer used, pharmacy payments / cancellations / refunds
--     MARKETING   (2026-11-12) Doctor Visit Log, Marketing Executive App leads / visits, field days and GPS points
--     OPD (more)  (2026-11-12) certificates issued and their send log, vaccinations
--     MEMBERSHIP  membership cards, members, points, redeem OTPs, card-fee payments
--     ACCOUNTS    OPD / LAB Day Closing, petty cash floats / expenses / closings, manual vouchers, bill scans
--     QUALITY     BOM consumption, IQC runs, EQAS cycles, CAPA, equipment breakdowns / calibrations / maintenance
--     LEDGER      every ledger voucher still left on the branch (books restart from the ledger opening balances)
--     LOGS        activity / audit entries (security history kept), e-mail / WhatsApp logs, bell notifications,
--                 permission decisions, Doctor IP access log; (2026-11-12) audit notification log, certificate send log,
--                 campaigns sent, decided approval requests (pending kept), Help Assistant questions / feedback,
--                 password reset OTPs and links
--     PATIENTS    (optional) Patient Master - only patients nothing refers to any more
--     SEQUENCES   bill, token, receipt, cancellation, barcode, voucher and patient-code numbers restart at 1;
--                 (2026-11-12) IP numbers, pharmacy document numbers, certificate numbers
--   Kept: company, branches, users, roles, permissions, menus, all masters (tests, profiles, rate lists, doctors,
--   franchises, services, departments, ledgers, expense heads, petty cash counters, equipment, IQC / EQAS set-up,
--   BOM, inventory items; pharmacy items, generics, manufacturers, suppliers, customers, schemes, stores, number series;
--   IPD buildings, wards, rooms, beds, tariffs, packages, visit fees; marketing executives and targets; certificate,
--   vaccine, print and campaign templates; approval matrices), Hospital Settings and every other setting, licence data,
--   Help Assistant learned answers and test-suggestion learning.
--   Doctor commission SET-UP is not touched (see 06_clear_opd_doctor_commission.sql for that).
--
--   HOW TO RUN
--     1. Select the database to clean, and run 00_install_cleanup_procedures.sql (again, if an older copy was
--        installed: it adds the new areas).
--     2. Set the scope below and run this script as it is (@Execute = 0): a DRY RUN. Every delete is performed and
--        then rolled back; the result grids list each table and how many rows WOULD go, and the files to remove.
--     3. Stop the web and API sites, and take a FULL database backup.
--     4. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' (for example 'CLEAR EMR_Live') and run again.
--     5. Remove the files listed in the last grid from the server (uploads, App_Data/accounts), if any.
--     6. Run 99_remove_cleanup_procedures.sql, then start the sites.
--   Any error rolls the whole run back: either everything listed is cleared, or nothing is.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @CompanyId      INT = NULL;   -- the company to clear (all its branches) ...
DECLARE @BranchId       INT = NULL;   -- ... or one branch (Branch Master > BranchID)
DECLARE @AllCompanies   BIT = 0;      -- 1 = every company (only when both ids above are NULL)
DECLARE @ClearPatients  BIT = 1;      -- 1 = also Patient Master (patients nothing refers to any more)
DECLARE @ClearLogs      BIT = 1;      -- 1 = also activity logs, message logs and bell notifications
DECLARE @ClearAuditLogs BIT = 1;      -- 1 = the LAB / OPD audit entries of the cleared bills

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

IF OBJECT_ID('cleanup.usp_ClearAccounts', 'P') IS NULL
    THROW 50130, 'Run the current 00_install_cleanup_procedures.sql first: this script needs its ACCOUNTS / MEMBERSHIP / QUALITY / LEDGER areas.', 1;
IF OBJECT_ID('cleanup.usp_ClearPharmacy', 'P') IS NULL OR OBJECT_ID('cleanup.usp_ClearIpdTransactions', 'P') IS NULL
    THROW 50131, 'Run the current 00_install_cleanup_procedures.sql again (2026-11-12): this script needs its IPD / PHARMACY / MARKETING areas.', 1;

DECLARE @Areas NVARCHAR(400) = CONCAT(N'IPD,LAB,OPD,PHARMACY,MARKETING,MEMBERSHIP,ACCOUNTS,QUALITY,LEDGER,',
                                      CASE WHEN @ClearPatients = 1 THEN N'PATIENTS,' END,
                                      CASE WHEN @ClearLogs = 1 THEN N'LOGS,' END,
                                      N'SEQUENCES');
EXEC cleanup.usp_Run @Areas = @Areas, @CompanyId = @CompanyId, @BranchId = @BranchId, @AllCompanies = @AllCompanies,
                     @ClearAuditLogs = @ClearAuditLogs, @Execute = @Execute, @Confirm = @Confirm;
GO
