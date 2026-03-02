-- =============================================================================
-- Script : 22_usp_Patient_Create_Update_v2.sql
-- Purpose: Re-creates usp_Patient_Create and usp_Patient_Update with the new
--          @DateOfBirth parameter.
-- Safe to re-run (uses CREATE OR ALTER).
-- Run AFTER 21_add_dateofbirth_column.sql.
-- =============================================================================

-- ─── 1. usp_Patient_Create ───────────────────────────────────────────────────
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
    @DateOfBirth            DATE            = NULL,
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
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    -- ── Output ────────────────────────────────────────────────────────────────
    @PatientCode            NVARCHAR(20)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(20)    OUTPUT,
    @TokenNo                NVARCHAR(15)    OUTPUT
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
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        -- Generate Bill No and Token No (branch-wise, via helper SPs)
        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        -- Compute total from line items JSON
        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- Insert OPD Bill header
        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
            GETUTCDATE(), 'Registered', 1, @UserId, GETUTCDATE()
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        -- Insert line items
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETUTCDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

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
    @DateOfBirth            DATE            = NULL,
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
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    -- ── Output ────────────────────────────────────────────────────────────────
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(20)    OUTPUT,
    @TokenNo                NVARCHAR(15)    OUTPUT
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
            DateOfBirth            = @DateOfBirth,
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

        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        IF @OPDServiceId > 0
        BEGIN
            -- Update existing bill header (same visit re-save)
            UPDATE dbo.PatientOPDService SET
                ConsultingDoctorId = @ConsultingDoctorId,
                TotalAmount        = @TotalAmount,
                ModifiedBy         = @UserId,
                ModifiedDate       = GETUTCDATE()
            WHERE OPDServiceId = @OPDServiceId;

            SET @NewOPDServiceId = @OPDServiceId;

            -- Delete & re-insert line items
            DELETE FROM dbo.PatientOPDServiceItem WHERE OPDServiceId = @OPDServiceId;

            SELECT @OPDBillNo = OPDBillNo, @TokenNo = TokenNo
            FROM dbo.PatientOPDService WHERE OPDServiceId = @OPDServiceId;
        END
        ELSE
        BEGIN
            -- New visit for returning patient (branch-wise)
            EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

            INSERT INTO dbo.PatientOPDService (
                PatientId, BranchId, ConsultingDoctorId,
                OPDBillNo, TokenNo, TotalAmount,
                VisitDate, Status, IsActive, CreatedBy, CreatedDate
            ) VALUES (
                @PatientId, @BranchId, @ConsultingDoctorId,
                @OPDBillNo, @TokenNo, @TotalAmount,
                GETUTCDATE(), 'Registered', 1, @UserId, GETUTCDATE()
            );
            SET @NewOPDServiceId = SCOPE_IDENTITY();
        END

        -- Insert line items
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETUTCDATE()
            FROM OPENJSON(@LineItemsJson) j;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

PRINT 'Script 22 complete: usp_Patient_Create and usp_Patient_Update updated with DateOfBirth.';
GO
