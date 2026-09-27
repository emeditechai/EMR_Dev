-- =============================================
-- Script : 2141_lab_organism_master.sql
-- Purpose: Organism Master — table and stored procedures.
-- CAP/NABL: Audit trail (Created/Modified By/Date), soft delete, company scope.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabOrganismMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabOrganismMaster
    (
        Organism_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                INT NOT NULL DEFAULT 1,
        Organism_Code NVARCHAR(50) NOT NULL,
        Organism_Name            NVARCHAR(150) NOT NULL,
        Gram_Type                NVARCHAR(30) NOT NULL,
        Organism_Type            NVARCHAR(30) NOT NULL,
        Organism_Category        NVARCHAR(50) NOT NULL,
        WHONET_Code              NVARCHAR(10) NULL,
        Description              NVARCHAR(500) NULL,
        Status                   BIT NOT NULL DEFAULT 1,
        IsDeleted                BIT NOT NULL DEFAULT 0,
        CreatedBy                INT NULL,
        CreatedDate              DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME2 NULL
    );
    CREATE INDEX IX_LabOrganismMaster_Status ON dbo.LabOrganismMaster(Status);
    CREATE UNIQUE INDEX UX_LabOrganismMaster_Code ON dbo.LabOrganismMaster(Organism_Code);
END
GO

IF COL_LENGTH('dbo.LabOrganismMaster', 'WHONET_Code') IS NULL
    ALTER TABLE dbo.LabOrganismMaster ADD WHONET_Code NVARCHAR(10) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrganismMaster_GetList
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Organism_ID,
        m.CompanyId,
        m.Organism_Code,
        m.Organism_Name,
        m.Gram_Type,
        m.Organism_Type,
        m.Organism_Category,
        m.WHONET_Code,
        m.Description,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabOrganismMaster m
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR
           m.Organism_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Organism_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Gram_Type LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Organism_Type LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Organism_Category LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.WHONET_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY m.Organism_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrganismMaster_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Organism_ID,
        m.CompanyId,
        m.Organism_Code,
        m.Organism_Name,
        m.Gram_Type,
        m.Organism_Type,
        m.Organism_Category,
        m.WHONET_Code,
        m.Description,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabOrganismMaster m
    WHERE m.Organism_ID = @Id AND m.IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrganismMaster_Create
    @Organism_Name          NVARCHAR(150),
    @Gram_Type              NVARCHAR(30),
    @Organism_Type          NVARCHAR(30),
    @Organism_Category      NVARCHAR(50),
    @WHONET_Code            NVARCHAR(10) = NULL,
    @Description            NVARCHAR(500) = NULL,
    @CompanyId              INT = 1,
    @UserId                 INT = NULL,
    @NewId                  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Organism_Name = NULLIF(LTRIM(RTRIM(@Organism_Name)), '');
    SET @Gram_Type = NULLIF(LTRIM(RTRIM(@Gram_Type)), '');
    SET @Organism_Type = NULLIF(LTRIM(RTRIM(@Organism_Type)), '');
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @WHONET_Code = NULLIF(LTRIM(RTRIM(@WHONET_Code)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    IF @Organism_Name IS NULL
    BEGIN
        RAISERROR('Organism Name is required.', 16, 1);
        RETURN;
    END
    IF @Gram_Type IS NULL
    BEGIN
        RAISERROR('Gram Type is required.', 16, 1);
        RETURN;
    END
    IF @Organism_Type IS NULL
    BEGIN
        RAISERROR('Organism Type is required.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NULL
    BEGIN
        RAISERROR('Category is required.', 16, 1);
        RETURN;
    END
    IF @Gram_Type NOT IN (N'Gram Positive', N'Gram Negative', N'Not Applicable')
    BEGIN
        RAISERROR('Gram Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Type NOT IN (N'Bacteria', N'Fungus', N'Parasite', N'Virus')
    BEGIN
        RAISERROR('Organism Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Category has an invalid value.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE LOWER(Organism_Name) = LOWER(@Organism_Name) AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('An Organism with the same name already exists.', 16, 1);
        RETURN;
    END

    DECLARE @Next INT, @GeneratedCode NVARCHAR(50), @RowId INT;
    SELECT @Next = ISNULL(MAX(Organism_ID), 0) + 1 FROM dbo.LabOrganismMaster;
    SET @GeneratedCode = 'ORG' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_Code = @GeneratedCode)
    BEGIN
        SET @Next += 1;
        SET @GeneratedCode = 'ORG' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    END

    BEGIN TRY
        INSERT INTO dbo.LabOrganismMaster
        (
        CompanyId,
        Organism_Code,
        Organism_Name,
        Gram_Type,
        Organism_Type,
        Organism_Category,
        WHONET_Code,
        Description,
        Status,
        CreatedBy,
        CreatedDate
        )
        VALUES
        (
        @CompanyId,
        @GeneratedCode,
        @Organism_Name,
        @Gram_Type,
        @Organism_Type,
        @Organism_Category,
        @WHONET_Code,
        @Description,
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrganismMaster_Update
    @Id INT,
    @Organism_Name          NVARCHAR(150),
    @Gram_Type              NVARCHAR(30),
    @Organism_Type          NVARCHAR(30),
    @Organism_Category      NVARCHAR(50),
    @WHONET_Code            NVARCHAR(10) = NULL,
    @Description            NVARCHAR(500) = NULL,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Organism record not found.', 16, 1);
        RETURN;
    END
    SET @Organism_Name = NULLIF(LTRIM(RTRIM(@Organism_Name)), '');
    SET @Gram_Type = NULLIF(LTRIM(RTRIM(@Gram_Type)), '');
    SET @Organism_Type = NULLIF(LTRIM(RTRIM(@Organism_Type)), '');
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @WHONET_Code = NULLIF(LTRIM(RTRIM(@WHONET_Code)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    IF @Organism_Name IS NULL
    BEGIN
        RAISERROR('Organism Name is required.', 16, 1);
        RETURN;
    END
    IF @Gram_Type IS NULL
    BEGIN
        RAISERROR('Gram Type is required.', 16, 1);
        RETURN;
    END
    IF @Organism_Type IS NULL
    BEGIN
        RAISERROR('Organism Type is required.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NULL
    BEGIN
        RAISERROR('Category is required.', 16, 1);
        RETURN;
    END
    IF @Gram_Type NOT IN (N'Gram Positive', N'Gram Negative', N'Not Applicable')
    BEGIN
        RAISERROR('Gram Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Type NOT IN (N'Bacteria', N'Fungus', N'Parasite', N'Virus')
    BEGIN
        RAISERROR('Organism Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Category has an invalid value.', 16, 1);
        RETURN;
    END

    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabOrganismMaster WHERE Organism_ID = @Id), @RowId INT = @Id;
    IF EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE LOWER(Organism_Name) = LOWER(@Organism_Name) AND CompanyId = @CompanyId AND Organism_ID <> @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('An Organism with the same name already exists.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.LabOrganismMaster
        SET Organism_Name = @Organism_Name,
        Gram_Type = @Gram_Type,
        Organism_Type = @Organism_Type,
        Organism_Category = @Organism_Category,
        WHONET_Code = @WHONET_Code,
        Description = @Description,
        Status = @Status,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
        WHERE Organism_ID = @Id;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrganismMaster_ToggleStatus
    @Id     INT,
    @Status BIT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Organism record not found.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabOrganismMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Organism_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabOrganismMaster_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Organism record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabOrganismMaster SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Organism_ID = @Id;
END
GO

-- Seed data
DECLARE @Seed TABLE (RowNo INT IDENTITY(1,1), Organism_Name NVARCHAR(200), Gram_Type NVARCHAR(200), Organism_Type NVARCHAR(200), Organism_Category NVARCHAR(200));
INSERT INTO @Seed (Organism_Name, Gram_Type, Organism_Type, Organism_Category) VALUES
    (N'Escherichia coli', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Klebsiella pneumoniae', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Klebsiella oxytoca', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Enterobacter cloacae', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Citrobacter freundii', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Proteus mirabilis', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Proteus vulgaris', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Morganella morganii', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Serratia marcescens', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Salmonella Typhi', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Salmonella Paratyphi A', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Shigella species', N'Gram Negative', N'Bacteria', N'Enterobacteriaceae'),
    (N'Pseudomonas aeruginosa', N'Gram Negative', N'Bacteria', N'Non-Fermenter'),
    (N'Acinetobacter baumannii', N'Gram Negative', N'Bacteria', N'Non-Fermenter'),
    (N'Stenotrophomonas maltophilia', N'Gram Negative', N'Bacteria', N'Non-Fermenter'),
    (N'Burkholderia cepacia complex', N'Gram Negative', N'Bacteria', N'Non-Fermenter'),
    (N'Haemophilus influenzae', N'Gram Negative', N'Bacteria', N'Fastidious Gram Negative'),
    (N'Neisseria gonorrhoeae', N'Gram Negative', N'Bacteria', N'Fastidious Gram Negative'),
    (N'Neisseria meningitidis', N'Gram Negative', N'Bacteria', N'Fastidious Gram Negative'),
    (N'Staphylococcus aureus (MSSA)', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Staphylococcus aureus (MRSA)', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Coagulase-negative Staphylococci', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Enterococcus faecalis', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Enterococcus faecium', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Streptococcus pneumoniae', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Streptococcus pyogenes (Group A)', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Streptococcus agalactiae (Group B)', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Viridans group Streptococci', N'Gram Positive', N'Bacteria', N'Gram Positive Cocci'),
    (N'Corynebacterium diphtheriae', N'Gram Positive', N'Bacteria', N'Gram Positive Bacilli'),
    (N'Listeria monocytogenes', N'Gram Positive', N'Bacteria', N'Gram Positive Bacilli'),
    (N'Bacteroides fragilis', N'Gram Negative', N'Bacteria', N'Anaerobes'),
    (N'Clostridioides difficile', N'Gram Positive', N'Bacteria', N'Anaerobes'),
    (N'Mycobacterium tuberculosis complex', N'Not Applicable', N'Bacteria', N'Mycobacteria'),
    (N'Candida albicans', N'Not Applicable', N'Fungus', N'Fungal'),
    (N'Candida auris', N'Not Applicable', N'Fungus', N'Fungal'),
    (N'Non-albicans Candida', N'Not Applicable', N'Fungus', N'Fungal'),
    (N'Cryptococcus neoformans', N'Not Applicable', N'Fungus', N'Fungal'),
    (N'Aspergillus fumigatus', N'Not Applicable', N'Fungus', N'Fungal'),
    (N'Aspergillus flavus', N'Not Applicable', N'Fungus', N'Fungal');

DECLARE @Base INT = (SELECT ISNULL(MAX(Organism_ID), 0) FROM dbo.LabOrganismMaster);
INSERT INTO dbo.LabOrganismMaster (CompanyId, Organism_Code, Organism_Name, Gram_Type, Organism_Type, Organism_Category, Status, CreatedDate)
SELECT 1, 'ORG' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY s.RowNo) AS NVARCHAR(10)), 4), s.Organism_Name, s.Gram_Type, s.Organism_Type, s.Organism_Category, 1, GETDATE()
FROM @Seed s
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster x WHERE x.Organism_Name = s.Organism_Name AND x.IsDeleted = 0);
GO

PRINT 'Organism Master ready.';
