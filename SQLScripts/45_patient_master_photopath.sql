USE [Dev_EMR];
GO

-- 1. Add PhotoPath column to PatientMaster if it does not exist
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PatientMaster')
      AND name = 'PhotoPath'
)
BEGIN
    ALTER TABLE dbo.PatientMaster
    ADD PhotoPath NVARCHAR(500) NULL;
    PRINT 'Column PhotoPath added to PatientMaster.';
END
ELSE
BEGIN
    PRINT 'Column PhotoPath already exists. Skipped.';
END
GO

-- 2. Update usp_Patient_Create
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
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
    @UserId                 INT             = NULL,

    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,

    @PatientCode            NVARCHAR(30)    OUTPUT,
    @NewPatientId           INT             OUTPUT,
    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RelName     NVARCHAR(100);
    DECLARE @Now         DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate   DATE;

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

        SET @Now = SYSUTCDATETIME();

        INSERT INTO dbo.PatientMaster
        (
            PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
            FirstName, MiddleName, LastName, Gender, DateOfBirth, ReligionId, EmailId,
            GuardianName, CountryId, StateId, DistrictId, CityId, AreaId, Address,
            RelationId,
            IdentificationTypeId, IdentificationNumber, IdentificationFilePath,
            PhotoPath,
            OccupationId, MaritalStatusId, BloodGroup, KnownAllergies, Remarks,
            BranchId, IsActive, CreatedBy, CreatedDate
        )
        VALUES
        (
            @PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
            @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth, @ReligionId, @EmailId,
            @GuardianName, @CountryId, @StateId, @DistrictId, @CityId, @AreaId, @Address,
            @RelationId,
            @IdentificationTypeId, @IdentificationNumber, @IdentificationFilePath,
            @PhotoPath,
            @OccupationId, @MaritalStatusId, @BloodGroup, @KnownAllergies, @Remarks,
            @BranchId, 1, @UserId, @Now
        );

        SET @NewPatientId = SCOPE_IDENTITY();

        -- Generate Bill No
        EXEC dbo.usp_OPD_GetNextBillNo @BranchId, @OPDBillNo OUTPUT;

        -- Token is NOT generated here — NULL until full payment
        SET @TokenNo = NULL;

        -- Calculate total
        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- Exception: zero-amount bills get token immediately (no payment required)
        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate,
            ScheduleId, AppointmentTime
        ) VALUES (
            @NewPatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
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

-- 3. Update usp_Patient_Update
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Patient_Update
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
    @UserId                 INT             = NULL,

    @ConsultingDoctorId     INT             = NULL,
    @LineItemsJson          NVARCHAR(MAX)   = NULL,

    @ScheduleId             INT             = NULL,
    @AppointmentDate        DATE            = NULL,
    @AppointmentTime        TIME            = NULL,

    @NewOPDServiceId        INT             OUTPUT,
    @OPDBillNo              NVARCHAR(30)    OUTPUT,
    @TokenNo                NVARCHAR(20)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RelName2    NVARCHAR(100);
    DECLARE @Now2        DATETIME2;
    DECLARE @TotalAmount DECIMAL(10,2);
    DECLARE @TokenDate   DATE;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Uniqueness check on update
        IF @RelationId IS NOT NULL AND EXISTS (
            SELECT 1 FROM dbo.PatientMaster
            WHERE  PhoneNumber = @PhoneNumber
              AND  RelationId  = @RelationId
              AND  IsActive    = 1
              AND  PatientId  <> @PatientId
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
            Address                = @Address,
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
            ModifiedBy             = @UserId,
            ModifiedDate           = @Now2
        WHERE PatientId = @PatientId;

        -- Calculate total
        SET @TotalAmount = 0;
        IF @LineItemsJson IS NOT NULL AND LEN(@LineItemsJson) > 2
            SELECT @TotalAmount = ISNULL(SUM(CAST(JSON_VALUE(j.value,'$.serviceCharges') AS DECIMAL(10,2))), 0)
            FROM OPENJSON(@LineItemsJson) j;

        -- Bill No generated, Token remains NULL until payment
        EXEC dbo.usp_OPD_GetNextBillNo @BranchId, @OPDBillNo OUTPUT;
        SET @TokenNo = NULL;

        -- Exception: zero-amount bills get token immediately
        IF @TotalAmount = 0
        BEGIN
            SET @TokenDate = ISNULL(@AppointmentDate, CAST(GETDATE() AS DATE));
            EXEC dbo.usp_OPD_GetNextTokenNo @BranchId, @TokenDate, @TokenNo OUTPUT;
        END

        INSERT INTO dbo.PatientOPDService (
            PatientId, BranchId, ConsultingDoctorId,
            OPDBillNo, TokenNo, TotalAmount,
            VisitDate, Status, IsActive, CreatedBy, CreatedDate,
            ScheduleId, AppointmentTime
        ) VALUES (
            @PatientId, @BranchId, @ConsultingDoctorId,
            @OPDBillNo, @TokenNo, @TotalAmount,
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

-- 4. Update usp_Api_Patient_Create
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_Create
    @PhoneNumber            NVARCHAR(15),
    @SecondaryPhoneNumber   NVARCHAR(15)   = NULL,
    @Salutation             NVARCHAR(10)   = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)  = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE           = NULL,
    @EmailId                NVARCHAR(150)  = NULL,
    @GuardianName           NVARCHAR(200)  = NULL,
    @Address                NVARCHAR(500)  = NULL,
    @RelationId             INT            = NULL,
    @BloodGroup             NVARCHAR(10)   = NULL,
    @KnownAllergies         NVARCHAR(500)  = NULL,
    @Remarks                NVARCHAR(1000) = NULL,
    @BranchId               INT            = NULL,
    @PhotoPath              NVARCHAR(500)  = NULL,
    @UserId                 INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PatientCode NVARCHAR(30);
    DECLARE @Seq INT;

    SELECT @Seq = ISNULL(MAX(CAST(SUBSTRING(PatientCode, LEN(PatientCode)-3, 4) AS INT)), 0) + 1
    FROM PatientMaster
    WHERE BranchId = @BranchId
      AND PatientCode LIKE '%-%';

    SET @PatientCode = ISNULL(CAST(@BranchId AS NVARCHAR), 'GEN')
                    + '-' + CONVERT(NVARCHAR, GETDATE(), 112)
                    + '-' + RIGHT('0000' + CAST(@Seq AS NVARCHAR), 4);

    INSERT INTO PatientMaster
        (PatientCode, PhoneNumber, SecondaryPhoneNumber, Salutation,
         FirstName, MiddleName, LastName, Gender, DateOfBirth,
         EmailId, GuardianName, Address, RelationId,
         BloodGroup, KnownAllergies, Remarks, BranchId, PhotoPath,
         IsActive, CreatedBy, CreatedDate)
    VALUES
        (@PatientCode, @PhoneNumber, @SecondaryPhoneNumber, @Salutation,
         @FirstName, @MiddleName, @LastName, @Gender, @DateOfBirth,
         @EmailId, @GuardianName, @Address, @RelationId,
         @BloodGroup, @KnownAllergies, @Remarks, @BranchId, @PhotoPath,
         1, @UserId, GETDATE());

    SELECT CAST(SCOPE_IDENTITY() AS INT);
END
GO

-- 5. Update usp_Api_Patient_Update
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_Update
    @PatientId              INT,
    @PhoneNumber            NVARCHAR(15),
    @SecondaryPhoneNumber   NVARCHAR(15)   = NULL,
    @Salutation             NVARCHAR(10)   = NULL,
    @FirstName              NVARCHAR(100),
    @MiddleName             NVARCHAR(100)  = NULL,
    @LastName               NVARCHAR(100),
    @Gender                 NVARCHAR(10),
    @DateOfBirth            DATE           = NULL,
    @EmailId                NVARCHAR(150)  = NULL,
    @GuardianName           NVARCHAR(200)  = NULL,
    @Address                NVARCHAR(500)  = NULL,
    @RelationId             INT            = NULL,
    @BloodGroup             NVARCHAR(10)   = NULL,
    @KnownAllergies         NVARCHAR(500)  = NULL,
    @Remarks                NVARCHAR(1000) = NULL,
    @PhotoPath              NVARCHAR(500)  = NULL,
    @UserId                 INT            = NULL
AS
BEGIN
    SET NOCOUNT OFF;

    UPDATE PatientMaster SET
        PhoneNumber          = @PhoneNumber,
        SecondaryPhoneNumber = @SecondaryPhoneNumber,
        Salutation           = @Salutation,
        FirstName            = @FirstName,
        MiddleName           = @MiddleName,
        LastName             = @LastName,
        Gender               = @Gender,
        DateOfBirth          = @DateOfBirth,
        EmailId              = @EmailId,
        GuardianName         = @GuardianName,
        Address              = @Address,
        RelationId           = @RelationId,
        BloodGroup           = @BloodGroup,
        KnownAllergies       = @KnownAllergies,
        Remarks              = @Remarks,
        PhotoPath            = @PhotoPath,
        ModifiedBy           = @UserId,
        ModifiedDate         = GETDATE()
    WHERE PatientId = @PatientId;
END
GO

-- 6. Update usp_Api_Patient_GetById
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_Patient_GetById
    @PatientId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PatientId,
        p.PatientCode,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ','') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ','') +
            p.LastName
        ))                          AS FullName,
        p.Salutation,
        p.FirstName,
        p.MiddleName,
        p.LastName,
        p.PhoneNumber,
        p.SecondaryPhoneNumber,
        p.Gender,
        p.DateOfBirth,
        p.BloodGroup,
        p.EmailId,
        p.GuardianName,
        p.Address,
        p.BranchId,
        p.IsActive,
        p.RelationId,
        r.RelationName,
        p.KnownAllergies,
        p.Remarks,
        p.CreatedDate,
        p.PhotoPath,
        (SELECT TOP 1 OPDBillNo
         FROM PatientOPDService
         WHERE PatientId = p.PatientId
         ORDER BY CreatedDate DESC)  AS LastOpdBillNo
    FROM PatientMaster p
    LEFT JOIN RelationMaster r ON r.RelationId = p.RelationId
    WHERE p.PatientId = @PatientId;
END
GO

-- 7. Update usp_Api_DoctorDashboard_GetQueue to select p.PhotoPath
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorDashboard_GetQueue
    @BranchId INT,
    @DoctorId INT = NULL,
    @Date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Date IS NULL SET @Date = CAST(GETDATE() AS DATE);

    -- ResultSet 1: Consulting queue list
    SELECT 
        s.OPDServiceId,
        s.VisitDate,
        s.OPDBillNo,
        s.TokenNo,
        p.PatientCode,
        p.PatientId,
        LTRIM(RTRIM(
            ISNULL(p.Salutation + ' ', '') +
            p.FirstName + ' ' +
            ISNULL(p.MiddleName + ' ', '') +
            p.LastName
        ))                           AS PatientName,
        p.Gender,
        CASE
            WHEN p.DateOfBirth IS NULL THEN NULL
            ELSE DATEDIFF(YEAR, p.DateOfBirth, GETDATE())
                 - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.DateOfBirth, GETDATE()), p.DateOfBirth) > GETDATE() THEN 1 ELSE 0 END
        END                          AS Age,
        d.FullName                   AS ConsultingDoctorName,
        ISNULL(s.TotalAmount, 0)     AS TotalAmount,
        s.Status,
        p.PhotoPath,
        (SELECT TOP 1 PaymentStatus FROM PaymentHeader 
         WHERE ModuleCode = 'OPD' AND ModuleRefId = s.OPDServiceId AND IsActive = 1) AS PaymentStatus
    FROM PatientOPDService s
    INNER JOIN PatientMaster p ON p.PatientId = s.PatientId
    LEFT JOIN DoctorMaster d ON d.DoctorId = s.ConsultingDoctorId
    WHERE s.BranchId = @BranchId
      AND CAST(s.VisitDate AS DATE) = @Date
      AND s.IsActive = 1
      AND p.IsActive = 1
      AND s.Status IN ('Consulting', 'Completed', 'Skipped')
      AND (@DoctorId IS NULL OR @DoctorId = 0 OR s.ConsultingDoctorId = @DoctorId)
    ORDER BY 
        CASE 
            WHEN s.Status = 'Consulting' THEN 0 
            WHEN s.Status = 'Skipped' THEN 1 
            ELSE 2 
        END ASC,
        s.TokenNo ASC;

    -- ResultSet 2: Summary Stats
    SELECT 
        -- Total waiting/skipped in active consulting queue today for this doctor
        (SELECT COUNT(*) 
         FROM PatientOPDService 
         WHERE BranchId = @BranchId 
           AND CAST(VisitDate AS DATE) = @Date 
           AND IsActive = 1 
           AND Status IN ('Consulting', 'Skipped')
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalWaiting,

        -- Total completed consultations today for this doctor
        (SELECT COUNT(*) 
         FROM PatientOPDService 
         WHERE BranchId = @BranchId 
           AND CAST(VisitDate AS DATE) = @Date 
           AND IsActive = 1 
           AND Status = 'Completed'
           AND (@DoctorId IS NULL OR @DoctorId = 0 OR ConsultingDoctorId = @DoctorId)) AS TotalCompleted;
END
GO
