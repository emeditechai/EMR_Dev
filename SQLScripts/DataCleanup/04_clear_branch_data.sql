-- ============================================================================
-- DataCleanup / 04_clear_branch_data.sql
-- Branch-wise clean-up: everything recorded for one branch
-- ----------------------------------------------------------------------------
--   For the chosen branch:
--     all LAB transactions (as 01) and all OPD transactions (as 19),
--     the branch's lab rate lists and the patients registered at the branch (as 02, optional),
--     the branch's activity logs (page views, module audit, e-mail and WhatsApp send logs; optional),
--     and its number series (bills, tokens, receipts, barcodes, cancellations, patient codes restart at 1).
--   Samples another branch transferred here belong to that branch's bills and are not touched; this branch's bills
--   are cleared together with samples it transferred to other branches.
--   A patient registered here who also has bills at another branch is kept.
--   Doctors and franchises belong to the company and are not touched (see 03).
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

DECLARE @BranchId          INT = NULL;   -- required: Branch Master > BranchID
DECLARE @ClearRateLists    BIT = 1;      -- 1 = also the branch's lab rate lists
DECLARE @ClearPatients     BIT = 1;      -- 1 = also the patients registered at the branch
DECLARE @ClearActivityLogs BIT = 1;      -- 1 = also the branch's activity / e-mail / WhatsApp logs

IF @BranchId IS NULL THROW 50120, 'Set @BranchId: this script clears one branch.', 1;
DECLARE @Areas NVARCHAR(200) = CONCAT(N'LAB,OPD,', CASE WHEN @ClearRateLists = 1 THEN N'RATELISTS,' END,
                                      CASE WHEN @ClearPatients = 1 THEN N'PATIENTS,' END, CASE WHEN @ClearActivityLogs = 1 THEN N'LOGS,' END, N'SEQUENCES');

IF OBJECT_ID('cleanup.usp_Run', 'P') IS NULL
    THROW 50130, 'Run 00_install_cleanup_procedures.sql first: this script uses its procedures.', 1;

DECLARE @Execute BIT           = 0;      -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';    -- with @Execute = 1: 'CLEAR ' + the database name

EXEC cleanup.usp_Run @Areas = @Areas, @BranchId = @BranchId, @Execute = @Execute, @Confirm = @Confirm;
