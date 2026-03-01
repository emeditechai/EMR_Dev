-- =============================================================================
-- Script : 17_patient_stored_procedures.sql
-- Purpose: Stored procedures for Patient Registration save operations.
--          Replaces hardcoded inline SQL in PatientService.cs.
-- Safe to re-run (uses CREATE OR ALTER).
-- =============================================================================

-- ─── 1. usp_Patient_Create ───────────────────────────────────────────────────
-- Creates a new PatientMaster row + a linked PatientOPDService row in a single
-- transaction.  Returns @PatientCode and @NewPatientId as OUTPUT parameters.
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
(
    -- ── PatientMaster fields ──────────────────────────────────────────────────
    @PhoneNumber            NVARCHAR(20),
    @SecondaryPhoneNumber   NVARCHAR(20)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(200)   = NULL,
    @GuardianName           NVARCHAR(200)   = NULL,
    @CountryId              INT             = NULL,
    @StateId                INT             = NULL,
    @DistrictId             INT             = NULL,
    @CityId                 INT             = NULL,
    @AreaId                 INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,

    -- ── PatientOPDService fields ──────────────────────────────────────────────
    @ConsultingDoctorId     INT             = NULL,
    @ServiceType            NVARCHAR(20)    = NULL,
    @ServiceId              INT             = NULL,
    @ServiceCharges         DECIMAL(10,2)   = NULL,

    -- ── Output ────────────────────────────────────────────────────────────────
    @PatientCode            NVARCHAR(20)    OUTPUT,
    @NewPatientId           INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Generate next sequence value → format P000001
        DECLARE @SeqVal INT = NEXT VALUE FOR dbo.PatientCodeSeq;
        SET @PatientCode = 'P' + RIGHT('000000' + CAST(@SeqVal AS NVARCHAR(6)), 6);

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

        -- INSERT PatientMaster
        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        -- INSERT PatientOPDService
        INSERT INTO dbo.PatientOPDService
        (
            PatientId, BranchId, ConsultingDoctorId, ServiceType, ServiceId, ServiceCharges,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @NewPatientId, @BranchId, @ConsultingDoctorId, @ServiceType, @ServiceId, @ServiceCharges,
            @Now, 'Registered', 1, @UserId, @Now
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

-- =============================================================================
-- ─── 2. usp_Patient_Update ───────────────────────────────────────────────────
-- Updates PatientMaster demographics and either:
--   • INSERTs a new PatientOPDService row  (when @OPDServiceId = 0 → new visit)
--   • UPDATEs the specified PatientOPDService row (when @OPDServiceId > 0)
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Update
(
    -- ── PatientMaster fields ──────────────────────────────────────────────────
    @PatientId              INT,
    @PhoneNumber            NVARCHAR(20),
    @SecondaryPhoneNumber   NVARCHAR(20)    = NULL,
    @Salutation             NVARCHAR(10)    = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)   = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @ReligionId             INT             = NULL,
    @EmailId                NVARCHAR(200)   = NULL,
    @GuardianName           NVARCHAR(200)   = NULL,
    @CountryId              INT             = NULL,
    @StateId                INT             = NULL,
    @DistrictId             INT             = NULL,
    @CityId                 INT             = NULL,
    @AreaId                 INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @UserId                 INT             = NULL,

    -- ── PatientOPDService fields ──────────────────────────────────────────────
    @OPDServiceId           INT             = 0,    -- 0 = new visit, >0 = update existing
    @BranchId               INT             = NULL,
    @ConsultingDoctorId     INT             = NULL,
    @ServiceType            NVARCHAR(20)    = NULL,
    @ServiceId              INT             = NULL,
    @ServiceCharges         DECIMAL(10,2)   = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

        -- UPDATE PatientMaster demographics
        UPDATE dbo.PatientMaster SET
            PhoneNumber            = @PhoneNumber,
            SecondaryPhoneNumber   = @SecondaryPhoneNumber,
            Salutation             = @Salutation,
            FirstName              = @FirstName,
            MiddleName             = @MiddleName,
            LastName               = @LastName,
            Gender                 = @Gender,
            ReligionId             = @ReligionId,
            EmailId                = @EmailId,
            GuardianName           = @GuardianName,
            CountryId              = @CountryId,
            StateId                = @StateId,
            DistrictId             = @DistrictId,
            CityId                 = @CityId,
            AreaId                 = @AreaId,
            IdentificationTypeId   = @IdentificationTypeId,
            IdentificationNumber   = @IdentificationNumber,
            IdentificationFilePath = @IdentificationFilePath,
            OccupationId           = @OccupationId,
            MaritalStatusId        = @MaritalStatusId,
            BloodGroup             = @BloodGroup,
            KnownAllergies         = @KnownAllergies,
            Remarks                = @Remarks,
            ModifiedBy             = @UserId,
            ModifiedDate           = @Now
        WHERE PatientId = @PatientId;

        -- Upsert PatientOPDService
        IF @OPDServiceId > 0
        BEGIN
            -- Edit an existing visit row
            UPDATE dbo.PatientOPDService SET
                ConsultingDoctorId = @ConsultingDoctorId,
                ServiceType        = @ServiceType,
                ServiceId          = @ServiceId,
                ServiceCharges     = @ServiceCharges,
                ModifiedBy         = @UserId,
                ModifiedDate       = @Now
            WHERE OPDServiceId = @OPDServiceId;
        END
        ELSE
        BEGIN
            -- New visit for an existing patient
            INSERT INTO dbo.PatientOPDService
            (
                PatientId, BranchId, ConsultingDoctorId, ServiceType, ServiceId, ServiceCharges,
                VisitDate, Status, IsActive, CreatedBy, CreatedDate
            )
            VALUES
            (
                @PatientId, @BranchId, @ConsultingDoctorId, @ServiceType, @ServiceId, @ServiceCharges,
                @Now, 'Registered', 1, @UserId, @Now
            );
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

PRINT 'Script 17 complete: usp_Patient_Create and usp_Patient_Update created/updated.';
GO
