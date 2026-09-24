-- =============================================
-- Seed Radiology Department, Category, and Investigation Tests
-- =============================================

-- 1. Insert Radiology Department (if not exists)
IF NOT EXISTS (SELECT 1 FROM DepartmentMaster WHERE DeptName = 'Radiology')
BEGIN
    INSERT INTO DepartmentMaster (DeptName, IsActive)
    VALUES ('Radiology', 1);
END
GO

-- 2. Insert Radiology Test Category (if not exists)
IF NOT EXISTS (SELECT 1 FROM LabTestCategoryMaster WHERE Category_Name = 'Radiology')
BEGIN
    INSERT INTO LabTestCategoryMaster (Category_Name, CompanyId, IsActive, CreatedDate)
    VALUES ('Radiology', 1, 1, GETDATE());
END
GO

-- 3. Insert Sub Categories for Radiology
DECLARE @RadiologyCatId INT = (SELECT TOP 1 Category_ID FROM LabTestCategoryMaster WHERE Category_Name = 'Radiology');

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'X-Ray' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, Category_ID, CompanyId, IsActive, CreatedDate) VALUES ('X-Ray', @RadiologyCatId, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'CT Scan' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, Category_ID, CompanyId, IsActive, CreatedDate) VALUES ('CT Scan', @RadiologyCatId, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'MRI' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, Category_ID, CompanyId, IsActive, CreatedDate) VALUES ('MRI', @RadiologyCatId, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'USG' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, Category_ID, CompanyId, IsActive, CreatedDate) VALUES ('USG', @RadiologyCatId, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'Mammography' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, Category_ID, CompanyId, IsActive, CreatedDate) VALUES ('Mammography', @RadiologyCatId, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'Doppler' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, Category_ID, CompanyId, IsActive, CreatedDate) VALUES ('Doppler', @RadiologyCatId, 1, 1, GETDATE());
GO

-- 4. Insert Radiology Investigation Tests
DECLARE @DeptId INT = (SELECT TOP 1 DeptId FROM DepartmentMaster WHERE DeptName = 'Radiology');
DECLARE @CatId INT = (SELECT TOP 1 Category_ID FROM LabTestCategoryMaster WHERE Category_Name = 'Radiology');
DECLARE @SubXRay INT = (SELECT TOP 1 SubCategory_ID FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'X-Ray' AND Category_ID = @CatId);
DECLARE @SubCT INT = (SELECT TOP 1 SubCategory_ID FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'CT Scan' AND Category_ID = @CatId);
DECLARE @SubMRI INT = (SELECT TOP 1 SubCategory_ID FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'MRI' AND Category_ID = @CatId);
DECLARE @SubUSG INT = (SELECT TOP 1 SubCategory_ID FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'USG' AND Category_ID = @CatId);
DECLARE @SubMammo INT = (SELECT TOP 1 SubCategory_ID FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'Mammography' AND Category_ID = @CatId);
DECLARE @SubDoppler INT = (SELECT TOP 1 SubCategory_ID FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'Doppler' AND Category_ID = @CatId);

-- X-Ray Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-XR-001', 'X-Ray Chest PA', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-XR-002', 'X-Ray Abdomen AP', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-XR-003', 'X-Ray Spine (Cervical/Lumbar)', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-XR-004', 'X-Ray Knee (Both)', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 1, 1, GETDATE());

-- CT Scan Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-CT-001', 'CT Brain (Plain)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-CT-002', 'CT Brain (Contrast)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-CT-003', 'CT Chest (HRCT)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-CT-004', 'CT Abdomen & Pelvis (Contrast)', @DeptId, @CatId, @SubCT, 'Image', 6, 1, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-005')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-CT-005', 'CT PNS (Plain)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 1, 1, GETDATE());

-- MRI Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-MR-001', 'MRI Brain (Plain)', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-MR-002', 'MRI Brain (Contrast)', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-MR-003', 'MRI Lumbar Spine', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, Is_Consent_Required, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-MR-004', 'MRI Knee', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 1, 1, GETDATE());

-- USG Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-US-001', 'USG Abdomen (Whole)', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-US-002', 'USG Pelvis', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-US-003', 'USG Obstetric (Anomaly Scan)', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-US-004', 'USG Thyroid', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-005')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-US-005', 'USG KUB', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 1, 1, GETDATE());

-- Mammography
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MG-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-MG-001', 'Mammography (Bilateral)', @DeptId, @CatId, @SubMammo, 'Image', 4, 1, 1, 1, GETDATE());

-- Doppler
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-DP-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-DP-001', 'Doppler Carotid (Bilateral)', @DeptId, @CatId, @SubDoppler, 'Image', 3, 1, 1, 1, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-DP-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, IsActive, CompanyId, CreatedDate)
    VALUES ('RAD-DP-002', 'Doppler Lower Limb Venous', @DeptId, @CatId, @SubDoppler, 'Image', 3, 1, 1, 1, GETDATE());

GO
