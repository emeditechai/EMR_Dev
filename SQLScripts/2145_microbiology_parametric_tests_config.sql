-- =============================================
-- Script : 2145_microbiology_parametric_tests_config.sql
-- Purpose: Track A master configuration — field-based microbiology /
--          clinical-pathology tests as investigation profiles:
--          Urine Routine, Stool Routine, Semen Analysis (WHO 6th ed.),
--          CSF Analysis, Body Fluid Analysis, plus standalone Sputum AFB.
--          Picklist parameters use Reporting_Type 'Select' with their
--          allowed values in LabParameterOptionMaster.
-- Note   : Reference ranges for the numeric parameters are NOT seeded here;
--          configure them in Reference Range Master.
-- =============================================

DECLARE @Micro INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptName = 'Microbiology');
DECLARE @Path  INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptName = 'Pathology');
DECLARE @CatCP INT = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE Category_Name = 'Clinical Pathology & Urinalysis' AND IsDeleted = 0);
DECLARE @CatMI INT = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE Category_Name = 'Microbiology & Serology' AND IsDeleted = 0);

DECLARE @SubUrine INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Routine Urine & Microscopic Examination' AND IsDeleted = 0);
DECLARE @SubStool INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Stool Routine & Occult Blood' AND IsDeleted = 0);
DECLARE @SubSemen INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Semen Analysis' AND IsDeleted = 0);
DECLARE @SubFluid INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Body Fluid & CSF Analysis' AND IsDeleted = 0);
DECLARE @SubStain INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Microscopy & Special Stains' AND IsDeleted = 0);

DECLARE @SmpUrine INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Random Urine Sample' AND IsDeleted = 0);
DECLARE @SmpStool INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Stool Sample' AND IsDeleted = 0);
DECLARE @SmpSemen INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Semen Sample' AND IsDeleted = 0);
DECLARE @SmpCsf   INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Cerebrospinal Fluid (CSF)' AND IsDeleted = 0);
DECLARE @SmpFluid INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Body Fluid (Pleural/Ascitic)' AND IsDeleted = 0);
DECLARE @SmpSput  INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Sputum Sample' AND IsDeleted = 0);

-- 1. Tests. Is_Profile = 1 rows are the orderable profiles; others are parameters.
DECLARE @T TABLE (Code NVARCHAR(50), Name NVARCHAR(200), RType NVARCHAR(20), IsProfile BIT, Dept INT, Cat INT, Sub INT, Smp INT, Tat INT, Mrp DECIMAL(10,2), Gender VARCHAR(10), ProfileCode NVARCHAR(50), Seq INT);
INSERT INTO @T VALUES
 -- Urine Routine
 ('CP-UR-000','Urine Routine & Microscopy','Numeric',1,@Path,@CatCP,@SubUrine,@SmpUrine,4,200,'All',NULL,0),
 ('CP-UR-001','Urine Colour','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',1),
 ('CP-UR-002','Urine Appearance','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',2),
 ('CP-UR-003','Urine pH','Numeric',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',3),
 ('CP-UR-004','Urine Specific Gravity','Numeric',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',4),
 ('CP-UR-005','Urine Protein (Albumin)','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',5),
 ('CP-UR-006','Urine Sugar (Glucose)','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',6),
 ('CP-UR-007','Urine Ketone Bodies','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',7),
 ('CP-UR-008','Urine Bile Salts','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',8),
 ('CP-UR-009','Urine Bile Pigments','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',9),
 ('CP-UR-010','Urine Urobilinogen','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',10),
 ('CP-UR-011','Urine Blood','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',11),
 ('CP-UR-012','Urine Nitrite','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',12),
 ('CP-UR-013','Urine Leukocyte Esterase','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',13),
 ('CP-UR-014','Urine Pus Cells','Numeric',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',14),
 ('CP-UR-015','Urine RBC','Numeric',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',15),
 ('CP-UR-016','Urine Epithelial Cells','Numeric',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',16),
 ('CP-UR-017','Urine Casts','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',17),
 ('CP-UR-018','Urine Crystals','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',18),
 ('CP-UR-019','Urine Bacteria','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',19),
 ('CP-UR-020','Urine Yeast Cells','Select',0,@Path,@CatCP,@SubUrine,@SmpUrine,4,0,'All','CP-UR-000',20),
 -- Stool Routine
 ('CP-ST-000','Stool Routine Examination','Numeric',1,@Path,@CatCP,@SubStool,@SmpStool,6,180,'All',NULL,0),
 ('CP-ST-001','Stool Colour','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',1),
 ('CP-ST-002','Stool Consistency','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',2),
 ('CP-ST-003','Stool Mucus','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',3),
 ('CP-ST-004','Stool Visible Blood','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',4),
 ('CP-ST-005','Stool Reaction','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',5),
 ('CP-ST-006','Stool Occult Blood','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',6),
 ('CP-ST-007','Stool Pus Cells','Numeric',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',7),
 ('CP-ST-008','Stool RBC','Numeric',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',8),
 ('CP-ST-009','Stool Ova','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',9),
 ('CP-ST-010','Stool Cysts','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',10),
 ('CP-ST-011','Stool Trophozoites','Select',0,@Path,@CatCP,@SubStool,@SmpStool,6,0,'All','CP-ST-000',11),
 -- Semen Analysis (WHO 6th edition)
 ('CP-SM-000','Semen Analysis','Numeric',1,@Path,@CatCP,@SubSemen,@SmpSemen,6,500,'Male',NULL,0),
 ('CP-SM-001','Semen Appearance','Select',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',1),
 ('CP-SM-002','Semen Liquefaction','Select',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',2),
 ('CP-SM-003','Semen Viscosity','Select',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',3),
 ('CP-SM-004','Semen Volume','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',4),
 ('CP-SM-005','Semen pH','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',5),
 ('CP-SM-006','Sperm Concentration','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',6),
 ('CP-SM-007','Total Sperm Count','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',7),
 ('CP-SM-008','Progressive Motility (PR)','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',8),
 ('CP-SM-009','Non-Progressive Motility (NP)','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',9),
 ('CP-SM-010','Immotile Sperm (IM)','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',10),
 ('CP-SM-011','Normal Morphology','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',11),
 ('CP-SM-012','Sperm Vitality','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',12),
 ('CP-SM-013','Sperm Agglutination','Select',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',13),
 ('CP-SM-014','Semen Round Cells','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',14),
 ('CP-SM-015','Semen WBC (Pus Cells)','Numeric',0,@Path,@CatCP,@SubSemen,@SmpSemen,6,0,'Male','CP-SM-000',15),
 -- CSF Analysis
 ('CP-CF-000','CSF Analysis','Numeric',1,@Path,@CatCP,@SubFluid,@SmpCsf,4,600,'All',NULL,0),
 ('CP-CF-001','CSF Appearance','Select',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',1),
 ('CP-CF-002','CSF Coagulum','Select',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',2),
 ('CP-CF-003','CSF Protein','Numeric',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',3),
 ('CP-CF-004','CSF Glucose','Numeric',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',4),
 ('CP-CF-005','CSF Chloride','Numeric',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',5),
 ('CP-CF-006','CSF Total Cell Count','Numeric',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',6),
 ('CP-CF-007','CSF Lymphocytes','Numeric',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',7),
 ('CP-CF-008','CSF Neutrophils','Numeric',0,@Path,@CatCP,@SubFluid,@SmpCsf,4,0,'All','CP-CF-000',8),
 -- Body Fluid Analysis (Pleural / Ascitic)
 ('CP-BF-000','Body Fluid Analysis (Pleural/Ascitic)','Numeric',1,@Path,@CatCP,@SubFluid,@SmpFluid,6,700,'All',NULL,0),
 ('CP-BF-001','Body Fluid Appearance','Select',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',1),
 ('CP-BF-002','Body Fluid Protein','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',2),
 ('CP-BF-003','Body Fluid Glucose','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',3),
 ('CP-BF-004','Body Fluid LDH','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',4),
 ('CP-BF-005','Body Fluid ADA','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',5),
 ('CP-BF-006','Body Fluid Total Cell Count','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',6),
 ('CP-BF-007','Body Fluid Lymphocytes','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',7),
 ('CP-BF-008','Body Fluid Neutrophils','Numeric',0,@Path,@CatCP,@SubFluid,@SmpFluid,6,0,'All','CP-BF-000',8),
 -- Standalone: Sputum AFB (Ziehl-Neelsen), graded per RNTCP / WHO
 ('MIC-AF-001','Sputum for AFB (ZN Stain)','Select',0,@Micro,@CatMI,@SubStain,@SmpSput,24,150,'All',NULL,0);

INSERT INTO dbo.LabInvestigationMaster
    (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Sample_Type_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
SELECT t.Code, t.Name, t.Dept, t.Cat, t.Sub, t.Smp, t.RType, t.Tat,
       CASE WHEN t.ProfileCode IS NULL THEN 1 ELSE 0 END, 0, 0, t.Mrp, 1, t.IsProfile, t.Gender, 0, 0, 0, 0, 1, GETDATE(), 0
FROM @T t
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster i WHERE i.Test_Code = t.Code);

-- 2. Profile headers
DECLARE @Base INT = (SELECT ISNULL(MAX(Profile_ID), 0) FROM dbo.LabInvestigationProfileHeader);
INSERT INTO dbo.LabInvestigationProfileHeader
    (CompanyId, Profile_Code, Profile_Name, MRP, Discount_Pct, Applicable_Gender, Profile_TAT_Hours, Profile_NABL_Accredited, Report_Print_Sequence, Status, IsDeleted, CreatedDate, Test_ID, Profile_Type)
SELECT 1, 'PRF' + RIGHT('0000' + CAST(@Base + ROW_NUMBER() OVER (ORDER BY i.Test_Code) AS NVARCHAR(10)), 4),
       i.Test_Name, i.MRP, 0, CASE WHEN i.Applicable_Gender = 'Male' THEN 'Male' ELSE 'All' END, i.TAT_Hours, 0, 1, 1, 0, GETDATE(), i.Test_ID, 1
FROM @T t
JOIN dbo.LabInvestigationMaster i ON i.Test_Code = t.Code AND i.IsDeleted = 0
WHERE t.IsProfile = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileHeader h WHERE h.Test_ID = i.Test_ID AND h.IsDeleted = 0);

-- 3. Profile members
INSERT INTO dbo.LabInvestigationProfileDetail (Profile_ID, Test_ID, Sequence, IsDeleted, CreatedDate)
SELECT h.Profile_ID, m.Test_ID, t.Seq, 0, GETDATE()
FROM @T t
JOIN dbo.LabInvestigationMaster m ON m.Test_Code = t.Code AND m.IsDeleted = 0
JOIN dbo.LabInvestigationMaster p ON p.Test_Code = t.ProfileCode AND p.IsDeleted = 0
JOIN dbo.LabInvestigationProfileHeader h ON h.Test_ID = p.Test_ID AND h.IsDeleted = 0
WHERE t.ProfileCode IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationProfileDetail d WHERE d.Profile_ID = h.Profile_ID AND d.Test_ID = m.Test_ID AND d.IsDeleted = 0);
GO

-- 4. Picklist options for every 'Select' parameter. (* = default, ! = abnormal)
DECLARE @O TABLE (Code NVARCHAR(50), Opts NVARCHAR(MAX));
INSERT INTO @O VALUES
 ('CP-UR-001', N'["*Pale Yellow","Straw","Yellow","!Dark Yellow","!Amber","!Red","!Brown","!Colourless"]'),
 ('CP-UR-002', N'["*Clear","!Slightly Turbid","!Turbid","!Cloudy"]'),
 ('CP-UR-005', N'["*Nil","!Trace","!1+","!2+","!3+","!4+"]'),
 ('CP-UR-006', N'["*Nil","!Trace","!1+","!2+","!3+","!4+"]'),
 ('CP-UR-007', N'["*Negative","!Positive"]'),
 ('CP-UR-008', N'["*Absent","!Present"]'),
 ('CP-UR-009', N'["*Absent","!Present"]'),
 ('CP-UR-010', N'["*Normal","!Increased"]'),
 ('CP-UR-011', N'["*Negative","!Trace","!1+","!2+","!3+"]'),
 ('CP-UR-012', N'["*Negative","!Positive"]'),
 ('CP-UR-013', N'["*Negative","!Trace","!1+","!2+","!3+"]'),
 ('CP-UR-017', N'["*Nil","Hyaline Casts (occasional)","!Granular Casts","!RBC Casts","!WBC Casts","!Waxy Casts"]'),
 ('CP-UR-018', N'["*Nil","Calcium Oxalate","Uric Acid","Triple Phosphate","Amorphous Urates","Amorphous Phosphates"]'),
 ('CP-UR-019', N'["*Nil","!Few","!Moderate","!Plenty"]'),
 ('CP-UR-020', N'["*Absent","!Present"]'),
 ('CP-ST-001', N'["*Brown","Yellow","Green","!Black","!Red","!Clay Coloured"]'),
 ('CP-ST-002', N'["*Formed","Semi-formed","!Loose","!Watery"]'),
 ('CP-ST-003', N'["*Absent","!Present"]'),
 ('CP-ST-004', N'["*Absent","!Present"]'),
 ('CP-ST-005', N'["*Alkaline","Neutral","Acidic"]'),
 ('CP-ST-006', N'["*Negative","!Positive"]'),
 ('CP-ST-009', N'["*Not Seen","!Seen (see remarks)"]'),
 ('CP-ST-010', N'["*Not Seen","!Seen (see remarks)"]'),
 ('CP-ST-011', N'["*Not Seen","!Seen (see remarks)"]'),
 ('CP-SM-001', N'["*Grey Opalescent","!Yellowish","!Reddish Brown","!Transparent"]'),
 ('CP-SM-002', N'["*Complete within 60 min","!Incomplete"]'),
 ('CP-SM-003', N'["*Normal","!Increased"]'),
 ('CP-SM-013', N'["*Absent","!Present"]'),
 ('CP-CF-001', N'["*Clear","!Turbid","!Xanthochromic","!Blood Stained"]'),
 ('CP-CF-002', N'["*Absent","!Present"]'),
 ('CP-BF-001', N'["*Clear","Straw Coloured","!Turbid","!Haemorrhagic","!Chylous","!Purulent"]'),
 ('MIC-AF-001', N'["*Negative (No AFB seen in 100 fields)","!Scanty (1-9 AFB in 100 fields)","!1+ (10-99 AFB in 100 fields)","!2+ (1-10 AFB per field)","!3+ (>10 AFB per field)"]');

DECLARE @OBase INT = (SELECT ISNULL(MAX(Option_ID), 0) FROM dbo.LabParameterOptionMaster);
;WITH parsed AS (
    SELECT i.Test_ID,
           CAST(j.[key] AS INT) + 1 AS Seq,
           CASE WHEN LEFT(j.[value], 1) IN ('*', '!') THEN SUBSTRING(j.[value], 2, 200) ELSE j.[value] END AS OptText,
           CASE WHEN LEFT(j.[value], 1) = '!' THEN 1 ELSE 0 END AS IsAbn,
           CASE WHEN LEFT(j.[value], 1) = '*' THEN 1 ELSE 0 END AS IsDef
    FROM @O o
    JOIN dbo.LabInvestigationMaster i ON i.Test_Code = o.Code AND i.IsDeleted = 0
    CROSS APPLY OPENJSON(o.Opts) j
)
INSERT INTO dbo.LabParameterOptionMaster (CompanyId, Option_Code, Test_ID, Option_Text, Display_Order, Is_Abnormal, Is_Default, Status, CreatedDate)
SELECT 1, 'OPT' + RIGHT('0000' + CAST(@OBase + ROW_NUMBER() OVER (ORDER BY p.Test_ID, p.Seq) AS NVARCHAR(10)), 4),
       p.Test_ID, p.OptText, p.Seq, p.IsAbn, p.IsDef, 1, GETDATE()
FROM parsed p
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabParameterOptionMaster x WHERE x.Test_ID = p.Test_ID AND x.Option_Text = p.OptText AND x.IsDeleted = 0);
GO

PRINT 'Track A: microbiology parametric tests configured.';

-- Gender 'Both' is not a valid value (booking and the edit form use 'All').
UPDATE dbo.LabInvestigationMaster SET Applicable_Gender = 'All'
WHERE Applicable_Gender = 'Both' AND IsDeleted = 0 AND (Test_Code LIKE 'CP-%' OR Test_Code LIKE 'MIC-%');
UPDATE dbo.LabInvestigationMaster SET Applicable_Gender = 'All'
WHERE Test_Code = 'CP-UR-000' AND Applicable_Gender = 'Male';
GO
