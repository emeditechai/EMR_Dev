-- =============================================
-- Script : 2146_microbiology_culture_tests_config.sql
-- Purpose: Culture & Sensitivity investigations (master configuration only).
--          Reporting_Type 'Culture' marks tests whose results are organism +
--          antibiotic susceptibility rather than a single value. Result entry
--          for this type is part of the reporting build, not this script.
-- =============================================

DECLARE @Micro INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptName = 'Microbiology');
DECLARE @Cat   INT = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE Category_Name = 'Microbiology & Serology' AND IsDeleted = 0);
DECLARE @SubBU INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Blood & Urine Culture Sensitivity' AND IsDeleted = 0);

-- Sub-category for cultures from other specimens
DECLARE @SubOther INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Culture & Sensitivity - Other Specimens' AND Category_ID = @Cat AND IsDeleted = 0);
IF @SubOther IS NULL
BEGIN
    DECLARE @NextSub INT = (SELECT ISNULL(MAX(SubCategory_ID), 0) + 1 FROM dbo.LabTestSubCategoryMaster);
    INSERT INTO dbo.LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted)
    VALUES ('Culture & Sensitivity - Other Specimens', 'LSUBCAT' + RIGHT('0000' + CAST(@NextSub AS NVARCHAR(10)), 4), @Cat, 6, 1, 1, GETDATE(), 0);
    SET @SubOther = SCOPE_IDENTITY();
END

DECLARE @T TABLE (Code NVARCHAR(50), Name NVARCHAR(200), Sub INT, Sample NVARCHAR(100), Tat INT, Mrp DECIMAL(10,2));
INSERT INTO @T VALUES
 ('MIC-CS-001', 'Urine Culture & Sensitivity',        @SubBU,    'Mid-Stream Clean Catch Urine', 72,  600),
 ('MIC-CS-002', 'Blood Culture & Sensitivity',        @SubBU,    'Blood Culture Bottle',         120, 1200),
 ('MIC-CS-003', 'Sputum Culture & Sensitivity',       @SubOther, 'Sputum Sample',                72,  700),
 ('MIC-CS-004', 'Pus / Wound Culture & Sensitivity',  @SubOther, 'Pus / Wound Swab',             72,  700),
 ('MIC-CS-005', 'Stool Culture & Sensitivity',        @SubOther, 'Stool Sample',                 72,  700),
 ('MIC-CS-006', 'CSF Culture & Sensitivity',          @SubOther, 'Cerebrospinal Fluid (CSF)',    72,  900),
 ('MIC-CS-007', 'Body Fluid Culture & Sensitivity',   @SubOther, 'Body Fluid (Pleural/Ascitic)', 72,  900);

INSERT INTO dbo.LabInvestigationMaster
    (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Sample_Type_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
SELECT t.Code, t.Name, @Micro, @Cat, t.Sub, s.Sample_Type_ID, 'Culture', t.Tat, 1, 0, 0, t.Mrp, 1, 0, 'All', 0, 0, 0, 0, 1, GETDATE(), 0
FROM @T t
LEFT JOIN dbo.LabSampleTypeMaster s ON s.Sample_Name = t.Sample AND s.IsDeleted = 0
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster i WHERE i.Test_Code = t.Code);
GO

PRINT 'Culture & Sensitivity tests configured.';
