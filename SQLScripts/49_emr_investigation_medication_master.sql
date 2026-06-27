-- =====================================================================
-- Script: 49_emr_investigation_medication_master.sql
-- Purpose: Create EMR Investigation and Medication master tables with
--          seed data for use in EMR Template builder toolbox
-- =====================================================================

USE Dev_EMR;
GO

-- ─────────────────────────────────────────
-- 1. EMR Investigation Master
-- ─────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'EmrInvestigationMaster' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE [dbo].[EmrInvestigationMaster] (
        [InvestigationId]   INT             IDENTITY(1,1)   NOT NULL,
        [InvestigationName] NVARCHAR(200)                   NOT NULL,
        [Category]          NVARCHAR(100)                   NULL,
        [Unit]              NVARCHAR(50)                    NULL,
        [NormalRange]       NVARCHAR(100)                   NULL,
        [Description]       NVARCHAR(500)                   NULL,
        [IsActive]          BIT             NOT NULL        DEFAULT 1,
        [CreatedDate]       DATETIME2       NOT NULL        DEFAULT GETDATE(),
        [CreatedBy]         INT             NOT NULL        DEFAULT 0,
        [ModifiedDate]      DATETIME2       NULL,
        [ModifiedBy]        INT             NULL,
        CONSTRAINT [PK_EmrInvestigationMaster] PRIMARY KEY CLUSTERED ([InvestigationId] ASC)
    );
    PRINT 'Table EmrInvestigationMaster created.';
END
ELSE
    PRINT 'Table EmrInvestigationMaster already exists.';
GO

-- ─────────────────────────────────────────
-- 2. EMR Medication Master
-- ─────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'EmrMedicationMaster' AND TABLE_SCHEMA = 'dbo')
BEGIN
    CREATE TABLE [dbo].[EmrMedicationMaster] (
        [MedicationId]          INT             IDENTITY(1,1)   NOT NULL,
        [MedicationName]        NVARCHAR(200)                   NOT NULL,
        [GenericName]           NVARCHAR(200)                   NULL,
        [Category]              NVARCHAR(100)                   NULL,
        [Strength]              NVARCHAR(100)                   NULL,
        [Unit]                  NVARCHAR(50)                    NULL,
        [RouteOfAdministration] NVARCHAR(100)                   NULL,
        [IsActive]              BIT             NOT NULL        DEFAULT 1,
        [CreatedDate]           DATETIME2       NOT NULL        DEFAULT GETDATE(),
        [CreatedBy]             INT             NOT NULL        DEFAULT 0,
        [ModifiedDate]          DATETIME2       NULL,
        [ModifiedBy]            INT             NULL,
        CONSTRAINT [PK_EmrMedicationMaster] PRIMARY KEY CLUSTERED ([MedicationId] ASC)
    );
    PRINT 'Table EmrMedicationMaster created.';
END
ELSE
    PRINT 'Table EmrMedicationMaster already exists.';
GO

-- ─────────────────────────────────────────
-- 3. Seed Investigation Data
-- ─────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM [dbo].[EmrInvestigationMaster])
BEGIN
    INSERT INTO [dbo].[EmrInvestigationMaster] ([InvestigationName], [Category], [Unit], [NormalRange], [Description])
    VALUES
    -- Haematology
    ('Complete Blood Count (CBC)',      'Haematology',      'cells/µL',     'See report',       'Full blood panel including WBC, RBC, Hb, Platelets'),
    ('Erythrocyte Sedimentation Rate (ESR)',  'Haematology', 'mm/hr',       'M: 0-22, F: 0-29', 'Marker for inflammation'),
    ('Haemoglobin (Hb)',                'Haematology',      'g/dL',         'M: 13.5-17.5, F: 12-15.5', 'Oxygen-carrying protein in RBC'),
    ('Platelet Count',                  'Haematology',      'x10³/µL',      '150-400',          'Clotting function assessment'),
    ('Peripheral Blood Smear',          'Haematology',      'N/A',          'Normal morphology','Microscopic examination of blood cells'),

    -- Biochemistry
    ('Fasting Blood Glucose (FBG)',     'Biochemistry',     'mg/dL',        '70-100',           'Diabetes screening and monitoring'),
    ('HbA1c (Glycated Haemoglobin)',   'Biochemistry',     '%',            '< 5.7',            'Average blood sugar over 3 months'),
    ('Liver Function Test (LFT)',       'Biochemistry',     'IU/L',         'See report',       'Hepatic enzyme panel'),
    ('Renal Function Test (RFT)',       'Biochemistry',     'mg/dL',        'See report',       'Kidney function panel including BUN and Creatinine'),
    ('Lipid Profile',                   'Biochemistry',     'mg/dL',        'See report',       'Cholesterol, HDL, LDL, TG levels'),
    ('Thyroid Function Test (TFT)',     'Biochemistry',     'mIU/L',        'TSH: 0.4-4.0',     'Thyroid hormone evaluation'),
    ('Serum Uric Acid',                 'Biochemistry',     'mg/dL',        'M: 3.4-7.0, F: 2.4-6.0', 'Gout assessment'),
    ('C-Reactive Protein (CRP)',        'Biochemistry',     'mg/L',         '< 10',             'Acute phase inflammatory marker'),
    ('Serum Ferritin',                  'Biochemistry',     'ng/mL',        'M: 24-336, F: 11-307', 'Iron storage protein'),
    ('Serum Electrolytes',              'Biochemistry',     'mEq/L',        'Na: 136-145, K: 3.5-5.1', 'Sodium, Potassium, Chloride balance'),

    -- Microbiology
    ('Urine Routine & Microscopy',      'Microbiology',     'N/A',          'Normal',           'Urine physical, chemical, and microscopic analysis'),
    ('Blood Culture & Sensitivity',    'Microbiology',     'N/A',          'No growth',        'Identifies blood-borne pathogens'),
    ('Sputum Culture & Sensitivity',   'Microbiology',     'N/A',          'Normal flora',     'Identifies respiratory pathogens'),

    -- Radiology
    ('Chest X-Ray (PA View)',           'Radiology',        'N/A',          'Normal',           'Pulmonary and cardiac assessment'),
    ('Ultrasound Abdomen & Pelvis',     'Radiology',        'N/A',          'Normal',           'Abdominal organ evaluation'),
    ('ECG (12-Lead)',                   'Cardiology',       'N/A',          'Normal sinus rhythm', 'Electrical activity of the heart'),
    ('Echocardiography',                'Cardiology',       'N/A',          'Normal',           'Heart structure and function assessment');

    PRINT 'Investigation seed data inserted.';
END
ELSE
    PRINT 'Investigation seed data already exists.';
GO

-- ─────────────────────────────────────────
-- 4. Seed Medication Data
-- ─────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM [dbo].[EmrMedicationMaster])
BEGIN
    INSERT INTO [dbo].[EmrMedicationMaster] ([MedicationName], [GenericName], [Category], [Strength], [Unit], [RouteOfAdministration])
    VALUES
    -- Analgesics / Anti-inflammatory
    ('Paracetamol 500mg Tab',       'Paracetamol',          'Analgesic/Antipyretic',    '500 mg',   'Tab',  'Oral'),
    ('Ibuprofen 400mg Tab',         'Ibuprofen',            'NSAID',                    '400 mg',   'Tab',  'Oral'),
    ('Diclofenac 75mg Inj',         'Diclofenac Sodium',    'NSAID',                    '75 mg',    'Amp',  'IM / IV'),
    ('Aspirin 75mg Tab',            'Aspirin',              'Antiplatelet',             '75 mg',    'Tab',  'Oral'),

    -- Antibiotics
    ('Amoxicillin 500mg Cap',       'Amoxicillin',          'Antibiotic',               '500 mg',   'Cap',  'Oral'),
    ('Azithromycin 500mg Tab',      'Azithromycin',         'Antibiotic',               '500 mg',   'Tab',  'Oral'),
    ('Ciprofloxacin 500mg Tab',     'Ciprofloxacin',        'Antibiotic',               '500 mg',   'Tab',  'Oral'),
    ('Metronidazole 400mg Tab',     'Metronidazole',        'Antibiotic/Antiprotozoal', '400 mg',   'Tab',  'Oral'),
    ('Ceftriaxone 1g Inj',          'Ceftriaxone',          'Antibiotic',               '1 g',      'Vial', 'IV / IM'),

    -- Antidiabetics
    ('Metformin 500mg Tab',         'Metformin HCl',        'Antidiabetic',             '500 mg',   'Tab',  'Oral'),
    ('Glimepiride 2mg Tab',         'Glimepiride',          'Antidiabetic',             '2 mg',     'Tab',  'Oral'),
    ('Insulin Regular 100IU/mL',    'Insulin Regular',      'Antidiabetic',             '100 IU/mL','Vial', 'SC / IV'),

    -- Antihypertensives
    ('Amlodipine 5mg Tab',          'Amlodipine',           'Antihypertensive',         '5 mg',     'Tab',  'Oral'),
    ('Atenolol 50mg Tab',           'Atenolol',             'Beta-Blocker',             '50 mg',    'Tab',  'Oral'),
    ('Losartan 50mg Tab',           'Losartan Potassium',   'ARB / Antihypertensive',   '50 mg',    'Tab',  'Oral'),
    ('Furosemide 40mg Tab',         'Furosemide',           'Diuretic',                 '40 mg',    'Tab',  'Oral'),

    -- GI / Others
    ('Omeprazole 20mg Cap',         'Omeprazole',           'Proton Pump Inhibitor',    '20 mg',    'Cap',  'Oral'),
    ('Ondansetron 4mg Tab',         'Ondansetron',          'Antiemetic',               '4 mg',     'Tab',  'Oral'),
    ('Levocetirizine 5mg Tab',      'Levocetirizine',       'Antihistamine',            '5 mg',     'Tab',  'Oral'),
    ('Salbutamol 100mcg Inhaler',   'Salbutamol',           'Bronchodilator',           '100 mcg',  'Inhaler','Inhalation');

    PRINT 'Medication seed data inserted.';
END
ELSE
    PRINT 'Medication seed data already exists.';
GO

PRINT 'Script 49 completed successfully.';
GO
