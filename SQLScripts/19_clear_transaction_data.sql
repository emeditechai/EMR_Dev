-- ============================================================
-- Script 19: Clear Transaction Data (DEV / TEST RESET ONLY)
-- ⚠  DO NOT RUN ON PRODUCTION
--
-- Clears ALL patient and OPD booking transactions while
-- preserving all master / reference data:
--   ✔ Branchmaster, Users, Roles, UserBranches
--   ✔ DoctorMaster, DoctorBranchMap, DoctorDepartmentMap
--   ✔ ServiceMaster, DoctorConsultingFees
--   ✔ Geography masters (Country/State/District/City/Area)
--   ✔ ReligionMaster, OccupationMaster, MaritalStatusMaster
--   ✔ IdentificationTypeMaster, DepartmentMaster
--   ✔ FloorMaster, DoctorRoomMaster, DoctorSpecialityMaster
--
-- Tables cleared (FK order — child first):
--   1. PatientOPDServiceItem
--   2. PatientOPDService
--   3. PatientMaster
--   4. OPDBillSequence   (reset counters)
--   5. OPDTokenSequence  (reset counters)
--   6. PatientCodeSeq    (reseed to 0)
-- ============================================================

PRINT '=== Starting transaction data clear ===';
PRINT 'Server  : ' + @@SERVERNAME;
PRINT 'Database: ' + DB_NAME();
PRINT 'Time    : ' + CONVERT(NVARCHAR, GETDATE(), 120);
PRINT '';

BEGIN TRY
    BEGIN TRANSACTION;

    -- ── 1. Line items (child of PatientOPDService) ────────────────────────
    IF OBJECT_ID('dbo.PatientOPDServiceItem', 'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.PatientOPDServiceItem;
        PRINT 'Cleared: PatientOPDServiceItem  (' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows)';
    END
    ELSE
        PRINT 'Skipped: PatientOPDServiceItem (table does not exist)';

    -- ── 2. OPD Service / Bill headers (child of PatientMaster) ───────────
    IF OBJECT_ID('dbo.PatientOPDService', 'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.PatientOPDService;
        PRINT 'Cleared: PatientOPDService       (' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows)';
    END
    ELSE
        PRINT 'Skipped: PatientOPDService (table does not exist)';

    -- ── 3. Patient Master ─────────────────────────────────────────────────
    IF OBJECT_ID('dbo.PatientMaster', 'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.PatientMaster;
        PRINT 'Cleared: PatientMaster           (' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows)';
    END
    ELSE
        PRINT 'Skipped: PatientMaster (table does not exist)';

    -- ── 4. OPD Bill Sequence counters ─────────────────────────────────────
    IF OBJECT_ID('dbo.OPDBillSequence', 'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.OPDBillSequence;
        PRINT 'Reset  : OPDBillSequence          (' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows)';
    END
    ELSE
        PRINT 'Skipped: OPDBillSequence (table does not exist)';

    -- ── 5. OPD Token Sequence counters ────────────────────────────────────
    IF OBJECT_ID('dbo.OPDTokenSequence', 'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.OPDTokenSequence;
        PRINT 'Reset  : OPDTokenSequence         (' + CAST(@@ROWCOUNT AS NVARCHAR) + ' rows)';
    END
    ELSE
        PRINT 'Skipped: OPDTokenSequence (table does not exist)';

    -- ── 6. Reseed PatientCodeSeq to 0 (next patient gets P000001) ─────────
    IF EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'PatientCodeSeq' AND schema_id = SCHEMA_ID('dbo'))
    BEGIN
        ALTER SEQUENCE dbo.PatientCodeSeq RESTART WITH 1;
        PRINT 'Reseeded: PatientCodeSeq → next value = 1 (P000001)';
    END
    ELSE
        PRINT 'Skipped: PatientCodeSeq sequence does not exist';

    COMMIT TRANSACTION;
    PRINT '';
    PRINT '=== Transaction data cleared successfully ===';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT '*** ERROR — rollback performed ***';
    PRINT 'Message : ' + ERROR_MESSAGE();
    PRINT 'Line    : ' + CAST(ERROR_LINE() AS NVARCHAR);
    THROW;
END CATCH
GO
