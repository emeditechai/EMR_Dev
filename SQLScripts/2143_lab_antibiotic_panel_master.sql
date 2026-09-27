-- =============================================
-- Script : 2143_lab_antibiotic_panel_master.sql
-- Purpose: Antibiotic Panel Master — table and stored procedures.
-- CAP/NABL: Audit trail (Created/Modified By/Date), soft delete, company scope.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabAntibioticPanelMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabAntibioticPanelMaster
    (
        Panel_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                INT NOT NULL DEFAULT 1,
        Panel_Code NVARCHAR(50) NOT NULL,
        Panel_Name               NVARCHAR(150) NOT NULL,
        Gram_Type                NVARCHAR(30) NOT NULL,
        Organism_Category        NVARCHAR(50) NULL,
        Sample_Type_ID           INT NULL,
        Description              NVARCHAR(500) NULL,
        Status                   BIT NOT NULL DEFAULT 1,
        IsDeleted                BIT NOT NULL DEFAULT 0,
        CreatedBy                INT NULL,
        CreatedDate              DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME2 NULL
    );
    CREATE INDEX IX_LabAntibioticPanelMaster_Status ON dbo.LabAntibioticPanelMaster(Status);
    CREATE UNIQUE INDEX UX_LabAntibioticPanelMaster_Code ON dbo.LabAntibioticPanelMaster(Panel_Code);
END
GO

IF COL_LENGTH('dbo.LabAntibioticPanelMaster', 'Sample_Type_ID') IS NULL
    ALTER TABLE dbo.LabAntibioticPanelMaster ADD Sample_Type_ID INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabAntibioticPanelDetail' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabAntibioticPanelDetail
    (
        Detail_ID     INT IDENTITY(1,1) PRIMARY KEY,
        Panel_ID INT NOT NULL REFERENCES dbo.LabAntibioticPanelMaster(Panel_ID),
        Antibiotic_ID INT NOT NULL REFERENCES dbo.LabAntibioticMaster(Antibiotic_ID),
        Display_Order INT NOT NULL DEFAULT 1
    );
    CREATE UNIQUE INDEX UX_LabAntibioticPanelDetail ON dbo.LabAntibioticPanelDetail(Panel_ID, Antibiotic_ID);
END
GO

IF COL_LENGTH('dbo.LabAntibioticPanelDetail', 'Tier') IS NULL
    ALTER TABLE dbo.LabAntibioticPanelDetail ADD Tier TINYINT NOT NULL DEFAULT 1;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_GetList
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL,
    @CompanyId INT = NULL,
    @Sample_Type_ID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Panel_ID,
        m.CompanyId,
        m.Panel_Code,
        m.Panel_Name,
        m.Gram_Type,
        m.Organism_Category,
        m.Sample_Type_ID,
        j3.Sample_Name AS Sample_Type_Name,
        m.Description,
        (SELECT STRING_AGG(CAST(d.Antibiotic_ID AS NVARCHAR(20)), ',') WITHIN GROUP (ORDER BY d.Display_Order)
           FROM dbo.LabAntibioticPanelDetail d WHERE d.Panel_ID = m.Panel_ID) AS Antibiotic_IDs,
        (SELECT STRING_AGG(x.Antibiotic_Name, ', ') WITHIN GROUP (ORDER BY d.Display_Order)
           FROM dbo.LabAntibioticPanelDetail d JOIN dbo.LabAntibioticMaster x ON x.Antibiotic_ID = d.Antibiotic_ID WHERE d.Panel_ID = m.Panel_ID) AS Antibiotic_Names,
        (SELECT STRING_AGG(CAST(d.Tier AS NVARCHAR(5)), ',') WITHIN GROUP (ORDER BY d.Display_Order)
           FROM dbo.LabAntibioticPanelDetail d WHERE d.Panel_ID = m.Panel_ID) AS Antibiotic_Tiers,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabAntibioticPanelMaster m
    LEFT JOIN dbo.LabSampleTypeMaster j3 ON j3.Sample_Type_ID = m.Sample_Type_ID
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Sample_Type_ID IS NULL OR m.Sample_Type_ID = @Sample_Type_ID)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR
           m.Panel_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Panel_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Gram_Type LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Organism_Category LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY m.Gram_Type, m.Panel_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Panel_ID,
        m.CompanyId,
        m.Panel_Code,
        m.Panel_Name,
        m.Gram_Type,
        m.Organism_Category,
        m.Sample_Type_ID,
        j3.Sample_Name AS Sample_Type_Name,
        m.Description,
        (SELECT STRING_AGG(CAST(d.Antibiotic_ID AS NVARCHAR(20)), ',') WITHIN GROUP (ORDER BY d.Display_Order)
           FROM dbo.LabAntibioticPanelDetail d WHERE d.Panel_ID = m.Panel_ID) AS Antibiotic_IDs,
        (SELECT STRING_AGG(x.Antibiotic_Name, ', ') WITHIN GROUP (ORDER BY d.Display_Order)
           FROM dbo.LabAntibioticPanelDetail d JOIN dbo.LabAntibioticMaster x ON x.Antibiotic_ID = d.Antibiotic_ID WHERE d.Panel_ID = m.Panel_ID) AS Antibiotic_Names,
        (SELECT STRING_AGG(CAST(d.Tier AS NVARCHAR(5)), ',') WITHIN GROUP (ORDER BY d.Display_Order)
           FROM dbo.LabAntibioticPanelDetail d WHERE d.Panel_ID = m.Panel_ID) AS Antibiotic_Tiers,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabAntibioticPanelMaster m
    LEFT JOIN dbo.LabSampleTypeMaster j3 ON j3.Sample_Type_ID = m.Sample_Type_ID
    WHERE m.Panel_ID = @Id AND m.IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_Create
    @Panel_Name             NVARCHAR(150),
    @Gram_Type              NVARCHAR(30),
    @Organism_Category      NVARCHAR(50) = NULL,
    @Sample_Type_ID         INT = NULL,
    @Description            NVARCHAR(500) = NULL,
    @Antibiotic_IDs         NVARCHAR(MAX) = NULL,
    @CompanyId              INT = 1,
    @UserId                 INT = NULL,
    @NewId                  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Panel_Name = NULLIF(LTRIM(RTRIM(@Panel_Name)), '');
    SET @Gram_Type = NULLIF(LTRIM(RTRIM(@Gram_Type)), '');
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    IF @Panel_Name IS NULL
    BEGIN
        RAISERROR('Panel Name is required.', 16, 1);
        RETURN;
    END
    IF @Gram_Type IS NULL
    BEGIN
        RAISERROR('Gram Type is required.', 16, 1);
        RETURN;
    END
    IF @Sample_Type_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID)
    BEGIN
        RAISERROR('Specimen Type is invalid.', 16, 1);
        RETURN;
    END
    IF @Gram_Type NOT IN (N'Gram Positive', N'Gram Negative', N'Not Applicable')
    BEGIN
        RAISERROR('Gram Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NOT NULL AND @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Organism Category has an invalid value.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE LOWER(Panel_Name) = LOWER(@Panel_Name) AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('An Antibiotic Panel with the same name already exists.', 16, 1);
        RETURN;
    END

    DECLARE @Next INT, @GeneratedCode NVARCHAR(50), @RowId INT;
    SELECT @Next = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @GeneratedCode = 'ABP' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Code = @GeneratedCode)
    BEGIN
        SET @Next += 1;
        SET @GeneratedCode = 'ABP' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    END

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.LabAntibioticPanelMaster
        (
        CompanyId,
        Panel_Code,
        Panel_Name,
        Gram_Type,
        Organism_Category,
        Sample_Type_ID,
        Description,
        Status,
        CreatedBy,
        CreatedDate
        )
        VALUES
        (
        @CompanyId,
        @GeneratedCode,
        @Panel_Name,
        @Gram_Type,
        @Organism_Category,
        @Sample_Type_ID,
        @Description,
        1,
        @UserId,
        GETDATE()
        );
        SET @RowId = SCOPE_IDENTITY();
    DELETE FROM dbo.LabAntibioticPanelDetail WHERE Panel_ID = @RowId;
    IF @Antibiotic_IDs IS NOT NULL AND ISJSON(@Antibiotic_IDs) = 1
        INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order, Tier)
        SELECT @RowId, j.Id, CAST(k.[key] AS INT) + 1, CASE WHEN j.Tier BETWEEN 1 AND 4 THEN j.Tier ELSE 1 END
        FROM OPENJSON(@Antibiotic_IDs) k
        CROSS APPLY OPENJSON(k.[value]) WITH (Id INT '$.id', Tier INT '$.tier') j
        WHERE EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster x WHERE x.Antibiotic_ID = j.Id AND x.IsDeleted = 0);
        SET @NewId = @RowId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_Update
    @Id INT,
    @Panel_Name             NVARCHAR(150),
    @Gram_Type              NVARCHAR(30),
    @Organism_Category      NVARCHAR(50) = NULL,
    @Sample_Type_ID         INT = NULL,
    @Description            NVARCHAR(500) = NULL,
    @Antibiotic_IDs         NVARCHAR(MAX) = NULL,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Antibiotic Panel record not found.', 16, 1);
        RETURN;
    END
    SET @Panel_Name = NULLIF(LTRIM(RTRIM(@Panel_Name)), '');
    SET @Gram_Type = NULLIF(LTRIM(RTRIM(@Gram_Type)), '');
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    IF @Panel_Name IS NULL
    BEGIN
        RAISERROR('Panel Name is required.', 16, 1);
        RETURN;
    END
    IF @Gram_Type IS NULL
    BEGIN
        RAISERROR('Gram Type is required.', 16, 1);
        RETURN;
    END
    IF @Sample_Type_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Type_ID = @Sample_Type_ID)
    BEGIN
        RAISERROR('Specimen Type is invalid.', 16, 1);
        RETURN;
    END
    IF @Gram_Type NOT IN (N'Gram Positive', N'Gram Negative', N'Not Applicable')
    BEGIN
        RAISERROR('Gram Type has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Organism_Category IS NOT NULL AND @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Organism Category has an invalid value.', 16, 1);
        RETURN;
    END

    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabAntibioticPanelMaster WHERE Panel_ID = @Id), @RowId INT = @Id;
    IF EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE LOWER(Panel_Name) = LOWER(@Panel_Name) AND CompanyId = @CompanyId AND Panel_ID <> @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('An Antibiotic Panel with the same name already exists.', 16, 1);
        RETURN;
    END

    BEGIN TRANSACTION;
    BEGIN TRY
        UPDATE dbo.LabAntibioticPanelMaster
        SET Panel_Name = @Panel_Name,
        Gram_Type = @Gram_Type,
        Organism_Category = @Organism_Category,
        Sample_Type_ID = @Sample_Type_ID,
        Description = @Description,
        Status = @Status,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
        WHERE Panel_ID = @Id;
    DELETE FROM dbo.LabAntibioticPanelDetail WHERE Panel_ID = @RowId;
    IF @Antibiotic_IDs IS NOT NULL AND ISJSON(@Antibiotic_IDs) = 1
        INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order, Tier)
        SELECT @RowId, j.Id, CAST(k.[key] AS INT) + 1, CASE WHEN j.Tier BETWEEN 1 AND 4 THEN j.Tier ELSE 1 END
        FROM OPENJSON(@Antibiotic_IDs) k
        CROSS APPLY OPENJSON(k.[value]) WITH (Id INT '$.id', Tier INT '$.tier') j
        WHERE EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster x WHERE x.Antibiotic_ID = j.Id AND x.IsDeleted = 0);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_ToggleStatus
    @Id     INT,
    @Status BIT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Antibiotic Panel record not found.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabAntibioticPanelMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Panel_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Antibiotic Panel record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabAntibioticPanelMaster SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Panel_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_LookupAntibiotics
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Antibiotic_ID AS Id, Antibiotic_Name + ISNULL(' (' + Abbreviation + ')', '') + ' - ' + Antibiotic_Class AS Text FROM dbo.LabAntibioticMaster WHERE IsDeleted = 0 AND Status = 1 AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Antibiotic_Class, Antibiotic_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticPanelMaster_LookupSampleTypes
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Sample_Type_ID AS Id, Sample_Name + ' (' + Container_Type + ')' AS Text FROM dbo.LabSampleTypeMaster WHERE IsDeleted = 0 AND Status = 1 AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Sample_Name;
END
GO

-- Seed panels (antibiotics resolved by abbreviation)
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Enterobacterales - Urine' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Enterobacterales - Urine', N'Gram Negative', N'Enterobacteriaceae', N'Urine isolates of Enterobacterales. Includes urinary-only agents.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["AMP", "AMC", "CXM", "CRO", "CAZ", "FEP", "CFS", "TZP", "ETP", "MEM", "GEN", "AMK", "CIP", "NOR", "SXT", "NIT", "FOS", "CST"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Enterobacterales - Blood / Systemic' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Enterobacterales - Blood / Systemic', N'Gram Negative', N'Enterobacteriaceae', N'Blood, pus and other systemic isolates of Enterobacterales.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["AMP", "AMC", "CXM", "CRO", "CTX", "CAZ", "FEP", "CFS", "TZP", "CZA", "ETP", "IPM", "MEM", "ATM", "GEN", "AMK", "CIP", "LVX", "SXT", "TGC", "CST"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Non-Fermenters (Pseudomonas / Acinetobacter)' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Non-Fermenters (Pseudomonas / Acinetobacter)', N'Gram Negative', N'Non-Fermenter', N'Pseudomonas aeruginosa and Acinetobacter spp.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["CAZ", "FEP", "TZP", "CFS", "CZA", "IPM", "MEM", "ATM", "GEN", "AMK", "TOB", "CIP", "LVX", "MIN", "TGC", "CST", "PMB"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Staphylococcus spp.' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Staphylococcus spp.', N'Gram Positive', N'Gram Positive Cocci', N'S. aureus and coagulase-negative staphylococci. Cefoxitin screens for MRSA.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["PEN", "FOX", "OXA", "ERY", "CLI", "GEN", "CIP", "LVX", "SXT", "TCY", "DOX", "VAN", "TEC", "LNZ", "NIT"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Enterococcus spp.' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Enterococcus spp.', N'Gram Positive', N'Gram Positive Cocci', N'Enterococcus faecalis / faecium. High-level gentamicin for synergy.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["AMP", "PEN", "GEN", "CIP", "LVX", "NIT", "FOS", "VAN", "TEC", "LNZ", "TGC"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Streptococcus spp.' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Streptococcus spp.', N'Gram Positive', N'Gram Positive Cocci', N'Beta-haemolytic and viridans streptococci, S. pneumoniae.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["PEN", "AMP", "CRO", "CTX", "ERY", "AZM", "CLI", "LVX", "SXT", "TCY", "VAN", "LNZ"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelMaster WHERE Panel_Name = N'Yeast / Candida' AND IsDeleted = 0)
BEGIN
    DECLARE @PanelId INT, @PanelCode NVARCHAR(50), @Nx INT;
    SELECT @Nx = ISNULL(MAX(Panel_ID), 0) + 1 FROM dbo.LabAntibioticPanelMaster;
    SET @PanelCode = 'ABP' + RIGHT('0000' + CAST(@Nx AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabAntibioticPanelMaster (CompanyId, Panel_Code, Panel_Name, Gram_Type, Organism_Category, Description, Status, CreatedDate)
    VALUES (1, @PanelCode, N'Yeast / Candida', N'Not Applicable', N'Fungal', N'Antifungal susceptibility for Candida and other yeasts.', 1, GETDATE());
    SET @PanelId = SCOPE_IDENTITY();
    INSERT INTO dbo.LabAntibioticPanelDetail (Panel_ID, Antibiotic_ID, Display_Order)
    SELECT @PanelId, a.Antibiotic_ID, o.Seq
    FROM (SELECT [value] AS Abbr, CAST([key] AS INT) + 1 AS Seq FROM OPENJSON(N'["FLU", "VOR", "AMB", "CAS", "MFG"]')) o
    JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = o.Abbr AND a.IsDeleted = 0;
END
GO

-- Sample reporting tiers (stewardship starter set; each lab reviews against its antibiogram)
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Urine' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'AMP', N'AMC', N'CXM', N'GEN', N'SXT', N'NIT', N'FOS');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Urine' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CRO', N'CAZ', N'FEP', N'CFS', N'TZP', N'CIP', N'NOR', N'AMK');
UPDATE d SET Tier = 3
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Urine' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'ETP', N'MEM');
UPDATE d SET Tier = 4
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Urine' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CST');
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Blood / Systemic' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'AMP', N'AMC', N'CXM', N'CRO', N'GEN', N'SXT');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Blood / Systemic' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CTX', N'CAZ', N'FEP', N'CFS', N'TZP', N'CIP', N'LVX', N'AMK');
UPDATE d SET Tier = 3
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Blood / Systemic' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'ETP', N'IPM', N'MEM', N'ATM', N'CZA', N'TGC');
UPDATE d SET Tier = 4
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterobacterales - Blood / Systemic' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CST');
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Non-Fermenters (Pseudomonas / Acinetobacter)' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CAZ', N'FEP', N'TZP', N'GEN', N'TOB', N'CIP', N'LVX');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Non-Fermenters (Pseudomonas / Acinetobacter)' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CFS', N'IPM', N'MEM', N'AMK', N'ATM', N'MIN');
UPDATE d SET Tier = 3
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Non-Fermenters (Pseudomonas / Acinetobacter)' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CZA', N'TGC');
UPDATE d SET Tier = 4
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Non-Fermenters (Pseudomonas / Acinetobacter)' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CST', N'PMB');
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Staphylococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'PEN', N'FOX', N'OXA', N'ERY', N'CLI', N'SXT', N'TCY', N'DOX');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Staphylococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'GEN', N'CIP', N'LVX', N'VAN', N'NIT');
UPDATE d SET Tier = 3
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Staphylococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'TEC', N'LNZ');
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'AMP', N'PEN', N'NIT', N'FOS');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'GEN', N'CIP', N'LVX', N'VAN');
UPDATE d SET Tier = 3
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Enterococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'TEC', N'LNZ', N'TGC');
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Streptococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'PEN', N'AMP', N'ERY', N'CLI', N'SXT', N'TCY');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Streptococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'CRO', N'CTX', N'AZM', N'LVX');
UPDATE d SET Tier = 3
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Streptococcus spp.' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'VAN', N'LNZ');
UPDATE d SET Tier = 1
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Yeast / Candida' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'FLU', N'VOR');
UPDATE d SET Tier = 2
FROM dbo.LabAntibioticPanelDetail d
JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID AND p.Panel_Name = N'Yeast / Candida' AND p.IsDeleted = 0
JOIN dbo.LabAntibioticMaster a ON a.Antibiotic_ID = d.Antibiotic_ID AND a.Abbreviation IN (N'AMB', N'CAS', N'MFG');
UPDATE p SET Sample_Type_ID = s.Sample_Type_ID
FROM dbo.LabAntibioticPanelMaster p
JOIN dbo.LabSampleTypeMaster s ON s.Sample_Name = N'Mid-Stream Clean Catch Urine' AND s.IsDeleted = 0
WHERE p.Panel_Name = N'Enterobacterales - Urine' AND p.IsDeleted = 0 AND p.Sample_Type_ID IS NULL;
UPDATE p SET Sample_Type_ID = s.Sample_Type_ID
FROM dbo.LabAntibioticPanelMaster p
JOIN dbo.LabSampleTypeMaster s ON s.Sample_Name = N'Blood Culture Bottle' AND s.IsDeleted = 0
WHERE p.Panel_Name = N'Enterobacterales - Blood / Systemic' AND p.IsDeleted = 0 AND p.Sample_Type_ID IS NULL;
GO

PRINT 'Antibiotic Panel Master ready.';
