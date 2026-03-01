-- =============================================================================
-- Script : 16_patient_opd_service.sql
-- Purpose: Split OPD visit/service data out of PatientMaster into a new
--          PatientOPDService table so the same patient can have multiple
--          visits/services over time.
-- Safe to re-run (uses IF NOT EXISTS / IF EXISTS guards).
-- =============================================================================

-- ─── 1. Create PatientOPDService table ───────────────────────────────────────
IF OBJECT_ID('dbo.PatientOPDService', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PatientOPDService
    (
        OPDServiceId        INT IDENTITY(1,1)   NOT NULL CONSTRAINT PK_PatientOPDService PRIMARY KEY,
        PatientId           INT                 NOT NULL,
        BranchId            INT                 NULL,
        ConsultingDoctorId  INT                 NULL,
        ServiceType         NVARCHAR(20)        NULL,   -- 'Consulting' / 'Services'
        ServiceId           INT                 NULL,
        ServiceCharges      DECIMAL(10,2)       NULL,
        VisitDate           DATETIME2           NOT NULL CONSTRAINT DF_PatientOPDService_VisitDate    DEFAULT SYSUTCDATETIME(),
        Status              NVARCHAR(20)        NOT NULL CONSTRAINT DF_PatientOPDService_Status       DEFAULT 'Registered',
        IsActive            BIT                 NOT NULL CONSTRAINT DF_PatientOPDService_IsActive     DEFAULT 1,
        CreatedBy           INT                 NULL,
        CreatedDate         DATETIME2           NOT NULL CONSTRAINT DF_PatientOPDService_CreatedDate  DEFAULT SYSUTCDATETIME(),
        ModifiedBy          INT                 NULL,
        ModifiedDate        DATETIME2           NULL,

        CONSTRAINT FK_PatientOPDService_Patient
            FOREIGN KEY (PatientId) REFERENCES dbo.PatientMaster(PatientId)
    );

    CREATE INDEX IX_PatientOPDService_PatientId  ON dbo.PatientOPDService (PatientId);
    CREATE INDEX IX_PatientOPDService_BranchId   ON dbo.PatientOPDService (BranchId);
    CREATE INDEX IX_PatientOPDService_VisitDate  ON dbo.PatientOPDService (VisitDate DESC);

    PRINT 'Created table: PatientOPDService';
END
GO

-- ─── 2. Migrate existing service data from PatientMaster ─────────────────────
-- (Only if columns still exist on PatientMaster – i.e. first run)
IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PatientMaster') AND name = 'ConsultingDoctorId'
)
BEGIN
    -- Migrate rows that have any service data
    INSERT INTO dbo.PatientOPDService
        (PatientId, BranchId, ConsultingDoctorId, ServiceType, ServiceId,
         VisitDate, Status, CreatedBy, CreatedDate)
    SELECT
        PatientId,
        BranchId,
        ConsultingDoctorId,
        ServiceType,
        ServiceId,
        CreatedDate,        -- treat original registration date as first visit date
        'Registered',
        CreatedBy,
        CreatedDate
    FROM dbo.PatientMaster
    WHERE ConsultingDoctorId IS NOT NULL
       OR ServiceType        IS NOT NULL
       OR ServiceId          IS NOT NULL;

    PRINT CAST(@@ROWCOUNT AS NVARCHAR) + ' rows migrated to PatientOPDService.';
END
GO

-- ─── 3. Drop service columns from PatientMaster ──────────────────────────────
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PatientMaster') AND name = 'ConsultingDoctorId')
    ALTER TABLE dbo.PatientMaster DROP COLUMN ConsultingDoctorId;

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PatientMaster') AND name = 'ServiceType')
    ALTER TABLE dbo.PatientMaster DROP COLUMN ServiceType;

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.PatientMaster') AND name = 'ServiceId')
    ALTER TABLE dbo.PatientMaster DROP COLUMN ServiceId;
GO

PRINT 'Script 16 complete: PatientOPDService table created and PatientMaster cleaned up.';
GO
