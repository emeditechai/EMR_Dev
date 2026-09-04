-- =============================================================
-- Migration 2023: Add HomeCollectionAddress, Latitude, and Longitude
-- to PatientMaster table and update usp_PatientMaster_Insert
-- =============================================================

-- 1. Add HomeCollectionAddress column if it does not exist
IF NOT EXISTS (
    SELECT 1 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' 
      AND COLUMN_NAME = 'HomeCollectionAddress'
)
BEGIN
    ALTER TABLE dbo.PatientMaster ADD HomeCollectionAddress NVARCHAR(500) NULL;
    PRINT 'Added HomeCollectionAddress column to PatientMaster table.';
END
ELSE
BEGIN
    PRINT 'HomeCollectionAddress column already exists in PatientMaster table.';
END
GO

-- 2. Add Latitude column if it does not exist
IF NOT EXISTS (
    SELECT 1 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' 
      AND COLUMN_NAME = 'Latitude'
)
BEGIN
    ALTER TABLE dbo.PatientMaster ADD Latitude DECIMAL(10, 8) NULL;
    PRINT 'Added Latitude column to PatientMaster table.';
END
ELSE
BEGIN
    PRINT 'Latitude column already exists in PatientMaster table.';
END
GO

-- 3. Add Longitude column if it does not exist
IF NOT EXISTS (
    SELECT 1 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = 'PatientMaster' 
      AND COLUMN_NAME = 'Longitude'
)
BEGIN
    ALTER TABLE dbo.PatientMaster ADD Longitude DECIMAL(11, 8) NULL;
    PRINT 'Added Longitude column to PatientMaster table.';
END
ELSE
BEGIN
    PRINT 'Longitude column already exists in PatientMaster table.';
END
GO

-- 4. Update dbo.usp_PatientMaster_Insert stored procedure
CREATE OR ALTER PROCEDURE dbo.usp_PatientMaster_Insert
(
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
    @HomeCollectionAddress  NVARCHAR(500)   = NULL,
    @Latitude               DECIMAL(10, 8)  = NULL,
    @Longitude              DECIMAL(11, 8)  = NULL,
    @RelationId             INT             = NULL,
    @IdentificationTypeId   INT             = NULL,
    @IdentificationNumber   NVARCHAR(100)   = NULL,
    @IdentificationFilePath NVARCHAR(500)   = NULL,
    @PhotoPath              NVARCHAR(500)   = NULL,
    @OccupationId           INT             = NULL,
    @MaritalStatusId        INT             = NULL,
    @BloodGroup             NVARCHAR(10)    = NULL,
    @KnownAllergies         NVARCHAR(500)   = NULL,
    @Remarks                NVARCHAR(500)   = NULL,
    @BranchId               INT             = NULL,
    @CompanyId              INT             = NULL,
    @CreatedBy              INT             = NULL,

    @PatientCode            NVARCHAR(50)    OUTPUT,
    @NewPatientId           INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RelName NVARCHAR(100);
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Uniqueness check: PhoneNumber + RelationId
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE  PhoneNumber = @PhoneNumber
              AND  RelationId  = @RelationId
              AND  IsActive    = 1
        )
        BEGIN
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            HomeCollectionAddress, Latitude, Longitude,
            RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, CompanyId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @HomeCollectionAddress, @Latitude, @Longitude,
            @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, ISNULL(@CompanyId, 1), 1, @CreatedBy, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT            = ERROR_SEVERITY();
        DECLARE @ErrSt  INT            = ERROR_STATE();
        RAISERROR(@ErrMsg, @ErrSev, @ErrSt);
    END CATCH
END
GO
