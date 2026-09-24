-- =============================================
-- Seed Radiology Category, Sub-Categories, and Investigation Tests
-- Radiology department (DeptId=14) already exists
-- =============================================

-- 1. Insert Radiology Test Category (if not exists)
DECLARE @RadDeptId INT = (SELECT TOP 1 DeptId FROM DepartmentMaster WHERE DeptName = 'Radiology');

IF NOT EXISTS (SELECT 1 FROM LabTestCategoryMaster WHERE Category_Name = 'Radiology')
BEGIN
    INSERT INTO LabTestCategoryMaster (Category_Name, Category_Code, Department_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted)
    VALUES ('Radiology', 'RAD', @RadDeptId, 1, 1, 1, GETDATE(), 0);
END
GO

-- 2. Insert Sub Categories for Radiology
DECLARE @RadiologyCatId INT = (SELECT TOP 1 Category_ID FROM LabTestCategoryMaster WHERE Category_Name = 'Radiology');

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'X-Ray' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted) VALUES ('X-Ray', 'XR', @RadiologyCatId, 1, 1, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'CT Scan' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted) VALUES ('CT Scan', 'CT', @RadiologyCatId, 2, 1, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'MRI' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted) VALUES ('MRI', 'MRI', @RadiologyCatId, 3, 1, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'USG' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted) VALUES ('USG', 'USG', @RadiologyCatId, 4, 1, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'Mammography' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted) VALUES ('Mammography', 'MAM', @RadiologyCatId, 5, 1, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabTestSubCategoryMaster WHERE SubCategory_Name = 'Doppler' AND Category_ID = @RadiologyCatId)
    INSERT INTO LabTestSubCategoryMaster (SubCategory_Name, SubCategory_Code, Category_ID, Display_Order, CompanyId, Status, CreatedDate, IsDeleted) VALUES ('Doppler', 'DOP', @RadiologyCatId, 6, 1, 1, GETDATE(), 0);
GO

-- 3. Insert Radiology Investigation Tests
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
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-XR-001', 'X-Ray Chest PA', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-XR-002', 'X-Ray Abdomen AP', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-XR-003', 'X-Ray Spine (Cervical/Lumbar)', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-XR-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-XR-004', 'X-Ray Knee (Both)', @DeptId, @CatId, @SubXRay, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

-- CT Scan Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-CT-001', 'CT Brain (Plain)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-CT-002', 'CT Brain (Contrast)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 0, 0, 1, 0, 'Both', 0, 1, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-CT-003', 'CT Chest (HRCT)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-CT-004', 'CT Abdomen & Pelvis (Contrast)', @DeptId, @CatId, @SubCT, 'Image', 6, 1, 0, 0, 0, 1, 0, 'Both', 0, 1, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-CT-005')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-CT-005', 'CT PNS (Plain)', @DeptId, @CatId, @SubCT, 'Image', 4, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

-- MRI Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-MR-001', 'MRI Brain (Plain)', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-MR-002', 'MRI Brain (Contrast)', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 0, 0, 1, 0, 'Both', 0, 1, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-MR-003', 'MRI Lumbar Spine', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MR-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-MR-004', 'MRI Knee', @DeptId, @CatId, @SubMRI, 'Image', 6, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

-- USG Tests
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-US-001', 'USG Abdomen (Whole)', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-US-002', 'USG Pelvis', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-003')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-US-003', 'USG Obstetric (Anomaly Scan)', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Female', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-004')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-US-004', 'USG Thyroid', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-US-005')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-US-005', 'USG KUB', @DeptId, @CatId, @SubUSG, 'Image', 2, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

-- Mammography
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-MG-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-MG-001', 'Mammography (Bilateral)', @DeptId, @CatId, @SubMammo, 'Image', 4, 1, 0, 0, 0, 1, 0, 'Female', 0, 0, 0, 0, 1, GETDATE(), 0);

-- Doppler
IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-DP-001')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-DP-001', 'Doppler Carotid (Bilateral)', @DeptId, @CatId, @SubDoppler, 'Image', 3, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

IF NOT EXISTS (SELECT 1 FROM LabInvestigationMaster WHERE Test_Code = 'RAD-DP-002')
    INSERT INTO LabInvestigationMaster (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
    VALUES ('RAD-DP-002', 'Doppler Lower Limb Venous', @DeptId, @CatId, @SubDoppler, 'Image', 3, 1, 0, 0, 0, 1, 0, 'Both', 0, 0, 0, 0, 1, GETDATE(), 0);

GO
