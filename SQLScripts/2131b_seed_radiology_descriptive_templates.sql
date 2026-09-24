-- =============================================
-- Seed Descriptive Test Templates for Radiology Tests
-- 6 standard RSNA sections per test with default content
-- =============================================

-- ===== X-Ray Chest PA (Test_ID = 122) =====
DECLARE @XRChest INT = 122;

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @XRChest AND Section_Name = 'Clinical History')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@XRChest, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred by {{ReferringDoctor}} for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ReferringDoctor}},{{ClinicalIndication}}', 1, 1, 'X-Ray', 'Chest', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @XRChest AND Section_Name = 'Technique')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@XRChest, 'Technique', 2, 1, '<p>PA view of the chest was obtained in erect position.</p>', NULL, 1, 1, 'X-Ray', 'Chest', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @XRChest AND Section_Name = 'Comparison')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@XRChest, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'X-Ray', 'Chest', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @XRChest AND Section_Name = 'Findings')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@XRChest, 'Findings', 4, 1, '<p><strong>Lungs:</strong> Both lung fields are clear. No focal consolidation, pleural effusion, or pneumothorax.</p><p><strong>Heart:</strong> Cardiac silhouette is normal in size and configuration. Cardiothoracic ratio is within normal limits.</p><p><strong>Mediastinum:</strong> Mediastinal contour is unremarkable. Trachea is central.</p><p><strong>Bony thorax:</strong> Visualised bony structures appear normal. No fracture or lytic lesion seen.</p><p><strong>Diaphragm:</strong> Both hemidiaphragms are normal in position and contour. Costophrenic angles are clear.</p>', NULL, 1, 1, 'X-Ray', 'Chest', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @XRChest AND Section_Name = 'Impression')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@XRChest, 'Impression', 5, 1, '<p>Normal chest radiograph.</p>', NULL, 1, 1, 'X-Ray', 'Chest', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @XRChest AND Section_Name = 'Recommendation')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@XRChest, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'X-Ray', 'Chest', 'N/A', 0, GETDATE());
GO

-- ===== CT Brain Plain (Test_ID = 126) =====
DECLARE @CTBrain INT = 126;

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @CTBrain AND Section_Name = 'Clinical History')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@CTBrain, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'CT', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @CTBrain AND Section_Name = 'Technique')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@CTBrain, 'Technique', 2, 1, '<p>Non-contrast CT scan of the brain was performed with axial sections from skull base to vertex. Slice thickness: {{SliceThickness}} mm.</p>', '{{SliceThickness}}', 1, 1, 'CT', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @CTBrain AND Section_Name = 'Comparison')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@CTBrain, 'Comparison', 3, 0, '<p>No prior imaging available for comparison.</p>', NULL, 1, 1, 'CT', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @CTBrain AND Section_Name = 'Findings')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@CTBrain, 'Findings', 4, 1, '<p><strong>Brain parenchyma:</strong> No evidence of intra-axial or extra-axial hemorrhage. Grey-white matter differentiation is preserved. No focal lesion or mass effect seen.</p><p><strong>Ventricles:</strong> Ventricular system is normal in size and configuration. No midline shift.</p><p><strong>Basal cisterns:</strong> Basal cisterns are patent.</p><p><strong>Calvarium:</strong> No fracture or calvarial lesion. Paranasal sinuses appear clear.</p><p><strong>DLP:</strong> {{DLP}} mGy.cm | <strong>CTDIvol:</strong> {{CTDIvol}} mGy</p>', '{{DLP}},{{CTDIvol}}', 1, 1, 'CT', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @CTBrain AND Section_Name = 'Impression')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@CTBrain, 'Impression', 5, 1, '<p>Normal non-contrast CT scan of the brain.</p>', NULL, 1, 1, 'CT', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @CTBrain AND Section_Name = 'Recommendation')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@CTBrain, 'Recommendation', 6, 0, '<p>MRI brain with contrast may be considered if clinically indicated.</p>', NULL, 1, 1, 'CT', 'Brain', 'N/A', 0, GETDATE());
GO

-- ===== USG Abdomen Whole (Test_ID = 135) =====
DECLARE @USGAbd INT = 135;

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @USGAbd AND Section_Name = 'Clinical History')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@USGAbd, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'USG', 'Abdomen', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @USGAbd AND Section_Name = 'Technique')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@USGAbd, 'Technique', 2, 1, '<p>Ultrasonographic evaluation of the abdomen was performed using {{Transducer}} MHz curvilinear transducer.</p>', '{{Transducer}}', 1, 1, 'USG', 'Abdomen', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @USGAbd AND Section_Name = 'Comparison')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@USGAbd, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'USG', 'Abdomen', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @USGAbd AND Section_Name = 'Findings')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@USGAbd, 'Findings', 4, 1, '<p><strong>Liver:</strong> Normal in size, shape and echotexture. No focal lesion. No intrahepatic biliary dilatation. Portal vein is normal.</p><p><strong>Gallbladder:</strong> Normal in size and wall thickness. No calculus or sludge. CBD is not dilated.</p><p><strong>Pancreas:</strong> Normal in size and echotexture. No focal lesion. Pancreatic duct is not dilated.</p><p><strong>Spleen:</strong> Normal in size and echotexture. No focal lesion.</p><p><strong>Kidneys:</strong> Both kidneys are normal in size, shape and cortical echotexture. No calculus, hydronephrosis or focal lesion. Corticomedullary differentiation is maintained.</p><p><strong>Urinary bladder:</strong> Adequately distended. Normal wall thickness. No calculus or mass.</p><p><strong>Aorta & IVC:</strong> Normal in calibre.</p><p><strong>Free fluid:</strong> No free fluid in the peritoneal cavity.</p>', NULL, 1, 1, 'USG', 'Abdomen', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @USGAbd AND Section_Name = 'Impression')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@USGAbd, 'Impression', 5, 1, '<p>Normal ultrasonographic study of the abdomen.</p>', NULL, 1, 1, 'USG', 'Abdomen', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @USGAbd AND Section_Name = 'Recommendation')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@USGAbd, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'USG', 'Abdomen', 'N/A', 0, GETDATE());
GO

-- ===== MRI Brain Plain (Test_ID = 131) =====
DECLARE @MRIBrain INT = 131;

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRIBrain AND Section_Name = 'Clinical History')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRIBrain, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'MRI', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRIBrain AND Section_Name = 'Technique')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRIBrain, 'Technique', 2, 1, '<p>MRI of the brain was performed on {{FieldStrength}}T scanner. Sequences obtained: {{Sequences}} in axial, coronal and sagittal planes.</p>', '{{FieldStrength}},{{Sequences}}', 1, 1, 'MRI', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRIBrain AND Section_Name = 'Comparison')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRIBrain, 'Comparison', 3, 0, '<p>No prior imaging available for comparison.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRIBrain AND Section_Name = 'Findings')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRIBrain, 'Findings', 4, 1, '<p><strong>Brain parenchyma:</strong> Normal signal intensity of the brain parenchyma on all sequences. No abnormal signal intensity lesion or mass effect. Grey-white matter differentiation is well maintained.</p><p><strong>Ventricles:</strong> Ventricular system is normal in size and configuration. No midline shift.</p><p><strong>Posterior fossa:</strong> Cerebellum and brainstem appear normal. Fourth ventricle is normal.</p><p><strong>Sella & parasellar region:</strong> Pituitary gland is normal in size and signal intensity.</p><p><strong>Extra-axial spaces:</strong> No extra-axial collection. Basal cisterns are patent.</p><p><strong>Orbits & paranasal sinuses:</strong> Appear normal.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRIBrain AND Section_Name = 'Impression')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRIBrain, 'Impression', 5, 1, '<p>Normal MRI of the brain.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRIBrain AND Section_Name = 'Recommendation')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRIBrain, 'Recommendation', 6, 0, '<p>Clinical correlation advised. Contrast-enhanced MRI may be considered if clinically indicated.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 0, GETDATE());
GO

-- ===== MRI Lumbar Spine (Test_ID = 133) =====
DECLARE @MRISpine INT = 133;

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRISpine AND Section_Name = 'Clinical History')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRISpine, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'MRI', 'Spine', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRISpine AND Section_Name = 'Technique')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRISpine, 'Technique', 2, 1, '<p>MRI of the lumbar spine was performed on {{FieldStrength}}T scanner. Sequences: T1W, T2W and STIR in sagittal and axial planes.</p>', '{{FieldStrength}}', 1, 1, 'MRI', 'Spine', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRISpine AND Section_Name = 'Comparison')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRISpine, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'MRI', 'Spine', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRISpine AND Section_Name = 'Findings')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRISpine, 'Findings', 4, 1, '<p><strong>Vertebral bodies:</strong> Normal alignment and height of lumbar vertebral bodies (L1-L5). Normal marrow signal intensity. No compression fracture.</p><p><strong>Intervertebral discs:</strong></p><ul><li><strong>L1-L2:</strong> Normal disc height and signal. No disc herniation.</li><li><strong>L2-L3:</strong> Normal disc height and signal. No disc herniation.</li><li><strong>L3-L4:</strong> Normal disc height and signal. No disc herniation.</li><li><strong>L4-L5:</strong> Normal disc height and signal. No disc herniation or canal stenosis.</li><li><strong>L5-S1:</strong> Normal disc height and signal. No disc herniation.</li></ul><p><strong>Spinal canal:</strong> No spinal canal stenosis. Conus medullaris terminates at normal level.</p><p><strong>Paravertebral soft tissues:</strong> Unremarkable.</p>', NULL, 1, 1, 'MRI', 'Spine', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRISpine AND Section_Name = 'Impression')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRISpine, 'Impression', 5, 1, '<p>Normal MRI of the lumbar spine.</p>', NULL, 1, 1, 'MRI', 'Spine', 'N/A', 0, GETDATE());

IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @MRISpine AND Section_Name = 'Recommendation')
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate)
    VALUES (@MRISpine, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'MRI', 'Spine', 'N/A', 0, GETDATE());
GO
