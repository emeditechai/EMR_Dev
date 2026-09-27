-- =============================================
-- Script : 2139_microbiology_foundation_samples_subcategories.sql
-- Purpose: Sample types and sub-categories needed by the microbiology build
--          (parametric tests, descriptive stains, culture & sensitivity).
-- CAP/NABL: Container, volume, storage temperature and rejection criteria
--           captured for every specimen (pre-analytical phase).
-- =============================================

-- 1. Sample types
DECLARE @Samples TABLE (Name NVARCHAR(100), Container NVARCHAR(100), Vol DECIMAL(10,2), Unit NVARCHAR(20), Req NVARCHAR(50), Temp NVARCHAR(50), Reject NVARCHAR(500));
INSERT INTO @Samples VALUES
 ('Stool Sample',               'Sterile Wide-Mouth Container', 10,  'g',      '10 g (pea-size)',     'Room Temp (process within 1 hr)',  'Contaminated with urine, Dried specimen, Delayed > 2 hrs'),
 ('Semen Sample',               'Sterile Wide-Mouth Container', 2,   'mL',     'Complete ejaculate',  '37°C (process within 1 hr)',       'Incomplete collection, Condom-collected, Delayed > 1 hr'),
 ('Cerebrospinal Fluid (CSF)',  'Sterile Screw-Cap Tube',       2,   'mL',     '1-2 mL per tube',     'Room Temp (never refrigerate)',    'Insufficient volume, Unlabelled tube, Delayed transport'),
 ('Sputum Sample',              'Sterile Wide-Mouth Container', 5,   'mL',     '3-5 mL early morning','2-8°C',                            'Saliva only (<10 SEC/LPF criteria), Leaking container'),
 ('Blood Culture Bottle',       'Aerobic/Anaerobic BC Bottle',  10,  'mL',     '8-10 mL per bottle',  'Room Temp (do not refrigerate)',   'Under/over-filled bottle, Unlabelled, Delayed loading > 2 hrs'),
 ('Pus / Wound Swab',           'Sterile Swab with Transport Medium', 1, 'Swab','1 Swab',             'Room Temp',                        'Dry swab, No transport medium, Delayed > 2 hrs'),
 ('Body Fluid (Pleural/Ascitic)','Sterile Screw-Cap Container', 10,  'mL',     '10 mL',               '2-8°C',                            'Clotted specimen, Insufficient volume, Leaking container');

DECLARE @Name NVARCHAR(100), @Container NVARCHAR(100), @Vol DECIMAL(10,2), @Unit NVARCHAR(20), @Req NVARCHAR(50), @Temp NVARCHAR(50), @Reject NVARCHAR(500);
DECLARE @Next INT, @Code NVARCHAR(50);
DECLARE s CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM @Samples;
OPEN s;
FETCH NEXT FROM s INTO @Name, @Container, @Vol, @Unit, @Req, @Temp, @Reject;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Name = @Name AND IsDeleted = 0)
    BEGIN
        SELECT @Next = ISNULL(MAX(Sample_Type_ID), 0) + 1 FROM dbo.LabSampleTypeMaster;
        SET @Code = 'SMP' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
        WHILE EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster WHERE Sample_Code = @Code)
        BEGIN
            SET @Next += 1;
            SET @Code = 'SMP' + RIGHT('0000' + CAST(@Next AS NVARCHAR(10)), 4);
        END
        INSERT INTO dbo.LabSampleTypeMaster
            (CompanyId, Sample_Name, Sample_Code, Container_Type, Volume_Value, Volume_Unit, Volume_Required, Storage_Temperature, Rejection_Criteria, Display_Order, Status, CreatedDate, IsDeleted)
        VALUES
            (1, @Name, @Code, @Container, @Vol, @Unit, @Req, @Temp, @Reject, 1, 1, GETDATE(), 0);
    END
    FETCH NEXT FROM s INTO @Name, @Container, @Vol, @Unit, @Req, @Temp, @Reject;
END
CLOSE s; DEALLOCATE s;
GO

-- 2. Sub-categories
DECLARE @ClinPathCat INT = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE Category_Name = 'Clinical Pathology & Urinalysis' AND IsDeleted = 0);
DECLARE @MicroCat    INT = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE Category_Name = 'Microbiology & Serology' AND IsDeleted = 0);
DECLARE @NextSub INT, @SubCode NVARCHAR(50);

IF NOT EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Body Fluid & CSF Analysis' AND Category_ID = @ClinPathCat AND IsDeleted = 0)
BEGIN
    SELECT @NextSub = ISNULL(MAX(SubCategory_ID), 0) + 1 FROM dbo.LabTestSubCategoryMaster;
    SET @SubCode = 'LSUBCAT' + RIGHT('0000' + CAST(@NextSub AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted)
    VALUES ('Body Fluid & CSF Analysis', @SubCode, @ClinPathCat, 4, 1, 1, GETDATE(), 0);
END

IF NOT EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Microscopy & Special Stains' AND Category_ID = @MicroCat AND IsDeleted = 0)
BEGIN
    SELECT @NextSub = ISNULL(MAX(SubCategory_ID), 0) + 1 FROM dbo.LabTestSubCategoryMaster;
    SET @SubCode = 'LSUBCAT' + RIGHT('0000' + CAST(@NextSub AS NVARCHAR(10)), 4);
    INSERT INTO dbo.LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted)
    VALUES ('Microscopy & Special Stains', @SubCode, @MicroCat, 5, 1, 1, GETDATE(), 0);
END
GO

PRINT 'Microbiology foundation: sample types and sub-categories ready.';
