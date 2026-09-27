-- =============================================
-- Script : 2150_microbiology_reference_ranges.sql
-- Purpose: Units and reference ranges for the numeric parameters of the
--          microbiology / clinical-pathology profiles (Urine, Stool, Semen,
--          CSF, Body Fluid). Without a range the result entry screen blocks
--          the parameter.
-- Notes  : Common-for-all ranges (0-100 years, all genders). Semen uses
--          WHO 6th edition lower reference limits (lower bound only).
--          CSF values are adult; add age bands for neonates/children.
--          Body-fluid values are interpretive cut-offs, not normal ranges.
--          Each lab's pathologist should review before go-live.
-- =============================================

-- 1. Units
DECLARE @U TABLE (Name NVARCHAR(100), Symbol NVARCHAR(30));
INSERT INTO @U VALUES
 ('Per High Power Field', '/HPF'),
 ('Milliliter', 'mL'),
 ('Millions per Milliliter', '10^6/mL'),
 ('Millions per Ejaculate', '10^6/ejaculate'),
 ('Dimensionless', '-');

DECLARE @UBase INT = (SELECT ISNULL(MAX(Unit_ID), 0) FROM dbo.LabUnitMaster);
INSERT INTO dbo.LabUnitMaster (CompanyId, Unit_Name, Unit_Code, Unit_Symbol, Conversion_Factor, Display_Order, Status, CreatedDate, IsDeleted)
SELECT 1, u.Name, 'UNT' + RIGHT('0000' + CAST(@UBase + ROW_NUMBER() OVER (ORDER BY u.Name) AS NVARCHAR(10)), 4),
       u.Symbol, 1.0, @UBase + ROW_NUMBER() OVER (ORDER BY u.Name), 1, GETDATE(), 0
FROM @U u
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster x WHERE x.Unit_Name = u.Name AND x.IsDeleted = 0);
GO

-- 2. Ranges (Low NULL = no lower bound, High NULL = no upper bound)
DECLARE @R TABLE (Code NVARCHAR(50), Unit NVARCHAR(100), LowV DECIMAL(12,4) NULL, HighV DECIMAL(12,4) NULL, Src NVARCHAR(200), Remark NVARCHAR(500) NULL);
INSERT INTO @R VALUES
 -- Urine Routine
 ('CP-UR-003', 'Dimensionless',               4.5,   8.0,  'Standard Urinalysis', NULL),
 ('CP-UR-004', 'Dimensionless',               1.005, 1.030,'Standard Urinalysis', NULL),
 ('CP-UR-014', 'Per High Power Field',        0,     5,    'Standard Urinalysis', NULL),
 ('CP-UR-015', 'Per High Power Field',        0,     2,    'Standard Urinalysis', NULL),
 ('CP-UR-016', 'Per High Power Field',        0,     5,    'Standard Urinalysis', NULL),
 -- Stool Routine
 ('CP-ST-007', 'Per High Power Field',        0,     2,    'Standard Clinical Pathology', 'Normally absent or occasional.'),
 ('CP-ST-008', 'Per High Power Field',        0,     2,    'Standard Clinical Pathology', 'Normally absent.'),
 -- Semen Analysis (WHO 6th edition, 2021)
 ('CP-SM-004', 'Milliliter',                  1.4,   NULL, 'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit.'),
 ('CP-SM-005', 'Dimensionless',               7.2,   8.0,  'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit 7.2.'),
 ('CP-SM-006', 'Millions per Milliliter',     16,    NULL, 'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit.'),
 ('CP-SM-007', 'Millions per Ejaculate',      39,    NULL, 'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit.'),
 ('CP-SM-008', 'Percentage',                  30,    NULL, 'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit. Total motility (PR + NP) lower limit is 42%.'),
 ('CP-SM-009', 'Percentage',                  0,     100,  'WHO Laboratory Manual 6th Ed. (2021)', 'No separate WHO reference limit; interpret with total motility (>= 42%).'),
 ('CP-SM-010', 'Percentage',                  0,     100,  'WHO Laboratory Manual 6th Ed. (2021)', 'No WHO reference limit.'),
 ('CP-SM-011', 'Percentage',                  4,     NULL, 'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit (strict criteria).'),
 ('CP-SM-012', 'Percentage',                  54,    NULL, 'WHO Laboratory Manual 6th Ed. (2021)', 'Lower reference limit.'),
 ('CP-SM-014', 'Millions per Milliliter',     0,     5,    'Laboratory practice', 'No WHO reference limit; commonly used cut-off - lab to confirm.'),
 ('CP-SM-015', 'Millions per Milliliter',     0,     1,    'WHO Laboratory Manual 6th Ed. (2021)', 'Peroxidase-positive leukocytes < 1 x 10^6/mL.'),
 -- CSF Analysis (adult)
 ('CP-CF-003', 'Milligrams per Deciliter',    15,    45,   'Standard Clinical Pathology', 'Adult reference; neonatal and paediatric values are higher - add age bands.'),
 ('CP-CF-004', 'Milligrams per Deciliter',    40,    70,   'Standard Clinical Pathology', 'About 60% of blood glucose; interpret with a simultaneous blood glucose.'),
 ('CP-CF-005', 'Millimoles per Liter',        118,   132,  'Standard Clinical Pathology', NULL),
 ('CP-CF-006', 'Cells per Cubic Millimeter',  0,     5,    'Standard Clinical Pathology', 'Adult reference; neonates may have up to 30 cells/cu.mm.'),
 ('CP-CF-007', 'Percentage',                  40,    80,   'Standard Clinical Pathology', 'Adult differential.'),
 ('CP-CF-008', 'Percentage',                  0,     6,    'Standard Clinical Pathology', 'Adult differential.'),
 -- Body Fluid (pleural / ascitic) - interpretive cut-offs
 ('CP-BF-002', 'Grams per Deciliter',         0,     3,    'Light''s criteria / clinical practice', '< 3 g/dL suggests transudate; confirm with Light''s criteria using serum values.'),
 ('CP-BF-003', 'Milligrams per Deciliter',    60,    NULL, 'Clinical practice', '< 60 mg/dL seen in infection, malignancy, rheumatoid effusion.'),
 ('CP-BF-004', 'Units per Liter',             0,     200,  'Light''s criteria / clinical practice', 'Transudate usually < 200 U/L; confirm with Light''s criteria using serum LDH.'),
 ('CP-BF-005', 'Units per Liter',             0,     40,   'Clinical practice', '>= 40 U/L suggests tuberculous effusion.'),
 ('CP-BF-006', 'Cells per Cubic Millimeter',  0,     1000, 'Clinical practice', 'Transudate usually < 1000/cu.mm. Ascitic neutrophils >= 250/cu.mm suggests SBP.'),
 ('CP-BF-007', 'Percentage',                  0,     100,  'Clinical practice', 'No normal range; interpret with total cell count.'),
 ('CP-BF-008', 'Percentage',                  0,     100,  'Clinical practice', 'No normal range; interpret with total cell count.');

-- 2a. Unit on the parameter itself (shown on entry and print)
UPDATE i SET Unit_ID = u.Unit_ID, ModifiedDate = GETDATE()
FROM dbo.LabInvestigationMaster i
JOIN @R r ON r.Code = i.Test_Code
JOIN dbo.LabUnitMaster u ON u.Unit_Name = r.Unit AND u.IsDeleted = 0
WHERE i.IsDeleted = 0 AND (i.Unit_ID IS NULL OR i.Unit_ID <> u.Unit_ID);

-- 2b. Reference ranges
INSERT INTO dbo.LabReferenceRangeMaster
    (CompanyId, Test_ID, Unit_ID, Age_From, Age_To, Age_Unit, Gender, Pregnancy_Trimester, Low_Value, High_Value, Range_Source,
     Effective_From, Status, IsDeleted, CreatedDate, Special_Remarks, Is_Common_For_All, Notification_Required, Acknowledgement_Required)
SELECT 1, i.Test_ID, u.Unit_ID, 0, 100, 'Years', 'All', 'Not Applicable', r.LowV, r.HighV, r.Src,
       '2025-01-01', 1, 0, GETDATE(), r.Remark, 1, 0, 0
FROM @R r
JOIN dbo.LabInvestigationMaster i ON i.Test_Code = r.Code AND i.IsDeleted = 0
JOIN dbo.LabUnitMaster u ON u.Unit_Name = r.Unit AND u.IsDeleted = 0
WHERE NOT EXISTS (SELECT 1 FROM dbo.LabReferenceRangeMaster x WHERE x.Test_ID = i.Test_ID AND x.IsDeleted = 0);
GO

PRINT 'Microbiology reference ranges configured.';
