-- ============================================================
-- Script 24: Add Address field to PatientMaster
-- ============================================================
-- 1. ALTER TABLE  – add Address column (idempotent)
-- 2. UPDATE       usp_Patient_Create  to accept @Address
-- 3. UPDATE       usp_Patient_Update  to accept @Address
-- ============================================================

-- ─── 1. Add column ────────────────────────────────────────────────────────────
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PatientMaster') AND name = 'Address'
)
BEGIN
    ALTER TABLE dbo.PatientMaster
        ADD [Address] NVARCHAR(500) NULL;
    PRINT 'Column PatientMaster.Address added.';
END
ELSE
    PRINT 'Column PatientMaster.Address already exists – skipped.';
GO

-- ─── 2. usp_Patient_Create ────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
(
    -- PatientMaster fields
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
    @Address                NVARCHAR(500)   = NULL,
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

    -- PatientOPDService fields
    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    -- Output
    @PatientCode            NVARCHAR(30)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(
                SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

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

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId')      AS INT),
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
END
GO

-- ─── 3. usp_Patient_Update ────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Update
(
    @PatientId              INT,
    -- PatientMaster fields
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
    @Address                NVARCHAR(500)   = NULL,
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

    -- PatientOPDService fields
    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    -- Output
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Now DATETIME2 = SYSUTCDATETIME();

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
            Address                = @Address,
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

        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenNo   OUTPUT;

        DECLARE @TotalAmount DECIMAL(10,2) = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(
                SUM(CAST(JSON_VALUE(j.value, '$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

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

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT
                @NewOPDServiceId,
                JSON_VALUE(j.value, '$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value, '$.serviceId')      AS INT),
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
END
GO

PRINT 'Script 24 complete: PatientMaster.Address column + SPs updated.';
