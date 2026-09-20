-- ============================================================
-- Script: 2081_seed_all_reference_ranges.sql
-- Description: Seeds complete standard reference ranges into dbo.LabReferenceRangeMaster
-- ============================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabReferenceRangeMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT 'Error: dbo.LabReferenceRangeMaster table does not exist.';
    RETURN;
END
GO

-- Seed standard clinical reference ranges
MERGE dbo.LabReferenceRangeMaster AS target
USING (
    VALUES
        (40, 1, 125.0, 200.0, 'Desirable: <200 mg/dL, Borderline high: 200-239 mg/dL, High: >=240 mg/dL', 'NCEP Guidelines'),
        (41, 1, 40.0, 60.0, 'Major risk factor: <40 mg/dL, Protective: >=60 mg/dL', 'NCEP Guidelines'),
        (42, 1, 0.0, 100.0, 'Optimal: <100 mg/dL, Near optimal: 100-129, Borderline: 130-159, High: 160-189, Very high: >=190', 'NCEP Guidelines'),
        (43, 1, 2.0, 30.0, 'Normal VLDL level is between 2 and 30 mg/dL', 'Standard Clinical Pathology'),
        (44, 1, 0.0, 150.0, 'Normal: <150 mg/dL, Borderline: 150-199, High: 200-499, Critical: >=500', 'NCEP Guidelines'),
        (45, 18, 0.0, 5.0, 'Average risk: 4.5-5.0, Moderate to high risk: >5.0', 'American Heart Association'),
        (46, 18, 0.0, 3.5, 'Desirable: <3.0, Borderline: 3.0-3.5, High risk: >3.5', 'American Heart Association'),
        (2, 1, 70.0, 100.0, 'Normal: 70-100 mg/dL, Impaired: 101-125 mg/dL, Diabetic: >=126 mg/dL', 'ADA Guidelines'),
        (3, 1, 70.0, 140.0, 'Normal: <140 mg/dL, Impaired: 140-199 mg/dL, Diabetic: >=200 mg/dL', 'ADA Guidelines'),
        (4, 14, 4.0, 5.6, 'Normal: <5.7%, Prediabetes: 5.7-6.4%, Diabetes: >=6.5%', 'ADA Guidelines'),
        (9, 1, 0.7, 1.3, 'Male: 0.7-1.3 mg/dL, Female: 0.6-1.1 mg/dL', 'Clinical Guidelines'),
        (16, 2, 12.0, 16.0, 'Adult Male: 13.0-17.0 g/dL, Adult Female: 12.0-15.0 g/dL', 'WHO Guidelines'),
        (17, 11, 4000.0, 11000.0, 'Normal: 4,000 - 11,000 /cumm', 'Standard Hematology'),
        (18, 14, 40.0, 75.0, 'Normal: 40 - 75%', 'Standard Hematology'),
        (19, 14, 20.0, 45.0, 'Normal: 20 - 45%', 'Standard Hematology'),
        (20, 14, 1.0, 6.0, 'Normal: 1 - 6%', 'Standard Hematology'),
        (21, 14, 2.0, 10.0, 'Normal: 2 - 10%', 'Standard Hematology'),
        (22, 14, 0.0, 1.0, 'Normal: 0 - 1%', 'Standard Hematology'),
        (23, 13, 4.5, 5.5, 'Normal: 4.5 - 5.5 mil/cumm', 'Standard Hematology'),
        (24, 14, 36.0, 48.0, 'Male: 40-50%, Female: 36-46%', 'Standard Hematology'),
        (25, 20, 80.0, 100.0, 'Normal: 80 - 100 fL', 'Standard Hematology'),
        (26, 9, 27.0, 32.0, 'Normal: 27 - 32 pg', 'Standard Hematology'),
        (27, 2, 32.0, 36.0, 'Normal: 32 - 36 g/dL', 'Standard Hematology'),
        (28, 12, 150000.0, 450000.0, 'Normal: 150,000 - 450,000 /cumm', 'Standard Hematology'),
        (29, 15, 0.0, 20.0, 'Male: 0-15 mm/hr, Female: 0-20 mm/hr', 'Westergren Method'),
        (30, 1, 0.2, 1.2, 'Normal: 0.2 - 1.2 mg/dL', 'Standard Biochemistry'),
        (31, 1, 0.0, 0.3, 'Normal: 0.0 - 0.3 mg/dL', 'Standard Biochemistry'),
        (32, 1, 0.2, 0.8, 'Normal: 0.2 - 0.8 mg/dL', 'Standard Biochemistry'),
        (33, 6, 5.0, 40.0, 'Normal: 5 - 40 U/L', 'Standard Biochemistry'),
        (34, 6, 7.0, 56.0, 'Normal: 7 - 56 U/L', 'Standard Biochemistry'),
        (35, 6, 44.0, 147.0, 'Normal: 44 - 147 U/L', 'Standard Biochemistry'),
        (36, 2, 6.0, 8.3, 'Normal: 6.0 - 8.3 g/dL', 'Standard Biochemistry'),
        (37, 2, 3.5, 5.0, 'Normal: 3.5 - 5.0 g/dL', 'Standard Biochemistry'),
        (38, 2, 2.0, 3.5, 'Normal: 2.0 - 3.5 g/dL', 'Standard Biochemistry'),
        (39, 18, 1.2, 2.2, 'Normal: 1.2 - 2.2', 'Standard Biochemistry'),
        (47, 8, 0.8, 2.0, 'Normal: 0.8 - 2.0 ng/mL', 'Standard Endocrinology'),
        (48, 7, 5.1, 14.1, 'Normal: 5.1 - 14.1 ug/dL', 'Standard Endocrinology'),
        (49, 10, 0.27, 4.20, 'Normal: 0.27 - 4.20 uIU/mL', 'CLIA Method'),
        (50, 1, 15.0, 45.0, 'Normal: 15 - 45 mg/dL', 'Standard Biochemistry'),
        (51, 1, 7.0, 20.0, 'Normal: 7 - 20 mg/dL', 'Standard Biochemistry'),
        (52, 1, 3.5, 7.2, 'Male: 3.5-7.2 mg/dL, Female: 2.6-6.0 mg/dL', 'Standard Biochemistry'),
        (53, 1, 8.5, 10.5, 'Normal: 8.5 - 10.5 mg/dL', 'Standard Biochemistry'),
        (54, 1, 2.5, 4.5, 'Normal: 2.5 - 4.5 mg/dL', 'Standard Biochemistry'),
        (55, 16, 135.0, 145.0, 'Normal: 135 - 145 mEq/L', 'ISE Method'),
        (56, 16, 3.5, 5.0, 'Normal: 3.5 - 5.0 mEq/L', 'ISE Method'),
        (57, 16, 96.0, 106.0, 'Normal: 96 - 106 mEq/L', 'ISE Method'),
        (58, 1, 0.7, 1.3, 'Male: 0.7-1.3 mg/dL, Female: 0.6-1.1 mg/dL', 'Standard Biochemistry')
) AS src (Test_ID, Unit_ID, Low_Value, High_Value, Special_Remarks, Range_Source)
ON (target.Test_ID = src.Test_ID AND target.CompanyId = 1 AND target.IsDeleted = 0)
WHEN MATCHED THEN
    UPDATE SET 
        target.Unit_ID = src.Unit_ID,
        target.Low_Value = src.Low_Value,
        target.High_Value = src.High_Value,
        target.Special_Remarks = src.Special_Remarks,
        target.Range_Source = src.Range_Source,
        target.Age_From = 0.00,
        target.Age_To = 100.00,
        target.Age_Unit = 'Years',
        target.Gender = 'All',
        target.Effective_From = '2020-01-01',
        target.Status = 1,
        target.Is_Common_For_All = 1,
        target.ModifiedDate = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (
        CompanyId, Test_ID, Method_ID, Unit_ID, Age_From, Age_To, Age_Unit, Gender,
        Pregnancy_Trimester, Low_Value, High_Value, Special_Remarks, Range_Source,
        Effective_From, Effective_To, Status, IsDeleted, CreatedDate, Is_Common_For_All
    ) VALUES (
        1, src.Test_ID, NULL, src.Unit_ID, 0.00, 100.00, 'Years', 'All',
        'Not Applicable', src.Low_Value, src.High_Value, src.Special_Remarks, src.Range_Source,
        '2020-01-01', NULL, 1, 0, GETDATE(), 1
    );

PRINT 'Successfully merged standard reference ranges into dbo.LabReferenceRangeMaster';
GO
