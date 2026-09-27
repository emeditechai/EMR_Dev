-- =============================================
-- Script : 2140_microbiology_descriptive_stains_and_templates.sql
-- Purpose: Track C — narrative microbiology tests (Gram, KOH, Wet Mount,
--          India Ink, Albert stain) with default report templates.
--          Reporting_Type 'Descriptive': narrative results written from
--          Descriptive Test Templates.
-- =============================================

-- 1. Investigations
DECLARE @Dept   INT = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptName = 'Microbiology');
DECLARE @Cat    INT = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE Category_Name = 'Microbiology & Serology' AND IsDeleted = 0);
DECLARE @Sub    INT = (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Name = 'Microscopy & Special Stains' AND Category_ID = @Cat AND IsDeleted = 0);
DECLARE @Swab   INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Pus / Wound Swab' AND IsDeleted = 0);
DECLARE @Csf    INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Cerebrospinal Fluid (CSF)' AND IsDeleted = 0);
DECLARE @Throat INT = (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster WHERE Sample_Name = 'Throat / Nasopharyngeal Swab' AND IsDeleted = 0);

DECLARE @Tests TABLE (Code NVARCHAR(50), Name NVARCHAR(200), SampleId INT, Tat INT);
INSERT INTO @Tests VALUES
 ('MIC-ST-001', 'Gram Stain',                          @Swab,   2),
 ('MIC-ST-002', 'KOH Mount (Fungal Elements)',          @Swab,   2),
 ('MIC-ST-003', 'Wet Mount Examination',               @Swab,   2),
 ('MIC-ST-004', 'India Ink Preparation (CSF)',         @Csf,    2),
 ('MIC-ST-005', 'Albert Stain (C. diphtheriae)',       @Throat, 4);

INSERT INTO dbo.LabInvestigationMaster
    (Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Sample_Type_ID, Reporting_Type, TAT_Hours, Is_Billable, NABL_Accredited, Is_Outsourced, MRP, Status, Is_Profile_Test, Applicable_Gender, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, CompanyId, CreatedDate, IsDeleted)
SELECT t.Code, t.Name, @Dept, @Cat, @Sub, t.SampleId, 'Descriptive', t.Tat, 1, 0, 0, 0, 1, 0, 'All', 0, 0, 0, 0, 1, GETDATE(), 0
FROM @Tests t
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster i WHERE i.Test_Code = t.Code);
GO

-- 2. Report templates (5 sections each)
DECLARE @Tpl TABLE (Code NVARCHAR(50), Seq INT, Section NVARCHAR(100), Mandatory BIT, Html NVARCHAR(MAX), Tags NVARCHAR(500));
DECLARE @Hist NVARCHAR(MAX) = N'<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>';
DECLARE @HistTags NVARCHAR(500) = N'{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}';

INSERT INTO @Tpl VALUES
 -- Gram Stain
 ('MIC-ST-001',1,'Clinical History',1,@Hist,@HistTags),
 ('MIC-ST-001',2,'Specimen',1,N'<p><strong>Specimen:</strong> Received in sterile container.</p>',NULL),
 ('MIC-ST-001',3,'Microscopy Findings',1,N'<p><strong>Pus cells:</strong> Occasional / 5-10 per HPF.</p><p><strong>Epithelial cells:</strong> Few.</p><p><strong>Organisms:</strong> No bacteria seen.</p><p><strong>Gram positive cocci:</strong> Not seen.</p><p><strong>Gram negative bacilli:</strong> Not seen.</p>',NULL),
 ('MIC-ST-001',4,'Impression',1,N'<p>No organisms seen on Gram stain.</p>',NULL),
 ('MIC-ST-001',5,'Recommendation',0,N'<p>Correlate with culture and sensitivity report.</p>',NULL),
 -- KOH Mount
 ('MIC-ST-002',1,'Clinical History',1,@Hist,@HistTags),
 ('MIC-ST-002',2,'Specimen',1,N'<p><strong>Specimen:</strong> Skin scraping / nail clipping / hair.</p>',NULL),
 ('MIC-ST-002',3,'Microscopy Findings',1,N'<p>10% KOH preparation examined under low and high power.</p><p><strong>Fungal hyphae:</strong> Not seen.</p><p><strong>Budding yeast cells:</strong> Not seen.</p><p><strong>Pseudohyphae:</strong> Not seen.</p>',NULL),
 ('MIC-ST-002',4,'Impression',1,N'<p>No fungal elements seen on KOH mount.</p>',NULL),
 ('MIC-ST-002',5,'Recommendation',0,N'<p>Fungal culture advised if clinical suspicion persists.</p>',NULL),
 -- Wet Mount
 ('MIC-ST-003',1,'Clinical History',1,@Hist,@HistTags),
 ('MIC-ST-003',2,'Specimen',1,N'<p><strong>Specimen:</strong> As received. Examined within 30 minutes of collection.</p>',NULL),
 ('MIC-ST-003',3,'Microscopy Findings',1,N'<p><strong>Pus cells:</strong> Occasional.</p><p><strong>Epithelial cells:</strong> Few.</p><p><strong>Clue cells:</strong> Not seen.</p><p><strong>Trichomonas vaginalis:</strong> Not seen.</p><p><strong>Budding yeast cells:</strong> Not seen.</p>',NULL),
 ('MIC-ST-003',4,'Impression',1,N'<p>No Trichomonas, yeast cells or clue cells seen.</p>',NULL),
 ('MIC-ST-003',5,'Recommendation',0,N'<p>Clinical correlation advised.</p>',NULL),
 -- India Ink
 ('MIC-ST-004',1,'Clinical History',1,@Hist,@HistTags),
 ('MIC-ST-004',2,'Specimen',1,N'<p><strong>Specimen:</strong> Cerebrospinal fluid, centrifuged deposit.</p>',NULL),
 ('MIC-ST-004',3,'Microscopy Findings',1,N'<p>India ink preparation of centrifuged CSF deposit examined.</p><p><strong>Capsulated budding yeast cells:</strong> Not seen.</p>',NULL),
 ('MIC-ST-004',4,'Impression',1,N'<p>Negative for Cryptococcus neoformans on India ink preparation.</p>',NULL),
 ('MIC-ST-004',5,'Recommendation',0,N'<p>Cryptococcal antigen test advised if clinical suspicion persists; India ink has limited sensitivity.</p>',NULL),
 -- Albert Stain
 ('MIC-ST-005',1,'Clinical History',1,@Hist,@HistTags),
 ('MIC-ST-005',2,'Specimen',1,N'<p><strong>Specimen:</strong> Throat swab.</p>',NULL),
 ('MIC-ST-005',3,'Microscopy Findings',1,N'<p>Albert stain smear examined.</p><p><strong>Green bacilli with bluish-black metachromatic granules (Chinese letter arrangement):</strong> Not seen.</p>',NULL),
 ('MIC-ST-005',4,'Impression',1,N'<p>No organisms morphologically resembling Corynebacterium diphtheriae seen.</p>',NULL),
 ('MIC-ST-005',5,'Recommendation',0,N'<p>Culture on Loeffler''s serum slope / tellurite medium advised; smear alone is not diagnostic.</p>',NULL);

INSERT INTO dbo.LabDescriptiveTestTemplate
    (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
SELECT i.Test_ID, t.Section, t.Seq, t.Mandatory, t.Html, t.Tags, 1, 1, 'Microscopy', NULL, 'N/A', 0, GETDATE()
FROM @Tpl t
JOIN dbo.LabInvestigationMaster i ON i.Test_Code = t.Code AND i.IsDeleted = 0
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabDescriptiveTestTemplate d WHERE d.Test_ID = i.Test_ID);
GO

-- 3. Template test picker: key on reporting type, not the Radiology department,
--    so narrative tests from any department can have templates.
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabDescriptiveTestTemplate_GetRadiologyTests
    @CompanyId INT = NULL,
    @Search    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT inv.Test_ID, inv.Test_Code, inv.Test_Name
    FROM dbo.LabInvestigationMaster inv
    WHERE inv.Reporting_Type IN ('Image', 'Descriptive')
      AND inv.Status = 1
      AND inv.IsDeleted = 0
      AND (@CompanyId IS NULL OR inv.CompanyId = @CompanyId)
      AND (@Search IS NULL OR inv.Test_Name LIKE '%' + @Search + '%' OR inv.Test_Code LIKE '%' + @Search + '%')
    ORDER BY inv.Test_Name;
END
GO

PRINT 'Track C: microbiology descriptive stains and templates seeded.';

-- Keep existing rows in line with the reporting type above.
UPDATE dbo.LabInvestigationMaster SET Reporting_Type = 'Descriptive'
WHERE Test_Code IN ('MIC-ST-001','MIC-ST-002','MIC-ST-003','MIC-ST-004','MIC-ST-005') AND Reporting_Type = 'Image';
GO
