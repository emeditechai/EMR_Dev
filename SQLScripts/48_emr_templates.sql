USE [Dev_EMR];
GO

-- ===========================================================================
-- 48_emr_templates.sql
-- Creates schema tables for EMR template settings mapped to specialities
-- and seeds the default General Physician EMR Template.
-- ===========================================================================

-- 1. EmrTemplates Master Table
IF OBJECT_ID('dbo.EmrTemplates', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.EmrTemplates (
        TemplateId INT IDENTITY(1,1) PRIMARY KEY,
        TemplateName NVARCHAR(150) NOT NULL,
        Description NVARCHAR(500) NULL,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedBy INT NULL,
        CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
        ModifiedBy INT NULL,
        ModifiedDate DATETIME NULL
    );
    PRINT 'Table dbo.EmrTemplates created.';
END
GO

-- 2. EmrTemplateSpecialityMap Mapping Table
IF OBJECT_ID('dbo.EmrTemplateSpecialityMap', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.EmrTemplateSpecialityMap (
        TemplateId INT NOT NULL,
        SpecialityId INT NOT NULL,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedBy INT NULL,
        CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT PK_EmrTemplateSpecialityMap PRIMARY KEY (TemplateId, SpecialityId),
        CONSTRAINT FK_EmrTemplateSpecialityMap_Templates FOREIGN KEY (TemplateId) REFERENCES dbo.EmrTemplates(TemplateId) ON DELETE CASCADE,
        CONSTRAINT FK_EmrTemplateSpecialityMap_Speciality FOREIGN KEY (SpecialityId) REFERENCES dbo.DoctorSpecialityMaster(SpecialityId)
    );
    PRINT 'Table dbo.EmrTemplateSpecialityMap created.';
END
GO

-- 3. EmrTemplateSections Table
IF OBJECT_ID('dbo.EmrTemplateSections', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.EmrTemplateSections (
        SectionId INT IDENTITY(1,1) PRIMARY KEY,
        TemplateId INT NOT NULL,
        SectionName NVARCHAR(100) NOT NULL,
        DisplayOrder INT NOT NULL DEFAULT 0,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedBy INT NULL,
        CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_EmrTemplateSections_Templates FOREIGN KEY (TemplateId) REFERENCES dbo.EmrTemplates(TemplateId) ON DELETE CASCADE
    );
    PRINT 'Table dbo.EmrTemplateSections created.';
END
GO

-- 4. EmrTemplateFields Table
IF OBJECT_ID('dbo.EmrTemplateFields', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.EmrTemplateFields (
        FieldId INT IDENTITY(1,1) PRIMARY KEY,
        SectionId INT NOT NULL,
        FieldName NVARCHAR(100) NOT NULL,
        FieldType NVARCHAR(50) NOT NULL, -- Text, TextArea, Select, MultiSelect, Number, Checkbox, Date
        OptionsJson NVARCHAR(MAX) NULL, -- JSON array of choices for Select/MultiSelect
        IsRequired BIT NOT NULL DEFAULT 0,
        DisplayOrder INT NOT NULL DEFAULT 0,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedBy INT NULL,
        CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_EmrTemplateFields_Sections FOREIGN KEY (SectionId) REFERENCES dbo.EmrTemplateSections(SectionId) ON DELETE CASCADE
    );
    PRINT 'Table dbo.EmrTemplateFields created.';
END
GO

-- 5. Seed Default General Physician EMR Template (SpecialityId = 1)
IF NOT EXISTS (SELECT 1 FROM dbo.EmrTemplates WHERE TemplateName = 'General Physician EMR Template')
BEGIN
    DECLARE @TemplateId INT;
    
    -- Insert Template
    INSERT INTO dbo.EmrTemplates (TemplateName, Description, IsActive, CreatedDate)
    VALUES ('General Physician EMR Template', 'Default medical record template for General Medicine consultations, structured according to guidelines.', 1, GETDATE());
    
    SET @TemplateId = SCOPE_IDENTITY();
    
    -- Map to SpecialityId 1 (General Medicine)
    INSERT INTO dbo.EmrTemplateSpecialityMap (TemplateId, SpecialityId, IsActive, CreatedDate)
    VALUES (@TemplateId, 1, 1, GETDATE());
    
    -- ── Section 1: History Taking ──
    DECLARE @SecHistory INT;
    INSERT INTO dbo.EmrTemplateSections (TemplateId, SectionName, DisplayOrder, IsActive, CreatedDate)
    VALUES (@TemplateId, 'History Taking', 1, 1, GETDATE());
    SET @SecHistory = SCOPE_IDENTITY();
    
    INSERT INTO dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive)
    VALUES 
        (@SecHistory, 'Chief Complaint', 'TextArea', NULL, 1, 1, 1),
        (@SecHistory, 'Present Illness History', 'TextArea', NULL, 0, 2, 1),
        (@SecHistory, 'Duration', 'Text', NULL, 0, 3, 1),
        (@SecHistory, 'Associated Symptoms', 'Text', NULL, 0, 4, 1),
        (@SecHistory, 'Previous Similar Episodes', 'Text', NULL, 0, 5, 1),
        (@SecHistory, 'Medication History', 'TextArea', NULL, 0, 6, 1),
        (@SecHistory, 'Social History', 'Text', NULL, 0, 7, 1),
        (@SecHistory, 'Smoking', 'Select', '["None", "Regular", "Occasional", "Ex-smoker"]', 0, 8, 1),
        (@SecHistory, 'Alcohol Consumption', 'Select', '["None", "Regular", "Occasional", "Ex-drinker"]', 0, 9, 1),
        (@SecHistory, 'Occupational History', 'Text', NULL, 0, 10, 1);

    -- ── Section 2: General Examination ──
    DECLARE @SecGenExam INT;
    INSERT INTO dbo.EmrTemplateSections (TemplateId, SectionName, DisplayOrder, IsActive, CreatedDate)
    VALUES (@TemplateId, 'General Examination', 2, 1, GETDATE());
    SET @SecGenExam = SCOPE_IDENTITY();
    
    INSERT INTO dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive)
    VALUES 
        (@SecGenExam, 'Consciousness', 'Select', '["Alert", "Confused", "Lethargic", "Stuporous", "Comatose"]', 0, 1, 1),
        (@SecGenExam, 'Orientation', 'Select', '["Oriented x3 (Time, Place, Person)", "Disoriented"]', 0, 2, 1),
        (@SecGenExam, 'Pallor', 'Select', '["Absent", "Mild", "Moderate", "Severe"]', 0, 3, 1),
        (@SecGenExam, 'Icterus', 'Select', '["Absent", "Mild", "Moderate", "Severe"]', 0, 4, 1),
        (@SecGenExam, 'Cyanosis', 'Select', '["Absent", "Present"]', 0, 5, 1),
        (@SecGenExam, 'Clubbing', 'Select', '["Absent", "Present"]', 0, 6, 1),
        (@SecGenExam, 'Lymphadenopathy', 'Select', '["Absent", "Present"]', 0, 7, 1),
        (@SecGenExam, 'Edema', 'Select', '["Absent", "Mild Pedal", "Bilateral Pedal", "Anasarca"]', 0, 8, 1);

    -- ── Section 3: Systemic Examination ──
    DECLARE @SecSysExam INT;
    INSERT INTO dbo.EmrTemplateSections (TemplateId, SectionName, DisplayOrder, IsActive, CreatedDate)
    VALUES (@TemplateId, 'Systemic Examination', 3, 1, GETDATE());
    SET @SecSysExam = SCOPE_IDENTITY();
    
    INSERT INTO dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive)
    VALUES 
        (@SecSysExam, 'Heart Sounds (CVS)', 'Select', '["S1, S2 Normal", "Abnormal"]', 0, 1, 1),
        (@SecSysExam, 'Murmurs (CVS)', 'Select', '["None", "Systolic", "Diastolic", "Continuous"]', 0, 2, 1),
        (@SecSysExam, 'Rhythm (CVS)', 'Select', '["Regular", "Irregular"]', 0, 3, 1),
        (@SecSysExam, 'Air Entry (RS)', 'Select', '["Bilateral Equal", "Decreased Left", "Decreased Right"]', 0, 4, 1),
        (@SecSysExam, 'Wheeze (RS)', 'Select', '["Absent", "Bilateral", "Unilateral"]', 0, 5, 1),
        (@SecSysExam, 'Crepitations (RS)', 'Select', '["Absent", "Bilateral Basal", "Unilateral"]', 0, 6, 1),
        (@SecSysExam, 'Tenderness (Abdomen)', 'Select', '["None", "Epigastric", "Right Upper Quadrant", "Generalized"]', 0, 7, 1),
        (@SecSysExam, 'Organomegaly (Abdomen)', 'Select', '["None", "Hepatomegaly", "Splenomegaly", "Both"]', 0, 8, 1),
        (@SecSysExam, 'Ascites (Abdomen)', 'Select', '["Absent", "Mild", "Moderate", "Severe"]', 0, 9, 1),
        (@SecSysExam, 'Motor System (CNS)', 'Text', NULL, 0, 10, 1),
        (@SecSysExam, 'Sensory System (CNS)', 'Text', NULL, 0, 11, 1),
        (@SecSysExam, 'Reflexes (CNS)', 'Text', NULL, 0, 12, 1);

    -- ── Section 4: Diagnosis ──
    DECLARE @SecDiagnosis INT;
    INSERT INTO dbo.EmrTemplateSections (TemplateId, SectionName, DisplayOrder, IsActive, CreatedDate)
    VALUES (@TemplateId, 'Diagnosis', 4, 1, GETDATE());
    SET @SecDiagnosis = SCOPE_IDENTITY();
    
    INSERT INTO dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive)
    VALUES 
        (@SecDiagnosis, 'Provisional Diagnosis', 'Text', NULL, 1, 1, 1),
        (@SecDiagnosis, 'Final Diagnosis', 'Text', NULL, 0, 2, 1),
        (@SecDiagnosis, 'ICD-10 Code', 'Text', NULL, 0, 3, 1),
        (@SecDiagnosis, 'Differential Diagnosis', 'TextArea', NULL, 0, 4, 1);

    -- ── Section 5: Investigations ──
    DECLARE @SecInvest INT;
    INSERT INTO dbo.EmrTemplateSections (TemplateId, SectionName, DisplayOrder, IsActive, CreatedDate)
    VALUES (@TemplateId, 'Investigations', 5, 1, GETDATE());
    SET @SecInvest = SCOPE_IDENTITY();
    
    INSERT INTO dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive)
    VALUES 
        (@SecInvest, 'CBC', 'Checkbox', NULL, 0, 1, 1),
        (@SecInvest, 'ESR', 'Checkbox', NULL, 0, 2, 1),
        (@SecInvest, 'CRP', 'Checkbox', NULL, 0, 3, 1),
        (@SecInvest, 'LFT', 'Checkbox', NULL, 0, 4, 1),
        (@SecInvest, 'RFT', 'Checkbox', NULL, 0, 5, 1),
        (@SecInvest, 'Lipid Profile', 'Checkbox', NULL, 0, 6, 1),
        (@SecInvest, 'HbA1c', 'Checkbox', NULL, 0, 7, 1),
        (@SecInvest, 'Thyroid Profile', 'Checkbox', NULL, 0, 8, 1),
        (@SecInvest, 'ECG', 'Checkbox', NULL, 0, 9, 1),
        (@SecInvest, 'X-Ray', 'Checkbox', NULL, 0, 10, 1),
        (@SecInvest, 'Ultrasound', 'Checkbox', NULL, 0, 11, 1),
        (@SecInvest, 'Custom Tests', 'Text', NULL, 0, 12, 1);

    -- ── Section 6: Treatment Plan ──
    DECLARE @SecTreatment INT;
    INSERT INTO dbo.EmrTemplateSections (TemplateId, SectionName, DisplayOrder, IsActive, CreatedDate)
    VALUES (@TemplateId, 'Treatment Plan', 6, 1, GETDATE());
    SET @SecTreatment = SCOPE_IDENTITY();
    
    INSERT INTO dbo.EmrTemplateFields (SectionId, FieldName, FieldType, OptionsJson, IsRequired, DisplayOrder, IsActive)
    VALUES 
        (@SecTreatment, 'Medications', 'TextArea', NULL, 0, 1, 1),
        (@SecTreatment, 'Advice', 'TextArea', NULL, 0, 2, 1),
        (@SecTreatment, 'Lifestyle Modifications', 'TextArea', NULL, 0, 3, 1),
        (@SecTreatment, 'Follow-up Date', 'Date', NULL, 0, 4, 1);

    PRINT 'Seeded default General Physician EMR Template mapped to General Medicine.';
END
GO
