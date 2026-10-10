-- ============================================================================
-- DataCleanup / 06_clear_opd_doctor_commission.sql
-- OPD doctor commission clean-up: set-up and calculated commission, so it can be configured again from scratch
-- ----------------------------------------------------------------------------
--   Settings > Doctor Visit Process      (DoctorVisitProcessConfigs/Index)   dbo.DoctorVisitProcessConfig
--   Settings > Doctor Commission Config  (DoctorCommissionConfigs/Index)     dbo.DoctorCommissionConfig
--   with @ClearDisbursals = 1, also the commission already worked out from that set-up:
--   Doctor Disbursal (calculated / approved / paid lines)                    dbo.DoctorDisbursal
--   Billing adjustments of those lines                                       dbo.DoctorBillingAdjustment
--   Doctor settlements / payout vouchers (SQLScripts/2213)                   dbo.DoctorSettlement
--   with @ClearProfiles = 1, the doctors' payout profiles (PAN, TDS, bank)   dbo.DoctorPayoutProfile
--   A disbursal line keeps the CommissionConfigId it was calculated with, so lines are cleared with the set-up;
--   otherwise they would point at rules that no longer exist and block re-calculation of the same visits.
--
--   Not touched: OPD bills, payments, consultations, Doctor Master and its fees / schedules / departments, the IPD
--   doctor payout set-up (Doctor_IP_Hdr / Doctor_IP_Dtl), pages and permissions.
--
--   Stand-alone: does not need 00_install_cleanup_procedures.sql.
--
--   HOW TO RUN
--     1. Select the database to clean. Set @CompanyId (or @AllCompanies = 1).
--     2. Run the script as it is (@Execute = 0): a DRY RUN. Every delete is performed and then rolled back; the
--        result grid lists each table and how many rows WOULD go.
--     3. Take a backup if the data may be needed again.
--     4. Set @Execute = 1 and @Confirm = 'CLEAR <database name>' (for example 'CLEAR Dev_EMR') and run again.
--   Any error rolls the whole run back: either everything listed is cleared, or nothing is.
--   When a table is left empty, its numbering restarts at 1.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CompanyId       INT = 1;      -- the company to clear ...
DECLARE @AllCompanies    BIT = 0;      -- ... or 1 = every company
DECLARE @ClearDisbursals BIT = 1;      -- 1 = also clear calculated / paid doctor disbursal lines, their adjustments and settlements
DECLARE @ClearProfiles   BIT = 0;      -- 1 = also clear the doctors' payout profiles (PAN, TDS, bank / UPI)

DECLARE @Execute BIT           = 0;    -- 0 = dry run (nothing is changed)   1 = delete for real
DECLARE @Confirm NVARCHAR(200) = N'';  -- with @Execute = 1: 'CLEAR ' + the database name

-- ── checks ──────────────────────────────────────────────────────────────────
IF @AllCompanies = 0 AND (@CompanyId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.CompanyMaster WHERE CompanyId = @CompanyId))
    THROW 50140, 'Set @CompanyId to an existing company, or @AllCompanies = 1.', 1;
IF @AllCompanies = 1 SET @CompanyId = NULL;
IF @Execute = 1 AND ISNULL(@Confirm, N'') <> N'CLEAR ' + DB_NAME()
BEGIN
    DECLARE @msg NVARCHAR(400) = N'To delete for real set @Confirm = ''CLEAR ' + DB_NAME() + N'''.';
    THROW 50141, @msg, 1;
END

-- a table variable: its rows survive the ROLLBACK of a dry run
DECLARE @Report TABLE (Step INT IDENTITY(1, 1), TableName SYSNAME, Action VARCHAR(10), RowsAffected INT, Note NVARCHAR(400));
DECLARE @n INT;

BEGIN TRANSACTION;

IF @ClearDisbursals = 1
BEGIN
    DELETE a FROM dbo.DoctorBillingAdjustment a
    WHERE @CompanyId IS NULL OR a.CompanyId = @CompanyId
       OR a.DisbursalId IN (SELECT d.DisbursalId FROM dbo.DoctorDisbursal d WHERE d.CompanyId = @CompanyId);
    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES ('DoctorBillingAdjustment', 'DELETE', @n, 'billing adjustments of doctor disbursal lines');

    DECLARE @paid INT = (SELECT COUNT(1) FROM dbo.DoctorDisbursal WHERE (@CompanyId IS NULL OR CompanyId = @CompanyId) AND PaymentStatus = 'Paid');
    DELETE d FROM dbo.DoctorDisbursal d WHERE @CompanyId IS NULL OR d.CompanyId = @CompanyId;
    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES ('DoctorDisbursal', 'DELETE', @n, CONCAT('doctor disbursal lines (', @paid, ' of them already paid)'));

    IF OBJECT_ID('dbo.DoctorSettlement', 'U') IS NOT NULL
    BEGIN
        DELETE ds FROM dbo.DoctorSettlement ds WHERE @CompanyId IS NULL OR ds.CompanyId = @CompanyId;
        SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES ('DoctorSettlement', 'DELETE', @n, 'doctor settlements / payout vouchers');
    END
END
ELSE
BEGIN
    SELECT @n = COUNT(1) FROM dbo.DoctorDisbursal WHERE @CompanyId IS NULL OR CompanyId = @CompanyId;
    INSERT INTO @Report VALUES ('DoctorDisbursal', 'KEPT', @n, 'kept (@ClearDisbursals = 0); they still refer to the cleared commission rules');
END

DELETE c FROM dbo.DoctorCommissionConfig c WHERE @CompanyId IS NULL OR c.CompanyId = @CompanyId;
SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES ('DoctorCommissionConfig', 'DELETE', @n, 'Doctor Commission Config rules (company-wide and branch)');

DELETE v FROM dbo.DoctorVisitProcessConfig v WHERE @CompanyId IS NULL OR v.CompanyId = @CompanyId;
SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES ('DoctorVisitProcessConfig', 'DELETE', @n, 'Doctor Visit Process rules (company-wide and branch)');

IF @ClearProfiles = 1 AND OBJECT_ID('dbo.DoctorPayoutProfile', 'U') IS NOT NULL
BEGIN
    DELETE p FROM dbo.DoctorPayoutProfile p WHERE @CompanyId IS NULL OR p.CompanyId = @CompanyId;
    SET @n = @@ROWCOUNT; INSERT INTO @Report VALUES ('DoctorPayoutProfile', 'DELETE', @n, 'doctor payout profiles (PAN, TDS, bank / UPI)');
END

-- numbering restarts at 1 for a table left empty (only when the run is kept)
IF @Execute = 1
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfig)   BEGIN DBCC CHECKIDENT ('dbo.DoctorCommissionConfig', RESEED, 0) WITH NO_INFOMSGS;   INSERT INTO @Report VALUES ('DoctorCommissionConfig', 'RESEED', 0, 'numbering restarts at 1'); END
    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorVisitProcessConfig) BEGIN DBCC CHECKIDENT ('dbo.DoctorVisitProcessConfig', RESEED, 0) WITH NO_INFOMSGS; INSERT INTO @Report VALUES ('DoctorVisitProcessConfig', 'RESEED', 0, 'numbering restarts at 1'); END
    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorDisbursal)          BEGIN DBCC CHECKIDENT ('dbo.DoctorDisbursal', RESEED, 0) WITH NO_INFOMSGS;          INSERT INTO @Report VALUES ('DoctorDisbursal', 'RESEED', 0, 'numbering restarts at 1'); END
    IF NOT EXISTS (SELECT 1 FROM dbo.DoctorBillingAdjustment)  BEGIN DBCC CHECKIDENT ('dbo.DoctorBillingAdjustment', RESEED, 0) WITH NO_INFOMSGS;  INSERT INTO @Report VALUES ('DoctorBillingAdjustment', 'RESEED', 0, 'numbering restarts at 1'); END
    IF OBJECT_ID('dbo.DoctorSettlement', 'U') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DoctorSettlement)
    BEGIN DBCC CHECKIDENT ('dbo.DoctorSettlement', RESEED, 0) WITH NO_INFOMSGS; INSERT INTO @Report VALUES ('DoctorSettlement', 'RESEED', 0, 'numbering restarts at 1'); END
    COMMIT TRANSACTION;
END
ELSE
    ROLLBACK TRANSACTION;

SELECT CASE WHEN @Execute = 1 THEN 'CLEARED' ELSE 'DRY RUN - nothing changed' END AS Result,
       DB_NAME() AS DatabaseName, ISNULL(CAST(@CompanyId AS VARCHAR(10)), 'ALL') AS CompanyId,
       TableName, Action, RowsAffected, Note
FROM @Report ORDER BY Step;

-- what is left (all companies)
SELECT 'DoctorVisitProcessConfig' AS TableName, COUNT(1) AS RowsLeft FROM dbo.DoctorVisitProcessConfig
UNION ALL SELECT 'DoctorCommissionConfig', COUNT(1) FROM dbo.DoctorCommissionConfig
UNION ALL SELECT 'DoctorDisbursal', COUNT(1) FROM dbo.DoctorDisbursal
UNION ALL SELECT 'DoctorBillingAdjustment', COUNT(1) FROM dbo.DoctorBillingAdjustment;

GO
