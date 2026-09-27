-- =============================================
-- Script : 2148_lab_breakpoint_master.sql
-- Purpose: Breakpoint Master — table and stored procedures.
-- CAP/NABL: Audit trail (Created/Modified By/Date), soft delete, company scope.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabBreakpointMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabBreakpointMaster
    (
        Breakpoint_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                INT NOT NULL DEFAULT 1,
        Breakpoint_Code NVARCHAR(50) NOT NULL,
        Organism_Category        NVARCHAR(50) NOT NULL,
        Organism_ID              INT NULL,
        Antibiotic_ID            INT NOT NULL,
        Standard                 NVARCHAR(20) NOT NULL,
        Standard_Version         NVARCHAR(50) NOT NULL,
        Method                   NVARCHAR(30) NOT NULL,
        Specimen_Scope           NVARCHAR(50) NOT NULL,
        S_Breakpoint             DECIMAL(12,4) NULL,
        R_Breakpoint             DECIMAL(12,4) NULL,
        Remarks                  NVARCHAR(500) NULL,
        Status                   BIT NOT NULL DEFAULT 1,
        IsDeleted                BIT NOT NULL DEFAULT 0,
        CreatedBy                INT NULL,
        CreatedDate              DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME2 NULL
    );
    CREATE INDEX IX_LabBreakpointMaster_Status ON dbo.LabBreakpointMaster(Status);
    CREATE UNIQUE INDEX UX_LabBreakpointMaster_Code ON dbo.LabBreakpointMaster(Breakpoint_Code);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_GetList
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL,
    @CompanyId INT = NULL,
    @Organism_ID INT = NULL,
    @Antibiotic_ID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Breakpoint_ID,
        m.CompanyId,
        m.Breakpoint_Code,
        m.Organism_Category,
        m.Organism_ID,
        j1.Organism_Name AS Organism_Name,
        m.Antibiotic_ID,
        j2.Antibiotic_Name AS Antibiotic_Name,
        m.Standard,
        m.Standard_Version,
        m.Method,
        m.Specimen_Scope,
        m.S_Breakpoint,
        m.R_Breakpoint,
        m.Remarks,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabBreakpointMaster m
    LEFT JOIN dbo.LabOrganismMaster j1 ON j1.Organism_ID = m.Organism_ID
    LEFT JOIN dbo.LabAntibioticMaster j2 ON j2.Antibiotic_ID = m.Antibiotic_ID
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Organism_ID IS NULL OR m.Organism_ID = @Organism_ID)
      AND (@Antibiotic_ID IS NULL OR m.Antibiotic_ID = @Antibiotic_ID)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR
           m.Breakpoint_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Standard_Version LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Organism_Category LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Standard LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Method LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Specimen_Scope LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY m.Standard, m.Organism_Category, j2.Antibiotic_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Breakpoint_ID,
        m.CompanyId,
        m.Breakpoint_Code,
        m.Organism_Category,
        m.Organism_ID,
        j1.Organism_Name AS Organism_Name,
        m.Antibiotic_ID,
        j2.Antibiotic_Name AS Antibiotic_Name,
        m.Standard,
        m.Standard_Version,
        m.Method,
        m.Specimen_Scope,
        m.S_Breakpoint,
        m.R_Breakpoint,
        m.Remarks,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabBreakpointMaster m
    LEFT JOIN dbo.LabOrganismMaster j1 ON j1.Organism_ID = m.Organism_ID
    LEFT JOIN dbo.LabAntibioticMaster j2 ON j2.Antibiotic_ID = m.Antibiotic_ID
    WHERE m.Breakpoint_ID = @Id AND m.IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_Create
    @Organism_Category      NVARCHAR(50),
    @Organism_ID            INT = NULL,
    @Antibiotic_ID          INT,
    @Standard               NVARCHAR(20),
    @Standard_Version       NVARCHAR(50),
    @Method                 NVARCHAR(30),
    @Specimen_Scope         NVARCHAR(50),
    @S_Breakpoint           DECIMAL(12,4) = NULL,
    @R_Breakpoint           DECIMAL(12,4) = NULL,
    @Remarks                NVARCHAR(500) = NULL,
    @CompanyId              INT = 1,
    @UserId                 INT = NULL,
    @NewId                  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @Standard = NULLIF(LTRIM(RTRIM(@Standard)), '');
    SET @Standard_Version = NULLIF(LTRIM(RTRIM(@Standard_Version)), '');
    SET @Method = NULLIF(LTRIM(RTRIM(@Method)), '');
    SET @Specimen_Scope = NULLIF(LTRIM(RTRIM(@Specimen_Scope)), '');
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '');
    IF @Organism_Category IS NULL
    BEGIN
        RAISERROR('Organism Category is required.', 16, 1);
        RETURN;
    END
    IF @Standard IS NULL
    BEGIN
        RAISERROR('Standard is required.', 16, 1);
        RETURN;
    END
    IF @Standard_Version IS NULL
    BEGIN
        RAISERROR('Standard Version is required.', 16, 1);
        RETURN;
    END
    IF @Method IS NULL
    BEGIN
        RAISERROR('Method is required.', 16, 1);
        RETURN;
    END
    IF @Specimen_Scope IS NULL
    BEGIN
        RAISERROR('Specimen Scope is required.', 16, 1);
        RETURN;
    END
    IF @Organism_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Organism_ID)
    BEGIN
        RAISERROR('Specific Organism is invalid.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Antibiotic_ID)
    BEGIN
        RAISERROR('Antibiotic is invalid.', 16, 1);
        RETURN;
    END
    IF @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Organism Category has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Standard NOT IN (N'CLSI', N'EUCAST')
    BEGIN
        RAISERROR('Standard has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Method NOT IN (N'MIC (mg/L)', N'Disk Diffusion (mm)')
    BEGIN
        RAISERROR('Method has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Specimen_Scope NOT IN (N'All Specimens', N'Urine (Uncomplicated UTI)', N'Non-Meningitis', N'Meningitis')
    BEGIN
        RAISERROR('Specimen Scope has an invalid value.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster WHERE LOWER(Organism_Category) = LOWER(@Organism_Category) AND ISNULL(Organism_ID, -1) = ISNULL(@Organism_ID, -1) AND Antibiotic_ID = @Antibiotic_ID AND LOWER(Standard) = LOWER(@Standard) AND LOWER(Standard_Version) = LOWER(@Standard_Version) AND LOWER(Method) = LOWER(@Method) AND LOWER(Specimen_Scope) = LOWER(@Specimen_Scope) AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('A breakpoint for this organism, antibiotic, standard, version, method and specimen scope already exists.', 16, 1);
        RETURN;
    END

    DECLARE @Next INT, @GeneratedCode NVARCHAR(50), @RowId INT;
    SELECT @Next = ISNULL(MAX(Breakpoint_ID), 0) + 1 FROM dbo.LabBreakpointMaster;
    SET @GeneratedCode = 'BKP' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster WHERE Breakpoint_Code = @GeneratedCode)
    BEGIN
        SET @Next += 1;
        SET @GeneratedCode = 'BKP' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    END

    BEGIN TRY
        INSERT INTO dbo.LabBreakpointMaster
        (
        CompanyId,
        Breakpoint_Code,
        Organism_Category,
        Organism_ID,
        Antibiotic_ID,
        Standard,
        Standard_Version,
        Method,
        Specimen_Scope,
        S_Breakpoint,
        R_Breakpoint,
        Remarks,
        Status,
        CreatedBy,
        CreatedDate
        )
        VALUES
        (
        @CompanyId,
        @GeneratedCode,
        @Organism_Category,
        @Organism_ID,
        @Antibiotic_ID,
        @Standard,
        @Standard_Version,
        @Method,
        @Specimen_Scope,
        @S_Breakpoint,
        @R_Breakpoint,
        @Remarks,
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_Update
    @Id INT,
    @Organism_Category      NVARCHAR(50),
    @Organism_ID            INT = NULL,
    @Antibiotic_ID          INT,
    @Standard               NVARCHAR(20),
    @Standard_Version       NVARCHAR(50),
    @Method                 NVARCHAR(30),
    @Specimen_Scope         NVARCHAR(50),
    @S_Breakpoint           DECIMAL(12,4) = NULL,
    @R_Breakpoint           DECIMAL(12,4) = NULL,
    @Remarks                NVARCHAR(500) = NULL,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster WHERE Breakpoint_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Breakpoint record not found.', 16, 1);
        RETURN;
    END
    SET @Organism_Category = NULLIF(LTRIM(RTRIM(@Organism_Category)), '');
    SET @Standard = NULLIF(LTRIM(RTRIM(@Standard)), '');
    SET @Standard_Version = NULLIF(LTRIM(RTRIM(@Standard_Version)), '');
    SET @Method = NULLIF(LTRIM(RTRIM(@Method)), '');
    SET @Specimen_Scope = NULLIF(LTRIM(RTRIM(@Specimen_Scope)), '');
    SET @Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '');
    IF @Organism_Category IS NULL
    BEGIN
        RAISERROR('Organism Category is required.', 16, 1);
        RETURN;
    END
    IF @Standard IS NULL
    BEGIN
        RAISERROR('Standard is required.', 16, 1);
        RETURN;
    END
    IF @Standard_Version IS NULL
    BEGIN
        RAISERROR('Standard Version is required.', 16, 1);
        RETURN;
    END
    IF @Method IS NULL
    BEGIN
        RAISERROR('Method is required.', 16, 1);
        RETURN;
    END
    IF @Specimen_Scope IS NULL
    BEGIN
        RAISERROR('Specimen Scope is required.', 16, 1);
        RETURN;
    END
    IF @Organism_ID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabOrganismMaster WHERE Organism_ID = @Organism_ID)
    BEGIN
        RAISERROR('Specific Organism is invalid.', 16, 1);
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Antibiotic_ID)
    BEGIN
        RAISERROR('Antibiotic is invalid.', 16, 1);
        RETURN;
    END
    IF @Organism_Category NOT IN (N'Enterobacteriaceae', N'Non-Fermenter', N'Gram Positive Cocci', N'Gram Positive Bacilli', N'Anaerobes', N'Fastidious Gram Negative', N'Mycobacteria', N'Fungal', N'Other')
    BEGIN
        RAISERROR('Organism Category has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Standard NOT IN (N'CLSI', N'EUCAST')
    BEGIN
        RAISERROR('Standard has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Method NOT IN (N'MIC (mg/L)', N'Disk Diffusion (mm)')
    BEGIN
        RAISERROR('Method has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Specimen_Scope NOT IN (N'All Specimens', N'Urine (Uncomplicated UTI)', N'Non-Meningitis', N'Meningitis')
    BEGIN
        RAISERROR('Specimen Scope has an invalid value.', 16, 1);
        RETURN;
    END

    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabBreakpointMaster WHERE Breakpoint_ID = @Id), @RowId INT = @Id;
    IF EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster WHERE LOWER(Organism_Category) = LOWER(@Organism_Category) AND ISNULL(Organism_ID, -1) = ISNULL(@Organism_ID, -1) AND Antibiotic_ID = @Antibiotic_ID AND LOWER(Standard) = LOWER(@Standard) AND LOWER(Standard_Version) = LOWER(@Standard_Version) AND LOWER(Method) = LOWER(@Method) AND LOWER(Specimen_Scope) = LOWER(@Specimen_Scope) AND CompanyId = @CompanyId AND Breakpoint_ID <> @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('A breakpoint for this organism, antibiotic, standard, version, method and specimen scope already exists.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.LabBreakpointMaster
        SET Organism_Category = @Organism_Category,
        Organism_ID = @Organism_ID,
        Antibiotic_ID = @Antibiotic_ID,
        Standard = @Standard,
        Standard_Version = @Standard_Version,
        Method = @Method,
        Specimen_Scope = @Specimen_Scope,
        S_Breakpoint = @S_Breakpoint,
        R_Breakpoint = @R_Breakpoint,
        Remarks = @Remarks,
        Status = @Status,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
        WHERE Breakpoint_ID = @Id;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_ToggleStatus
    @Id     INT,
    @Status BIT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster WHERE Breakpoint_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Breakpoint record not found.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabBreakpointMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Breakpoint_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster WHERE Breakpoint_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Breakpoint record not found or already deleted.', 16, 1);
        RETURN;
    END

    UPDATE dbo.LabBreakpointMaster SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Breakpoint_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_LookupOrganisms
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Organism_ID AS Id, Organism_Name + ' - ' + Organism_Category AS Text FROM dbo.LabOrganismMaster WHERE IsDeleted = 0 AND Status = 1 AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Organism_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabBreakpointMaster_LookupAntibiotics
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Antibiotic_ID AS Id, Antibiotic_Name + ISNULL(' (' + Abbreviation + ')', '') AS Text FROM dbo.LabAntibioticMaster WHERE IsDeleted = 0 AND Status = 1 AND (@CompanyId IS NULL OR CompanyId = @CompanyId) ORDER BY Antibiotic_Name;
END
GO

-- Seed sample EUCAST breakpoints (MIC, mg/L). Starter examples only - verify before use.
DECLARE @B TABLE (RowNo INT IDENTITY(1,1), Cat NVARCHAR(50), Org NVARCHAR(150), Abx NVARCHAR(20), Scope NVARCHAR(50), SV DECIMAL(12,4), RV DECIMAL(12,4));
INSERT INTO @B (Cat, Org, Abx, Scope, SV, RV) VALUES
    (N'Enterobacteriaceae', NULL, N'AMP', N'All Specimens', 8, 8),
    (N'Enterobacteriaceae', NULL, N'AMC', N'All Specimens', 8, 8),
    (N'Enterobacteriaceae', NULL, N'CRO', N'All Specimens', 1, 2),
    (N'Enterobacteriaceae', NULL, N'CAZ', N'All Specimens', 1, 4),
    (N'Enterobacteriaceae', NULL, N'FEP', N'All Specimens', 1, 4),
    (N'Enterobacteriaceae', NULL, N'MEM', N'Non-Meningitis', 2, 8),
    (N'Enterobacteriaceae', NULL, N'ETP', N'All Specimens', 0.5, 0.5),
    (N'Enterobacteriaceae', NULL, N'GEN', N'All Specimens', 2, 2),
    (N'Enterobacteriaceae', NULL, N'AMK', N'All Specimens', 8, 8),
    (N'Enterobacteriaceae', NULL, N'CIP', N'All Specimens', 0.25, 0.5),
    (N'Enterobacteriaceae', NULL, N'SXT', N'All Specimens', 2, 4),
    (N'Enterobacteriaceae', N'Escherichia coli', N'NIT', N'Urine (Uncomplicated UTI)', 64, 64),
    (N'Non-Fermenter', N'Pseudomonas aeruginosa', N'MEM', N'Non-Meningitis', 2, 8),
    (N'Non-Fermenter', N'Pseudomonas aeruginosa', N'CAZ', N'All Specimens', 0.001, 8),
    (N'Non-Fermenter', N'Pseudomonas aeruginosa', N'TZP', N'All Specimens', 0.001, 16),
    (N'Non-Fermenter', N'Pseudomonas aeruginosa', N'CIP', N'All Specimens', 0.001, 0.5),
    (N'Gram Positive Cocci', N'Staphylococcus aureus (MSSA)', N'VAN', N'All Specimens', 2, 2),
    (N'Gram Positive Cocci', N'Staphylococcus aureus (MSSA)', N'FOX', N'All Specimens', 4, 4);

DECLARE @Base INT = (SELECT ISNULL(MAX(Breakpoint_ID), 0) FROM dbo.LabBreakpointMaster);
INSERT INTO dbo.LabBreakpointMaster (CompanyId, Breakpoint_Code, Organism_Category, Organism_ID, Antibiotic_ID, Standard, Standard_Version, Method, Specimen_Scope, S_Breakpoint, R_Breakpoint, Remarks, Status, CreatedDate)
SELECT 1, 'BKP' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY b.RowNo) AS NVARCHAR(10)), 4),
       b.Cat, o.Organism_ID, a.Antibiotic_ID, 'EUCAST', 'EUCAST v14.0 (Sample)', 'MIC (mg/L)', b.Scope, b.SV, b.RV, N'Sample value - verify against the current EUCAST breakpoint table before go-live. EUCAST: S if MIC <= S breakpoint; R if MIC > R breakpoint.', 1, GETDATE()
FROM @B b
JOIN dbo.LabAntibioticMaster a ON a.Abbreviation = b.Abx AND a.CompanyId = 1 AND a.IsDeleted = 0
LEFT JOIN dbo.LabOrganismMaster o ON o.Organism_Name = b.Org AND o.CompanyId = 1 AND o.IsDeleted = 0
WHERE (b.Org IS NULL OR o.Organism_ID IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM dbo.LabBreakpointMaster x
                  WHERE x.CompanyId = 1 AND x.IsDeleted = 0 AND x.Organism_Category = b.Cat AND x.Antibiotic_ID = a.Antibiotic_ID
                    AND ISNULL(x.Organism_ID, -1) = ISNULL(o.Organism_ID, -1) AND x.Standard = 'EUCAST'
                    AND x.Standard_Version = 'EUCAST v14.0 (Sample)' AND x.Method = 'MIC (mg/L)' AND x.Specimen_Scope = b.Scope);
GO

PRINT 'Breakpoint Master ready.';
