-- ============================================================================
-- DataCleanup / 12_clear_ipd_transactions.sql
-- Company-wise clean-up of IPD transactions only
-- ----------------------------------------------------------------------------
--   For the chosen company and all its branches, every IPD transaction:
--     admissions (status / bed history, attendants, consents, payers, MLC, documents), charges, final bills,
--     advances / refunds / settlements (module IPD money receipts), IPD Day Closings, estimates, admission advice
--     from OPD, bed reservations and cleaning tasks;
--     LAB / radiology orders placed for the admissions (with samples, results and reports);
--     ward pharmacy issues / returns and OT implants (the stock goes back to the store) and ward medicine indents;
--     OT bookings, checklists, anaesthesia records, surgery notes; ICU flowsheet, infusions, devices;
--     TPA pre-authorisations, claims, settlements, write-offs (and their approval requests);
--     discharge advice, clearances, discharge / death summaries, LAMA / DAMA forms, death records, gate passes,
--     OPD follow-ups;
--     clinical and nursing records: assessments, notes, orders, eMAR, vitals, intake / output, risk scores,
--     care plans, handovers, incidents, cross-consultations;
--     the IPD ledger vouchers (advance, refund, bill, settlement, TPA, ward issue, day closing).
--   After it: every bed of the company that was Occupied, Reserved or waiting for cleaning is Available for a new
--   admission, and the IPD number series (IP no., IPD bill, receipt, issue, indent, gate pass ...) restart from 1.
--
--   KEPT: patients, doctors, all IPD masters (buildings, floors, wards, rooms, beds, bed categories, tariffs, ICU tariff,
--   packages, doctor visit charges, TPA document checklist), OPD / LAB / pharmacy transactions that are not IPD,
--   users, settings, ledgers. Blocked / under-maintenance beds stay blocked unless @ReleaseBlockedBeds = 1.
--
--   HOW TO RUN
--     1. Select the database, and run 00_install_cleanup_procedures.sql once (it installs the procedures).
--     2. Set @CompanyId below and run this script as it is (@Execute = 0): a DRY RUN. Every delete is performed and
--        then rolled back; the result grid lists each table and how many rows WOULD go.
--     3. Take a full database backup.
--     4. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' (for example 'CLEAR EMR_Live') and run again.
--     5. Remove the files listed in the last grid (IPD documents) from the server's upload folders, if any.
--   Any error rolls the whole run back: either everything listed is cleared, or nothing is.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @CompanyId          INT = NULL;   -- required: Company Master > CompanyId
DECLARE @ReleaseBlockedBeds BIT = 0;      -- 1 = also make Blocked / Maintenance beds Available

DECLARE @Execute BIT           = 0;       -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';     -- with @Execute = 1: 'CLEAR ' + the database name

IF @CompanyId IS NULL THROW 50121, 'Set @CompanyId: this script clears the IPD transactions of one company.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId) THROW 50122, 'No company with this @CompanyId.', 1;
IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run 00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

IF OBJECT_ID('tempdb..#IpdReleaseBlockedBeds') IS NOT NULL DROP TABLE #IpdReleaseBlockedBeds;
IF @ReleaseBlockedBeds = 1 CREATE TABLE #IpdReleaseBlockedBeds (x INT);

-- before: what the company has now
SELECT 'Before' AS [When], b.BranchName,
       (SELECT COUNT(*) FROM dbo.IpdAdmission a WHERE a.BranchId = b.BranchID) AS Admissions,
       (SELECT COUNT(*) FROM dbo.IpdAdmission a WHERE a.BranchId = b.BranchID AND a.IsOpen = 1) AS InHospital,
       (SELECT COUNT(*) FROM dbo.BedMaster d WHERE d.BranchId = b.BranchID AND d.IsActive = 1) AS Beds,
       (SELECT COUNT(*) FROM dbo.BedMaster d WHERE d.BranchId = b.BranchID AND d.IsActive = 1 AND d.BedStatus = 'Available') AS BedsAvailable
FROM dbo.BranchMaster b WHERE b.CompanyId = @CompanyId ORDER BY b.BranchName;

EXEC cleanup.usp_Run @Areas = N'IPD', @CompanyId = @CompanyId, @Execute = @Execute, @Confirm = @Confirm;

-- after: on a dry run this shows the data as it still is (everything was rolled back)
SELECT CASE WHEN @Execute = 1 THEN 'After' ELSE 'After (dry run: unchanged)' END AS [When], b.BranchName,
       (SELECT COUNT(*) FROM dbo.IpdAdmission a WHERE a.BranchId = b.BranchID) AS Admissions,
       (SELECT COUNT(*) FROM dbo.BedMaster d WHERE d.BranchId = b.BranchID AND d.IsActive = 1) AS Beds,
       (SELECT COUNT(*) FROM dbo.BedMaster d WHERE d.BranchId = b.BranchID AND d.IsActive = 1 AND d.BedStatus = 'Available') AS BedsAvailable,
       (SELECT COUNT(*) FROM dbo.BedMaster d WHERE d.BranchId = b.BranchID AND d.IsActive = 1 AND d.BedStatus <> 'Available') AS BedsNotAvailable
FROM dbo.BranchMaster b WHERE b.CompanyId = @CompanyId ORDER BY b.BranchName;
IF OBJECT_ID('tempdb..#IpdReleaseBlockedBeds') IS NOT NULL DROP TABLE #IpdReleaseBlockedBeds;
