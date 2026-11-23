-- ============================================================================
-- Migration: 2251_qc_equipment_eqas.sql
-- Description: Quality & Compliance - LF-06 Equipment and EQAS register (ISO 15189 6.4 equipment, 7.3.7.3 EQA).
--   Equipment register: every instrument of a branch (optionally the Analyzer master's analyzer it is), type, make,
--     model, serial no., location, warranty, AMC / CMC contract with a Supplier Master vendor, calibration and
--     preventive maintenance intervals (defaults from the equipment type), status In use / Out of service / Retired.
--   Calibration log: date, internal / external agency, certificate no. and file, result Pass / Adjusted / Fail and the
--     next due date. A Fail takes the instrument out of service and opens a CAPA; a later Pass returns it to use
--     (unless a breakdown is still open).
--   Maintenance log: daily / weekly / monthly ... checks and preventive maintenance / vendor service visits, with the
--     next preventive maintenance due date.
--   Breakdown log: reporting a breakdown takes the instrument out of service; it is resolved only with the resolution
--     and a passed QC run after the repair; downtime hours are kept. A breakdown can raise a CAPA.
--   EQAS: programmes (provider, enrolment, cycles a year, z-score limits) with the tests in scope; cycles (sample
--     received, report due, submitted, evaluated); results with target / SD (or the SDI from the report) -> z-score ->
--     Acceptable (|z| <= limit) / Warning / Unacceptable; qualitative results against the expected answer.
--     An unacceptable result opens a CAPA.
--   CAPA: corrective and preventive action register (source EQAS / Calibration / Breakdown / Other): root cause,
--     actions, responsible user, target date; closing needs root cause, corrective action and an effectiveness check.
--   Reports (Reports > LAB, shape of SQLScripts/2124): equipment-due, equipment-downtime, eqas-performance, capa-register.
--   Pages under Quality & Compliance > Equipment & EQAS and Reports > LAB; the Analyzers page reads the equipment status.
--   No role is granted here (Settings > Security). Business rules: THROW 54000-54999. Safe to re-run.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Tables ---------------------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.QcEquipmentType', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEquipmentType
    (
        TypeId              INT IDENTITY(1,1) CONSTRAINT PK_QcEquipmentType PRIMARY KEY,
        TypeName            NVARCHAR(80) NOT NULL CONSTRAINT UQ_QcEquipmentType_Name UNIQUE,
        CalibrationFreqDays INT NULL,               -- default for new equipment of the type
        PmFreqDays          INT NULL,
        SortOrder           INT NOT NULL CONSTRAINT DF_QcEquipmentType_Sort DEFAULT 0,
        IsActive            BIT NOT NULL CONSTRAINT DF_QcEquipmentType_Active DEFAULT 1
    );
    INSERT INTO dbo.QcEquipmentType (TypeName, CalibrationFreqDays, PmFreqDays, SortOrder) VALUES
     (N'Analyzer', 365, 90, 10), (N'Centrifuge', 365, 180, 20), (N'Microscope', 365, 180, 30),
     (N'Refrigerator / Freezer', 365, 90, 40), (N'Incubator', 365, 180, 50), (N'Water bath', 365, 180, 60),
     (N'Hot air oven', 365, 180, 70), (N'Autoclave', 365, 90, 80), (N'Biosafety cabinet', 365, 180, 90),
     (N'Micropipette', 180, NULL, 100), (N'Thermometer / Data logger', 365, NULL, 110), (N'Weighing balance', 365, 180, 120),
     (N'Other', NULL, NULL, 999);
END
GO

IF OBJECT_ID(N'dbo.QcEquipment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEquipment
    (
        EquipmentId         INT IDENTITY(1,1) CONSTRAINT PK_QcEquipment PRIMARY KEY,
        CompanyId           INT NOT NULL,
        BranchId            INT NOT NULL,
        AssetCode           NVARCHAR(20) NOT NULL,       -- EQ0001 ...
        EquipmentName       NVARCHAR(200) NOT NULL,
        TypeId              INT NOT NULL CONSTRAINT FK_QcEquipment_Type REFERENCES dbo.QcEquipmentType(TypeId),
        AnalyzerId          INT NULL,                    -- tbl_mst_analyzer (one equipment per analyzer)
        DepartmentId        INT NULL,
        Make                NVARCHAR(100) NULL,
        Model               NVARCHAR(100) NULL,
        SerialNo            NVARCHAR(100) NULL,
        Location            NVARCHAR(150) NULL,
        SupplierId          INT NULL,                    -- InvSupplier: who supplied it
        InstallDate         DATE NULL,
        WarrantyUpto        DATE NULL,
        ContractType        VARCHAR(10) NOT NULL CONSTRAINT DF_QcEquipment_Contract DEFAULT 'NONE',   -- NONE | AMC | CMC
        ContractVendorId    INT NULL,                    -- InvSupplier
        ContractFrom        DATE NULL,
        ContractUpto        DATE NULL,
        ContractCost        DECIMAL(14,2) NULL,
        PurchaseCost        DECIMAL(14,2) NULL,
        CalibrationFreqDays INT NULL,
        PmFreqDays          INT NULL,
        Status              VARCHAR(20) NOT NULL CONSTRAINT DF_QcEquipment_Status DEFAULT 'IN_USE',  -- IN_USE | OUT_OF_SERVICE | RETIRED
        StatusReason        NVARCHAR(300) NULL,
        StatusOn            DATETIME NULL,
        Remarks             NVARCHAR(500) NULL,
        IsDeleted           BIT NOT NULL CONSTRAINT DF_QcEquipment_Deleted DEFAULT 0,
        CreatedBy           INT NULL,
        CreatedDate         DATETIME NOT NULL CONSTRAINT DF_QcEquipment_Created DEFAULT GETDATE(),
        ModifiedBy          INT NULL,
        ModifiedDate        DATETIME NULL,
        CONSTRAINT CK_QcEquipment_Contract CHECK (ContractType IN ('NONE', 'AMC', 'CMC')),
        CONSTRAINT CK_QcEquipment_Status CHECK (Status IN ('IN_USE', 'OUT_OF_SERVICE', 'RETIRED'))
    );
    CREATE UNIQUE INDEX UX_QcEquipment_Code ON dbo.QcEquipment(CompanyId, AssetCode);
    CREATE UNIQUE INDEX UX_QcEquipment_Analyzer ON dbo.QcEquipment(AnalyzerId) WHERE AnalyzerId IS NOT NULL AND IsDeleted = 0;
    CREATE INDEX IX_QcEquipment_Branch ON dbo.QcEquipment(BranchId, Status);
END
GO

IF OBJECT_ID(N'dbo.QcEquipmentCalibration', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEquipmentCalibration
    (
        CalibrationId   INT IDENTITY(1,1) CONSTRAINT PK_QcEquipmentCalibration PRIMARY KEY,
        EquipmentId     INT NOT NULL CONSTRAINT FK_QcEquipmentCalibration_Eq REFERENCES dbo.QcEquipment(EquipmentId),
        CalibratedOn    DATE NOT NULL,
        Agency          VARCHAR(10) NOT NULL,            -- INTERNAL | EXTERNAL
        AgencyName      NVARCHAR(200) NULL,
        VendorId        INT NULL,
        CertificateNo   NVARCHAR(100) NULL,
        Result          VARCHAR(10) NOT NULL,            -- PASS | ADJUSTED | FAIL
        NextDueOn       DATE NULL,
        Remarks         NVARCHAR(500) NULL,
        CertificatePath NVARCHAR(400) NULL,
        IsDeleted       BIT NOT NULL CONSTRAINT DF_QcEquipmentCalibration_Deleted DEFAULT 0,
        CreatedBy       INT NULL,
        CreatedDate     DATETIME NOT NULL CONSTRAINT DF_QcEquipmentCalibration_Created DEFAULT GETDATE(),
        CONSTRAINT CK_QcEquipmentCalibration_Agency CHECK (Agency IN ('INTERNAL', 'EXTERNAL')),
        CONSTRAINT CK_QcEquipmentCalibration_Result CHECK (Result IN ('PASS', 'ADJUSTED', 'FAIL'))
    );
    CREATE INDEX IX_QcEquipmentCalibration_Eq ON dbo.QcEquipmentCalibration(EquipmentId, CalibratedOn);
END
GO

IF OBJECT_ID(N'dbo.QcEquipmentMaintenance', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEquipmentMaintenance
    (
        MaintenanceId  INT IDENTITY(1,1) CONSTRAINT PK_QcEquipmentMaintenance PRIMARY KEY,
        EquipmentId    INT NOT NULL CONSTRAINT FK_QcEquipmentMaintenance_Eq REFERENCES dbo.QcEquipment(EquipmentId),
        MaintType      VARCHAR(20) NOT NULL,            -- DAILY | WEEKLY | MONTHLY | QUARTERLY | HALF_YEARLY | YEARLY | PREVENTIVE | SERVICE_VISIT
        DoneOn         DATE NOT NULL,
        DoneByName     NVARCHAR(150) NULL,              -- technician / service engineer
        VendorId       INT NULL,
        Checklist      NVARCHAR(1000) NULL,
        Findings       NVARCHAR(1000) NULL,
        NextDueOn      DATE NULL,                       -- next preventive maintenance (PREVENTIVE / SERVICE_VISIT)
        Cost           DECIMAL(14,2) NULL,
        ReportPath     NVARCHAR(400) NULL,
        IsDeleted      BIT NOT NULL CONSTRAINT DF_QcEquipmentMaintenance_Deleted DEFAULT 0,
        CreatedBy      INT NULL,
        CreatedDate    DATETIME NOT NULL CONSTRAINT DF_QcEquipmentMaintenance_Created DEFAULT GETDATE(),
        CONSTRAINT CK_QcEquipmentMaintenance_Type CHECK (MaintType IN ('DAILY', 'WEEKLY', 'MONTHLY', 'QUARTERLY', 'HALF_YEARLY', 'YEARLY', 'PREVENTIVE', 'SERVICE_VISIT'))
    );
    CREATE INDEX IX_QcEquipmentMaintenance_Eq ON dbo.QcEquipmentMaintenance(EquipmentId, DoneOn);
END
GO

IF OBJECT_ID(N'dbo.QcCapa', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcCapa
    (
        CapaId            INT IDENTITY(1,1) CONSTRAINT PK_QcCapa PRIMARY KEY,
        CompanyId         INT NOT NULL,
        BranchId          INT NOT NULL,
        CapaNo            NVARCHAR(20) NOT NULL,         -- CAPA-0001 ...
        SourceType        VARCHAR(15) NOT NULL,          -- EQAS | CALIBRATION | BREAKDOWN | OTHER
        SourceId          INT NULL,
        EquipmentId       INT NULL,
        ProgramId         INT NULL,
        Title             NVARCHAR(200) NOT NULL,
        Problem           NVARCHAR(1000) NULL,
        RootCause         NVARCHAR(1000) NULL,
        CorrectiveAction  NVARCHAR(1000) NULL,
        PreventiveAction  NVARCHAR(1000) NULL,
        ResponsibleUserId INT NULL,
        TargetDate        DATE NULL,
        Status            VARCHAR(15) NOT NULL CONSTRAINT DF_QcCapa_Status DEFAULT 'OPEN',   -- OPEN | ACTION_TAKEN | CLOSED
        Effectiveness     NVARCHAR(1000) NULL,
        ClosedOn          DATETIME NULL,
        ClosedBy          INT NULL,
        CreatedBy         INT NULL,
        CreatedDate       DATETIME NOT NULL CONSTRAINT DF_QcCapa_Created DEFAULT GETDATE(),
        ModifiedBy        INT NULL,
        ModifiedDate      DATETIME NULL,
        CONSTRAINT CK_QcCapa_Source CHECK (SourceType IN ('EQAS', 'CALIBRATION', 'BREAKDOWN', 'OTHER')),
        CONSTRAINT CK_QcCapa_Status CHECK (Status IN ('OPEN', 'ACTION_TAKEN', 'CLOSED'))
    );
    CREATE UNIQUE INDEX UX_QcCapa_No ON dbo.QcCapa(CompanyId, CapaNo);
    CREATE INDEX IX_QcCapa_Branch ON dbo.QcCapa(BranchId, Status);
END
GO

IF OBJECT_ID(N'dbo.QcEquipmentBreakdown', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEquipmentBreakdown
    (
        BreakdownId    INT IDENTITY(1,1) CONSTRAINT PK_QcEquipmentBreakdown PRIMARY KEY,
        EquipmentId    INT NOT NULL CONSTRAINT FK_QcEquipmentBreakdown_Eq REFERENCES dbo.QcEquipment(EquipmentId),
        ReportedOn     DATETIME NOT NULL,
        ReportedBy     INT NULL,
        Problem        NVARCHAR(1000) NOT NULL,
        Impact         NVARCHAR(500) NULL,              -- tests stopped / sent to another branch or analyzer
        VendorId       INT NULL,
        VendorTicketNo NVARCHAR(100) NULL,
        CallLoggedOn   DATETIME NULL,
        ResolvedOn     DATETIME NULL,
        ResolvedBy     INT NULL,
        Resolution     NVARCHAR(1000) NULL,
        PartsReplaced  NVARCHAR(500) NULL,
        Cost           DECIMAL(14,2) NULL,
        QcVerified     BIT NOT NULL CONSTRAINT DF_QcEquipmentBreakdown_Qc DEFAULT 0,   -- QC run passed after the repair
        Status         VARCHAR(10) NOT NULL CONSTRAINT DF_QcEquipmentBreakdown_Status DEFAULT 'OPEN',   -- OPEN | RESOLVED
        CapaId         INT NULL CONSTRAINT FK_QcEquipmentBreakdown_Capa REFERENCES dbo.QcCapa(CapaId),
        CreatedDate    DATETIME NOT NULL CONSTRAINT DF_QcEquipmentBreakdown_Created DEFAULT GETDATE(),
        CONSTRAINT CK_QcEquipmentBreakdown_Status CHECK (Status IN ('OPEN', 'RESOLVED'))
    );
    CREATE INDEX IX_QcEquipmentBreakdown_Eq ON dbo.QcEquipmentBreakdown(EquipmentId, Status);
END
GO

IF OBJECT_ID(N'dbo.QcEqasProgram', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEqasProgram
    (
        ProgramId     INT IDENTITY(1,1) CONSTRAINT PK_QcEqasProgram PRIMARY KEY,
        CompanyId     INT NOT NULL,
        BranchId      INT NOT NULL,
        ProgramName   NVARCHAR(200) NOT NULL,
        Provider      NVARCHAR(200) NOT NULL,            -- CMC Vellore, AIIMS, Bio-Rad EQAS, Randox RIQAS ...
        EnrolmentNo   NVARCHAR(100) NULL,                -- our lab code with the provider
        DepartmentId  INT NULL,
        CyclesPerYear INT NULL,
        EnrolledFrom  DATE NULL,
        EnrolledUpto  DATE NULL,
        Fee           DECIMAL(14,2) NULL,
        AcceptZ       DECIMAL(5,2) NOT NULL CONSTRAINT DF_QcEqasProgram_AcceptZ DEFAULT 2,   -- |z| <= AcceptZ = acceptable
        ActionZ       DECIMAL(5,2) NOT NULL CONSTRAINT DF_QcEqasProgram_ActionZ DEFAULT 3,   -- |z| >  ActionZ = unacceptable
        Remarks       NVARCHAR(500) NULL,
        Status        BIT NOT NULL CONSTRAINT DF_QcEqasProgram_Status DEFAULT 1,
        IsDeleted     BIT NOT NULL CONSTRAINT DF_QcEqasProgram_Deleted DEFAULT 0,
        CreatedBy     INT NULL,
        CreatedDate   DATETIME NOT NULL CONSTRAINT DF_QcEqasProgram_Created DEFAULT GETDATE(),
        ModifiedBy    INT NULL,
        ModifiedDate  DATETIME NULL
    );
    CREATE TABLE dbo.QcEqasProgramTest
    (
        ProgramTestId INT IDENTITY(1,1) CONSTRAINT PK_QcEqasProgramTest PRIMARY KEY,
        ProgramId     INT NOT NULL CONSTRAINT FK_QcEqasProgramTest_Program REFERENCES dbo.QcEqasProgram(ProgramId),
        TestId        INT NOT NULL,                      -- LabInvestigationMaster (the analyte / parameter)
        ResultType    VARCHAR(5) NOT NULL CONSTRAINT DF_QcEqasProgramTest_Type DEFAULT 'QUANT',   -- QUANT | QUAL
        Unit          NVARCHAR(50) NULL,
        IsActive      BIT NOT NULL CONSTRAINT DF_QcEqasProgramTest_Active DEFAULT 1,
        CONSTRAINT CK_QcEqasProgramTest_Type CHECK (ResultType IN ('QUANT', 'QUAL'))
    );
    CREATE UNIQUE INDEX UX_QcEqasProgramTest ON dbo.QcEqasProgramTest(ProgramId, TestId);
END
GO

IF OBJECT_ID(N'dbo.QcEqasCycle', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.QcEqasCycle
    (
        CycleId      INT IDENTITY(1,1) CONSTRAINT PK_QcEqasCycle PRIMARY KEY,
        ProgramId    INT NOT NULL CONSTRAINT FK_QcEqasCycle_Program REFERENCES dbo.QcEqasProgram(ProgramId),
        CycleName    NVARCHAR(100) NOT NULL,             -- e.g. 2026 / Cycle 3
        SampleCode   NVARCHAR(100) NULL,
        ReceivedOn   DATE NOT NULL,
        ReportDueOn  DATE NULL,
        SubmittedOn  DATE NULL,
        EvaluatedOn  DATE NULL,
        Status       VARCHAR(10) NOT NULL CONSTRAINT DF_QcEqasCycle_Status DEFAULT 'RECEIVED',   -- RECEIVED | SUBMITTED | EVALUATED
        ReportPath   NVARCHAR(400) NULL,                 -- the provider's evaluation report
        Remarks      NVARCHAR(500) NULL,
        IsDeleted    BIT NOT NULL CONSTRAINT DF_QcEqasCycle_Deleted DEFAULT 0,
        CreatedBy    INT NULL,
        CreatedDate  DATETIME NOT NULL CONSTRAINT DF_QcEqasCycle_Created DEFAULT GETDATE(),
        CONSTRAINT CK_QcEqasCycle_Status CHECK (Status IN ('RECEIVED', 'SUBMITTED', 'EVALUATED'))
    );
    CREATE TABLE dbo.QcEqasResult
    (
        ResultId      INT IDENTITY(1,1) CONSTRAINT PK_QcEqasResult PRIMARY KEY,
        CycleId       INT NOT NULL CONSTRAINT FK_QcEqasResult_Cycle REFERENCES dbo.QcEqasCycle(CycleId),
        ProgramTestId INT NOT NULL CONSTRAINT FK_QcEqasResult_Test REFERENCES dbo.QcEqasProgramTest(ProgramTestId),
        OurValue      NVARCHAR(100) NULL,
        TargetValue   DECIMAL(18,4) NULL,                -- assigned / peer mean
        Sd            DECIMAL(18,4) NULL,                -- SD for proficiency assessment
        ReportedZ     DECIMAL(8,2) NULL,                 -- z / SDI printed on the provider's report (wins over target / SD)
        ExpectedValue NVARCHAR(100) NULL,                -- qualitative: the expected answer
        ZScore        DECIMAL(8,2) NULL,
        Performance   VARCHAR(15) NOT NULL CONSTRAINT DF_QcEqasResult_Perf DEFAULT 'NOT_EVALUATED',  -- ACCEPTABLE | WARNING | UNACCEPTABLE | NOT_EVALUATED
        CapaId        INT NULL CONSTRAINT FK_QcEqasResult_Capa REFERENCES dbo.QcCapa(CapaId),
        Remarks       NVARCHAR(300) NULL
    );
    CREATE UNIQUE INDEX UX_QcEqasResult ON dbo.QcEqasResult(CycleId, ProgramTestId);
END
GO

-- 2. Helpers ----------------------------------------------------------------------------------------------
-- every equipment with its calibration / maintenance / contract position as on today
CREATE OR ALTER FUNCTION dbo.ufn_Qc_EquipmentStatus (@CompanyId INT)
RETURNS TABLE
AS RETURN
(
    SELECT e.EquipmentId, e.CompanyId, e.BranchId, b.BranchName, e.AssetCode, e.EquipmentName, e.TypeId, t.TypeName,
           e.AnalyzerId, a.Analyzer_Name AS AnalyzerName, e.DepartmentId, d.DeptName AS DepartmentName,
           e.Make, e.Model, e.SerialNo, e.Location, e.SupplierId, sp.SupplierName, e.InstallDate, e.WarrantyUpto,
           e.ContractType, e.ContractVendorId, cv.SupplierName AS ContractVendorName, e.ContractFrom, e.ContractUpto, e.ContractCost,
           e.PurchaseCost, e.CalibrationFreqDays, e.PmFreqDays, e.Status, e.StatusReason, e.StatusOn, e.Remarks,
           lc.CalibratedOn AS LastCalibratedOn, lc.Result AS LastCalibrationResult,
           COALESCE(lc.NextDueOn, CASE WHEN lc.CalibrationId IS NULL AND e.CalibrationFreqDays IS NOT NULL AND e.InstallDate IS NOT NULL
                                       THEN DATEADD(DAY, e.CalibrationFreqDays, e.InstallDate) END) AS NextCalibrationDue,
           lp.DoneOn AS LastPmOn,
           COALESCE(lp.NextDueOn, CASE WHEN lp.MaintenanceId IS NULL AND e.PmFreqDays IS NOT NULL AND e.InstallDate IS NOT NULL
                                       THEN DATEADD(DAY, e.PmFreqDays, e.InstallDate) END) AS NextPmDue,
           (SELECT COUNT(1) FROM dbo.QcEquipmentBreakdown x WHERE x.EquipmentId = e.EquipmentId AND x.Status = 'OPEN') AS OpenBreakdowns,
           (SELECT COUNT(1) FROM dbo.QcCapa x WHERE x.EquipmentId = e.EquipmentId AND x.Status <> 'CLOSED') AS OpenCapas
    FROM dbo.QcEquipment e
    INNER JOIN dbo.QcEquipmentType t ON t.TypeId = e.TypeId
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = e.BranchId
    LEFT JOIN dbo.tbl_mst_analyzer a ON a.Analyzer_ID = e.AnalyzerId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = e.DepartmentId
    LEFT JOIN dbo.InvSupplier sp ON sp.SupplierId = e.SupplierId
    LEFT JOIN dbo.InvSupplier cv ON cv.SupplierId = e.ContractVendorId
    OUTER APPLY (SELECT TOP 1 c.CalibrationId, c.CalibratedOn, c.Result, c.NextDueOn FROM dbo.QcEquipmentCalibration c
                 WHERE c.EquipmentId = e.EquipmentId AND c.IsDeleted = 0 ORDER BY c.CalibratedOn DESC, c.CalibrationId DESC) lc
    OUTER APPLY (SELECT TOP 1 m.MaintenanceId, m.DoneOn, m.NextDueOn FROM dbo.QcEquipmentMaintenance m
                 WHERE m.EquipmentId = e.EquipmentId AND m.IsDeleted = 0 AND m.MaintType IN ('PREVENTIVE', 'SERVICE_VISIT')
                 ORDER BY m.DoneOn DESC, m.MaintenanceId DESC) lp
    WHERE e.CompanyId = @CompanyId AND e.IsDeleted = 0
);
GO

-- due position of a date: OVERDUE | DUE_30 (within 30 days) | OK | NEVER (interval set, nothing recorded) | NA
CREATE OR ALTER FUNCTION dbo.ufn_Qc_DueState (@Due DATE, @FreqDays INT, @Status VARCHAR(20))
RETURNS VARCHAR(10)
AS
BEGIN
    IF @Status = 'RETIRED' RETURN 'NA';
    IF @Due IS NULL RETURN CASE WHEN @FreqDays IS NULL THEN 'NA' ELSE 'NEVER' END;
    IF @Due < CAST(GETDATE() AS DATE) RETURN 'OVERDUE';
    IF @Due <= DATEADD(DAY, 30, CAST(GETDATE() AS DATE)) RETURN 'DUE_30';
    RETURN 'OK';
END;
GO

-- next number of a code series: prefix + 4 digits
CREATE OR ALTER PROCEDURE dbo.usp_Qc_NextCapaNo
    @CompanyId INT, @CapaNo NVARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT = ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(CapaNo, 6, 10) AS INT)) FROM dbo.QcCapa WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @CompanyId), 0) + 1;
    SET @CapaNo = N'CAPA-' + RIGHT('0000' + CAST(@n AS VARCHAR(10)), CASE WHEN @n > 9999 THEN LEN(@n) ELSE 4 END);
END;
GO

-- open a CAPA from an event (calibration failed, EQAS unacceptable, breakdown); returns its id
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Capa_Raise
    @CompanyId INT, @BranchId INT, @SourceType VARCHAR(15), @SourceId INT = NULL, @EquipmentId INT = NULL, @ProgramId INT = NULL,
    @Title NVARCHAR(200), @Problem NVARCHAR(1000) = NULL, @UserId INT = NULL, @CapaId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @No NVARCHAR(20);
    EXEC dbo.usp_Qc_NextCapaNo @CompanyId, @No OUTPUT;
    INSERT INTO dbo.QcCapa (CompanyId, BranchId, CapaNo, SourceType, SourceId, EquipmentId, ProgramId, Title, Problem, TargetDate, CreatedBy)
    VALUES (@CompanyId, @BranchId, @No, @SourceType, @SourceId, @EquipmentId, @ProgramId, @Title, @Problem, DATEADD(DAY, 15, CAST(GETDATE() AS DATE)), @UserId);
    SET @CapaId = SCOPE_IDENTITY();
END;
GO

-- 3. Lookups ----------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_EqLookups
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TypeId AS Id, TypeName AS Name, CalibrationFreqDays, PmFreqDays FROM dbo.QcEquipmentType WHERE IsActive = 1 ORDER BY SortOrder, TypeName;
    SELECT SupplierId AS Id, SupplierName + CASE WHEN IsApproved = 1 THEN N'' ELSE N' (not approved)' END AS Name, IsApproved
    FROM dbo.InvSupplier WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Status = 1 ORDER BY IsApproved DESC, SupplierName;
    SELECT a.Analyzer_ID AS Id, a.Analyzer_Name + CASE WHEN ISNULL(a.Status, 1) = 1 THEN N'' ELSE N' (inactive)' END AS Name, a.Department_ID AS DepartmentId,
           CAST(ISNULL(a.Status, 1) AS BIT) AS Status,   -- the Analyzer master's own status: QC entry offers only active analyzers
           (SELECT TOP 1 e.EquipmentId FROM dbo.QcEquipment e WHERE e.AnalyzerId = a.Analyzer_ID AND e.IsDeleted = 0) AS EquipmentId
    FROM dbo.tbl_mst_analyzer a WHERE ISNULL(a.IsDeleted, 0) = 0 AND (a.CompanyId = @CompanyId OR a.CompanyId IS NULL) ORDER BY a.Analyzer_Name;
    SELECT DeptId AS Id, DeptName AS Name FROM dbo.DepartmentMaster WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%') ORDER BY DeptName;
    SELECT BranchID AS Id, BranchName AS Name FROM dbo.Branchmaster WHERE ISNULL(IsActive, 1) = 1 AND (CompanyId = @CompanyId OR CompanyId IS NULL) ORDER BY BranchName;
    SELECT Id, ISNULL(NULLIF(LTRIM(RTRIM(FullName)), ''), Username) AS Name FROM dbo.Users WHERE ISNULL(IsActive, 0) = 1 ORDER BY 2;
    SELECT m.Test_ID AS Id, m.Test_Name + ISNULL(N' (' + NULLIF(m.Test_Code, '') + N')', N'') AS Name, m.Department_ID AS DepartmentId
    FROM dbo.LabInvestigationMaster m
    WHERE ISNULL(m.IsDeleted, 0) = 0 AND m.Status = 1 AND (m.CompanyId = @CompanyId OR m.CompanyId IS NULL) AND ISNULL(m.Is_Profile_Test, 0) = 0
    ORDER BY m.Test_Name;
END;
GO

-- 4. Equipment ----------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Equipment_List
    @CompanyId INT, @BranchId INT = NULL, @TypeId INT = NULL, @DepartmentId INT = NULL, @Status VARCHAR(20) = NULL,
    @Due VARCHAR(10) = NULL,               -- OVERDUE | DUE_30 (calibration or maintenance)
    @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Status = NULLIF(@Status, ''); SET @Due = NULLIF(@Due, '');
    SELECT s.*, dbo.ufn_Qc_DueState(s.NextCalibrationDue, s.CalibrationFreqDays, s.Status) AS CalibrationState,
           dbo.ufn_Qc_DueState(s.NextPmDue, s.PmFreqDays, s.Status) AS PmState,
           CASE WHEN s.ContractUpto IS NULL OR s.Status = 'RETIRED' THEN 'NA' WHEN s.ContractUpto < CAST(GETDATE() AS DATE) THEN 'EXPIRED'
                WHEN s.ContractUpto <= DATEADD(DAY, 30, CAST(GETDATE() AS DATE)) THEN 'DUE_30' ELSE 'OK' END AS ContractState
    INTO #E
    FROM dbo.ufn_Qc_EquipmentStatus(@CompanyId) s
    WHERE (@BranchId IS NULL OR s.BranchId = @BranchId) AND (@TypeId IS NULL OR s.TypeId = @TypeId)
      AND (@DepartmentId IS NULL OR s.DepartmentId = @DepartmentId) AND (@Status IS NULL OR s.Status = @Status)
      AND (@Search IS NULL OR s.EquipmentName LIKE '%' + @Search + '%' OR s.AssetCode LIKE '%' + @Search + '%' OR s.SerialNo LIKE '%' + @Search + '%'
           OR s.Make LIKE '%' + @Search + '%' OR s.Model LIKE '%' + @Search + '%');
    SELECT * FROM #E
    WHERE @Due IS NULL OR (@Due = 'OVERDUE' AND (CalibrationState IN ('OVERDUE', 'NEVER') OR PmState IN ('OVERDUE', 'NEVER')))
       OR (@Due = 'DUE_30' AND (CalibrationState = 'DUE_30' OR PmState = 'DUE_30'))
    ORDER BY CASE Status WHEN 'OUT_OF_SERVICE' THEN 0 WHEN 'IN_USE' THEN 1 ELSE 2 END, EquipmentName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Equipment_Save
    @EquipmentId INT = NULL, @CompanyId INT, @BranchId INT, @EquipmentName NVARCHAR(200), @TypeId INT, @AnalyzerId INT = NULL,
    @DepartmentId INT = NULL, @Make NVARCHAR(100) = NULL, @Model NVARCHAR(100) = NULL, @SerialNo NVARCHAR(100) = NULL,
    @Location NVARCHAR(150) = NULL, @SupplierId INT = NULL, @InstallDate DATE = NULL, @WarrantyUpto DATE = NULL,
    @ContractType VARCHAR(10) = 'NONE', @ContractVendorId INT = NULL, @ContractFrom DATE = NULL, @ContractUpto DATE = NULL,
    @ContractCost DECIMAL(14,2) = NULL, @PurchaseCost DECIMAL(14,2) = NULL, @CalibrationFreqDays INT = NULL, @PmFreqDays INT = NULL,
    @Remarks NVARCHAR(500) = NULL, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @EquipmentName = NULLIF(LTRIM(RTRIM(@EquipmentName)), ''); SET @SerialNo = NULLIF(LTRIM(RTRIM(@SerialNo)), '');
    SET @ContractType = UPPER(ISNULL(NULLIF(@ContractType, ''), 'NONE'));
    IF @EquipmentName IS NULL THROW 54001, 'Equipment name is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.QcEquipmentType WHERE TypeId = @TypeId AND IsActive = 1) THROW 54002, 'Choose the equipment type.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 54003, 'Choose the branch.', 1;
    IF @AnalyzerId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.tbl_mst_analyzer WHERE Analyzer_ID = @AnalyzerId AND ISNULL(IsDeleted, 0) = 0)
        THROW 54004, 'The analyzer is not valid.', 1;
    IF @AnalyzerId IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.QcEquipment WHERE AnalyzerId = @AnalyzerId AND IsDeleted = 0 AND EquipmentId <> ISNULL(@EquipmentId, 0))
        THROW 54005, 'This analyzer is already registered as another equipment.', 1;
    IF @SerialNo IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.QcEquipment WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND SerialNo = @SerialNo
                                                 AND ISNULL(Make, '') = ISNULL(@Make, '') AND EquipmentId <> ISNULL(@EquipmentId, 0))
        THROW 54006, 'Another equipment of this make already has this serial number.', 1;
    IF @ContractType NOT IN ('NONE', 'AMC', 'CMC') THROW 54007, 'Contract type must be None, AMC or CMC.', 1;
    IF @ContractType <> 'NONE' AND (@ContractVendorId IS NULL OR @ContractUpto IS NULL) THROW 54008, 'An AMC / CMC needs the service vendor and the contract end date.', 1;
    IF @ContractFrom IS NOT NULL AND @ContractUpto IS NOT NULL AND @ContractUpto < @ContractFrom THROW 54009, 'Contract end date is before its start date.', 1;
    IF @InstallDate > CAST(GETDATE() AS DATE) THROW 54010, 'Installation date cannot be in the future.', 1;
    IF @WarrantyUpto IS NOT NULL AND @InstallDate IS NOT NULL AND @WarrantyUpto < @InstallDate THROW 54011, 'Warranty ends before installation.', 1;
    IF (@CalibrationFreqDays IS NOT NULL AND (@CalibrationFreqDays < 1 OR @CalibrationFreqDays > 3650))
       OR (@PmFreqDays IS NOT NULL AND (@PmFreqDays < 1 OR @PmFreqDays > 3650)) THROW 54012, 'Intervals must be 1 to 3650 days.', 1;
    IF @ContractType = 'NONE' SELECT @ContractVendorId = NULL, @ContractFrom = NULL, @ContractUpto = NULL, @ContractCost = NULL;

    IF ISNULL(@EquipmentId, 0) = 0
    BEGIN
        BEGIN TRANSACTION;
            DECLARE @n INT = ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(AssetCode, 3, 10) AS INT)) FROM dbo.QcEquipment WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @CompanyId), 0) + 1;
            INSERT INTO dbo.QcEquipment (CompanyId, BranchId, AssetCode, EquipmentName, TypeId, AnalyzerId, DepartmentId, Make, Model, SerialNo, Location,
                                         SupplierId, InstallDate, WarrantyUpto, ContractType, ContractVendorId, ContractFrom, ContractUpto, ContractCost,
                                         PurchaseCost, CalibrationFreqDays, PmFreqDays, Remarks, CreatedBy)
            VALUES (@CompanyId, @BranchId, N'EQ' + RIGHT('0000' + CAST(@n AS VARCHAR(10)), CASE WHEN @n > 9999 THEN LEN(@n) ELSE 4 END), @EquipmentName,
                    @TypeId, @AnalyzerId, @DepartmentId, NULLIF(LTRIM(RTRIM(@Make)), ''), NULLIF(LTRIM(RTRIM(@Model)), ''), @SerialNo,
                    NULLIF(LTRIM(RTRIM(@Location)), ''), @SupplierId, @InstallDate, @WarrantyUpto, @ContractType, @ContractVendorId, @ContractFrom,
                    @ContractUpto, @ContractCost, @PurchaseCost, @CalibrationFreqDays, @PmFreqDays, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
            SET @NewId = SCOPE_IDENTITY();
        COMMIT TRANSACTION;
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.QcEquipment WHERE EquipmentId = @EquipmentId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 54013, 'Equipment not found.', 1;
        UPDATE dbo.QcEquipment SET BranchId = @BranchId, EquipmentName = @EquipmentName, TypeId = @TypeId, AnalyzerId = @AnalyzerId, DepartmentId = @DepartmentId,
               Make = NULLIF(LTRIM(RTRIM(@Make)), ''), Model = NULLIF(LTRIM(RTRIM(@Model)), ''), SerialNo = @SerialNo, Location = NULLIF(LTRIM(RTRIM(@Location)), ''),
               SupplierId = @SupplierId, InstallDate = @InstallDate, WarrantyUpto = @WarrantyUpto, ContractType = @ContractType, ContractVendorId = @ContractVendorId,
               ContractFrom = @ContractFrom, ContractUpto = @ContractUpto, ContractCost = @ContractCost, PurchaseCost = @PurchaseCost,
               CalibrationFreqDays = @CalibrationFreqDays, PmFreqDays = @PmFreqDays, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''),
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE EquipmentId = @EquipmentId;
        SET @NewId = @EquipmentId;
    END
END;
GO

-- In use / Out of service / Retired by hand (a breakdown or a failed calibration also changes it)
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Equipment_SetStatus
    @EquipmentId INT, @CompanyId INT, @Status VARCHAR(20), @Reason NVARCHAR(300) = NULL, @Delete BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), ''); SET @Status = UPPER(ISNULL(@Status, ''));
    IF NOT EXISTS (SELECT 1 FROM dbo.QcEquipment WHERE EquipmentId = @EquipmentId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 54013, 'Equipment not found.', 1;
    IF @Delete = 1
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.QcEquipmentCalibration WHERE EquipmentId = @EquipmentId AND IsDeleted = 0)
           OR EXISTS (SELECT 1 FROM dbo.QcEquipmentMaintenance WHERE EquipmentId = @EquipmentId AND IsDeleted = 0)
           OR EXISTS (SELECT 1 FROM dbo.QcEquipmentBreakdown WHERE EquipmentId = @EquipmentId)
            THROW 54014, 'This equipment has calibration, maintenance or breakdown records. Retire it instead of deleting.', 1;
        UPDATE dbo.QcEquipment SET IsDeleted = 1, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE EquipmentId = @EquipmentId;
        RETURN;
    END
    IF @Status NOT IN ('IN_USE', 'OUT_OF_SERVICE', 'RETIRED') THROW 54015, 'Choose In use, Out of service or Retired.', 1;
    IF @Status IN ('OUT_OF_SERVICE', 'RETIRED') AND @Reason IS NULL THROW 54016, 'Give the reason.', 1;
    IF @Status = 'IN_USE' AND EXISTS (SELECT 1 FROM dbo.QcEquipmentBreakdown WHERE EquipmentId = @EquipmentId AND Status = 'OPEN')
        THROW 54017, 'A breakdown is still open. Resolve it to return the equipment to use.', 1;
    IF @Status = 'IN_USE' AND (SELECT TOP 1 Result FROM dbo.QcEquipmentCalibration WHERE EquipmentId = @EquipmentId AND IsDeleted = 0
                                ORDER BY CalibratedOn DESC, CalibrationId DESC) = 'FAIL'
        THROW 54018, 'The last calibration failed. Record a passed calibration to return the equipment to use.', 1;
    UPDATE dbo.QcEquipment SET Status = @Status, StatusReason = CASE WHEN @Status = 'IN_USE' THEN NULL ELSE @Reason END, StatusOn = GETDATE(),
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE EquipmentId = @EquipmentId;
END;
GO

-- the equipment card: equipment, calibrations, maintenance, breakdowns, CAPAs
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Equipment_Get
    @EquipmentId INT, @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.*, dbo.ufn_Qc_DueState(s.NextCalibrationDue, s.CalibrationFreqDays, s.Status) AS CalibrationState,
           dbo.ufn_Qc_DueState(s.NextPmDue, s.PmFreqDays, s.Status) AS PmState
    FROM dbo.ufn_Qc_EquipmentStatus(@CompanyId) s WHERE s.EquipmentId = @EquipmentId;

    SELECT c.*, v.SupplierName AS VendorName, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName
    FROM dbo.QcEquipmentCalibration c LEFT JOIN dbo.InvSupplier v ON v.SupplierId = c.VendorId LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
    WHERE c.EquipmentId = @EquipmentId AND c.IsDeleted = 0 ORDER BY c.CalibratedOn DESC, c.CalibrationId DESC;

    SELECT m.*, v.SupplierName AS VendorName, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS CreatedByName
    FROM dbo.QcEquipmentMaintenance m LEFT JOIN dbo.InvSupplier v ON v.SupplierId = m.VendorId LEFT JOIN dbo.Users u ON u.Id = m.CreatedBy
    WHERE m.EquipmentId = @EquipmentId AND m.IsDeleted = 0 ORDER BY m.DoneOn DESC, m.MaintenanceId DESC;

    SELECT b.*, v.SupplierName AS VendorName, c.CapaNo,
           ISNULL(NULLIF(LTRIM(RTRIM(ur.FullName)), ''), ur.Username) AS ReportedByName, ISNULL(NULLIF(LTRIM(RTRIM(uv.FullName)), ''), uv.Username) AS ResolvedByName,
           CAST(DATEDIFF(MINUTE, b.ReportedOn, ISNULL(b.ResolvedOn, GETDATE())) / 60.0 AS DECIMAL(10,1)) AS DowntimeHours
    FROM dbo.QcEquipmentBreakdown b LEFT JOIN dbo.InvSupplier v ON v.SupplierId = b.VendorId LEFT JOIN dbo.QcCapa c ON c.CapaId = b.CapaId
    LEFT JOIN dbo.Users ur ON ur.Id = b.ReportedBy LEFT JOIN dbo.Users uv ON uv.Id = b.ResolvedBy
    WHERE b.EquipmentId = @EquipmentId ORDER BY b.ReportedOn DESC;

    SELECT c.CapaId, c.CapaNo, c.SourceType, c.Title, c.Status, c.TargetDate, c.CreatedDate, c.ClosedOn,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS ResponsibleName
    FROM dbo.QcCapa c LEFT JOIN dbo.Users u ON u.Id = c.ResponsibleUserId
    WHERE c.EquipmentId = @EquipmentId ORDER BY c.CreatedDate DESC;
END;
GO

-- record a calibration; a Fail takes the equipment out of service and opens a CAPA, a Pass after a Fail returns it to use
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Calibration_Add
    @EquipmentId INT, @CompanyId INT, @CalibratedOn DATE, @Agency VARCHAR(10), @AgencyName NVARCHAR(200) = NULL, @VendorId INT = NULL,
    @CertificateNo NVARCHAR(100) = NULL, @Result VARCHAR(10), @NextDueOn DATE = NULL, @Remarks NVARCHAR(500) = NULL,
    @CertificatePath NVARCHAR(400) = NULL, @UserId INT = NULL, @NewId INT = NULL OUTPUT, @CapaId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Agency = UPPER(ISNULL(@Agency, '')); SET @Result = UPPER(ISNULL(@Result, ''));
    DECLARE @Freq INT, @Br INT, @St VARCHAR(20), @Name NVARCHAR(250);
    SELECT @Freq = CalibrationFreqDays, @Br = BranchId, @St = Status, @Name = AssetCode + N' ' + EquipmentName
    FROM dbo.QcEquipment WHERE EquipmentId = @EquipmentId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @Br IS NULL THROW 54013, 'Equipment not found.', 1;
    IF @St = 'RETIRED' THROW 54019, 'The equipment is retired.', 1;
    IF @CalibratedOn IS NULL OR @CalibratedOn > CAST(GETDATE() AS DATE) THROW 54020, 'Calibration date is required and cannot be in the future.', 1;
    IF @Agency NOT IN ('INTERNAL', 'EXTERNAL') THROW 54021, 'Choose internal or external calibration.', 1;
    IF @Agency = 'EXTERNAL' AND @VendorId IS NULL AND NULLIF(LTRIM(RTRIM(@AgencyName)), '') IS NULL THROW 54022, 'Give the calibration agency.', 1;
    IF @Result NOT IN ('PASS', 'ADJUSTED', 'FAIL') THROW 54023, 'Choose the result: Pass, Pass after adjustment or Fail.', 1;
    IF @NextDueOn IS NOT NULL AND @NextDueOn <= @CalibratedOn THROW 54024, 'Next due date must be after the calibration date.', 1;
    IF @NextDueOn IS NULL AND @Result <> 'FAIL' AND @Freq IS NOT NULL SET @NextDueOn = DATEADD(DAY, @Freq, @CalibratedOn);
    IF @Result = 'FAIL' SET @NextDueOn = NULL;   -- a failed instrument is due now

    BEGIN TRANSACTION;
        INSERT INTO dbo.QcEquipmentCalibration (EquipmentId, CalibratedOn, Agency, AgencyName, VendorId, CertificateNo, Result, NextDueOn, Remarks, CertificatePath, CreatedBy)
        VALUES (@EquipmentId, @CalibratedOn, @Agency, NULLIF(LTRIM(RTRIM(@AgencyName)), ''), @VendorId, NULLIF(LTRIM(RTRIM(@CertificateNo)), ''), @Result,
                @NextDueOn, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @CertificatePath, @UserId);
        SET @NewId = SCOPE_IDENTITY();
        IF @Result = 'FAIL'
        BEGIN
            UPDATE dbo.QcEquipment SET Status = 'OUT_OF_SERVICE', StatusReason = N'Calibration failed on ' + CONVERT(NVARCHAR(11), @CalibratedOn, 106), StatusOn = GETDATE()
            WHERE EquipmentId = @EquipmentId;
            DECLARE @Title NVARCHAR(200) = LEFT(N'Calibration failed: ' + @Name, 200);
            EXEC dbo.usp_Qc_Capa_Raise @CompanyId, @Br, 'CALIBRATION', @NewId, @EquipmentId, NULL, @Title, @Remarks, @UserId, @CapaId OUTPUT;
        END
        ELSE IF @St = 'OUT_OF_SERVICE' AND NOT EXISTS (SELECT 1 FROM dbo.QcEquipmentBreakdown WHERE EquipmentId = @EquipmentId AND Status = 'OPEN')
             AND (SELECT StatusReason FROM dbo.QcEquipment WHERE EquipmentId = @EquipmentId) LIKE N'Calibration failed%'
            UPDATE dbo.QcEquipment SET Status = 'IN_USE', StatusReason = NULL, StatusOn = GETDATE() WHERE EquipmentId = @EquipmentId;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Maintenance_Add
    @EquipmentId INT, @CompanyId INT, @MaintType VARCHAR(20), @DoneOn DATE, @DoneByName NVARCHAR(150) = NULL, @VendorId INT = NULL,
    @Checklist NVARCHAR(1000) = NULL, @Findings NVARCHAR(1000) = NULL, @NextDueOn DATE = NULL, @Cost DECIMAL(14,2) = NULL,
    @ReportPath NVARCHAR(400) = NULL, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @MaintType = UPPER(ISNULL(@MaintType, ''));
    DECLARE @Pm INT, @St VARCHAR(20);
    SELECT @Pm = PmFreqDays, @St = Status FROM dbo.QcEquipment WHERE EquipmentId = @EquipmentId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @St IS NULL THROW 54013, 'Equipment not found.', 1;
    IF @St = 'RETIRED' THROW 54019, 'The equipment is retired.', 1;
    IF @MaintType NOT IN ('DAILY', 'WEEKLY', 'MONTHLY', 'QUARTERLY', 'HALF_YEARLY', 'YEARLY', 'PREVENTIVE', 'SERVICE_VISIT') THROW 54025, 'Choose the maintenance type.', 1;
    IF @DoneOn IS NULL OR @DoneOn > CAST(GETDATE() AS DATE) THROW 54026, 'Maintenance date is required and cannot be in the future.', 1;
    IF @Cost < 0 THROW 54027, 'Cost cannot be negative.', 1;
    IF @NextDueOn IS NOT NULL AND @NextDueOn <= @DoneOn THROW 54028, 'Next due date must be after the maintenance date.', 1;
    IF @MaintType IN ('PREVENTIVE', 'SERVICE_VISIT') AND @NextDueOn IS NULL AND @Pm IS NOT NULL SET @NextDueOn = DATEADD(DAY, @Pm, @DoneOn);
    IF @MaintType NOT IN ('PREVENTIVE', 'SERVICE_VISIT') SET @NextDueOn = NULL;
    INSERT INTO dbo.QcEquipmentMaintenance (EquipmentId, MaintType, DoneOn, DoneByName, VendorId, Checklist, Findings, NextDueOn, Cost, ReportPath, CreatedBy)
    VALUES (@EquipmentId, @MaintType, @DoneOn, NULLIF(LTRIM(RTRIM(@DoneByName)), ''), @VendorId, NULLIF(LTRIM(RTRIM(@Checklist)), ''),
            NULLIF(LTRIM(RTRIM(@Findings)), ''), @NextDueOn, @Cost, @ReportPath, @UserId);
    SET @NewId = SCOPE_IDENTITY();
END;
GO

-- report a breakdown: the equipment goes out of service
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Breakdown_Open
    @EquipmentId INT, @CompanyId INT, @ReportedOn DATETIME, @Problem NVARCHAR(1000), @Impact NVARCHAR(500) = NULL,
    @VendorId INT = NULL, @VendorTicketNo NVARCHAR(100) = NULL, @CallLoggedOn DATETIME = NULL, @RaiseCapa BIT = 0,
    @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Problem = NULLIF(LTRIM(RTRIM(@Problem)), '');
    DECLARE @St VARCHAR(20), @Br INT, @Name NVARCHAR(250);
    SELECT @St = Status, @Br = BranchId, @Name = AssetCode + N' ' + EquipmentName FROM dbo.QcEquipment WHERE EquipmentId = @EquipmentId AND CompanyId = @CompanyId AND IsDeleted = 0;
    IF @St IS NULL THROW 54013, 'Equipment not found.', 1;
    IF @St = 'RETIRED' THROW 54019, 'The equipment is retired.', 1;
    IF @Problem IS NULL THROW 54029, 'Describe the problem.', 1;
    IF @ReportedOn IS NULL OR @ReportedOn > DATEADD(MINUTE, 5, GETDATE()) THROW 54030, 'Reported date/time is required and cannot be in the future.', 1;
    IF @CallLoggedOn IS NOT NULL AND @CallLoggedOn < @ReportedOn THROW 54031, 'The call cannot be logged before the breakdown was reported.', 1;
    BEGIN TRANSACTION;
        INSERT INTO dbo.QcEquipmentBreakdown (EquipmentId, ReportedOn, ReportedBy, Problem, Impact, VendorId, VendorTicketNo, CallLoggedOn)
        VALUES (@EquipmentId, @ReportedOn, @UserId, @Problem, NULLIF(LTRIM(RTRIM(@Impact)), ''), @VendorId, NULLIF(LTRIM(RTRIM(@VendorTicketNo)), ''), @CallLoggedOn);
        SET @NewId = SCOPE_IDENTITY();
        UPDATE dbo.QcEquipment SET Status = 'OUT_OF_SERVICE', StatusReason = LEFT(N'Breakdown: ' + @Problem, 300), StatusOn = @ReportedOn WHERE EquipmentId = @EquipmentId;
        IF @RaiseCapa = 1
        BEGIN
            DECLARE @Capa INT, @Title NVARCHAR(200) = LEFT(N'Breakdown: ' + @Name, 200);
            EXEC dbo.usp_Qc_Capa_Raise @CompanyId, @Br, 'BREAKDOWN', @NewId, @EquipmentId, NULL, @Title, @Problem, @UserId, @Capa OUTPUT;
            UPDATE dbo.QcEquipmentBreakdown SET CapaId = @Capa WHERE BreakdownId = @NewId;
        END
    COMMIT TRANSACTION;
END;
GO

-- resolve: needs the resolution and a passed QC run; the equipment returns to use when nothing else keeps it out
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Breakdown_Resolve
    @BreakdownId INT, @CompanyId INT, @ResolvedOn DATETIME, @Resolution NVARCHAR(1000), @PartsReplaced NVARCHAR(500) = NULL,
    @Cost DECIMAL(14,2) = NULL, @QcVerified BIT = 0, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Resolution = NULLIF(LTRIM(RTRIM(@Resolution)), '');
    DECLARE @Eq INT, @Rep DATETIME, @St VARCHAR(10);
    SELECT @Eq = b.EquipmentId, @Rep = b.ReportedOn, @St = b.Status FROM dbo.QcEquipmentBreakdown b
    INNER JOIN dbo.QcEquipment e ON e.EquipmentId = b.EquipmentId AND e.CompanyId = @CompanyId WHERE b.BreakdownId = @BreakdownId;
    IF @Eq IS NULL THROW 54032, 'Breakdown not found.', 1;
    IF @St = 'RESOLVED' THROW 54033, 'This breakdown is already resolved.', 1;
    IF @Resolution IS NULL THROW 54034, 'Describe what was done to resolve it.', 1;
    IF @ResolvedOn IS NULL OR @ResolvedOn < @Rep OR @ResolvedOn > DATEADD(MINUTE, 5, GETDATE()) THROW 54035, 'Resolved date/time must be after the breakdown and not in the future.', 1;
    IF ISNULL(@QcVerified, 0) = 0 THROW 54036, 'Run QC after the repair: the equipment returns to use only after QC passes.', 1;
    IF @Cost < 0 THROW 54027, 'Cost cannot be negative.', 1;
    BEGIN TRANSACTION;
        UPDATE dbo.QcEquipmentBreakdown SET ResolvedOn = @ResolvedOn, ResolvedBy = @UserId, Resolution = @Resolution,
               PartsReplaced = NULLIF(LTRIM(RTRIM(@PartsReplaced)), ''), Cost = @Cost, QcVerified = 1, Status = 'RESOLVED'
        WHERE BreakdownId = @BreakdownId;
        IF NOT EXISTS (SELECT 1 FROM dbo.QcEquipmentBreakdown WHERE EquipmentId = @Eq AND Status = 'OPEN')
           AND ISNULL((SELECT TOP 1 Result FROM dbo.QcEquipmentCalibration WHERE EquipmentId = @Eq AND IsDeleted = 0 ORDER BY CalibratedOn DESC, CalibrationId DESC), '') <> 'FAIL'
            UPDATE dbo.QcEquipment SET Status = 'IN_USE', StatusReason = NULL, StatusOn = @ResolvedOn WHERE EquipmentId = @Eq AND Status = 'OUT_OF_SERVICE';
    COMMIT TRANSACTION;
END;
GO

-- compliance position of a branch (KPI tiles; the Analyzers page)
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Compliance_Summary
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    SELECT s.EquipmentId, s.Status, dbo.ufn_Qc_DueState(s.NextCalibrationDue, s.CalibrationFreqDays, s.Status) AS Cal,
           dbo.ufn_Qc_DueState(s.NextPmDue, s.PmFreqDays, s.Status) AS Pm, s.ContractUpto, s.OpenBreakdowns
    INTO #E FROM dbo.ufn_Qc_EquipmentStatus(@CompanyId) s WHERE @BranchId IS NULL OR s.BranchId = @BranchId;
    SELECT
        (SELECT COUNT(1) FROM #E WHERE Status <> 'RETIRED') AS Equipment,
        (SELECT COUNT(1) FROM #E WHERE Status = 'OUT_OF_SERVICE') AS OutOfService,
        (SELECT COUNT(1) FROM #E WHERE Cal IN ('OVERDUE', 'NEVER')) AS CalibrationOverdue,
        (SELECT COUNT(1) FROM #E WHERE Cal = 'DUE_30') AS CalibrationDue30,
        (SELECT COUNT(1) FROM #E WHERE Pm IN ('OVERDUE', 'NEVER')) AS PmOverdue,
        (SELECT COUNT(1) FROM #E WHERE Pm = 'DUE_30') AS PmDue30,
        (SELECT ISNULL(SUM(OpenBreakdowns), 0) FROM #E) AS OpenBreakdowns,
        (SELECT COUNT(1) FROM #E WHERE Status <> 'RETIRED' AND ContractUpto IS NOT NULL AND ContractUpto <= DATEADD(DAY, 30, @Today)) AS ContractsEnding,
        (SELECT COUNT(1) FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId AND p.IsDeleted = 0
          WHERE c.IsDeleted = 0 AND c.Status = 'RECEIVED' AND (@BranchId IS NULL OR p.BranchId = @BranchId)) AS EqasPending,
        (SELECT COUNT(1) FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId AND p.IsDeleted = 0
          WHERE c.IsDeleted = 0 AND c.Status = 'RECEIVED' AND c.ReportDueOn < @Today AND (@BranchId IS NULL OR p.BranchId = @BranchId)) AS EqasOverdue,
        (SELECT COUNT(1) FROM dbo.QcEqasResult r INNER JOIN dbo.QcEqasCycle c ON c.CycleId = r.CycleId AND c.IsDeleted = 0
          INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId AND p.IsDeleted = 0
          WHERE r.Performance = 'UNACCEPTABLE' AND c.ReceivedOn >= DATEADD(YEAR, -1, @Today) AND (@BranchId IS NULL OR p.BranchId = @BranchId)) AS EqasUnacceptable12m,
        (SELECT COUNT(1) FROM dbo.QcCapa WHERE CompanyId = @CompanyId AND Status <> 'CLOSED' AND (@BranchId IS NULL OR BranchId = @BranchId)) AS OpenCapa,
        (SELECT COUNT(1) FROM dbo.QcCapa WHERE CompanyId = @CompanyId AND Status <> 'CLOSED' AND TargetDate < @Today AND (@BranchId IS NULL OR BranchId = @BranchId)) AS OverdueCapa;
END;
GO

-- the Analyzers page: each analyzer's equipment and its compliance state
CREATE OR ALTER PROCEDURE dbo.usp_Qc_AnalyzerEquipmentStatus
    @CompanyId INT, @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- equipment is branch-wise: IsOwnBranch = 0 means the analyzer is registered (and handled) at another branch
    SELECT s.AnalyzerId, s.EquipmentId, s.AssetCode, s.Status, s.StatusReason, s.NextCalibrationDue, s.NextPmDue, s.OpenBreakdowns,
           s.BranchId, s.BranchName, CAST(CASE WHEN @BranchId IS NULL OR s.BranchId = @BranchId THEN 1 ELSE 0 END AS BIT) AS IsOwnBranch,
           dbo.ufn_Qc_DueState(s.NextCalibrationDue, s.CalibrationFreqDays, s.Status) AS CalibrationState,
           dbo.ufn_Qc_DueState(s.NextPmDue, s.PmFreqDays, s.Status) AS PmState
    FROM dbo.ufn_Qc_EquipmentStatus(@CompanyId) s WHERE s.AnalyzerId IS NOT NULL;
END;
GO

-- 5. EQAS ----------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Eqas_ProgramList
    @CompanyId INT, @BranchId INT = NULL, @Status BIT = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SELECT p.*, b.BranchName, d.DeptName AS DepartmentName,
           (SELECT COUNT(1) FROM dbo.QcEqasProgramTest t WHERE t.ProgramId = p.ProgramId AND t.IsActive = 1) AS Tests,
           (SELECT COUNT(1) FROM dbo.QcEqasCycle c WHERE c.ProgramId = p.ProgramId AND c.IsDeleted = 0) AS Cycles,
           (SELECT COUNT(1) FROM dbo.QcEqasCycle c WHERE c.ProgramId = p.ProgramId AND c.IsDeleted = 0 AND c.Status = 'RECEIVED') AS PendingCycles,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r INNER JOIN dbo.QcEqasCycle c ON c.CycleId = r.CycleId AND c.IsDeleted = 0
             WHERE c.ProgramId = p.ProgramId AND r.Performance IN ('ACCEPTABLE', 'WARNING', 'UNACCEPTABLE')) AS Evaluated,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r INNER JOIN dbo.QcEqasCycle c ON c.CycleId = r.CycleId AND c.IsDeleted = 0
             WHERE c.ProgramId = p.ProgramId AND r.Performance = 'ACCEPTABLE') AS Acceptable,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r INNER JOIN dbo.QcEqasCycle c ON c.CycleId = r.CycleId AND c.IsDeleted = 0
             WHERE c.ProgramId = p.ProgramId AND r.Performance = 'UNACCEPTABLE') AS Unacceptable,
           (SELECT MAX(c.ReceivedOn) FROM dbo.QcEqasCycle c WHERE c.ProgramId = p.ProgramId AND c.IsDeleted = 0) AS LastCycleOn
    FROM dbo.QcEqasProgram p
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = p.BranchId
    LEFT JOIN dbo.DepartmentMaster d ON d.DeptId = p.DepartmentId
    WHERE p.CompanyId = @CompanyId AND p.IsDeleted = 0 AND (@BranchId IS NULL OR p.BranchId = @BranchId) AND (@Status IS NULL OR p.Status = @Status)
      AND (@Search IS NULL OR p.ProgramName LIKE '%' + @Search + '%' OR p.Provider LIKE '%' + @Search + '%' OR p.EnrolmentNo LIKE '%' + @Search + '%')
    ORDER BY p.Status DESC, p.ProgramName;

    SELECT t.ProgramTestId, t.ProgramId, t.TestId, m.Test_Name AS TestName, m.Test_Code AS TestCode, t.ResultType, t.Unit, t.IsActive
    FROM dbo.QcEqasProgramTest t INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = t.ProgramId AND p.CompanyId = @CompanyId AND p.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId
    WHERE t.IsActive = 1 ORDER BY t.ProgramId, m.Test_Name;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Eqas_ProgramSave
    @ProgramId INT = NULL, @CompanyId INT, @BranchId INT, @ProgramName NVARCHAR(200), @Provider NVARCHAR(200), @EnrolmentNo NVARCHAR(100) = NULL,
    @DepartmentId INT = NULL, @CyclesPerYear INT = NULL, @EnrolledFrom DATE = NULL, @EnrolledUpto DATE = NULL, @Fee DECIMAL(14,2) = NULL,
    @AcceptZ DECIMAL(5,2) = 2, @ActionZ DECIMAL(5,2) = 3, @Remarks NVARCHAR(500) = NULL, @Status BIT = 1,
    @TestsJson NVARCHAR(MAX) = NULL,       -- [{ testId, resultType, unit }]
    @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @ProgramName = NULLIF(LTRIM(RTRIM(@ProgramName)), ''); SET @Provider = NULLIF(LTRIM(RTRIM(@Provider)), '');
    IF @ProgramName IS NULL THROW 54040, 'Programme name is required.', 1;
    IF @Provider IS NULL THROW 54041, 'EQAS provider is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 54003, 'Choose the branch.', 1;
    IF @CyclesPerYear IS NOT NULL AND (@CyclesPerYear < 1 OR @CyclesPerYear > 52) THROW 54042, 'Cycles a year must be 1 to 52.', 1;
    IF @EnrolledFrom IS NOT NULL AND @EnrolledUpto IS NOT NULL AND @EnrolledUpto < @EnrolledFrom THROW 54043, 'Enrolment ends before it starts.', 1;
    SET @AcceptZ = ISNULL(@AcceptZ, 2); SET @ActionZ = ISNULL(@ActionZ, 3);
    IF @AcceptZ <= 0 OR @ActionZ < @AcceptZ OR @ActionZ > 10 THROW 54044, 'z-score limits: acceptable above 0 and unacceptable at least the acceptable limit (usually 2 and 3).', 1;
    IF EXISTS (SELECT 1 FROM dbo.QcEqasProgram WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND IsDeleted = 0 AND ProgramName = @ProgramName
                                                AND Provider = @Provider AND ProgramId <> ISNULL(@ProgramId, 0))
        THROW 54045, 'This branch already has this programme with this provider.', 1;

    DECLARE @T TABLE (TestId INT, ResultType VARCHAR(5), Unit NVARCHAR(50));
    INSERT INTO @T SELECT j.testId, UPPER(ISNULL(NULLIF(j.resultType, ''), 'QUANT')), NULLIF(LTRIM(RTRIM(j.unit)), '')
    FROM OPENJSON(ISNULL(@TestsJson, '[]')) WITH (testId INT '$.testId', resultType VARCHAR(5) '$.resultType', unit NVARCHAR(50) '$.unit') j WHERE j.testId IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM @T) THROW 54046, 'Add the tests (analytes) the programme covers.', 1;
    IF EXISTS (SELECT 1 FROM @T WHERE ResultType NOT IN ('QUANT', 'QUAL')) THROW 54047, 'Result type must be quantitative or qualitative.', 1;
    IF EXISTS (SELECT 1 FROM @T GROUP BY TestId HAVING COUNT(1) > 1) THROW 54048, 'A test appears twice in the programme.', 1;
    IF EXISTS (SELECT 1 FROM @T t WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster m WHERE m.Test_ID = t.TestId AND ISNULL(m.IsDeleted, 0) = 0))
        THROW 54049, 'A test of the programme is not in the test master.', 1;

    BEGIN TRANSACTION;
        IF ISNULL(@ProgramId, 0) = 0
        BEGIN
            INSERT INTO dbo.QcEqasProgram (CompanyId, BranchId, ProgramName, Provider, EnrolmentNo, DepartmentId, CyclesPerYear, EnrolledFrom, EnrolledUpto, Fee,
                                           AcceptZ, ActionZ, Remarks, Status, CreatedBy)
            VALUES (@CompanyId, @BranchId, @ProgramName, @Provider, NULLIF(LTRIM(RTRIM(@EnrolmentNo)), ''), @DepartmentId, @CyclesPerYear, @EnrolledFrom,
                    @EnrolledUpto, @Fee, @AcceptZ, @ActionZ, NULLIF(LTRIM(RTRIM(@Remarks)), ''), ISNULL(@Status, 1), @UserId);
            SET @ProgramId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.QcEqasProgram WHERE ProgramId = @ProgramId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 54050, 'Programme not found.', 1;
            UPDATE dbo.QcEqasProgram SET BranchId = @BranchId, ProgramName = @ProgramName, Provider = @Provider, EnrolmentNo = NULLIF(LTRIM(RTRIM(@EnrolmentNo)), ''),
                   DepartmentId = @DepartmentId, CyclesPerYear = @CyclesPerYear, EnrolledFrom = @EnrolledFrom, EnrolledUpto = @EnrolledUpto, Fee = @Fee,
                   AcceptZ = @AcceptZ, ActionZ = @ActionZ, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), ''), Status = ISNULL(@Status, 1),
                   ModifiedBy = @UserId, ModifiedDate = GETDATE()
            WHERE ProgramId = @ProgramId;
        END
        -- tests: kept rows stay (their results keep pointing at them), removed rows are switched off, new rows added
        UPDATE pt SET IsActive = CASE WHEN t.TestId IS NULL THEN 0 ELSE 1 END, ResultType = ISNULL(t.ResultType, pt.ResultType), Unit = CASE WHEN t.TestId IS NULL THEN pt.Unit ELSE t.Unit END
        FROM dbo.QcEqasProgramTest pt LEFT JOIN @T t ON t.TestId = pt.TestId WHERE pt.ProgramId = @ProgramId;
        INSERT INTO dbo.QcEqasProgramTest (ProgramId, TestId, ResultType, Unit)
        SELECT @ProgramId, t.TestId, t.ResultType, t.Unit FROM @T t WHERE NOT EXISTS (SELECT 1 FROM dbo.QcEqasProgramTest pt WHERE pt.ProgramId = @ProgramId AND pt.TestId = t.TestId);
        SET @NewId = @ProgramId;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Eqas_CycleList
    @ProgramId INT, @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.*,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r WHERE r.CycleId = c.CycleId AND NULLIF(r.OurValue, '') IS NOT NULL) AS Entered,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r WHERE r.CycleId = c.CycleId AND r.Performance = 'ACCEPTABLE') AS Acceptable,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r WHERE r.CycleId = c.CycleId AND r.Performance = 'WARNING') AS Warning,
           (SELECT COUNT(1) FROM dbo.QcEqasResult r WHERE r.CycleId = c.CycleId AND r.Performance = 'UNACCEPTABLE') AS Unacceptable
    FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId
    WHERE c.ProgramId = @ProgramId AND c.IsDeleted = 0 ORDER BY c.ReceivedOn DESC, c.CycleId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Eqas_CycleSave
    @CycleId INT = NULL, @ProgramId INT, @CompanyId INT, @CycleName NVARCHAR(100), @SampleCode NVARCHAR(100) = NULL, @ReceivedOn DATE,
    @ReportDueOn DATE = NULL, @Remarks NVARCHAR(500) = NULL, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @CycleName = NULLIF(LTRIM(RTRIM(@CycleName)), '');
    IF NOT EXISTS (SELECT 1 FROM dbo.QcEqasProgram WHERE ProgramId = @ProgramId AND CompanyId = @CompanyId AND IsDeleted = 0) THROW 54050, 'Programme not found.', 1;
    IF @CycleName IS NULL THROW 54051, 'Cycle name is required (for example 2026 / Cycle 3).', 1;
    IF @ReceivedOn IS NULL OR @ReceivedOn > CAST(GETDATE() AS DATE) THROW 54052, 'Sample received date is required and cannot be in the future.', 1;
    IF @ReportDueOn IS NOT NULL AND @ReportDueOn < @ReceivedOn THROW 54053, 'Result due date is before the sample was received.', 1;
    IF EXISTS (SELECT 1 FROM dbo.QcEqasCycle WHERE ProgramId = @ProgramId AND IsDeleted = 0 AND CycleName = @CycleName AND CycleId <> ISNULL(@CycleId, 0))
        THROW 54054, 'This programme already has a cycle with this name.', 1;
    IF ISNULL(@CycleId, 0) = 0
    BEGIN
        INSERT INTO dbo.QcEqasCycle (ProgramId, CycleName, SampleCode, ReceivedOn, ReportDueOn, Remarks, CreatedBy)
        VALUES (@ProgramId, @CycleName, NULLIF(LTRIM(RTRIM(@SampleCode)), ''), @ReceivedOn, @ReportDueOn, NULLIF(LTRIM(RTRIM(@Remarks)), ''), @UserId);
        SET @NewId = SCOPE_IDENTITY();
        -- one result line per active test of the programme
        INSERT INTO dbo.QcEqasResult (CycleId, ProgramTestId) SELECT @NewId, ProgramTestId FROM dbo.QcEqasProgramTest WHERE ProgramId = @ProgramId AND IsActive = 1;
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.QcEqasCycle WHERE CycleId = @CycleId AND ProgramId = @ProgramId AND IsDeleted = 0) THROW 54055, 'Cycle not found.', 1;
        UPDATE dbo.QcEqasCycle SET CycleName = @CycleName, SampleCode = NULLIF(LTRIM(RTRIM(@SampleCode)), ''), ReceivedOn = @ReceivedOn,
               ReportDueOn = @ReportDueOn, Remarks = NULLIF(LTRIM(RTRIM(@Remarks)), '')
        WHERE CycleId = @CycleId;
        SET @NewId = @CycleId;
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Eqas_ResultGet
    @CycleId INT, @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.*, p.ProgramName, p.Provider, p.AcceptZ, p.ActionZ
    FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId WHERE c.CycleId = @CycleId AND c.IsDeleted = 0;
    -- tests added to the programme after the cycle was created get their line now
    INSERT INTO dbo.QcEqasResult (CycleId, ProgramTestId)
    SELECT c.CycleId, t.ProgramTestId FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgramTest t ON t.ProgramId = c.ProgramId AND t.IsActive = 1
    WHERE c.CycleId = @CycleId AND c.Status <> 'EVALUATED' AND NOT EXISTS (SELECT 1 FROM dbo.QcEqasResult r WHERE r.CycleId = c.CycleId AND r.ProgramTestId = t.ProgramTestId);
    SELECT r.*, t.TestId, m.Test_Name AS TestName, m.Test_Code AS TestCode, t.ResultType, t.Unit, cp.CapaNo
    FROM dbo.QcEqasResult r INNER JOIN dbo.QcEqasProgramTest t ON t.ProgramTestId = r.ProgramTestId
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId LEFT JOIN dbo.QcCapa cp ON cp.CapaId = r.CapaId
    WHERE r.CycleId = @CycleId ORDER BY m.Test_Name;
END;
GO

-- save the results of a cycle. Stage SUBMIT = our values sent to the provider; EVALUATE = the provider's targets / SDI:
-- z = (our - target) / SD unless the report gives it; |z| <= AcceptZ acceptable, <= ActionZ warning, above unacceptable;
-- qualitative: our answer = expected answer. An unacceptable result opens a CAPA (once).
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Eqas_ResultSave
    @CycleId INT, @CompanyId INT, @Stage VARCHAR(10), @SubmittedOn DATE = NULL, @EvaluatedOn DATE = NULL, @ReportPath NVARCHAR(400) = NULL,
    @ResultsJson NVARCHAR(MAX), @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Stage = UPPER(ISNULL(@Stage, ''));
    DECLARE @Prog INT, @Br INT, @AZ DECIMAL(5,2), @XZ DECIMAL(5,2), @St VARCHAR(10), @Rec DATE, @PName NVARCHAR(200), @CName NVARCHAR(100);
    SELECT @Prog = p.ProgramId, @Br = p.BranchId, @AZ = p.AcceptZ, @XZ = p.ActionZ, @St = c.Status, @Rec = c.ReceivedOn, @PName = p.ProgramName, @CName = c.CycleName
    FROM dbo.QcEqasCycle c INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId
    WHERE c.CycleId = @CycleId AND c.IsDeleted = 0;
    IF @Prog IS NULL THROW 54055, 'Cycle not found.', 1;
    IF @Stage NOT IN ('SUBMIT', 'EVALUATE') THROW 54056, 'Choose submit or evaluate.', 1;

    DECLARE @R TABLE (ResultId INT, OurValue NVARCHAR(100), TargetValue DECIMAL(18,4), Sd DECIMAL(18,4), ReportedZ DECIMAL(8,2), ExpectedValue NVARCHAR(100), Remarks NVARCHAR(300));
    INSERT INTO @R
    SELECT j.resultId, NULLIF(LTRIM(RTRIM(j.ourValue)), ''), j.targetValue, j.sd, j.reportedZ, NULLIF(LTRIM(RTRIM(j.expectedValue)), ''), NULLIF(LTRIM(RTRIM(j.remarks)), '')
    FROM OPENJSON(ISNULL(@ResultsJson, '[]')) WITH (resultId INT '$.resultId', ourValue NVARCHAR(100) '$.ourValue', targetValue DECIMAL(18,4) '$.targetValue',
         sd DECIMAL(18,4) '$.sd', reportedZ DECIMAL(8,2) '$.reportedZ', expectedValue NVARCHAR(100) '$.expectedValue', remarks NVARCHAR(300) '$.remarks') j;
    IF EXISTS (SELECT 1 FROM @R r WHERE NOT EXISTS (SELECT 1 FROM dbo.QcEqasResult x WHERE x.ResultId = r.ResultId AND x.CycleId = @CycleId))
        THROW 54057, 'A result line does not belong to this cycle.', 1;

    IF @Stage = 'SUBMIT'
    BEGIN
        IF @St = 'EVALUATED' THROW 54058, 'This cycle is already evaluated; its results are final.', 1;
        IF NOT EXISTS (SELECT 1 FROM @R WHERE OurValue IS NOT NULL) THROW 54059, 'Enter at least one result.', 1;
        SET @SubmittedOn = ISNULL(@SubmittedOn, CAST(GETDATE() AS DATE));
        IF @SubmittedOn < @Rec OR @SubmittedOn > CAST(GETDATE() AS DATE) THROW 54060, 'Submitted date must be between the sample receipt and today.', 1;
        BEGIN TRANSACTION;
            UPDATE x SET OurValue = r.OurValue, Remarks = r.Remarks FROM dbo.QcEqasResult x INNER JOIN @R r ON r.ResultId = x.ResultId;
            UPDATE dbo.QcEqasCycle SET Status = 'SUBMITTED', SubmittedOn = @SubmittedOn WHERE CycleId = @CycleId;
        COMMIT TRANSACTION;
        RETURN;
    END

    -- EVALUATE
    IF @St = 'RECEIVED' THROW 54061, 'Submit our results first; then enter the provider''s evaluation.', 1;
    SET @EvaluatedOn = ISNULL(@EvaluatedOn, CAST(GETDATE() AS DATE));
    IF @EvaluatedOn < @Rec OR @EvaluatedOn > CAST(GETDATE() AS DATE) THROW 54062, 'Evaluation date must be between the sample receipt and today.', 1;
    IF EXISTS (SELECT 1 FROM @R WHERE Sd IS NOT NULL AND Sd <= 0) THROW 54063, 'SD must be more than 0.', 1;
    BEGIN TRANSACTION;
        UPDATE x SET TargetValue = r.TargetValue, Sd = r.Sd, ReportedZ = r.ReportedZ, ExpectedValue = r.ExpectedValue,
               Remarks = ISNULL(r.Remarks, x.Remarks), OurValue = ISNULL(x.OurValue, r.OurValue)
        FROM dbo.QcEqasResult x INNER JOIN @R r ON r.ResultId = x.ResultId;
        UPDATE x SET ZScore = z.Z,
               Performance = CASE
                   WHEN t.ResultType = 'QUAL' THEN CASE WHEN x.OurValue IS NULL OR x.ExpectedValue IS NULL THEN 'NOT_EVALUATED'
                                                        WHEN UPPER(LTRIM(RTRIM(x.OurValue))) = UPPER(LTRIM(RTRIM(x.ExpectedValue))) THEN 'ACCEPTABLE' ELSE 'UNACCEPTABLE' END
                   WHEN z.Z IS NULL THEN 'NOT_EVALUATED'
                   WHEN ABS(z.Z) <= @AZ THEN 'ACCEPTABLE' WHEN ABS(z.Z) <= @XZ THEN 'WARNING' ELSE 'UNACCEPTABLE' END
        FROM dbo.QcEqasResult x
        INNER JOIN dbo.QcEqasProgramTest t ON t.ProgramTestId = x.ProgramTestId
        CROSS APPLY (SELECT CAST(CASE WHEN t.ResultType = 'QUAL' THEN NULL
                                      WHEN x.ReportedZ IS NOT NULL THEN x.ReportedZ
                                      WHEN x.TargetValue IS NOT NULL AND x.Sd > 0 AND TRY_CAST(x.OurValue AS DECIMAL(18,4)) IS NOT NULL
                                           THEN ROUND((TRY_CAST(x.OurValue AS DECIMAL(18,4)) - x.TargetValue) / x.Sd, 2) END AS DECIMAL(8,2)) AS Z) z
        WHERE x.CycleId = @CycleId;
        UPDATE dbo.QcEqasCycle SET Status = 'EVALUATED', EvaluatedOn = @EvaluatedOn, ReportPath = ISNULL(@ReportPath, ReportPath) WHERE CycleId = @CycleId;

        -- one CAPA per unacceptable result
        DECLARE @Rid INT, @Test NVARCHAR(200), @Z DECIMAL(8,2), @Capa INT, @Title NVARCHAR(200), @Prob NVARCHAR(1000);
        DECLARE cr CURSOR LOCAL FAST_FORWARD FOR
            SELECT x.ResultId, m.Test_Name, x.ZScore FROM dbo.QcEqasResult x INNER JOIN dbo.QcEqasProgramTest t ON t.ProgramTestId = x.ProgramTestId
            INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId
            WHERE x.CycleId = @CycleId AND x.Performance = 'UNACCEPTABLE' AND x.CapaId IS NULL;
        OPEN cr; FETCH NEXT FROM cr INTO @Rid, @Test, @Z;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Title = LEFT(N'EQAS unacceptable: ' + @Test + N' (' + @CName + N')', 200);
            SET @Prob = LEFT(N'Programme ' + @PName + N', cycle ' + @CName + ISNULL(N', z = ' + CAST(@Z AS NVARCHAR(20)), N', result not as expected'), 1000);
            EXEC dbo.usp_Qc_Capa_Raise @CompanyId, @Br, 'EQAS', @Rid, NULL, @Prog, @Title, @Prob, @UserId, @Capa OUTPUT;
            UPDATE dbo.QcEqasResult SET CapaId = @Capa WHERE ResultId = @Rid;
            FETCH NEXT FROM cr INTO @Rid, @Test, @Z;
        END
        CLOSE cr; DEALLOCATE cr;
    COMMIT TRANSACTION;
END;
GO

-- 6. CAPA ----------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Qc_Capa_List
    @CompanyId INT, @BranchId INT = NULL, @Status VARCHAR(15) = NULL, @SourceType VARCHAR(15) = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Status = NULLIF(@Status, ''); SET @SourceType = NULLIF(@SourceType, '');
    SELECT c.*, b.BranchName, e.AssetCode, e.EquipmentName, p.ProgramName,
           ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), u.Username) AS ResponsibleName,
           ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), ''), cu.Username) AS CreatedByName,
           CAST(CASE WHEN c.Status <> 'CLOSED' AND c.TargetDate < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS BIT) AS IsOverdue
    FROM dbo.QcCapa c
    LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
    LEFT JOIN dbo.QcEquipment e ON e.EquipmentId = c.EquipmentId
    LEFT JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId
    LEFT JOIN dbo.Users u ON u.Id = c.ResponsibleUserId
    LEFT JOIN dbo.Users cu ON cu.Id = c.CreatedBy
    WHERE c.CompanyId = @CompanyId AND (@BranchId IS NULL OR c.BranchId = @BranchId)
      AND (@Status IS NULL OR (@Status = 'PENDING' AND c.Status <> 'CLOSED') OR c.Status = @Status) AND (@SourceType IS NULL OR c.SourceType = @SourceType)
      AND (@Search IS NULL OR c.CapaNo LIKE '%' + @Search + '%' OR c.Title LIKE '%' + @Search + '%' OR e.EquipmentName LIKE '%' + @Search + '%')
    ORDER BY CASE c.Status WHEN 'OPEN' THEN 0 WHEN 'ACTION_TAKEN' THEN 1 ELSE 2 END, c.TargetDate, c.CapaId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Qc_Capa_Save
    @CapaId INT = NULL, @CompanyId INT, @BranchId INT, @Title NVARCHAR(200), @Problem NVARCHAR(1000) = NULL, @RootCause NVARCHAR(1000) = NULL,
    @CorrectiveAction NVARCHAR(1000) = NULL, @PreventiveAction NVARCHAR(1000) = NULL, @ResponsibleUserId INT = NULL, @TargetDate DATE = NULL,
    @Status VARCHAR(15) = 'OPEN', @Effectiveness NVARCHAR(1000) = NULL, @EquipmentId INT = NULL, @UserId INT = NULL, @NewId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Title = NULLIF(LTRIM(RTRIM(@Title)), ''); SET @Status = UPPER(ISNULL(NULLIF(@Status, ''), 'OPEN'));
    SET @RootCause = NULLIF(LTRIM(RTRIM(@RootCause)), ''); SET @CorrectiveAction = NULLIF(LTRIM(RTRIM(@CorrectiveAction)), '');
    SET @Effectiveness = NULLIF(LTRIM(RTRIM(@Effectiveness)), '');
    IF @Title IS NULL THROW 54070, 'Title is required.', 1;
    IF @Status NOT IN ('OPEN', 'ACTION_TAKEN', 'CLOSED') THROW 54071, 'Choose the status.', 1;
    IF @Status IN ('ACTION_TAKEN', 'CLOSED') AND (@RootCause IS NULL OR @CorrectiveAction IS NULL) THROW 54072, 'Record the root cause and the corrective action first.', 1;
    IF @Status = 'CLOSED' AND @Effectiveness IS NULL THROW 54073, 'Record how the effectiveness of the action was checked before closing.', 1;
    IF @ResponsibleUserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @ResponsibleUserId) THROW 54074, 'Responsible user not found.', 1;
    DECLARE @Old VARCHAR(15);
    IF ISNULL(@CapaId, 0) = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId) THROW 54003, 'Choose the branch.', 1;
        BEGIN TRANSACTION;
            EXEC dbo.usp_Qc_Capa_Raise @CompanyId, @BranchId, 'OTHER', NULL, @EquipmentId, NULL, @Title, @Problem, @UserId, @NewId OUTPUT;
            UPDATE dbo.QcCapa SET RootCause = @RootCause, CorrectiveAction = @CorrectiveAction, PreventiveAction = NULLIF(LTRIM(RTRIM(@PreventiveAction)), ''),
                   ResponsibleUserId = @ResponsibleUserId, TargetDate = ISNULL(@TargetDate, TargetDate), Status = @Status, Effectiveness = @Effectiveness,
                   ClosedOn = CASE WHEN @Status = 'CLOSED' THEN GETDATE() END, ClosedBy = CASE WHEN @Status = 'CLOSED' THEN @UserId END
            WHERE CapaId = @NewId;
        COMMIT TRANSACTION;
        RETURN;
    END
    SELECT @Old = Status FROM dbo.QcCapa WHERE CapaId = @CapaId AND CompanyId = @CompanyId;
    IF @Old IS NULL THROW 54075, 'CAPA not found.', 1;
    IF @Old = 'CLOSED' THROW 54076, 'This CAPA is closed.', 1;
    UPDATE dbo.QcCapa SET Title = @Title, Problem = NULLIF(LTRIM(RTRIM(@Problem)), ''), RootCause = @RootCause, CorrectiveAction = @CorrectiveAction,
           PreventiveAction = NULLIF(LTRIM(RTRIM(@PreventiveAction)), ''), ResponsibleUserId = @ResponsibleUserId, TargetDate = @TargetDate, Status = @Status,
           Effectiveness = @Effectiveness, ClosedOn = CASE WHEN @Status = 'CLOSED' THEN GETDATE() END, ClosedBy = CASE WHEN @Status = 'CLOSED' THEN @UserId END,
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE CapaId = @CapaId;
    SET @NewId = @CapaId;
END;
GO

-- 7. Reports (Reports > LAB, shape of SQLScripts/2124) -------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_EquipmentDue
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @DueState VARCHAR(20) = NULL,         -- OVERDUE | DUE_30 | OUT_OF_SERVICE | CONTRACT
    @TypeId INT = NULL, @DepartmentId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @DueState = NULLIF(UPPER(LTRIM(RTRIM(@DueState))), '');
    SELECT s.EquipmentId, s.AssetCode, s.EquipmentName, s.TypeId, s.TypeName, s.AnalyzerName, ISNULL(s.DepartmentId, 0) AS DepartmentId,
           ISNULL(s.DepartmentName, N'Not set') AS DepartmentName, s.Make, s.Model, s.SerialNo, s.Location, s.Status, s.StatusReason,
           s.InstallDate, s.WarrantyUpto, s.ContractType, s.ContractVendorName, s.ContractUpto, s.LastCalibratedOn, s.LastCalibrationResult,
           s.NextCalibrationDue, s.LastPmOn, s.NextPmDue, s.OpenBreakdowns, s.OpenCapas,
           dbo.ufn_Qc_DueState(s.NextCalibrationDue, s.CalibrationFreqDays, s.Status) AS CalibrationState,
           dbo.ufn_Qc_DueState(s.NextPmDue, s.PmFreqDays, s.Status) AS PmState,
           CASE WHEN s.ContractUpto IS NULL OR s.Status = 'RETIRED' THEN 'NA' WHEN s.ContractUpto < CAST(GETDATE() AS DATE) THEN 'EXPIRED'
                WHEN s.ContractUpto <= DATEADD(DAY, 30, CAST(GETDATE() AS DATE)) THEN 'DUE_30' ELSE 'OK' END AS ContractState
    INTO #R
    FROM dbo.ufn_Qc_EquipmentStatus(@CompanyId) s
    WHERE s.BranchId = @BranchId AND (@TypeId IS NULL OR s.TypeId = @TypeId) AND (@DepartmentId IS NULL OR s.DepartmentId = @DepartmentId)
      AND (@Search IS NULL OR s.EquipmentName LIKE '%' + @Search + '%' OR s.AssetCode LIKE '%' + @Search + '%' OR s.SerialNo LIKE '%' + @Search + '%');
    ALTER TABLE #R ADD Overall VARCHAR(20), OverallLabel NVARCHAR(40), OverallOrder INT;
    UPDATE #R SET Overall = CASE WHEN Status = 'RETIRED' THEN 'RETIRED' WHEN Status = 'OUT_OF_SERVICE' THEN 'OUT_OF_SERVICE'
                                 WHEN CalibrationState IN ('OVERDUE', 'NEVER') OR PmState IN ('OVERDUE', 'NEVER') THEN 'OVERDUE'
                                 WHEN CalibrationState = 'DUE_30' OR PmState = 'DUE_30' OR ContractState IN ('DUE_30', 'EXPIRED') THEN 'DUE_30' ELSE 'OK' END;
    UPDATE #R SET OverallLabel = CASE Overall WHEN 'OUT_OF_SERVICE' THEN N'Out of service' WHEN 'OVERDUE' THEN N'Overdue' WHEN 'DUE_30' THEN N'Due in 30 days'
                                              WHEN 'RETIRED' THEN N'Retired' ELSE N'Up to date' END,
                  OverallOrder = CASE Overall WHEN 'OUT_OF_SERVICE' THEN 1 WHEN 'OVERDUE' THEN 2 WHEN 'DUE_30' THEN 3 WHEN 'OK' THEN 4 ELSE 5 END;

    SELECT COUNT(CASE WHEN Status <> 'RETIRED' THEN 1 END) AS Equipment, SUM(CASE WHEN Status = 'OUT_OF_SERVICE' THEN 1 ELSE 0 END) AS OutOfService,
           SUM(CASE WHEN CalibrationState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END) AS CalibrationOverdue, SUM(CASE WHEN CalibrationState = 'DUE_30' THEN 1 ELSE 0 END) AS CalibrationDue30,
           SUM(CASE WHEN PmState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END) AS PmOverdue, SUM(CASE WHEN PmState = 'DUE_30' THEN 1 ELSE 0 END) AS PmDue30,
           SUM(CASE WHEN ContractState IN ('DUE_30', 'EXPIRED') THEN 1 ELSE 0 END) AS ContractsEnding, SUM(OpenBreakdowns) AS OpenBreakdowns
    FROM #R;

    SELECT 'byState' AS GroupKey, NULL AS GroupId, OverallLabel AS GroupName, MIN(OverallOrder) AS SortOrder, COUNT(1) AS Items,
           SUM(CASE WHEN CalibrationState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END) AS CalOverdue, SUM(CASE WHEN PmState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END) AS PmOverdue
    FROM #R GROUP BY OverallLabel
    UNION ALL
    SELECT 'byType', TypeId, TypeName, 1, COUNT(1), SUM(CASE WHEN CalibrationState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END), SUM(CASE WHEN PmState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END)
    FROM #R GROUP BY TypeId, TypeName
    UNION ALL
    SELECT 'byDept', DepartmentId, DepartmentName, 1, COUNT(1), SUM(CASE WHEN CalibrationState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END), SUM(CASE WHEN PmState IN ('OVERDUE', 'NEVER') THEN 1 ELSE 0 END)
    FROM #R GROUP BY DepartmentId, DepartmentName
    ORDER BY GroupKey, SortOrder, GroupName;

    SELECT * FROM #R
    WHERE @DueState IS NULL OR (@DueState = 'OVERDUE' AND Overall = 'OVERDUE') OR (@DueState = 'DUE_30' AND Overall = 'DUE_30')
       OR (@DueState = 'OUT_OF_SERVICE' AND Status = 'OUT_OF_SERVICE') OR (@DueState = 'CONTRACT' AND ContractState IN ('DUE_30', 'EXPIRED'))
    ORDER BY OverallOrder, EquipmentName;

    SELECT 'typeId' AS FilterKey, CAST(TypeId AS VARCHAR(20)) AS Value, TypeName AS Text FROM dbo.QcEquipmentType WHERE IsActive = 1
    UNION ALL
    SELECT 'departmentId', CAST(DeptId AS VARCHAR(20)), DeptName FROM dbo.DepartmentMaster WHERE IsActive = 1 AND (UPPER(DeptType) = 'LAB' OR DeptType LIKE '%Lab%')
    ORDER BY FilterKey, Text;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_EquipmentDowntime
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @BreakdownStatus VARCHAR(20) = NULL,  -- OPEN | RESOLVED
    @TypeId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @BreakdownStatus = NULLIF(UPPER(LTRIM(RTRIM(@BreakdownStatus))), '');
    SELECT b.BreakdownId, b.ReportedOn, CONVERT(VARCHAR(10), CAST(b.ReportedOn AS DATE), 23) AS ReportedDay, b.Problem, b.Impact, b.VendorTicketNo,
           b.CallLoggedOn, b.ResolvedOn, b.Resolution, b.PartsReplaced, ISNULL(b.Cost, 0) AS Cost, b.Status,
           CASE b.Status WHEN 'OPEN' THEN N'Open' ELSE N'Resolved' END AS StatusLabel,
           CAST(DATEDIFF(MINUTE, b.ReportedOn, ISNULL(b.ResolvedOn, GETDATE())) / 60.0 AS DECIMAL(10,1)) AS DowntimeHours,
           CAST(CASE WHEN b.CallLoggedOn IS NULL THEN NULL ELSE DATEDIFF(MINUTE, b.ReportedOn, b.CallLoggedOn) / 60.0 END AS DECIMAL(10,1)) AS ResponseHours,
           e.EquipmentId, e.AssetCode, e.EquipmentName, t.TypeId, t.TypeName, v.SupplierName AS VendorName, c.CapaNo,
           ISNULL(NULLIF(LTRIM(RTRIM(ur.FullName)), ''), ur.Username) AS ReportedByName
    INTO #R
    FROM dbo.QcEquipmentBreakdown b
    INNER JOIN dbo.QcEquipment e ON e.EquipmentId = b.EquipmentId AND e.CompanyId = @CompanyId AND e.BranchId = @BranchId
    INNER JOIN dbo.QcEquipmentType t ON t.TypeId = e.TypeId
    LEFT JOIN dbo.InvSupplier v ON v.SupplierId = b.VendorId
    LEFT JOIN dbo.QcCapa c ON c.CapaId = b.CapaId
    LEFT JOIN dbo.Users ur ON ur.Id = b.ReportedBy
    WHERE b.ReportedOn >= @From AND b.ReportedOn < @To
      AND (@BreakdownStatus IS NULL OR b.Status = @BreakdownStatus) AND (@TypeId IS NULL OR e.TypeId = @TypeId)
      AND (@Search IS NULL OR e.EquipmentName LIKE '%' + @Search + '%' OR e.AssetCode LIKE '%' + @Search + '%' OR b.Problem LIKE '%' + @Search + '%');

    SELECT COUNT(1) AS Breakdowns, SUM(CASE WHEN Status = 'OPEN' THEN 1 ELSE 0 END) AS OpenNow, CAST(ISNULL(SUM(DowntimeHours), 0) AS DECIMAL(12,1)) AS DowntimeHours,
           CAST(AVG(CASE WHEN Status = 'RESOLVED' THEN DowntimeHours END) AS DECIMAL(10,1)) AS AvgRepairHours, CAST(ISNULL(SUM(Cost), 0) AS DECIMAL(14,2)) AS RepairCost,
           COUNT(DISTINCT EquipmentId) AS EquipmentAffected
    FROM #R;
    SELECT 'byEquipment' AS GroupKey, EquipmentId AS GroupId, AssetCode + N' ' + EquipmentName AS GroupName, COUNT(1) AS Breakdowns,
           CAST(SUM(DowntimeHours) AS DECIMAL(12,1)) AS DowntimeHours, CAST(SUM(Cost) AS DECIMAL(14,2)) AS Cost
    FROM #R GROUP BY EquipmentId, AssetCode, EquipmentName
    UNION ALL
    SELECT 'byType', TypeId, TypeName, COUNT(1), CAST(SUM(DowntimeHours) AS DECIMAL(12,1)), CAST(SUM(Cost) AS DECIMAL(14,2)) FROM #R GROUP BY TypeId, TypeName
    UNION ALL
    SELECT 'byStatus', NULL, StatusLabel, COUNT(1), CAST(SUM(DowntimeHours) AS DECIMAL(12,1)), CAST(SUM(Cost) AS DECIMAL(14,2)) FROM #R GROUP BY StatusLabel
    UNION ALL
    SELECT 'byDate', NULL, ReportedDay, COUNT(1), CAST(SUM(DowntimeHours) AS DECIMAL(12,1)), CAST(SUM(Cost) AS DECIMAL(14,2)) FROM #R GROUP BY ReportedDay
    ORDER BY GroupKey, GroupName;
    SELECT * FROM #R ORDER BY ReportedOn DESC;
    SELECT 'typeId' AS FilterKey, CAST(TypeId AS VARCHAR(20)) AS Value, TypeName AS Text FROM dbo.QcEquipmentType WHERE IsActive = 1 ORDER BY Text;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_EqasPerformance
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @Performance VARCHAR(20) = NULL,      -- ACCEPTABLE | WARNING | UNACCEPTABLE | NOT_EVALUATED
    @ProgramId INT = NULL,
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @Performance = NULLIF(UPPER(LTRIM(RTRIM(@Performance))), '');
    SELECT r.ResultId, c.CycleId, c.CycleName, c.SampleCode, c.ReceivedOn, c.ReportDueOn, c.SubmittedOn, c.EvaluatedOn, c.Status AS CycleStatus,
           p.ProgramId, p.ProgramName, p.Provider, t.TestId, m.Test_Name AS TestName, m.Test_Code AS TestCode, t.ResultType, t.Unit,
           r.OurValue, r.TargetValue, r.Sd, r.ExpectedValue, r.ZScore, r.Performance,
           CASE r.Performance WHEN 'ACCEPTABLE' THEN N'Acceptable' WHEN 'WARNING' THEN N'Warning' WHEN 'UNACCEPTABLE' THEN N'Unacceptable' ELSE N'Not evaluated' END AS PerformanceLabel,
           cp.CapaNo, cp.Status AS CapaStatus,
           CAST(CASE WHEN c.SubmittedOn IS NOT NULL AND c.ReportDueOn IS NOT NULL AND c.SubmittedOn > c.ReportDueOn THEN 1 ELSE 0 END AS BIT) AS SubmittedLate
    INTO #R
    FROM dbo.QcEqasResult r
    INNER JOIN dbo.QcEqasCycle c ON c.CycleId = r.CycleId AND c.IsDeleted = 0
    INNER JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId AND p.CompanyId = @CompanyId AND p.BranchId = @BranchId AND p.IsDeleted = 0
    INNER JOIN dbo.QcEqasProgramTest t ON t.ProgramTestId = r.ProgramTestId
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId
    LEFT JOIN dbo.QcCapa cp ON cp.CapaId = r.CapaId
    WHERE c.ReceivedOn >= @FromDate AND c.ReceivedOn <= @ToDate
      AND (@ProgramId IS NULL OR p.ProgramId = @ProgramId) AND (@Performance IS NULL OR r.Performance = @Performance)
      AND (@Search IS NULL OR m.Test_Name LIKE '%' + @Search + '%' OR p.ProgramName LIKE '%' + @Search + '%' OR c.CycleName LIKE '%' + @Search + '%');

    SELECT COUNT(1) AS Results, SUM(CASE WHEN Performance <> 'NOT_EVALUATED' THEN 1 ELSE 0 END) AS Evaluated,
           SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END) AS Acceptable, SUM(CASE WHEN Performance = 'WARNING' THEN 1 ELSE 0 END) AS Warning,
           SUM(CASE WHEN Performance = 'UNACCEPTABLE' THEN 1 ELSE 0 END) AS Unacceptable,
           CAST(SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN Performance <> 'NOT_EVALUATED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS AcceptablePct,
           COUNT(DISTINCT CycleId) AS Cycles, COUNT(DISTINCT CASE WHEN SubmittedLate = 1 THEN CycleId END) AS LateCycles
    FROM #R;
    SELECT 'byProgram' AS GroupKey, ProgramId AS GroupId, ProgramName AS GroupName, COUNT(1) AS Results,
           SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END) AS Acceptable, SUM(CASE WHEN Performance = 'WARNING' THEN 1 ELSE 0 END) AS Warning,
           SUM(CASE WHEN Performance = 'UNACCEPTABLE' THEN 1 ELSE 0 END) AS Unacceptable,
           CAST(SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN Performance <> 'NOT_EVALUATED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS AcceptablePct
    FROM #R GROUP BY ProgramId, ProgramName
    UNION ALL
    SELECT 'byTest', TestId, TestName, COUNT(1), SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END), SUM(CASE WHEN Performance = 'WARNING' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Performance = 'UNACCEPTABLE' THEN 1 ELSE 0 END),
           CAST(SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN Performance <> 'NOT_EVALUATED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1))
    FROM #R GROUP BY TestId, TestName
    UNION ALL
    SELECT 'byPerformance', NULL, PerformanceLabel, COUNT(1), SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END), SUM(CASE WHEN Performance = 'WARNING' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Performance = 'UNACCEPTABLE' THEN 1 ELSE 0 END), NULL
    FROM #R GROUP BY PerformanceLabel
    UNION ALL
    SELECT 'byCycle', CycleId, ProgramName + N' · ' + CycleName, COUNT(1), SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Performance = 'WARNING' THEN 1 ELSE 0 END), SUM(CASE WHEN Performance = 'UNACCEPTABLE' THEN 1 ELSE 0 END),
           CAST(SUM(CASE WHEN Performance = 'ACCEPTABLE' THEN 1 ELSE 0 END) * 100.0 / NULLIF(SUM(CASE WHEN Performance <> 'NOT_EVALUATED' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1))
    FROM #R GROUP BY CycleId, ProgramName, CycleName
    ORDER BY GroupKey, GroupName;
    SELECT * FROM #R ORDER BY ReceivedOn DESC, ProgramName, TestName;
    SELECT 'programId' AS FilterKey, CAST(ProgramId AS VARCHAR(20)) AS Value, ProgramName AS Text FROM dbo.QcEqasProgram
    WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND IsDeleted = 0 ORDER BY Text;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabReport_CapaRegister
    @BranchId INT, @FromDate DATE, @ToDate DATE, @Search NVARCHAR(100) = NULL,
    @CapaStatus VARCHAR(20) = NULL,       -- OPEN | ACTION_TAKEN | CLOSED | OVERDUE
    @SourceType VARCHAR(20) = NULL,       -- EQAS | CALIBRATION | BREAKDOWN | OTHER
    @UserId INT = NULL, @IsAdmin BIT = 0, @IsSuperAdmin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabReport_CheckAccess @BranchId, @UserId, @IsSuperAdmin;
    IF @ToDate < @FromDate BEGIN DECLARE @s DATE = @FromDate; SET @FromDate = @ToDate; SET @ToDate = @s; END
    DECLARE @From DATETIME = @FromDate, @To DATETIME = DATEADD(DAY, 1, CAST(@ToDate AS DATETIME));
    DECLARE @CompanyId INT = dbo.ufn_Qc_BranchCompany(@BranchId);
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), ''); SET @CapaStatus = NULLIF(UPPER(LTRIM(RTRIM(@CapaStatus))), ''); SET @SourceType = NULLIF(UPPER(LTRIM(RTRIM(@SourceType))), '');
    SELECT c.CapaId, c.CapaNo, c.SourceType,
           CASE c.SourceType WHEN 'EQAS' THEN N'EQAS' WHEN 'CALIBRATION' THEN N'Calibration' WHEN 'BREAKDOWN' THEN N'Breakdown' ELSE N'Other' END AS SourceLabel,
           c.Title, c.Problem, c.RootCause, c.CorrectiveAction, c.PreventiveAction, c.Effectiveness, c.Status,
           CASE c.Status WHEN 'OPEN' THEN N'Open' WHEN 'ACTION_TAKEN' THEN N'Action taken' ELSE N'Closed' END AS StatusLabel,
           c.TargetDate, c.CreatedDate, CONVERT(VARCHAR(10), CAST(c.CreatedDate AS DATE), 23) AS CreatedDay, c.ClosedOn,
           CAST(CASE WHEN c.Status <> 'CLOSED' AND c.TargetDate < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
           DATEDIFF(DAY, c.CreatedDate, ISNULL(c.ClosedOn, GETDATE())) AS AgeDays,
           ISNULL(c.ResponsibleUserId, 0) AS ResponsibleId, ISNULL(NULLIF(LTRIM(RTRIM(u.FullName)), ''), ISNULL(u.Username, N'Not assigned')) AS ResponsibleName,
           e.AssetCode, e.EquipmentName, p.ProgramName
    INTO #R
    FROM dbo.QcCapa c
    LEFT JOIN dbo.Users u ON u.Id = c.ResponsibleUserId
    LEFT JOIN dbo.QcEquipment e ON e.EquipmentId = c.EquipmentId
    LEFT JOIN dbo.QcEqasProgram p ON p.ProgramId = c.ProgramId
    WHERE c.CompanyId = @CompanyId AND c.BranchId = @BranchId AND c.CreatedDate >= @From AND c.CreatedDate < @To
      AND (@SourceType IS NULL OR c.SourceType = @SourceType)
      AND (@Search IS NULL OR c.CapaNo LIKE '%' + @Search + '%' OR c.Title LIKE '%' + @Search + '%');
    DELETE FROM #R WHERE @CapaStatus IS NOT NULL AND NOT ((@CapaStatus = 'OVERDUE' AND IsOverdue = 1) OR Status = @CapaStatus);

    SELECT COUNT(1) AS Capas, SUM(CASE WHEN Status <> 'CLOSED' THEN 1 ELSE 0 END) AS OpenCapas, SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) AS Overdue,
           SUM(CASE WHEN Status = 'CLOSED' THEN 1 ELSE 0 END) AS Closed, CAST(AVG(CASE WHEN Status = 'CLOSED' THEN AgeDays * 1.0 END) AS DECIMAL(10,1)) AS AvgDaysToClose
    FROM #R;
    SELECT 'bySource' AS GroupKey, NULL AS GroupId, SourceLabel AS GroupName, COUNT(1) AS Capas, SUM(CASE WHEN Status <> 'CLOSED' THEN 1 ELSE 0 END) AS OpenCapas,
           SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) AS Overdue
    FROM #R GROUP BY SourceLabel
    UNION ALL
    SELECT 'byStatus', NULL, StatusLabel, COUNT(1), SUM(CASE WHEN Status <> 'CLOSED' THEN 1 ELSE 0 END), SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END) FROM #R GROUP BY StatusLabel
    UNION ALL
    SELECT 'byResponsible', ResponsibleId, ResponsibleName, COUNT(1), SUM(CASE WHEN Status <> 'CLOSED' THEN 1 ELSE 0 END), SUM(CASE WHEN IsOverdue = 1 THEN 1 ELSE 0 END)
    FROM #R GROUP BY ResponsibleId, ResponsibleName
    ORDER BY GroupKey, GroupName;
    SELECT * FROM #R ORDER BY CASE Status WHEN 'OPEN' THEN 0 WHEN 'ACTION_TAKEN' THEN 1 ELSE 2 END, TargetDate, CapaId DESC;
END;
GO

-- 8. Menu, pages, controls, endpoints -----------------------------------------------------------------------------
DECLARE @co INT, @top INT, @mEq INT, @mRep INT, @page INT, @ctl INT, @code NVARCHAR(150), @title NVARCHAR(150), @ctrl NVARCHAR(100),
        @sort INT, @icon NVARCHAR(100), @action NVARCHAR(100);
DECLARE @Pages TABLE (Code NVARCHAR(150), Title NVARCHAR(150), Ctrl NVARCHAR(100), Action NVARCHAR(100), Sort INT, Icon NVARCHAR(100), Menu VARCHAR(10));
INSERT INTO @Pages VALUES
 (N'QC.EQUIPMENT', N'Equipment Register',         N'QcEquipment', N'Index', 10, N'bi bi-tools me-2',             'EQ'),
 (N'QC.EQAS',      N'EQAS Programmes & Results',  N'QcEqas',      N'Index', 20, N'bi bi-award me-2',             'EQ'),
 (N'QC.CAPA',      N'CAPA Register',              N'QcCapa',      N'Index', 30, N'bi bi-clipboard2-check me-2',  'EQ'),
 (N'REPORTS.LABEQUIPMENTDUE',      N'Equipment Calibration & Maintenance Due', N'Reports', N'LabEquipmentDue',      400, N'bi bi-calendar-check me-2', 'REP'),
 (N'REPORTS.LABEQUIPMENTDOWNTIME', N'Equipment Breakdown & Downtime',          N'Reports', N'LabEquipmentDowntime', 405, N'bi bi-exclamation-octagon me-2', 'REP'),
 (N'REPORTS.LABEQASPERFORMANCE',   N'EQAS Performance',                        N'Reports', N'LabEqasPerformance',   410, N'bi bi-award me-2', 'REP'),
 (N'REPORTS.LABCAPAREGISTER',      N'CAPA Register (Report)',                  N'Reports', N'LabCapaRegister',      415, N'bi bi-clipboard2-check me-2', 'REP');
DECLARE @Controls TABLE (Page NVARCHAR(150), Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES
 (N'QC.EQUIPMENT', 'ADD', N'Add / edit equipment', 20), (N'QC.EQUIPMENT', 'CALIBRATE', N'Record calibration', 30),
 (N'QC.EQUIPMENT', 'MAINTAIN', N'Record maintenance and breakdowns', 40), (N'QC.EQUIPMENT', 'STATUS', N'Change status / retire', 50),
 (N'QC.EQUIPMENT', 'DELETE', N'Delete', 60),
 (N'QC.EQAS', 'ADD', N'Add / edit programmes', 20), (N'QC.EQAS', 'RESULT', N'Cycles and results', 30),
 (N'QC.CAPA', 'EDIT', N'Add / update CAPA', 20), (N'QC.CAPA', 'CLOSE', N'Close CAPA', 30);
DECLARE @Ep TABLE (Page NVARCHAR(150), Method VARCHAR(10), Ctrl NVARCHAR(100), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Ep VALUES
 (N'QC.EQUIPMENT', 'GET', N'QcEquipment', N'Index', 'VIEW'), (N'QC.EQUIPMENT', 'GET', N'QcEquipment', N'List', 'VIEW'),
 (N'QC.EQUIPMENT', 'GET', N'QcEquipment', N'Card', 'VIEW'), (N'QC.EQUIPMENT', 'GET', N'QcEquipment', N'CardData', 'VIEW'),
 (N'QC.EQUIPMENT', 'GET', N'QcEquipment', N'Summary', 'VIEW'),
 (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'Save', 'ADD'), (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'SetStatus', 'STATUS'),
 (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'Delete', 'DELETE'), (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'AddCalibration', 'CALIBRATE'),
 (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'AddMaintenance', 'MAINTAIN'), (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'OpenBreakdown', 'MAINTAIN'),
 (N'QC.EQUIPMENT', 'POST', N'QcEquipment', N'ResolveBreakdown', 'MAINTAIN'),
 (N'QC.EQAS', 'GET', N'QcEqas', N'Index', 'VIEW'), (N'QC.EQAS', 'GET', N'QcEqas', N'List', 'VIEW'), (N'QC.EQAS', 'GET', N'QcEqas', N'Cycles', 'VIEW'),
 (N'QC.EQAS', 'GET', N'QcEqas', N'Results', 'VIEW'), (N'QC.EQAS', 'POST', N'QcEqas', N'Save', 'ADD'),
 (N'QC.EQAS', 'POST', N'QcEqas', N'SaveCycle', 'RESULT'), (N'QC.EQAS', 'POST', N'QcEqas', N'SaveResults', 'RESULT'),
 (N'QC.CAPA', 'GET', N'QcCapa', N'Index', 'VIEW'), (N'QC.CAPA', 'GET', N'QcCapa', N'List', 'VIEW'), (N'QC.CAPA', 'POST', N'QcCapa', N'Save', 'EDIT'),
 (N'REPORTS.LABEQUIPMENTDUE', 'GET', N'Reports', N'LabEquipmentDue', 'VIEW'), (N'REPORTS.LABEQUIPMENTDUE', 'GET', N'Reports', N'GetLabReportData', 'VIEW'),
 (N'REPORTS.LABEQUIPMENTDOWNTIME', 'GET', N'Reports', N'LabEquipmentDowntime', 'VIEW'), (N'REPORTS.LABEQUIPMENTDOWNTIME', 'GET', N'Reports', N'GetLabReportData', 'VIEW'),
 (N'REPORTS.LABEQASPERFORMANCE', 'GET', N'Reports', N'LabEqasPerformance', 'VIEW'), (N'REPORTS.LABEQASPERFORMANCE', 'GET', N'Reports', N'GetLabReportData', 'VIEW'),
 (N'REPORTS.LABCAPAREGISTER', 'GET', N'Reports', N'LabCapaRegister', 'VIEW'), (N'REPORTS.LABCAPAREGISTER', 'GET', N'Reports', N'GetLabReportData', 'VIEW');

DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @top = NULL; SET @mRep = NULL;
    SELECT @top = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'QUALITY' AND CompanyId = @co;
    SELECT @mRep = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'REPORTS.LAB' AND CompanyId = @co;
    IF @top IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_MenuMaster_Upsert @CompanyId = @co, @Parent_Menu_ID = @top, @Menu_Type = 'MENU', @Menu_Code = N'QUALITY.EQUIPMENT',
             @Title = N'Equipment & EQAS', @Icon = N'bi bi-tools me-2', @Sort_Order = 30, @Menu_ID = @mEq OUTPUT;
        DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Ctrl, Action, Sort, Icon FROM @Pages WHERE Menu = 'EQ' OR (Menu = 'REP' AND @mRep IS NOT NULL);
        OPEN pg; FETCH NEXT FROM pg INTO @code, @title, @ctrl, @action, @sort, @icon;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @page = NULL;
            DECLARE @mid INT = CASE WHEN @ctrl = N'Reports' THEN @mRep ELSE @mEq END;
            EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @mid, @Page_Code = @code, @Title = @title, @Controller = @ctrl, @Action = @action,
                 @Show_In_Menu = 1, @Sort_Order = @sort, @Icon = @icon, @Page_ID = @page OUTPUT;
            DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT;
            DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls WHERE Page = @code;
            OPEN c1; FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
                FETCH NEXT FROM c1 INTO @cc, @ct, @cs;
            END
            CLOSE c1; DEALLOCATE c1;
            DECLARE @em VARCHAR(10), @ec NVARCHAR(100), @ea NVARCHAR(100), @ecode VARCHAR(30);
            DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Ctrl, Action, Code FROM @Ep WHERE Page = @code;
            OPEN e1; FETCH NEXT FROM e1 INTO @em, @ec, @ea, @ecode;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @ctl = NULL;
                SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @ecode;
                EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @em,
                     @Controller = @ec, @Action = @ea, @Source = 'SEED';
                FETCH NEXT FROM e1 INTO @em, @ec, @ea, @ecode;
            END
            CLOSE e1; DEALLOCATE e1;
            FETCH NEXT FROM pg INTO @code, @title, @ctrl, @action, @sort, @icon;
        END
        CLOSE pg; DEALLOCATE pg;
    END
    -- the Analyzers page reads each analyzer's equipment status with its own VIEW
    SET @page = NULL; SET @ctl = NULL;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = 'MASTER.ANALYZERS' AND CompanyId = @co;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    IF @page IS NOT NULL
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'QcEquipment', @Action = N'AnalyzerStatus', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2253 applied: LF-06 Equipment and EQAS register (equipment, calibration, maintenance, breakdowns, EQAS, CAPA, 4 reports).';
GO
