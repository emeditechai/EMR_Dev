-- =================================================================================
-- Script Name: 2012_clean_and_seed_lab_profiles.sql
-- Description: Cleans Profile Header/Detail data and seeds standard Investigation
--              Profiles (CBC, LFT, Lipid Profile, KFT, Thyroid Profile) with component tests.
-- Database:    Dev_EMR (SQL Server)
-- =================================================================================

USE [Dev_EMR];
GO

SET NOCOUNT ON;

PRINT '1. Cleaning existing Investigation Profile Header and Detail records...';

-- 1. Clean Profile Data
DELETE FROM [dbo].[LabInvestigationProfileDetail];
DELETE FROM [dbo].[LabInvestigationProfileHeader];

DBCC CHECKIDENT ('[dbo].[LabInvestigationProfileDetail]', RESEED, 0);
DBCC CHECKIDENT ('[dbo].[LabInvestigationProfileHeader]', RESEED, 0);

PRINT 'Profile tables cleaned and reseeded.';

-- 2. Mark profile tests in dbo.LabInvestigationMaster as Is_Profile_Test = 1
UPDATE [dbo].[LabInvestigationMaster]
SET [Is_Profile_Test] = 1
WHERE [Test_Name] LIKE '%Complete Blood Count%' 
   OR [Test_Name] LIKE '%Liver Function Test%' 
   OR [Test_Name] LIKE '%Lipid Profile%' 
   OR [Test_Name] LIKE '%Renal Function Test%' 
   OR [Test_Name] LIKE '%Thyroid Profile%';

PRINT 'Updated Is_Profile_Test = 1 for parent profile tests in LabInvestigationMaster.';

-- 3. Helper to insert component tests if not existing
DECLARE @NextTestNo INT;
SELECT @NextTestNo = ISNULL(MAX(CAST(RIGHT([Test_Code], 4) AS INT)), 0) FROM [dbo].[LabInvestigationMaster] WHERE [Test_Code] LIKE 'TST%';

-- Helper Table for Component Test Definitions
DECLARE @Components TABLE (
    [Category_ID] INT,
    [Sample_Type_ID] INT,
    [Unit_ID] INT,
    [Test_Name] NVARCHAR(200),
    [Reporting_Type] NVARCHAR(50),
    [MRP] DECIMAL(18,2)
);

-- CBC Components (Category: 2 Hematology, Sample: 1 EDTA Whole Blood)
INSERT INTO @Components VALUES
(2, 1, 2, 'Hemoglobin (Hb)', 'Numeric', 100.00),
(2, 1, 11, 'Total Leukocyte Count (TLC / WBC)', 'Numeric', 120.00),
(2, 1, 14, 'Neutrophils', 'Numeric', 60.00),
(2, 1, 14, 'Lymphocytes', 'Numeric', 60.00),
(2, 1, 14, 'Eosinophils', 'Numeric', 60.00),
(2, 1, 14, 'Monocytes', 'Numeric', 60.00),
(2, 1, 14, 'Basophils', 'Numeric', 60.00),
(2, 1, 13, 'Red Blood Cell Count (RBC)', 'Numeric', 120.00),
(2, 1, 14, 'Packed Cell Volume (PCV / Hematocrit)', 'Numeric', 100.00),
(2, 1, 20, 'Mean Corpuscular Volume (MCV)', 'Numeric', 80.00),
(2, 1, 9, 'Mean Corpuscular Hemoglobin (MCH)', 'Numeric', 80.00),
(2, 1, 2, 'MCHC', 'Numeric', 80.00),
(2, 1, 12, 'Platelet Count', 'Numeric', 150.00),
(2, 1, 15, 'Erythrocyte Sedimentation Rate (ESR)', 'Numeric', 100.00),

-- LFT Components (Category: 1 Clinical Biochemistry, Sample: 2 Serum)
(1, 2, 1, 'Serum Bilirubin Total', 'Numeric', 120.00),
(1, 2, 1, 'Serum Bilirubin Direct', 'Numeric', 120.00),
(1, 2, 1, 'Serum Bilirubin Indirect', 'Numeric', 120.00),
(1, 2, 6, 'SGOT / AST', 'Numeric', 150.00),
(1, 2, 6, 'SGPT / ALT', 'Numeric', 150.00),
(1, 2, 6, 'Alkaline Phosphatase (ALP)', 'Numeric', 160.00),
(1, 2, 2, 'Total Protein', 'Numeric', 120.00),
(1, 2, 2, 'Serum Albumin', 'Numeric', 120.00),
(1, 2, 2, 'Serum Globulin', 'Numeric', 120.00),
(1, 2, 18, 'Albumin / Globulin (A/G) Ratio', 'Numeric', 100.00),

-- Lipid Profile Components (Category: 1 Clinical Biochemistry, Sample: 2 Serum)
(1, 2, 1, 'Total Cholesterol', 'Numeric', 160.00),
(1, 2, 1, 'HDL Cholesterol (Good Cholesterol)', 'Numeric', 180.00),
(1, 2, 1, 'LDL Cholesterol (Bad Cholesterol)', 'Numeric', 180.00),
(1, 2, 1, 'VLDL Cholesterol', 'Numeric', 160.00),
(1, 2, 1, 'Serum Triglycerides', 'Numeric', 180.00),
(1, 2, 18, 'Total Cholesterol / HDL Ratio', 'Numeric', 100.00),
(1, 2, 18, 'LDL / HDL Ratio', 'Numeric', 100.00),

-- Thyroid Components (Category: 5 Endocrinology, Sample: 2 Serum)
(5, 2, 8, 'Total Triiodothyronine (T3)', 'Numeric', 250.00),
(5, 2, 7, 'Total Thyroxine (T4)', 'Numeric', 250.00),
(5, 2, 10, 'Thyroid Stimulating Hormone (TSH, Ultrasensitive)', 'Numeric', 300.00),

-- RFT / KFT Components (Category: 1 Clinical Biochemistry, Sample: 2 Serum)
(1, 2, 1, 'Blood Urea', 'Numeric', 150.00),
(1, 2, 1, 'Blood Urea Nitrogen (BUN)', 'Numeric', 150.00),
(1, 2, 1, 'Serum Uric Acid', 'Numeric', 160.00),
(1, 2, 1, 'Serum Calcium', 'Numeric', 180.00),
(1, 2, 1, 'Serum Phosphorus', 'Numeric', 180.00),
(1, 2, 16, 'Serum Sodium (Na+)', 'Numeric', 180.00),
(1, 2, 16, 'Serum Potassium (K+)', 'Numeric', 180.00),
(1, 2, 16, 'Serum Chloride (Cl-)', 'Numeric', 180.00);

-- Cursor to insert missing components
DECLARE @CatID INT, @SampleID INT, @UnitID INT, @TName NVARCHAR(200), @RType NVARCHAR(50), @TMrp DECIMAL(18,2);

DECLARE comp_cursor CURSOR FOR 
SELECT [Category_ID], [Sample_Type_ID], [Unit_ID], [Test_Name], [Reporting_Type], [MRP] 
FROM @Components;

OPEN comp_cursor;
FETCH NEXT FROM comp_cursor INTO @CatID, @SampleID, @UnitID, @TName, @RType, @TMrp;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM [dbo].[LabInvestigationMaster] WHERE [Test_Name] = @TName AND [IsDeleted] = 0)
    BEGIN
        SET @NextTestNo = @NextTestNo + 1;
        DECLARE @TCode VARCHAR(50) = 'TST' + RIGHT('0000' + CAST(@NextTestNo AS VARCHAR(4)), 4);

        INSERT INTO [dbo].[LabInvestigationMaster]
        (
            [Test_Code], [Test_Name], [Department_ID], [Category_ID], [Sample_Type_ID], [Unit_ID],
            [Reporting_Type], [TAT_Hours], [NABL_Accredited], [Is_Outsourced], [Is_Profile_Test],
            [MRP], [Status], [IsDeleted], [CreatedDate]
        )
        VALUES
        (
            @TCode, @TName, 13, @CatID, @SampleID, @UnitID,
            @RType, 24, 1, 0, 0,
            @TMrp, 1, 0, GETDATE()
        );
    END
    FETCH NEXT FROM comp_cursor INTO @CatID, @SampleID, @UnitID, @TName, @RType, @TMrp;
END

CLOSE comp_cursor;
DEALLOCATE comp_cursor;

PRINT 'Component investigation tests verified / inserted.';

-- 4. Insert Profile Headers & Details

-- 4A. Profile: Complete Blood Count (CBC)
DECLARE @CbcTestID INT, @CbcProfileID INT;
SELECT TOP 1 @CbcTestID = [Test_ID] FROM [dbo].[LabInvestigationMaster] WHERE [Test_Name] LIKE '%Complete Blood Count%' AND [IsDeleted] = 0;

IF @CbcTestID IS NOT NULL
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    (
        [CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [Test_ID],
        [MRP], [Discount_Pct], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited],
        [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate]
    )
    VALUES
    (
        1, 'PRF0001', 'Complete Blood Count (CBC) with ESR', 'Profile', @CbcTestID,
        450.00, 0.00, 'All', 12, 1,
        1, 1, 0, GETDATE()
    );
    SET @CbcProfileID = SCOPE_IDENTITY();

    -- Insert Details
    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @CbcProfileID, [Test_ID], ROW_NUMBER() OVER (ORDER BY [Test_ID]), 0, GETDATE()
    FROM [dbo].[LabInvestigationMaster]
    WHERE [Test_Name] IN (
        'Hemoglobin (Hb)', 'Total Leukocyte Count (TLC / WBC)', 'Neutrophils', 'Lymphocytes',
        'Eosinophils', 'Monocytes', 'Basophils', 'Red Blood Cell Count (RBC)',
        'Packed Cell Volume (PCV / Hematocrit)', 'Mean Corpuscular Volume (MCV)',
        'Mean Corpuscular Hemoglobin (MCH)', 'MCHC', 'Platelet Count', 'Erythrocyte Sedimentation Rate (ESR)'
    ) AND [IsDeleted] = 0;

    PRINT 'Seeded Profile: Complete Blood Count (CBC) with Details.';
END

-- 4B. Profile: Liver Function Test (LFT)
DECLARE @LftTestID INT, @LftProfileID INT;
SELECT TOP 1 @LftTestID = [Test_ID] FROM [dbo].[LabInvestigationMaster] WHERE [Test_Name] LIKE '%Liver Function Test%' AND [IsDeleted] = 0;

IF @LftTestID IS NOT NULL
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    (
        [CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [Test_ID],
        [MRP], [Discount_Pct], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited],
        [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate]
    )
    VALUES
    (
        1, 'PRF0002', 'Liver Function Test (LFT)', 'Profile', @LftTestID,
        950.00, 0.00, 'All', 24, 1,
        2, 1, 0, GETDATE()
    );
    SET @LftProfileID = SCOPE_IDENTITY();

    -- Insert Details
    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @LftProfileID, [Test_ID], ROW_NUMBER() OVER (ORDER BY [Test_ID]), 0, GETDATE()
    FROM [dbo].[LabInvestigationMaster]
    WHERE [Test_Name] IN (
        'Serum Bilirubin Total', 'Serum Bilirubin Direct', 'Serum Bilirubin Indirect',
        'SGOT / AST', 'SGPT / ALT', 'Alkaline Phosphatase (ALP)',
        'Total Protein', 'Serum Albumin', 'Serum Globulin', 'Albumin / Globulin (A/G) Ratio'
    ) AND [IsDeleted] = 0;

    PRINT 'Seeded Profile: Liver Function Test (LFT) with Details.';
END

-- 4C. Profile: Lipid Profile Total
DECLARE @LipidTestID INT, @LipidProfileID INT;
SELECT TOP 1 @LipidTestID = [Test_ID] FROM [dbo].[LabInvestigationMaster] WHERE [Test_Name] LIKE '%Lipid Profile%' AND [IsDeleted] = 0;

IF @LipidTestID IS NOT NULL
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    (
        [CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [Test_ID],
        [MRP], [Discount_Pct], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited],
        [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate]
    )
    VALUES
    (
        1, 'PRF0003', 'Lipid Profile Total', 'Profile', @LipidTestID,
        850.00, 0.00, 'All', 24, 1,
        3, 1, 0, GETDATE()
    );
    SET @LipidProfileID = SCOPE_IDENTITY();

    -- Insert Details
    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @LipidProfileID, [Test_ID], ROW_NUMBER() OVER (ORDER BY [Test_ID]), 0, GETDATE()
    FROM [dbo].[LabInvestigationMaster]
    WHERE [Test_Name] IN (
        'Total Cholesterol', 'HDL Cholesterol (Good Cholesterol)', 'LDL Cholesterol (Bad Cholesterol)',
        'VLDL Cholesterol', 'Serum Triglycerides', 'Total Cholesterol / HDL Ratio', 'LDL / HDL Ratio'
    ) AND [IsDeleted] = 0;

    PRINT 'Seeded Profile: Lipid Profile Total with Details.';
END

-- 4D. Profile: Thyroid Profile (T3, T4, TSH)
DECLARE @ThyroidTestID INT, @ThyroidProfileID INT;
SELECT TOP 1 @ThyroidTestID = [Test_ID] FROM [dbo].[LabInvestigationMaster] WHERE [Test_Name] LIKE '%Thyroid Profile%' AND [IsDeleted] = 0;

IF @ThyroidTestID IS NOT NULL
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    (
        [CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [Test_ID],
        [MRP], [Discount_Pct], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited],
        [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate]
    )
    VALUES
    (
        1, 'PRF0004', 'Thyroid Profile (T3, T4, TSH)', 'Profile', @ThyroidTestID,
        750.00, 0.00, 'All', 24, 1,
        4, 1, 0, GETDATE()
    );
    SET @ThyroidProfileID = SCOPE_IDENTITY();

    -- Insert Details
    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @ThyroidProfileID, [Test_ID], ROW_NUMBER() OVER (ORDER BY [Test_ID]), 0, GETDATE()
    FROM [dbo].[LabInvestigationMaster]
    WHERE [Test_Name] IN (
        'Total Triiodothyronine (T3)', 'Total Thyroxine (T4)', 'Thyroid Stimulating Hormone (TSH, Ultrasensitive)'
    ) AND [IsDeleted] = 0;

    PRINT 'Seeded Profile: Thyroid Profile with Details.';
END

-- 4E. Profile: Renal Function Test (KFT / RFT)
DECLARE @KftTestID INT, @KftProfileID INT;
SELECT TOP 1 @KftTestID = [Test_ID] FROM [dbo].[LabInvestigationMaster] WHERE [Test_Name] LIKE '%Renal Function Test%' AND [IsDeleted] = 0;

IF @KftTestID IS NOT NULL
BEGIN
    INSERT INTO [dbo].[LabInvestigationProfileHeader]
    (
        [CompanyId], [Profile_Code], [Profile_Name], [Profile_Type], [Test_ID],
        [MRP], [Discount_Pct], [Applicable_Gender], [Profile_TAT_Hours], [Profile_NABL_Accredited],
        [Report_Print_Sequence], [Status], [IsDeleted], [CreatedDate]
    )
    VALUES
    (
        1, 'PRF0005', 'Renal Function Test (KFT / RFT)', 'Profile', @KftTestID,
        900.00, 0.00, 'All', 24, 1,
        5, 1, 0, GETDATE()
    );
    SET @KftProfileID = SCOPE_IDENTITY();

    -- Insert Details
    INSERT INTO [dbo].[LabInvestigationProfileDetail] ([Profile_ID], [Test_ID], [Sequence], [IsDeleted], [CreatedDate])
    SELECT @KftProfileID, [Test_ID], ROW_NUMBER() OVER (ORDER BY [Test_ID]), 0, GETDATE()
    FROM [dbo].[LabInvestigationMaster]
    WHERE [Test_Name] IN (
        'Blood Urea', 'Blood Urea Nitrogen (BUN)', 'Serum Creatinine',
        'Serum Uric Acid', 'Serum Calcium', 'Serum Phosphorus',
        'Serum Sodium (Na+)', 'Serum Potassium (K+)', 'Serum Chloride (Cl-)'
    ) AND [IsDeleted] = 0;

    PRINT 'Seeded Profile: Renal Function Test (KFT / RFT) with Details.';
END

PRINT 'All Profiles & Component Details seeded successfully!';
GO
