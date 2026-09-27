-- =============================================
-- Script : 2147_lab_expert_rule_master.sql
-- Purpose: Expert Rule Master — table and stored procedures.
-- CAP/NABL: Audit trail (Created/Modified By/Date), soft delete, company scope.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabExpertRuleMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabExpertRuleMaster
    (
        Rule_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                INT NOT NULL DEFAULT 1,
        Rule_Code NVARCHAR(50) NOT NULL,
        Rule_Type                NVARCHAR(50) NOT NULL,
        Organism_Category        NVARCHAR(50) NULL,
        Organism_ID              INT NULL,
        Antibiotic_ID            INT NOT NULL,
        Trigger_Result           NVARCHAR(5) NOT NULL,
        Rule_Action              NVARCHAR(30) NOT NULL,
        Alert_Message            NVARCHAR(300) NOT NULL,
        Status                   BIT NOT NULL DEFAULT 1,
        IsDeleted                BIT NOT NULL DEFAULT 0,
        CreatedBy                INT NULL,
        CreatedDate              DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME2 NULL
    );
    CREATE INDEX IX_LabExpertRuleMaster_Status ON dbo.LabExpertRuleMaster(Status);
    CREATE UNIQUE INDEX UX_LabExpertRuleMaster_Code ON dbo.LabExpertRuleMaster(Rule_Code);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_GetList
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL,
    @CompanyId INT = NULL,
    @Organism_ID INT = NULL,
    @Antibiotic_ID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Rule_ID,
        m.CompanyId,
        m.Rule_Code,
        m.Rule_Type,
        m.Organism_Category,
        m.Organism_ID,
        j2.Organism_Name AS Organism_Name,
        m.Antibiotic_ID,
        j3.Antibiotic_Name AS Antibiotic_Name,
        m.Trigger_Result,
        m.Rule_Action,
        m.Alert_Message,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabExpertRuleMaster m
    LEFT JOIN dbo.LabOrganismMaster j2 ON j2.Organism_ID = m.Organism_ID
    LEFT JOIN dbo.LabAntibioticMaster j3 ON j3.Antibiotic_ID = m.Antibiotic_ID
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Organism_ID IS NULL OR m.Organism_ID = @Organism_ID)
      AND (@Antibiotic_ID IS NULL OR m.Antibiotic_ID = @Antibiotic_ID)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR
           m.Rule_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Alert_Message LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Rule_Type LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Organism_Category LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Trigger_Result LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Rule_Action LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY m.Rule_Type, j2.Organism_Name, j3.Antibiotic_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Rule_ID,
        m.CompanyId,
        m.Rule_Code,
        m.Rule_Type,
        m.Organism_Category,
        m.Organism_ID,
        j2.Organism_Name AS Organism_Name,
        m.Antibiotic_ID,
        j3.Antibiotic_Name AS Antibiotic_Name,
        m.Trigger_Result,
        m.Rule_Action,
        m.Alert_Message,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabExpertRuleMaster m
    LEFT JOIN dbo.LabOrganismMaster j2 ON j2.Organism_ID = m.Organism_ID
    LEFT JOIN dbo.LabAntibioticMaster j3 ON j3.Antibiotic_ID = m.Antibiotic_ID
    WHERE m.Rule_ID = @Id AND m.IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_Create
    @Rule_Type              NVARCHAR(50),
    @Organism_Category      NVARCHAR(50) = NULL,
    @Organism_ID            INT = NULL,
    @Antibiotic_ID          INT,
    @Trigger_Result         NVARCHAR(5),
    @Rule_Action            NVARCHAR(30),
    @Alert_Message          NVARCHAR(300),
    @CompanyId              INT = 1,
    @UserId                 INT = NULL,
    @NewId                  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Rule_Type = NULLIF(LTRIM(RTRIM(@Rule_Type)), '');
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @Trigger_Result = NULLIF(LTRIM(RTRIM(@Trigger_Result)), '');
    SET @Rule_Action = NULLIF(LTRIM(RTRIM(@Rule_Action)), '');
    SET @Alert_Message = NULLIF(LTRIM(RTRIM(@Alert_Message)), '');
    IF @Rule_Type IS NULL
    BEGIN
        RAISERROR('Rule Type is required.', 16, 1);
        RETURN;
    END
    IF @Trigger_Result IS NULL
    BEGIN
        RAISERROR('Trigger When Result Is is required.', 16, 1);
        RETURN;
    END
    IF @Rule_Action IS NULL
    BEGIN
        RAISERROR('Action is required.', 16, 1);
        RETURN;
    END
    IF @Alert_Message IS NULL
    BEGIN
        RAISERROR('Alert Message is required.', 16, 1);
        RETURN;
    END
    IF @Organism_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Organism_ID)
    BEGIN
        RAISERROR('Organism is invalid.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Antibiotic_ID)
    BEGIN
        RAISERROR('Antibiotic is invalid.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NULL AND @Organism_ID IS NULL
    BEGIN
        RAISERROR('Select an Organism or an Organism Category.', 16, 1);
        RETURN;
    END
    IF @Rule_Type NOT IN (N'Intrinsic Resistance', N'MRSA Indicator', N'ESBL Indicator', N'CRE Indicator', N'VRE Indicator', N'Custom Alert')
    BEGIN
        RAISERROR('Rule Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NOT NULL AND @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Organism Category has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Trigger_Result NOT IN (N'S', N'I', N'R')
    BEGIN
        RAISERROR('Trigger When Result Is has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Rule_Action NOT IN (N'Warn Only', N'Report as Resistant', N'Block Approval')
    BEGIN
        RAISERROR('Action has an invalid value.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster WHERE LOWER(Rule_Type) = LOWER(@Rule_Type) AND LOWER(ISNULL(Organism_Category, '')) = LOWER(ISNULL(@Organism_Category, '')) AND ISNULL(Organism_ID, -1) = ISNULL(@Organism_ID, -1) AND Antibiotic_ID = @Antibiotic_ID AND LOWER(Trigger_Result) = LOWER(@Trigger_Result) AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('An identical rule already exists.', 16, 1);
        RETURN;
    END

    DECLARE @Next INT, @GeneratedCode NVARCHAR(50), @RowId INT;
    SELECT @Next = ISNULL(MAX(Rule_ID), 0) + 1 FROM dbo.LabExpertRuleMaster;
    SET @GeneratedCode = 'EXR' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster WHERE Rule_Code = @GeneratedCode)
    BEGIN
        SET @Next += 1;
        SET @GeneratedCode = 'EXR' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    END

    BEGIN TRY
        INSERT INTO dbo.LabExpertRuleMaster
        (
        CompanyId,
        Rule_Code,
        Rule_Type,
        Organism_Category,
        Organism_ID,
        Antibiotic_ID,
        Trigger_Result,
        Rule_Action,
        Alert_Message,
        Status,
        CreatedBy,
        CreatedDate
        )
        VALUES
        (
        @CompanyId,
        @GeneratedCode,
        @Rule_Type,
        @Organism_Category,
        @Organism_ID,
        @Antibiotic_ID,
        @Trigger_Result,
        @Rule_Action,
        @Alert_Message,
        1,
        @UserId,
        GETDATE()
        );
        SET @RowId = SCOPE_IDENTITY();
        SET @NewId = @RowId;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_Update
    @Id INT,
    @Rule_Type              NVARCHAR(50),
    @Organism_Category      NVARCHAR(50) = NULL,
    @Organism_ID            INT = NULL,
    @Antibiotic_ID          INT,
    @Trigger_Result         NVARCHAR(5),
    @Rule_Action            NVARCHAR(30),
    @Alert_Message          NVARCHAR(300),
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster WHERE Rule_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Expert Rule record not found.', 16, 1);
        RETURN;
    END
    SET @Rule_Type = NULLIF(LTRIM(RTRIM(@Rule_Type)), '');
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @Trigger_Result = NULLIF(LTRIM(RTRIM(@Trigger_Result)), '');
    SET @Rule_Action = NULLIF(LTRIM(RTRIM(@Rule_Action)), '');
    SET @Alert_Message = NULLIF(LTRIM(RTRIM(@Alert_Message)), '');
    IF @Rule_Type IS NULL
    BEGIN
        RAISERROR('Rule Type is required.', 16, 1);
        RETURN;
    END
    IF @Trigger_Result IS NULL
    BEGIN
        RAISERROR('Trigger When Result Is is required.', 16, 1);
        RETURN;
    END
    IF @Rule_Action IS NULL
    BEGIN
        RAISERROR('Action is required.', 16, 1);
        RETURN;
    END
    IF @Alert_Message IS NULL
    BEGIN
        RAISERROR('Alert Message is required.', 16, 1);
        RETURN;
    END
    IF @Organism_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Organism_ID)
    BEGIN
        RAISERROR('Organism is invalid.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Antibiotic_ID)
    BEGIN
        RAISERROR('Antibiotic is invalid.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NULL AND @Organism_ID IS NULL
    BEGIN
        RAISERROR('Select an Organism or an Organism Category.', 16, 1);
        RETURN;
    END
    IF @Rule_Type NOT IN (N'Intrinsic Resistance', N'MRSA Indicator', N'ESBL Indicator', N'CRE Indicator', N'VRE Indicator', N'Custom Alert')
    BEGIN
        RAISERROR('Rule Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NOT NULL AND @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Organism Category has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Trigger_Result NOT IN (N'S', N'I', N'R')
    BEGIN
        RAISERROR('Trigger When Result Is has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Rule_Action NOT IN (N'Warn Only', N'Report as Resistant', N'Block Approval')
    BEGIN
        RAISERROR('Action has an invalid value.', 16, 1);
        RETURN;
    END

    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabExpertRuleMaster WHERE Rule_ID = @Id), @RowId INT = @Id;
    IF EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster WHERE LOWER(Rule_Type) = LOWER(@Rule_Type) AND LOWER(ISNULL(Organism_Category, '')) = LOWER(ISNULL(@Organism_Category, '')) AND ISNULL(Organism_ID, -1) = ISNULL(@Organism_ID, -1) AND Antibiotic_ID = @Antibiotic_ID AND LOWER(Trigger_Result) = LOWER(@Trigger_Result) AND CompanyId = @CompanyId AND Rule_ID <> @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('An identical rule already exists.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.LabExpertRuleMaster
        SET Rule_Type = @Rule_Type,
        Organism_Category = @Organism_Category,
        Organism_ID = @Organism_ID,
        Antibiotic_ID = @Antibiotic_ID,
        Trigger_Result = @Trigger_Result,
        Rule_Action = @Rule_Action,
        Alert_Message = @Alert_Message,
        Status = @Status,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
        WHERE Rule_ID = @Id;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_ToggleStatus
    @Id     INT,
    @Status BIT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster WHERE Rule_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Expert Rule record not found.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabExpertRuleMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Rule_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster WHERE Rule_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Expert Rule record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabExpertRuleMaster SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Rule_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_LookupOrganisms
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Organism_ID AS Id, Organism_Name + ' - ' + Organism_Category AS Text FROM dbo.LabOrganismMaster WHERE IsDeleted = 0 AND Status = 1 AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Organism_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabExpertRuleMaster_LookupAntibiotics
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Antibiotic_ID AS Id, Antibiotic_Name + ISNULL(' (' + Abbreviation + ')', '') AS Text FROM dbo.LabAntibioticMaster WHERE IsDeleted = 0 AND Status = 1 AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Antibiotic_Name;
END
GO

-- Seed rules (EUCAST expected-resistant phenotypes + common resistance indicators)
DECLARE @R TABLE (RowNo INT IDENTITY(1,1), Rule_Type NVARCHAR(50), Cat NVARCHAR(50), Org NVARCHAR(150), Abx NVARCHAR(20), Trig NVARCHAR(5), Act NVARCHAR(30), Msg NVARCHAR(300));
INSERT INTO @R (Rule_Type, Cat, Org, Abx, Trig, Act, Msg) VALUES
    (N'Intrinsic Resistance', NULL, N'Klebsiella pneumoniae', N'AMP', N'S', N'Report as Resistant', N'Klebsiella pneumoniae is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Klebsiella oxytoca', N'AMP', N'S', N'Report as Resistant', N'Klebsiella oxytoca is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Citrobacter freundii', N'AMP', N'S', N'Report as Resistant', N'Citrobacter freundii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Citrobacter freundii', N'AMC', N'S', N'Report as Resistant', N'Citrobacter freundii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Citrobacter freundii', N'CFZ', N'S', N'Report as Resistant', N'Citrobacter freundii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Citrobacter freundii', N'FOX', N'S', N'Report as Resistant', N'Citrobacter freundii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterobacter cloacae', N'AMP', N'S', N'Report as Resistant', N'Enterobacter cloacae is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterobacter cloacae', N'AMC', N'S', N'Report as Resistant', N'Enterobacter cloacae is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterobacter cloacae', N'CFZ', N'S', N'Report as Resistant', N'Enterobacter cloacae is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterobacter cloacae', N'FOX', N'S', N'Report as Resistant', N'Enterobacter cloacae is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Serratia marcescens', N'AMP', N'S', N'Report as Resistant', N'Serratia marcescens is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Serratia marcescens', N'AMC', N'S', N'Report as Resistant', N'Serratia marcescens is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Serratia marcescens', N'CFZ', N'S', N'Report as Resistant', N'Serratia marcescens is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Serratia marcescens', N'CXM', N'S', N'Report as Resistant', N'Serratia marcescens is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Serratia marcescens', N'CST', N'S', N'Report as Resistant', N'Serratia marcescens is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Serratia marcescens', N'NIT', N'S', N'Report as Resistant', N'Serratia marcescens is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus mirabilis', N'CST', N'S', N'Report as Resistant', N'Proteus mirabilis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus mirabilis', N'NIT', N'S', N'Report as Resistant', N'Proteus mirabilis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus mirabilis', N'TCY', N'S', N'Report as Resistant', N'Proteus mirabilis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus mirabilis', N'TGC', N'S', N'Report as Resistant', N'Proteus mirabilis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'AMP', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'CFZ', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'CXM', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'CST', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'NIT', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'TCY', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Proteus vulgaris', N'TGC', N'S', N'Report as Resistant', N'Proteus vulgaris is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'AMP', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'AMC', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'CFZ', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'CST', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'NIT', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'TCY', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Morganella morganii', N'TGC', N'S', N'Report as Resistant', N'Morganella morganii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'AMP', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'AMC', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'CFZ', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'CRO', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'CTX', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'FOX', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'ETP', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'SXT', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'TCY', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Pseudomonas aeruginosa', N'TGC', N'S', N'Report as Resistant', N'Pseudomonas aeruginosa is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Acinetobacter baumannii', N'AMP', N'S', N'Report as Resistant', N'Acinetobacter baumannii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Acinetobacter baumannii', N'AMC', N'S', N'Report as Resistant', N'Acinetobacter baumannii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Acinetobacter baumannii', N'CFZ', N'S', N'Report as Resistant', N'Acinetobacter baumannii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Acinetobacter baumannii', N'ETP', N'S', N'Report as Resistant', N'Acinetobacter baumannii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Acinetobacter baumannii', N'FOS', N'S', N'Report as Resistant', N'Acinetobacter baumannii is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Stenotrophomonas maltophilia', N'IPM', N'S', N'Report as Resistant', N'Stenotrophomonas maltophilia is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Stenotrophomonas maltophilia', N'MEM', N'S', N'Report as Resistant', N'Stenotrophomonas maltophilia is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Stenotrophomonas maltophilia', N'ETP', N'S', N'Report as Resistant', N'Stenotrophomonas maltophilia is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Stenotrophomonas maltophilia', N'GEN', N'S', N'Report as Resistant', N'Stenotrophomonas maltophilia is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Stenotrophomonas maltophilia', N'AMK', N'S', N'Report as Resistant', N'Stenotrophomonas maltophilia is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Stenotrophomonas maltophilia', N'TOB', N'S', N'Report as Resistant', N'Stenotrophomonas maltophilia is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'CFZ', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'CXM', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'CRO', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'CTX', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'CAZ', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'FEP', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecalis', N'CLI', N'S', N'Report as Resistant', N'Enterococcus faecalis is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecium', N'CFZ', N'S', N'Report as Resistant', N'Enterococcus faecium is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecium', N'CXM', N'S', N'Report as Resistant', N'Enterococcus faecium is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecium', N'CRO', N'S', N'Report as Resistant', N'Enterococcus faecium is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecium', N'CTX', N'S', N'Report as Resistant', N'Enterococcus faecium is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecium', N'CAZ', N'S', N'Report as Resistant', N'Enterococcus faecium is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Enterococcus faecium', N'FEP', N'S', N'Report as Resistant', N'Enterococcus faecium is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Staphylococcus aureus (MSSA)', N'ATM', N'S', N'Report as Resistant', N'Staphylococcus aureus (MSSA) is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Staphylococcus aureus (MSSA)', N'CST', N'S', N'Report as Resistant', N'Staphylococcus aureus (MSSA) is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Staphylococcus aureus (MRSA)', N'ATM', N'S', N'Report as Resistant', N'Staphylococcus aureus (MRSA) is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Staphylococcus aureus (MRSA)', N'CST', N'S', N'Report as Resistant', N'Staphylococcus aureus (MRSA) is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Coagulase-negative Staphylococci', N'ATM', N'S', N'Report as Resistant', N'Coagulase-negative Staphylococci is intrinsically resistant to this agent - report as R.'),
    (N'Intrinsic Resistance', NULL, N'Coagulase-negative Staphylococci', N'CST', N'S', N'Report as Resistant', N'Coagulase-negative Staphylococci is intrinsically resistant to this agent - report as R.'),
    (N'MRSA Indicator', NULL, N'Staphylococcus aureus (MSSA)', N'FOX', N'R', N'Warn Only', N'Cefoxitin resistant - isolate is MRSA; report all beta-lactams as R.'),
    (N'ESBL Indicator', N'Enterobacteriaceae', NULL, N'CRO', N'R', N'Warn Only', N'Ceftriaxone resistant - possible ESBL producer; confirm with ESBL test.'),
    (N'ESBL Indicator', N'Enterobacteriaceae', NULL, N'CAZ', N'R', N'Warn Only', N'Ceftazidime resistant - possible ESBL producer; confirm with ESBL test.'),
    (N'CRE Indicator', N'Enterobacteriaceae', NULL, N'MEM', N'R', N'Warn Only', N'Carbapenem-resistant Enterobacterales (CRE) - notify infection control.'),
    (N'CRE Indicator', N'Enterobacteriaceae', NULL, N'IPM', N'R', N'Warn Only', N'Carbapenem-resistant Enterobacterales (CRE) - notify infection control.'),
    (N'CRE Indicator', N'Enterobacteriaceae', NULL, N'ETP', N'R', N'Warn Only', N'Carbapenem-resistant Enterobacterales (CRE) - notify infection control.'),
    (N'VRE Indicator', NULL, N'Enterococcus faecalis', N'VAN', N'R', N'Warn Only', N'Vancomycin-resistant Enterococcus (VRE) - notify infection control.'),
    (N'VRE Indicator', NULL, N'Enterococcus faecium', N'VAN', N'R', N'Warn Only', N'Vancomycin-resistant Enterococcus (VRE) - notify infection control.');

DECLARE @Base INT = (SELECT ISNULL(MAX(Rule_ID), 0) FROM dbo.LabExpertRuleMaster);
INSERT INTO dbo.LabExpertRuleMaster (CompanyId, Rule_Code, Rule_Type, Organism_Category, Organism_ID, Antibiotic_ID, Trigger_Result, Rule_Action, Alert_Message, Status, CreatedDate)
SELECT 1, 'EXR' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY r.RowNo) AS NVARCHAR(10)), 4),
       r.Rule_Type, r.Cat, o.Organism_ID, a.Antibiotic_ID, r.Trig, r.Act, r.Msg, 1, GETDATE()
FROM @R r
JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = r.Abx AND a.CompanyId = 1 AND a.IsDeleted = 0
LEFT JOIN dbo.LabOrganismMaster o ON o.Organism_Name = r.Org AND o.CompanyId = 1 AND o.IsDeleted = 0
WHERE (r.Org IS NULL OR o.Organism_ID IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM dbo.LabExpertRuleMaster x
                  WHERE x.CompanyId = 1 AND x.IsDeleted = 0 AND x.Rule_Type = r.Rule_Type AND x.Antibiotic_ID = a.Antibiotic_ID
                    AND x.Trigger_Result = r.Trig AND ISNULL(x.Organism_ID, -1) = ISNULL(o.Organism_ID, -1)
                    AND ISNULL(x.Organism_Category, '') = ISNULL(r.Cat, ''));
GO

PRINT 'Expert Rule Master ready.';
