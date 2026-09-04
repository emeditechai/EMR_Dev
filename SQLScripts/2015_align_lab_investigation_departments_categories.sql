-- ====================================================================================================
-- Script: 2015_align_lab_investigation_departments_categories.sql
-- Description: Corrects Department, Category, and SubCategory alignment across Lab master tables
-- ====================================================================================================

-- 1. Align Category Departments in LabTestCategoryMaster
UPDATE LabTestCategoryMaster SET Department_ID = 11 WHERE Category_ID IN (1, 5, 8, 9);
UPDATE LabTestCategoryMaster SET Department_ID = 12 WHERE Category_ID IN (4, 7);
UPDATE LabTestCategoryMaster SET Department_ID = 13 WHERE Category_ID IN (2, 3, 6, 11);
UPDATE LabTestCategoryMaster SET Department_ID = 14 WHERE Category_ID IN (13);

-- 2. Align SubCategory Categories in LabTestSubCategoryMaster
UPDATE LabTestSubCategoryMaster SET Category_ID = 1 WHERE SubCategory_ID IN (1, 2, 3, 4, 5);
UPDATE LabTestSubCategoryMaster SET Category_ID = 2 WHERE SubCategory_ID IN (6, 7, 8);
UPDATE LabTestSubCategoryMaster SET Category_ID = 3 WHERE SubCategory_ID IN (9, 10, 11);
UPDATE LabTestSubCategoryMaster SET Category_ID = 4 WHERE SubCategory_ID IN (12, 13, 14);
UPDATE LabTestSubCategoryMaster SET Category_ID = 5 WHERE SubCategory_ID IN (15, 16, 17);
UPDATE LabTestSubCategoryMaster SET Category_ID = 7 WHERE SubCategory_ID IN (18);
UPDATE LabTestSubCategoryMaster SET Category_ID = 8 WHERE SubCategory_ID IN (19, 21, 22, 23);

-- 3. Align LabInvestigationMaster items with proper Department_ID, Category_ID, SubCategory_ID
-- CBC (Hematology / Pathology)
UPDATE LabInvestigationMaster SET Department_ID = 13, Category_ID = 2, SubCategory_ID = 6 WHERE Test_ID = 1;
-- Sugar / HbA1c (Biochemistry / Diabetic)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 4 WHERE Test_ID IN (2, 3, 4);
-- Lipid Profile (Biochemistry / Lipid)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 1 WHERE Test_ID = 5;
-- LFT (Biochemistry / LFT)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 2 WHERE Test_ID = 6;
-- KFT / Creatinine (Biochemistry / KFT)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 3 WHERE Test_ID IN (7, 9);
-- Thyroid Profile (Biochemistry / Endocrinology)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 5, SubCategory_ID = 15 WHERE Test_ID = 8;
-- Urine Routine (Pathology / Urinalysis)
UPDATE LabInvestigationMaster SET Department_ID = 13, Category_ID = 3, SubCategory_ID = 9 WHERE Test_ID = 10;
-- Dengue Serology (Microbiology / Serology)
UPDATE LabInvestigationMaster SET Department_ID = 12, Category_ID = 4, SubCategory_ID = 14 WHERE Test_ID = 11;
-- RT-PCR (Microbiology / Molecular)
UPDATE LabInvestigationMaster SET Department_ID = 12, Category_ID = 7, SubCategory_ID = 18 WHERE Test_ID = 12;
-- Vitamins (Biochemistry / Endocrinology)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 5, SubCategory_ID = 16 WHERE Test_ID IN (13, 14);
-- hs-CRP (Biochemistry / Cardiac)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 5 WHERE Test_ID = 15;

-- Tests 16-29: Hematology (Pathology / Hematology / CBC & ESR)
UPDATE LabInvestigationMaster SET Department_ID = 13, Category_ID = 2, SubCategory_ID = 6 WHERE Test_ID BETWEEN 16 AND 29;

-- Tests 30-39: Bilirubin, SGOT, SGPT, ALP, Protein, Albumin (Biochemistry / LFT)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 2 WHERE Test_ID BETWEEN 30 AND 39;

-- Tests 40-46: Cholesterol, HDL, LDL, VLDL, Triglycerides (Biochemistry / Lipid)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 1 WHERE Test_ID BETWEEN 40 AND 46;

-- Tests 47-49: T3, T4, TSH (Biochemistry / Endocrinology / Thyroid)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 5, SubCategory_ID = 15 WHERE Test_ID BETWEEN 47 AND 49;

-- Tests 50-57: Urea, BUN, Uric Acid, Calcium, Electrolytes (Biochemistry / KFT)
UPDATE LabInvestigationMaster SET Department_ID = 11, Category_ID = 1, SubCategory_ID = 3 WHERE Test_ID BETWEEN 50 AND 57;
GO
