-- 2330 Patient uniqueness company-wise: one active "Self" patient per phone number WITHIN a company
--   (same phone may be registered once in each company). New patients get the branch's company.
--   Procedures: usp_PatientMaster_Insert, usp_Patient_Create, usp_Patient_Update. Index UIX_PatientMaster_Phone_Self -> (CompanyId, PhoneNumber).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UIX_PatientMaster_Phone_Self' AND object_id=OBJECT_ID('dbo.PatientMaster'))
    DROP INDEX UIX_PatientMaster_Phone_Self ON dbo.PatientMaster;
GO
CREATE UNIQUE INDEX UIX_PatientMaster_Phone_Self ON dbo.PatientMaster (CompanyId, PhoneNumber) WHERE RelationId = 1 AND IsActive = 1;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_PatientMaster_Insert]
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
    @LanguageId             INT             = NULL,
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
    DECLARE @PatCompanyId INT;   -- 2330: the patient's company (from the branch); phone rule is per company
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;
        SELECT @PatCompanyId = COALESCE((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), NULLIF(@CompanyId, 0), 1);

        IF @RelationId IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.RelationMaster WHERE RelationId = @RelationId AND RelationName = N'Self')   -- only "Self" is unique per phone (2221)
           AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber AND RelationId = @RelationId AND IsActive = 1 AND CompanyId = @PatCompanyId
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
            HomeCollectionAddress, Latitude, Longitude, RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath, PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            LanguageId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @HomeCollectionAddress, @Latitude, @Longitude, @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath, @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @LanguageId, @BranchId, @PatCompanyId, 1, @CreatedBy, @Now
        );
        SET @NewPatientId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrSev INT = ERROR_SEVERITY();
        DECLARE @ErrSt  INT = ERROR_STATE();
        RAISERROR(@ErrMsg, @ErrSev, @ErrSt);
    END CATCH
END
GO


-- Update usp_Patient_Create
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Create
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
    @LanguageId             INT             = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,
    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,
    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,
    @PatientCode            NVARCHAR(50)    OUTPUT,
    @OPDBillNo              NVARCHAR(50)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RelName NVARCHAR(100);
    DECLARE @PatCompanyId INT;   -- 2330: the patient's company (from the branch); phone rule is per company
    DECLARE @Now DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate DATE;

    BEGIN TRY
        BEGIN TRANSACTION;
        SELECT @PatCompanyId = COALESCE((SELECT CompanyId FROM dbo.BranchMaster WHERE BranchId = @BranchId), 1);

        IF @RelationId IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.RelationMaster WHERE RelationId = @RelationId AND RelationName = N'Self')   -- only "Self" is unique per phone (2221)
           AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber AND RelationId = @RelationId AND IsActive = 1 AND CompanyId = @PatCompanyId
        )
        BEGIN
            SELECT @RelName = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName, @PhoneNumber);
        END

        SET @Now = SYSUTCDATETIME();
        EXEC dbo.usp_Patient_GetNextCode @BranchId, @PatientCode OUTPUT;
        EXEC dbo.usp_OPD_GetNextBillNo  @BranchId, @OPDBillNo OUTPUT;
        SET @TokenNo = NULL;

        IF (@Address IS NULL OR LTRIM(RTRIM(@Address)) = '') AND (@HomeCollectionAddress IS NOT NULL AND LTRIM(RTRIM(@HomeCollectionAddress)) <> '')
            SET @Address = @HomeCollectionAddress;

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            HomeCollectionAddress, Latitude, Longitude, RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath, PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            LanguageId, BranchId, CompanyId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @HomeCollectionAddress, @Latitude, @Longitude, @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath, @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @LanguageId, @BranchId, @PatCompanyId, 1, @UserId, @Now
        );
        SET @NewPatientId = SCOPE_IDENTITY();

        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId, OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate, ScheduleId, AppointmentTime
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId, @OPDBillNo, @TokenNo, @TotalAmount,
            ISNULL(@AppointmentDate, GETDATE()), 'Registered', 1, @UserId, GETDATE(),
            @ScheduleId, @AppointmentTime
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT @NewOPDServiceId,
                JSON_VALUE(j.value,'$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETDATE()
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

CREATE OR ALTER PROCEDURE [dbo].[usp_Patient_Update]
(
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
    @LanguageId             INT             = NULL,
    @BranchId               INT             = NULL,
    @UserId                 INT             = NULL,
    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,
    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(50)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RelName2    NVARCHAR(100);
    DECLARE @PatCompanyId INT;   -- 2330: the patient's company (from the branch); phone rule is per company
    DECLARE @Now2        DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate   DATE;

    BEGIN TRY
        BEGIN TRANSACTION;
        SELECT @PatCompanyId = CompanyId FROM dbo.PatientMaster WHERE PatientId = @PatientId;

        IF @RelationId IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.RelationMaster WHERE RelationId = @RelationId AND RelationName = N'Self')   -- only "Self" is unique per phone (2221)
           AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE PhoneNumber = @PhoneNumber AND RelationId = @RelationId AND IsActive = 1 AND PatientId <> @PatientId AND CompanyId = @PatCompanyId
        )
        BEGIN
            SELECT @RelName2 = RelationName FROM dbo.RelationMaster WHERE RelationId = @RelationId;
            RAISERROR(N'A patient with relation "%s" is already registered for phone number %s.', 16, 1, @RelName2, @PhoneNumber);
        END

        SET @Now2 = SYSUTCDATETIME();

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
            Address                = CASE
                                        WHEN @Address IS NOT NULL AND LTRIM(RTRIM(@Address)) <> '' THEN @Address
                                        WHEN Address IS NOT NULL AND LTRIM(RTRIM(Address)) <> '' THEN Address
                                        WHEN @HomeCollectionAddress IS NOT NULL AND LTRIM(RTRIM(@HomeCollectionAddress)) <> '' THEN @HomeCollectionAddress
                                        ELSE HomeCollectionAddress
                                     END,
            HomeCollectionAddress  = ISNULL(@HomeCollectionAddress, HomeCollectionAddress),
            Latitude               = ISNULL(@Latitude, Latitude),
            Longitude              = ISNULL(@Longitude, Longitude),
            RelationId             = @RelationId,
            IdentificationTypeId   = @IdentificationTypeId,
            IdentificationNumber   = @IdentificationNumber,
            IdentificationFilePath = @IdentificationFilePath,
            PhotoPath              = @PhotoPath,
            OccupationId           = @OccupationId,
            MaritalStatusId        = @MaritalStatusId,
            BloodGroup             = @BloodGroup,
            KnownAllergies         = @KnownAllergies,
            Remarks                = @Remarks,
            LanguageId             = @LanguageId,
            ModifiedBy             = @UserId,
            ModifiedDate           = @Now2
        WHERE PatientId = @PatientId;

        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        EXEC dbo.usp_OPD_GetNextBillNo @BranchId, @OPDBillNo OUTPUT;
        SET @TokenNo = NULL;

        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId, OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate, ScheduleId, AppointmentTime
        ) VALUES (
            @PatientId, @BranchId, @ConsultingDoctorId, @OPDBillNo, @TokenNo, @TotalAmount,
            ISNULL(@AppointmentDate, GETDATE()), 'Registered', 1, @UserId, GETDATE(),
            @ScheduleId, @AppointmentTime
        );
        SET @NewOPDServiceId = SCOPE_IDENTITY();

        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
        BEGIN
            INSERT INTO dbo.PatientOPDServiceItem
                (OPDServiceId, ServiceType, ServiceId, ServiceCharges, IsActive, CreatedBy, CreatedDate)
            SELECT @NewOPDServiceId,
                JSON_VALUE(j.value,'$.serviceType'),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceId') AS INT),
                TRY_CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2)),
                1, @UserId, GETDATE()
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

PRINT 'Script 2330 applied: Self patient phone unique per company.';
GO
