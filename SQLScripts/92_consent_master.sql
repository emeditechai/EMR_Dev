-- ====================================================================================================
-- Script: 92_consent_master.sql
-- Description: Creates dbo.ConsentMaster table and Stored Procedures for Consent Masters
--              under Master -> General -> Consent Master.
-- ====================================================================================================

-- 1. Create dbo.ConsentMaster Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ConsentMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.ConsentMaster
    (
        Consent_ID             INT IDENTITY(1,1) PRIMARY KEY,
        CompanyId              INT NOT NULL DEFAULT 1,
        Branch_ID              INT NOT NULL,
        ConsentType            NVARCHAR(100) NOT NULL, -- General Admission Consent, Surgical Consent, Anaesthesia Consent, etc.
        Type                   NVARCHAR(20) NOT NULL,  -- IPD, OPD, LAB, MED
        Procedure_ID           INT NULL,               -- FK to ProcedureMaster (if Type = 'IPD')
        Language               NVARCHAR(50) NOT NULL DEFAULT 'English',
        ConsentTemplateContent NVARCHAR(MAX) NOT NULL,
        Version                NVARCHAR(20) NOT NULL DEFAULT '1.0',
        ValidityPeriod         NVARCHAR(50) NOT NULL DEFAULT 'Per Admission',
        WitnessRequired        BIT NOT NULL DEFAULT 1,
        Status                 BIT NOT NULL DEFAULT 1,
        CreatedBy              INT NULL,
        CreatedDate            DATETIME2 NOT NULL DEFAULT GETDATE(),
        ModifiedBy             INT NULL,
        ModifiedDate           DATETIME2 NULL,
        CONSTRAINT FK_ConsentMaster_Branch FOREIGN KEY (Branch_ID) REFERENCES dbo.Branchmaster(BranchID),
        CONSTRAINT FK_ConsentMaster_Procedure FOREIGN KEY (Procedure_ID) REFERENCES dbo.ProcedureMaster(ProcedureId)
    );
    CREATE INDEX IX_ConsentMaster_Branch_Status ON dbo.ConsentMaster(Branch_ID, Status);
    CREATE INDEX IX_ConsentMaster_Type ON dbo.ConsentMaster(Type, ConsentType);
    CREATE INDEX IX_ConsentMaster_Procedure ON dbo.ConsentMaster(Procedure_ID);
    PRINT 'Created table dbo.ConsentMaster';
END
ELSE
BEGIN
    PRINT 'Table dbo.ConsentMaster already exists';
END
GO

-- 2. Stored Procedure: usp_Api_ConsentMaster_GetList
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_GetList
    @BranchId     INT = NULL,
    @Type         NVARCHAR(20) = NULL,
    @ConsentType  NVARCHAR(100) = NULL,
    @Language     NVARCHAR(50) = NULL,
    @ProcedureId  INT = NULL,
    @Status       BIT = NULL,
    @Search       NVARCHAR(100) = NULL,
    @CompanyId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        c.Consent_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName,
        b.BranchCode,
        c.ConsentType,
        c.Type,
        c.Procedure_ID,
        p.ProcedureCode,
        p.ProcedureName,
        p.ProcedureCategory,
        c.Language,
        c.ConsentTemplateContent,
        c.Version,
        c.ValidityPeriod,
        c.WitnessRequired,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.ConsentMaster c
    INNER JOIN dbo.Branchmaster b ON c.Branch_ID = b.BranchID
    LEFT JOIN dbo.ProcedureMaster p ON c.Procedure_ID = p.ProcedureId
    WHERE (@BranchId IS NULL OR c.Branch_ID = @BranchId)
      AND (@Type IS NULL OR @Type = '' OR c.Type = @Type)
      AND (@ConsentType IS NULL OR @ConsentType = '' OR c.ConsentType = @ConsentType)
      AND (@Language IS NULL OR @Language = '' OR c.Language = @Language)
      AND (@ProcedureId IS NULL OR c.Procedure_ID = @ProcedureId)
      AND (@Status IS NULL OR c.Status = @Status)
      AND (@CompanyId IS NULL OR c.CompanyId = @CompanyId)
      AND (@Search IS NULL OR @Search = '' OR
           c.ConsentType LIKE '%' + @Search + '%' OR
           c.Type LIKE '%' + @Search + '%' OR
           c.Language LIKE '%' + @Search + '%' OR
           c.Version LIKE '%' + @Search + '%' OR
           p.ProcedureName LIKE '%' + @Search + '%' OR
           p.ProcedureCode LIKE '%' + @Search + '%')
    ORDER BY c.Type, c.ConsentType, c.Language, c.Version DESC;
END
GO

-- 3. Stored Procedure: usp_Api_ConsentMaster_GetById
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_GetById
    @Consent_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        c.Consent_ID,
        c.CompanyId,
        c.Branch_ID,
        b.BranchName,
        b.BranchCode,
        c.ConsentType,
        c.Type,
        c.Procedure_ID,
        p.ProcedureCode,
        p.ProcedureName,
        p.ProcedureCategory,
        c.Language,
        c.ConsentTemplateContent,
        c.Version,
        c.ValidityPeriod,
        c.WitnessRequired,
        c.Status,
        c.CreatedBy,
        c.CreatedDate,
        c.ModifiedBy,
        c.ModifiedDate
    FROM dbo.ConsentMaster c
    INNER JOIN dbo.Branchmaster b ON c.Branch_ID = b.BranchID
    LEFT JOIN dbo.ProcedureMaster p ON c.Procedure_ID = p.ProcedureId
    WHERE c.Consent_ID = @Consent_ID;
END
GO

-- 4. Stored Procedure: usp_Api_ConsentMaster_Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_Create
    @CompanyId              INT = 1,
    @Branch_ID              INT,
    @ConsentType            NVARCHAR(100),
    @Type                   NVARCHAR(20),
    @Procedure_ID           INT = NULL,
    @Language               NVARCHAR(50) = 'English',
    @ConsentTemplateContent NVARCHAR(MAX),
    @Version                NVARCHAR(20) = '1.0',
    @ValidityPeriod         NVARCHAR(50) = 'Per Admission',
    @WitnessRequired        BIT = 1,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- If Type is not IPD, clear Procedure_ID
    IF (@Type <> 'IPD')
    BEGIN
        SET @Procedure_ID = NULL;
    END

    INSERT INTO dbo.ConsentMaster
    (
        CompanyId,
        Branch_ID,
        ConsentType,
        Type,
        Procedure_ID,
        Language,
        ConsentTemplateContent,
        Version,
        ValidityPeriod,
        WitnessRequired,
        Status,
        CreatedBy,
        CreatedDate
    )
    VALUES
    (
        @CompanyId,
        @Branch_ID,
        LTRIM(RTRIM(@ConsentType)),
        LTRIM(RTRIM(@Type)),
        @Procedure_ID,
        LTRIM(RTRIM(@Language)),
        @ConsentTemplateContent,
        LTRIM(RTRIM(@Version)),
        LTRIM(RTRIM(@ValidityPeriod)),
        @WitnessRequired,
        @Status,
        @UserId,
        GETDATE()
    );

    SELECT SCOPE_IDENTITY() AS NewConsentId;
END
GO

-- 5. Stored Procedure: usp_Api_ConsentMaster_Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_Update
    @Consent_ID             INT,
    @CompanyId              INT = 1,
    @Branch_ID              INT,
    @ConsentType            NVARCHAR(100),
    @Type                   NVARCHAR(20),
    @Procedure_ID           INT = NULL,
    @Language               NVARCHAR(50) = 'English',
    @ConsentTemplateContent NVARCHAR(MAX),
    @Version                NVARCHAR(20) = '1.0',
    @ValidityPeriod         NVARCHAR(50) = 'Per Admission',
    @WitnessRequired        BIT = 1,
    @Status                 BIT = 1,
    @UserId                 INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- If Type is not IPD, clear Procedure_ID
    IF (@Type <> 'IPD')
    BEGIN
        SET @Procedure_ID = NULL;
    END

    UPDATE dbo.ConsentMaster
    SET
        CompanyId              = @CompanyId,
        Branch_ID              = @Branch_ID,
        ConsentType            = LTRIM(RTRIM(@ConsentType)),
        Type                   = LTRIM(RTRIM(@Type)),
        Procedure_ID           = @Procedure_ID,
        Language               = LTRIM(RTRIM(@Language)),
        ConsentTemplateContent = @ConsentTemplateContent,
        Version                = LTRIM(RTRIM(@Version)),
        ValidityPeriod         = LTRIM(RTRIM(@ValidityPeriod)),
        WitnessRequired        = @WitnessRequired,
        Status                 = @Status,
        ModifiedBy             = @UserId,
        ModifiedDate           = GETDATE()
    WHERE Consent_ID = @Consent_ID;

    SELECT @@ROWCOUNT AS RowsAffected;
END
GO

-- 6. Stored Procedure: usp_Api_ConsentMaster_ToggleStatus
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_ToggleStatus
    @Consent_ID INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ConsentMaster
    SET 
        Status       = CASE WHEN Status = 1 THEN 0 ELSE 1 END,
        ModifiedBy   = @UserId,
        ModifiedDate = GETDATE()
    WHERE Consent_ID = @Consent_ID;

    SELECT @@ROWCOUNT AS RowsAffected;
END
GO

-- 7. Stored Procedure: usp_Api_ConsentMaster_Delete
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_Delete
    @Consent_ID INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.ConsentMaster
    WHERE Consent_ID = @Consent_ID;

    SELECT @@ROWCOUNT AS RowsAffected;
END
GO

-- 8. Stored Procedure: usp_Api_ConsentMaster_GetProcedureOptions
CREATE OR ALTER PROCEDURE dbo.usp_Api_ConsentMaster_GetProcedureOptions
    @BranchId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        p.ProcedureId,
        p.ProcedureCode,
        p.ProcedureName,
        p.ProcedureCategory,
        d.DeptName AS DepartmentName,
        s.SpecialityName
    FROM dbo.ProcedureMaster p
    LEFT JOIN dbo.DepartmentMaster d ON p.DepartmentId = d.DeptId
    LEFT JOIN dbo.DoctorSpecialityMaster s ON p.SpecialityId = s.SpecialityId
    WHERE p.IsActive = 1
      AND (@BranchId IS NULL OR p.BranchId = @BranchId)
    ORDER BY p.ProcedureCategory, p.ProcedureName;
END
GO

-- 9. Seed Standard Hospital Consent Templates
IF NOT EXISTS (SELECT 1 FROM dbo.ConsentMaster WHERE Branch_ID = 1)
BEGIN
    -- 1. General Admission Consent (IPD)
    INSERT INTO dbo.ConsentMaster 
    (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedDate)
    VALUES
    (
        1, 1, 'General Admission Consent', 'IPD', NULL, 'English',
        '<h3>GENERAL INFORMED CONSENT FOR ADMISSION AND TREATMENT</h3><p>I, <strong>{{PatientName}}</strong> (UHID: <code>{{UHID}}</code> / IPD No: <code>{{IPDNo}}</code>), age <strong>{{Age}}</strong>, gender <strong>{{Gender}}</strong>, hereby authorize <strong>{{HospitalName}}</strong> and its attending medical staff under the supervision of <strong>{{DoctorName}}</strong> to admit me and administer routine nursing care, diagnostic examinations, laboratory testing, and medical treatment as deemed clinically necessary.</p><p>I understand that medicine is not an exact science and no guarantees have been made regarding the outcome of treatment. I confirm that all financial terms and hospital policies have been explained to me.</p><p><strong>Patient / Guardian Signature:</strong> ________________________<br/><strong>Date:</strong> {{Date}} &nbsp;&nbsp; <strong>Time:</strong> {{Time}}</p>',
        '1.0', 'Per Admission', 1, 1, GETDATE()
    );

    -- 2. Surgical & Operative Consent (IPD)
    DECLARE @ProcId INT = (SELECT TOP 1 ProcedureId FROM dbo.ProcedureMaster WHERE ProcedureCode = 'PROC-SURG-01');
    INSERT INTO dbo.ConsentMaster 
    (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedDate)
    VALUES
    (
        1, 1, 'Surgical / Operative Consent', 'IPD', @ProcId, 'English',
        '<h3>INFORMED CONSENT FOR SURGICAL / INVASIVE PROCEDURE</h3><p>I hereby authorize <strong>{{DoctorName}}</strong> and designated surgical team at <strong>{{HospitalName}}</strong> to perform the following procedure: <strong>{{ProcedureName}}</strong> on patient <strong>{{PatientName}}</strong> (UHID: <code>{{UHID}}</code>).</p><p>The nature, purpose, potential benefits, known risks (including bleeding, infection, unexpected complications, and anaesthesia hazards), and alternative treatment options have been thoroughly explained to me in a language I understand.</p><p>I consent to the administration of general, regional, or local anaesthesia and blood transfusion if required during surgery.</p><p><strong>Patient / Authorised Representative:</strong> ________________________<br/><strong>Witness Name & Signature:</strong> {{WitnessName}} ________________________<br/><strong>Surgeon Signature:</strong> {{DoctorName}} ________________________<br/><strong>Date:</strong> {{Date}}</p>',
        '1.0', 'Single Procedure', 1, 1, GETDATE()
    );

    -- 3. Blood & Component Transfusion Consent (IPD)
    INSERT INTO dbo.ConsentMaster 
    (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedDate)
    VALUES
    (
        1, 1, 'Blood & Component Transfusion Consent', 'IPD', NULL, 'English',
        '<h3>CONSENT FOR BLOOD AND BLOOD COMPONENT TRANSFUSION</h3><p>I consent to the transfusion of whole blood, packed red cells, platelets, or fresh frozen plasma for <strong>{{PatientName}}</strong> (UHID: <code>{{UHID}}</code>) as recommended by <strong>{{DoctorName}}</strong>.</p><p>I understand the clinical indications and recognize that despite strict screening, minimal risks such as allergic reactions, fever, or rare infectious transmission cannot be completely eliminated.</p><p><strong>Patient / Next of Kin Signature:</strong> ________________________<br/><strong>Witness Signature:</strong> ________________________<br/><strong>Date:</strong> {{Date}}</p>',
        '1.0', 'Per Admission', 1, 1, GETDATE()
    );

    -- 4. Discharge Against Medical Advice (DAMA) (IPD)
    INSERT INTO dbo.ConsentMaster 
    (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedDate)
    VALUES
    (
        1, 1, 'Discharge Against Medical Advice (DAMA)', 'IPD', NULL, 'English',
        '<h3>DISCHARGE AGAINST MEDICAL ADVICE (DAMA / LAMA) REFUSAL FORM</h3><p>This is to certify that I, <strong>{{PatientName}}</strong> (UHID: <code>{{UHID}}</code> / IPD No: <code>{{IPDNo}}</code>), am leaving <strong>{{HospitalName}}</strong> against the explicit advice of the treating consultant <strong>{{DoctorName}}</strong>.</p><p>The severe clinical risks of premature discharge, including deterioration of health, permanent impairment, or death, have been clearly communicated to me. I voluntarily release the hospital, doctors, and staff from any and all liability resulting from this decision.</p><p><strong>Patient / Guardian Signature:</strong> ________________________<br/><strong>Relationship:</strong> ________________________<br/><strong>Witness Signature:</strong> ________________________<br/><strong>Date:</strong> {{Date}}</p>',
        '1.0', 'Single Procedure', 1, 1, GETDATE()
    );

    -- 5. Diagnostic Radiology & Endoscopy Consent (OPD)
    INSERT INTO dbo.ConsentMaster 
    (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedDate)
    VALUES
    (
        1, 1, 'Diagnostic Procedure Consent', 'OPD', NULL, 'English',
        '<h3>INFORMED CONSENT FOR OUTPATIENT DIAGNOSTIC PROCEDURE</h3><p>I consent to undergoing the scheduled diagnostic procedure at <strong>{{HospitalName}}</strong> for patient <strong>{{PatientName}}</strong> (UHID: <code>{{UHID}}</code> / OPD No: <code>{{OPDNo}}</code>).</p><p>I have followed all pre-procedure fasting and medication guidelines as directed by <strong>{{DoctorName}}</strong>.</p><p><strong>Patient Signature:</strong> ________________________<br/><strong>Date:</strong> {{Date}}</p>',
        '1.0', 'Single Procedure', 0, 1, GETDATE()
    );

    -- 6. Hindi Admission Consent (IPD)
    INSERT INTO dbo.ConsentMaster 
    (CompanyId, Branch_ID, ConsentType, Type, Procedure_ID, Language, ConsentTemplateContent, Version, ValidityPeriod, WitnessRequired, Status, CreatedDate)
    VALUES
    (
        1, 1, 'General Admission Consent', 'IPD', NULL, 'Hindi',
        '<h3>अस्पताल में भर्ती एवं उपचार हेतु सहमति पत्र (INFORMED CONSENT)</h3><p>मैं, <strong>{{PatientName}}</strong> (UHID: <code>{{UHID}}</code> / IPD संख्या: <code>{{IPDNo}}</code>), <strong>{{HospitalName}}</strong> में डॉ. <strong>{{DoctorName}}</strong> की देखरेख में भर्ती होने और आवश्यक जांच, नर्सिंग देखभाल एवं चिकित्सकीय उपचार के लिए अपनी पूर्ण सहमति देता/देती हूँ।</p><p>मुझे अस्पताल के नियम एवं संभावित उपचार प्रक्रियाओं की जानकारी स्पष्ट भाषा में समझा दी गई है।</p><p><strong>मरीज / अभिभावक के हस्ताक्षर:</strong> ________________________<br/><strong>गवाह के हस्ताक्षर:</strong> ________________________<br/><strong>दिनांक:</strong> {{Date}}</p>',
        '1.0', 'Per Admission', 1, 1, GETDATE()
    );

    PRINT 'Seeded sample Consent Masters';
END
GO
