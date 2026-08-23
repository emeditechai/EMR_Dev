-- Migration Script: 105_analyzer_master_tbl_mst_analyzer.sql
-- Purpose: Create Analyzer / Instrument Master (tbl_mst_analyzer) and Stored Procedures for API CRUD

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'tbl_mst_analyzer' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.tbl_mst_analyzer (
        Analyzer_ID         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_tbl_mst_analyzer PRIMARY KEY,
        CompanyId           INT NOT NULL CONSTRAINT DF_tbl_mst_analyzer_CompanyId DEFAULT 1,
        Branch_ID           INT NOT NULL,
        Department_ID       INT NOT NULL,
        Analyzer_Name       NVARCHAR(150) NOT NULL,
        Interface_Protocol  NVARCHAR(50) NOT NULL, -- HL7 / ASTM / Manual Entry
        Status              BIT NOT NULL CONSTRAINT DF_tbl_mst_analyzer_Status DEFAULT 1,
        CreatedDate         DATETIME2 NOT NULL CONSTRAINT DF_tbl_mst_analyzer_CreatedDate DEFAULT GETDATE(),
        CreatedBy           INT NULL,
        ModifiedDate        DATETIME2 NULL,
        ModifiedBy          INT NULL
    );

    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Branchmaster')
    BEGIN
        ALTER TABLE dbo.tbl_mst_analyzer
        ADD CONSTRAINT FK_tbl_mst_analyzer_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID);
    END

    IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'DepartmentMaster')
    BEGIN
        ALTER TABLE dbo.tbl_mst_analyzer
        ADD CONSTRAINT FK_tbl_mst_analyzer_Department FOREIGN KEY (Department_ID) REFERENCES dbo.DepartmentMaster(DeptId);
    END
END
GO

-- 1. usp_Api_Analyzer_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_Analyzer_GetList
    @BranchId INT = NULL,
    @DepartmentId INT = NULL,
    @InterfaceProtocol NVARCHAR(50) = NULL,
    @Status BIT = NULL,
    @Search NVARCHAR(100) = NULL,
    @CompanyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        a.Analyzer_ID,
        a.CompanyId,
        a.Branch_ID,
        ISNULL(b.BranchName, 'Main Branch') AS BranchName,
        ISNULL(b.BranchCode, 'MB') AS BranchCode,
        a.Department_ID,
        ISNULL(d.DeptName, 'Laboratory') AS DepartmentName,
        ISNULL(d.DeptCode, 'LAB') AS DepartmentCode,
        ISNULL(d.DeptType, 'Lab') AS DepartmentType,
        a.Analyzer_Name,
        a.Interface_Protocol,
        a.Status,
        a.CreatedDate,
        a.CreatedBy,
        a.ModifiedDate,
        a.ModifiedBy
    FROM dbo.tbl_mst_analyzer a
    LEFT JOIN dbo.Branchmaster b ON a.Branch_ID = b.BranchID
    LEFT JOIN dbo.DepartmentMaster d ON a.Department_ID = d.DeptId
    WHERE (@CompanyId IS NULL OR a.CompanyId = @CompanyId)
      AND (@BranchId IS NULL OR a.Branch_ID = @BranchId)
      AND (@DepartmentId IS NULL OR a.Department_ID = @DepartmentId)
      AND (@InterfaceProtocol IS NULL OR a.Interface_Protocol = @InterfaceProtocol)
      AND (@Status IS NULL OR a.Status = @Status)
      AND (@Search IS NULL OR (
          a.Analyzer_Name LIKE '%' + @Search + '%' OR
          a.Interface_Protocol LIKE '%' + @Search + '%' OR
          b.BranchName LIKE '%' + @Search + '%' OR
          d.DeptName LIKE '%' + @Search + '%'
      ))
    ORDER BY a.Analyzer_Name ASC;
END
GO

-- 2. usp_Api_Analyzer_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_Analyzer_GetById
    @Analyzer_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        a.Analyzer_ID,
        a.CompanyId,
        a.Branch_ID,
        ISNULL(b.BranchName, 'Main Branch') AS BranchName,
        ISNULL(b.BranchCode, 'MB') AS BranchCode,
        a.Department_ID,
        ISNULL(d.DeptName, 'Laboratory') AS DepartmentName,
        ISNULL(d.DeptCode, 'LAB') AS DepartmentCode,
        ISNULL(d.DeptType, 'Lab') AS DepartmentType,
        a.Analyzer_Name,
        a.Interface_Protocol,
        a.Status,
        a.CreatedDate,
        a.CreatedBy,
        a.ModifiedDate,
        a.ModifiedBy
    FROM dbo.tbl_mst_analyzer a
    LEFT JOIN dbo.Branchmaster b ON a.Branch_ID = b.BranchID
    LEFT JOIN dbo.DepartmentMaster d ON a.Department_ID = d.DeptId
    WHERE a.Analyzer_ID = @Analyzer_ID;
END
GO

-- 3. usp_Api_Analyzer_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_Analyzer_Create
    @CompanyId INT = 1,
    @Branch_ID INT,
    @Department_ID INT,
    @Analyzer_Name NVARCHAR(150),
    @Interface_Protocol NVARCHAR(50),
    @Status BIT = 1,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.tbl_mst_analyzer (
        CompanyId,
        Branch_ID,
        Department_ID,
        Analyzer_Name,
        Interface_Protocol,
        Status,
        CreatedDate,
        CreatedBy,
        ModifiedDate,
        ModifiedBy
    )
    VALUES (
        ISNULL(@CompanyId, 1),
        @Branch_ID,
        @Department_ID,
        @Analyzer_Name,
        @Interface_Protocol,
        @Status,
        GETDATE(),
        @UserId,
        GETDATE(),
        @UserId
    );

    SELECT CAST(SCOPE_IDENTITY() AS INT);
END
GO

-- 4. usp_Api_Analyzer_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_Analyzer_Update
    @Analyzer_ID INT,
    @CompanyId INT = 1,
    @Branch_ID INT,
    @Department_ID INT,
    @Analyzer_Name NVARCHAR(150),
    @Interface_Protocol NVARCHAR(50),
    @Status BIT = 1,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.tbl_mst_analyzer
    SET Branch_ID = @Branch_ID,
        Department_ID = @Department_ID,
        Analyzer_Name = @Analyzer_Name,
        Interface_Protocol = @Interface_Protocol,
        Status = @Status,
        ModifiedDate = GETDATE(),
        ModifiedBy = @UserId
    WHERE Analyzer_ID = @Analyzer_ID;

    SELECT @@ROWCOUNT;
END
GO

-- 5. usp_Api_Analyzer_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_Analyzer_ToggleStatus
    @Analyzer_ID INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.tbl_mst_analyzer
    SET Status = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedDate = GETDATE(),
        ModifiedBy = @UserId
    WHERE Analyzer_ID = @Analyzer_ID;

    SELECT Status FROM dbo.tbl_mst_analyzer WHERE Analyzer_ID = @Analyzer_ID;
END
GO

-- 6. usp_Api_Analyzer_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_Analyzer_Delete
    @Analyzer_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.tbl_mst_analyzer
    WHERE Analyzer_ID = @Analyzer_ID;

    SELECT @@ROWCOUNT;
END
GO

-- 7. Seed Initial Lab Analyzers if empty
IF NOT EXISTS (SELECT 1 FROM dbo.tbl_mst_analyzer)
BEGIN
    DECLARE @DefaultBranch INT = (SELECT TOP 1 BranchID FROM dbo.Branchmaster WHERE IsActive = 1 ORDER BY BranchID);
    DECLARE @LabDept INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE (DeptType = 'Lab' OR DeptType = 'LAB' OR DeptName LIKE '%Pathology%' OR DeptName LIKE '%Lab%') AND IsActive = 1 ORDER BY DeptId);

    IF @DefaultBranch IS NULL SET @DefaultBranch = 1;
    IF @LabDept IS NULL SET @LabDept = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE IsActive = 1 ORDER BY DeptId);
    IF @LabDept IS NULL SET @LabDept = 1;

    INSERT INTO dbo.tbl_mst_analyzer (CompanyId, Branch_ID, Department_ID, Analyzer_Name, Interface_Protocol, Status, CreatedDate, CreatedBy)
    VALUES 
    (1, @DefaultBranch, @LabDept, 'Roche Cobas 6000 (c501/e601)', 'HL7', 1, GETDATE(), 1),
    (1, @DefaultBranch, @LabDept, 'Sysmex XN-1000 Hematology Analyzer', 'ASTM', 1, GETDATE(), 1),
    (1, @DefaultBranch, @LabDept, 'Beckman Coulter AU480 Clinical Chemistry', 'ASTM', 1, GETDATE(), 1),
    (1, @DefaultBranch, @LabDept, 'Bio-Rad D-10 Hemoglobin Testing System', 'Manual Entry', 1, GETDATE(), 1),
    (1, @DefaultBranch, @LabDept, 'Mindray BC-6800 Plus Auto Hematology', 'HL7', 1, GETDATE(), 1);
END
GO
