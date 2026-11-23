-- ============================================================================
-- DataCleanup / 11_production_reset.sql            ONE consolidated clean-up for production go-live
-- ----------------------------------------------------------------------------
--   Scope: a whole company (@BranchId = NULL), or one branch of it (@BranchId set).
--
--   Clears, in ONE transaction (all or nothing):
--     TRANSACTIONS  LAB, OPD, IPD, PHARMACY, home collection / phlebotomist, marketing, membership, accounts
--                   (day closing, petty cash, vouchers), quality, every ledger voucher, activity / message logs;
--                   number series restart at 1
--     PATIENTS      Patient Master
--     DOCTORS       Doctor Master with schedules, exceptions, rooms, consulting fees, departments, branches,
--                   commission, Doctor IP, visit process, IPD visit fees, certificate profiles
--                   (branch scope: that branch's doctor set-up; doctors created there with no other branch go too)
--     FRANCHISES    Franchise Master with franchise rate lists, wallet / top-ups, credit limit, barcode series / pool
--     CORPORATES    Corporate (Company) Master with corporate rate lists, hospital rates, commission overrides
--     B2C RATES     B2C rate lists (with their rates)
--     USERS         every user of the company / branch with roles, branch links, permissions, sessions, notifications.
--                   SUPER ADMIN (IsSuperAdmin = 1) is NEVER removed: his login, roles and head-office link stay,
--                   his data (notifications, sessions, approver / signatory entries, GPS, devices) is removed.
--     BRANCHES      HEAD OFFICE is ALWAYS KEPT - only its data is cleared.
--                   Company scope: every other branch is removed with all its set-up.
--                   Branch scope : the chosen branch is removed (unless it is the head office).
--   Kept: company, head-office branch, Super Admin, roles, menus, permissions of roles, test / profile / service /
--   department / pharmacy item / IPD masters, settings of the head office, licence data.
--
--   HOW TO RUN (SSMS, on the live database)
--     1. Select the database. Run 00_install_cleanup_procedures.sql, then 10_install_production_reset.sql.
--     2. Set @CompanyId (and @BranchId for one branch). Run this script as it is: DRY RUN. Everything is done and
--        rolled back; the grids show per area / per table how many rows WOULD go, and the users list.
--     3. Stop the web and API sites. Take a FULL database backup.
--     4. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' (e.g. 'CLEAR EMR_Live'). Run again.
--     5. Remove the files listed in the last grid (uploads), if any.
--     6. Run 99_remove_cleanup_procedures.sql. Start the sites.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @CompanyId INT = 1;       -- Company Master > CompanyId
DECLARE @BranchId  INT = NULL;    -- NULL = whole company;  a BranchID = only that branch

DECLARE @ClearTransactions      BIT = 1;   -- LAB / OPD / IPD / PHARMACY and all other transactions
DECLARE @ClearPatients          BIT = 1;
DECLARE @ClearDoctors           BIT = 1;   -- Doctor Master + schedules, rate / fee lists ...
DECLARE @ClearFranchises        BIT = 1;   -- Franchise Master + rate lists ...
DECLARE @ClearCorporates        BIT = 1;   -- Corporate (Company) Master + rate lists ...
DECLARE @ClearB2CRateLists      BIT = 1;
DECLARE @ClearUsers             BIT = 1;   -- Super Admin always kept (his data removed)
DECLARE @RemoveMultiBranchUsers BIT = 0;   -- branch scope only: 1 = also remove users who work in other branches too
DECLARE @RemoveBranches         BIT = 1;   -- head office always kept

DECLARE @Execute BIT           = 0;        -- 0 = DRY RUN (nothing changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';      -- with @Execute = 1: 'CLEAR ' + database name

IF OBJECT_ID('cleanup.usp_ProductionReset', 'P') IS NULL
    THROW 51100, 'Run 00_install_cleanup_procedures.sql and 10_install_production_reset.sql first.', 1;

EXEC cleanup.usp_ProductionReset
     @CompanyId = @CompanyId, @BranchId = @BranchId,
     @ClearTransactions = @ClearTransactions, @ClearPatients = @ClearPatients, @ClearDoctors = @ClearDoctors,
     @ClearFranchises = @ClearFranchises, @ClearCorporates = @ClearCorporates, @ClearB2CRateLists = @ClearB2CRateLists,
     @ClearUsers = @ClearUsers, @RemoveMultiBranchUsers = @RemoveMultiBranchUsers, @RemoveBranches = @RemoveBranches,
     @Execute = @Execute, @Confirm = @Confirm;
GO
