-- =============================================
-- Script : 2142_lab_antibiotic_master.sql
-- Purpose: Antibiotic Master — table and stored procedures.
-- CAP/NABL: Audit trail (Created/Modified By/Date), soft delete, company scope.
-- =============================================

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabAntibioticMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabAntibioticMaster
    (
        Antibiotic_ID INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId                INT NOT NULL DEFAULT 1,
        Antibiotic_Code NVARCHAR(50) NOT NULL,
        Antibiotic_Name          NVARCHAR(150) NOT NULL,
        Abbreviation             NVARCHAR(10) NULL,
        Antibiotic_Class         NVARCHAR(50) NOT NULL,
        Route                    NVARCHAR(30) NOT NULL,
        WHONET_Code              NVARCHAR(20) NULL,
        Description              NVARCHAR(500) NULL,
        Status                   BIT NOT NULL DEFAULT 1,
        IsDeleted                BIT NOT NULL DEFAULT 0,
        CreatedBy                INT NULL,
        CreatedDate              DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy               INT NULL,
        ModifiedDate             DATETIME2 NULL
    );
    CREATE INDEX IX_LabAntibioticMaster_Status ON dbo.LabAntibioticMaster(Status);
    CREATE UNIQUE INDEX UX_LabAntibioticMaster_Code ON dbo.LabAntibioticMaster(Antibiotic_Code);
END
GO

IF COL_LENGTH('dbo.LabAntibioticMaster', 'WHONET_Code') IS NULL
    ALTER TABLE dbo.LabAntibioticMaster ADD WHONET_Code NVARCHAR(20) NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticMaster_GetList
    @Status    BIT = NULL,
    @Search    NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Antibiotic_ID,
        m.CompanyId,
        m.Antibiotic_Code,
        m.Antibiotic_Name,
        m.Abbreviation,
        m.Antibiotic_Class,
        m.Route,
        m.WHONET_Code,
        m.Description,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabAntibioticMaster m
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = '' OR
           m.Antibiotic_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Antibiotic_Name LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Abbreviation LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Antibiotic_Class LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.Route LIKE '%' + LTRIM(RTRIM(@Search)) + '%' OR
           m.WHONET_Code LIKE '%' + LTRIM(RTRIM(@Search)) + '%')
    ORDER BY m.Antibiotic_Class, m.Antibiotic_Name;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticMaster_GetById
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        m.Antibiotic_ID,
        m.CompanyId,
        m.Antibiotic_Code,
        m.Antibiotic_Name,
        m.Abbreviation,
        m.Antibiotic_Class,
        m.Route,
        m.WHONET_Code,
        m.Description,
        m.Status,
        m.CreatedBy,
        m.CreatedDate,
        m.ModifiedBy,
        m.ModifiedDate
    FROM dbo.LabAntibioticMaster m
    WHERE m.Antibiotic_ID = @Id AND m.IsDeleted = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticMaster_Create
    @Antibiotic_Name        NVARCHAR(150),
    @Abbreviation           NVARCHAR(10) = NULL,
    @Antibiotic_Class       NVARCHAR(50),
    @Route                  NVARCHAR(30),
    @WHONET_Code            NVARCHAR(20) = NULL,
    @Description            NVARCHAR(500) = NULL,
    @CompanyId              INT = 1,
    @UserId                 INT = NULL,
    @NewId                  INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Antibiotic_Name = NULLIF(LTRIM(RTRIM(@Antibiotic_Name)), '');
    SET @Abbreviation = NULLIF(LTRIM(RTRIM(@Abbreviation)), '');
    SET @Antibiotic_Class = NULLIF(LTRIM(RTRIM(@Antibiotic_Class)), '');
    SET @Route = NULLIF(LTRIM(RTRIM(@Route)), '');
    SET @WHONET_Code = NULLIF(LTRIM(RTRIM(@WHONET_Code)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    IF @Antibiotic_Name IS NULL
    BEGIN
        RAISERROR('Antibiotic Name is required.', 16, 1);
        RETURN;
    END
    IF @Antibiotic_Class IS NULL
    BEGIN
        RAISERROR('Antibiotic Class is required.', 16, 1);
        RETURN;
    END
    IF @Route IS NULL
    BEGIN
        RAISERROR('Route is required.', 16, 1);
        RETURN;
    END
    IF @Antibiotic_Class NOT IN (N'Penicillins', N'Beta-lactam Combinations', N'Cephalosporins', N'Carbapenems', N'Monobactams', N'Aminoglycosides', N'Quinolones', N'Macrolides', N'Lincosamides', N'Tetracyclines', N'Glycopeptides', N'Oxazolidinones', N'Polymyxins', N'Sulfonamides', N'Nitrofurans', N'Phosphonic Acids', N'Antifungals', N'Other')
    BEGIN
        RAISERROR('Antibiotic Class has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Route NOT IN (N'Oral', N'IV', N'IM', N'Oral / IV', N'IV / IM', N'Topical', N'Urinary Only')
    BEGIN
        RAISERROR('Route has an invalid value.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE LOWER(Antibiotic_Name) = LOWER(@Antibiotic_Name) AND CompanyId = @CompanyId AND IsDeleted = 0)
    BEGIN
        RAISERROR('An Antibiotic with the same name already exists.', 16, 1);
        RETURN;
    END

    DECLARE @Next INT, @GeneratedCode NVARCHAR(50), @RowId INT;
    SELECT @Next = ISNULL(MAX(Antibiotic_ID), 0) + 1 FROM dbo.LabAntibioticMaster;
    SET @GeneratedCode = 'ABX' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_Code = @GeneratedCode)
    BEGIN
        SET @Next += 1;
        SET @GeneratedCode = 'ABX' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
    END

    BEGIN TRY
        INSERT INTO dbo.LabAntibioticMaster
        (
        CompanyId,
        Antibiotic_Code,
        Antibiotic_Name,
        Abbreviation,
        Antibiotic_Class,
        Route,
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
        @Antibiotic_Name,
        @Abbreviation,
        @Antibiotic_Class,
        @Route,
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

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticMaster_Update
    @Id INT,
    @Antibiotic_Name        NVARCHAR(150),
    @Abbreviation           NVARCHAR(10) = NULL,
    @Antibiotic_Class       NVARCHAR(50),
    @Route                  NVARCHAR(30),
    @WHONET_Code            NVARCHAR(20) = NULL,
    @Description            NVARCHAR(500) = NULL,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Antibiotic record not found.', 16, 1);
        RETURN;
    END
    SET @Antibiotic_Name = NULLIF(LTRIM(RTRIM(@Antibiotic_Name)), '');
    SET @Abbreviation = NULLIF(LTRIM(RTRIM(@Abbreviation)), '');
    SET @Antibiotic_Class = NULLIF(LTRIM(RTRIM(@Antibiotic_Class)), '');
    SET @Route = NULLIF(LTRIM(RTRIM(@Route)), '');
    SET @WHONET_Code = NULLIF(LTRIM(RTRIM(@WHONET_Code)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    IF @Antibiotic_Name IS NULL
    BEGIN
        RAISERROR('Antibiotic Name is required.', 16, 1);
        RETURN;
    END
    IF @Antibiotic_Class IS NULL
    BEGIN
        RAISERROR('Antibiotic Class is required.', 16, 1);
        RETURN;
    END
    IF @Route IS NULL
    BEGIN
        RAISERROR('Route is required.', 16, 1);
        RETURN;
    END
    IF @Antibiotic_Class NOT IN (N'Penicillins', N'Beta-lactam Combinations', N'Cephalosporins', N'Carbapenems', N'Monobactams', N'Aminoglycosides', N'Quinolones', N'Macrolides', N'Lincosamides', N'Tetracyclines', N'Glycopeptides', N'Oxazolidinones', N'Polymyxins', N'Sulfonamides', N'Nitrofurans', N'Phosphonic Acids', N'Antifungals', N'Other')
    BEGIN
        RAISERROR('Antibiotic Class has an invalid value.', 16, 1);
        RETURN;
    END
    IF @Route NOT IN (N'Oral', N'IV', N'IM', N'Oral / IV', N'IV / IM', N'Topical', N'Urinary Only')
    BEGIN
        RAISERROR('Route has an invalid value.', 16, 1);
        RETURN;
    END

    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Id), @RowId INT = @Id;
    IF EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE LOWER(Antibiotic_Name) = LOWER(@Antibiotic_Name) AND CompanyId = @CompanyId AND Antibiotic_ID <> @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('An Antibiotic with the same name already exists.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.LabAntibioticMaster
        SET Antibiotic_Name = @Antibiotic_Name,
        Abbreviation = @Abbreviation,
        Antibiotic_Class = @Antibiotic_Class,
        Route = @Route,
        WHONET_Code = @WHONET_Code,
        Description = @Description,
        Status = @Status,
        ModifiedBy = @UserId,
        ModifiedDate = GETDATE()
        WHERE Antibiotic_ID = @Id;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticMaster_ToggleStatus
    @Id     INT,
    @Status BIT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Antibiotic record not found.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabAntibioticMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Antibiotic_ID = @Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabAntibioticMaster_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster WHERE Antibiotic_ID = @Id AND IsDeleted = 0)
    BEGIN
        RAISERROR('Antibiotic record not found or already deleted.', 16, 1);
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabAntibioticPanelDetail')
       AND EXISTS (SELECT 1 FROM dbo.LabAntibioticPanelDetail d JOIN dbo.LabAntibioticPanelMaster p ON p.Panel_ID = d.Panel_ID
                   WHERE d.Antibiotic_ID = @Id AND p.IsDeleted = 0)
    BEGIN
        RAISERROR('This Antibiotic is used in an Antibiotic Panel. Remove it from the panel first.', 16, 1);
        RETURN;
    END
    UPDATE dbo.LabAntibioticMaster SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Antibiotic_ID = @Id;
END
GO

-- Seed data
DECLARE @Seed TABLE (RowNo INT IDENTITY(1,1), Antibiotic_Name NVARCHAR(200), Abbreviation NVARCHAR(200), Antibiotic_Class NVARCHAR(200), Route NVARCHAR(200));
INSERT INTO @Seed (Antibiotic_Name, Abbreviation, Antibiotic_Class, Route) VALUES
    (N'Ampicillin', N'AMP', N'Penicillins', N'Oral / IV'),
    (N'Amoxicillin', N'AMX', N'Penicillins', N'Oral'),
    (N'Penicillin G', N'PEN', N'Penicillins', N'IV / IM'),
    (N'Oxacillin', N'OXA', N'Penicillins', N'IV'),
    (N'Amoxicillin-Clavulanate', N'AMC', N'Beta-lactam Combinations', N'Oral / IV'),
    (N'Ampicillin-Sulbactam', N'SAM', N'Beta-lactam Combinations', N'IV'),
    (N'Piperacillin-Tazobactam', N'TZP', N'Beta-lactam Combinations', N'IV'),
    (N'Cefoperazone-Sulbactam', N'CFS', N'Beta-lactam Combinations', N'IV'),
    (N'Ceftazidime-Avibactam', N'CZA', N'Beta-lactam Combinations', N'IV'),
    (N'Cefazolin', N'CFZ', N'Cephalosporins', N'IV / IM'),
    (N'Cefuroxime', N'CXM', N'Cephalosporins', N'Oral / IV'),
    (N'Cefoxitin', N'FOX', N'Cephalosporins', N'IV'),
    (N'Ceftriaxone', N'CRO', N'Cephalosporins', N'IV / IM'),
    (N'Cefotaxime', N'CTX', N'Cephalosporins', N'IV / IM'),
    (N'Ceftazidime', N'CAZ', N'Cephalosporins', N'IV'),
    (N'Cefepime', N'FEP', N'Cephalosporins', N'IV'),
    (N'Cefixime', N'CFM', N'Cephalosporins', N'Oral'),
    (N'Imipenem', N'IPM', N'Carbapenems', N'IV'),
    (N'Meropenem', N'MEM', N'Carbapenems', N'IV'),
    (N'Ertapenem', N'ETP', N'Carbapenems', N'IV / IM'),
    (N'Aztreonam', N'ATM', N'Monobactams', N'IV'),
    (N'Gentamicin', N'GEN', N'Aminoglycosides', N'IV / IM'),
    (N'Amikacin', N'AMK', N'Aminoglycosides', N'IV / IM'),
    (N'Tobramycin', N'TOB', N'Aminoglycosides', N'IV'),
    (N'Ciprofloxacin', N'CIP', N'Quinolones', N'Oral / IV'),
    (N'Levofloxacin', N'LVX', N'Quinolones', N'Oral / IV'),
    (N'Ofloxacin', N'OFX', N'Quinolones', N'Oral'),
    (N'Norfloxacin', N'NOR', N'Quinolones', N'Urinary Only'),
    (N'Erythromycin', N'ERY', N'Macrolides', N'Oral'),
    (N'Azithromycin', N'AZM', N'Macrolides', N'Oral / IV'),
    (N'Clindamycin', N'CLI', N'Lincosamides', N'Oral / IV'),
    (N'Tetracycline', N'TCY', N'Tetracyclines', N'Oral'),
    (N'Doxycycline', N'DOX', N'Tetracyclines', N'Oral / IV'),
    (N'Minocycline', N'MIN', N'Tetracyclines', N'Oral / IV'),
    (N'Tigecycline', N'TGC', N'Tetracyclines', N'IV'),
    (N'Vancomycin', N'VAN', N'Glycopeptides', N'IV'),
    (N'Teicoplanin', N'TEC', N'Glycopeptides', N'IV / IM'),
    (N'Linezolid', N'LNZ', N'Oxazolidinones', N'Oral / IV'),
    (N'Colistin', N'CST', N'Polymyxins', N'IV'),
    (N'Polymyxin B', N'PMB', N'Polymyxins', N'IV'),
    (N'Trimethoprim-Sulfamethoxazole', N'SXT', N'Sulfonamides', N'Oral / IV'),
    (N'Nitrofurantoin', N'NIT', N'Nitrofurans', N'Urinary Only'),
    (N'Fosfomycin', N'FOS', N'Phosphonic Acids', N'Urinary Only'),
    (N'Fluconazole', N'FLU', N'Antifungals', N'Oral / IV'),
    (N'Voriconazole', N'VOR', N'Antifungals', N'Oral / IV'),
    (N'Amphotericin B', N'AMB', N'Antifungals', N'IV'),
    (N'Caspofungin', N'CAS', N'Antifungals', N'IV'),
    (N'Micafungin', N'MFG', N'Antifungals', N'IV');

DECLARE @Base INT = (SELECT ISNULL(MAX(Antibiotic_ID), 0) FROM dbo.LabAntibioticMaster);
INSERT INTO dbo.LabAntibioticMaster (CompanyId, Antibiotic_Code, Antibiotic_Name, Abbreviation, Antibiotic_Class, Route, Status, CreatedDate)
SELECT 1, 'ABX' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY s.RowNo) AS NVARCHAR(10)), 4), s.Antibiotic_Name, s.Abbreviation, s.Antibiotic_Class, s.Route, 1, GETDATE()
FROM @Seed s
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabAntibioticMaster x WHERE x.Antibiotic_Name = s.Antibiotic_Name AND x.IsDeleted = 0);
GO

PRINT 'Antibiotic Master ready.';
