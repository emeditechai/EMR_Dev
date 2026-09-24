-- =============================================
-- Seed Descriptive Test Templates for remaining Radiology Tests
-- 6 RSNA sections each with standard default content
-- =============================================

-- ===== X-Ray Abdomen AP (Test_ID = 123) =====
DECLARE @T123 INT = 123;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T123)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T123, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'X-Ray', 'Abdomen', 'N/A', 0, GETDATE()),
    (@T123, 'Technique', 2, 1, '<p>AP view of the abdomen was obtained in supine position.</p>', NULL, 1, 1, 'X-Ray', 'Abdomen', 'N/A', 0, GETDATE()),
    (@T123, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'X-Ray', 'Abdomen', 'N/A', 0, GETDATE()),
    (@T123, 'Findings', 4, 1, '<p><strong>Gas pattern:</strong> Normal bowel gas pattern. No evidence of intestinal obstruction or ileus. No free air under the diaphragm.</p><p><strong>Soft tissues:</strong> Psoas shadows are preserved bilaterally. No abnormal soft tissue mass or calcification.</p><p><strong>Bony structures:</strong> Visualised bony structures appear normal. No fracture or lytic lesion.</p><p><strong>Kidneys:</strong> Renal outlines are normal. No radio-opaque calculus seen.</p>', NULL, 1, 1, 'X-Ray', 'Abdomen', 'N/A', 0, GETDATE()),
    (@T123, 'Impression', 5, 1, '<p>Normal abdominal radiograph.</p>', NULL, 1, 1, 'X-Ray', 'Abdomen', 'N/A', 0, GETDATE()),
    (@T123, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'X-Ray', 'Abdomen', 'N/A', 0, GETDATE());
END
GO

-- ===== X-Ray Spine Cervical/Lumbar (Test_ID = 124) =====
DECLARE @T124 INT = 124;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T124)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T124, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'X-Ray', 'Spine', 'N/A', 0, GETDATE()),
    (@T124, 'Technique', 2, 1, '<p>AP and lateral views of the spine were obtained.</p>', NULL, 1, 1, 'X-Ray', 'Spine', 'N/A', 0, GETDATE()),
    (@T124, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'X-Ray', 'Spine', 'N/A', 0, GETDATE()),
    (@T124, 'Findings', 4, 1, '<p><strong>Alignment:</strong> Normal spinal alignment. No listhesis or subluxation.</p><p><strong>Vertebral bodies:</strong> Normal height and morphology of the vertebral bodies. No compression fracture or lytic/sclerotic lesion.</p><p><strong>Disc spaces:</strong> Disc spaces are maintained. No significant disc space narrowing.</p><p><strong>Pedicles & posterior elements:</strong> Pedicles are intact. Posterior elements appear normal.</p><p><strong>Soft tissues:</strong> Prevertebral/paravertebral soft tissues are unremarkable.</p>', NULL, 1, 1, 'X-Ray', 'Spine', 'N/A', 0, GETDATE()),
    (@T124, 'Impression', 5, 1, '<p>Normal radiograph of the spine.</p>', NULL, 1, 1, 'X-Ray', 'Spine', 'N/A', 0, GETDATE()),
    (@T124, 'Recommendation', 6, 0, '<p>MRI may be considered if symptoms persist.</p>', NULL, 1, 1, 'X-Ray', 'Spine', 'N/A', 0, GETDATE());
END
GO

-- ===== X-Ray Knee Both (Test_ID = 125) =====
DECLARE @T125 INT = 125;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T125)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T125, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'X-Ray', 'Knee', 'Bilateral', 0, GETDATE()),
    (@T125, 'Technique', 2, 1, '<p>AP and lateral views of both knees were obtained.</p>', NULL, 1, 1, 'X-Ray', 'Knee', 'Bilateral', 0, GETDATE()),
    (@T125, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'X-Ray', 'Knee', 'Bilateral', 0, GETDATE()),
    (@T125, 'Findings', 4, 1, '<p><strong>Right Knee:</strong></p><p>Joint space is maintained. No osteophyte formation. No fracture or dislocation. Patella is normal in position. Soft tissues are unremarkable.</p><p><strong>Left Knee:</strong></p><p>Joint space is maintained. No osteophyte formation. No fracture or dislocation. Patella is normal in position. Soft tissues are unremarkable.</p>', NULL, 1, 1, 'X-Ray', 'Knee', 'Bilateral', 0, GETDATE()),
    (@T125, 'Impression', 5, 1, '<p>Normal radiograph of both knees.</p>', NULL, 1, 1, 'X-Ray', 'Knee', 'Bilateral', 0, GETDATE()),
    (@T125, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'X-Ray', 'Knee', 'Bilateral', 0, GETDATE());
END
GO

-- ===== CT Brain Contrast (Test_ID = 127) =====
DECLARE @T127 INT = 127;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T127)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, Contrast_Agent, CreatedDate) VALUES
    (@T127, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'CT', 'Brain', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T127, 'Technique', 2, 1, '<p>Non-contrast and contrast-enhanced CT scan of the brain was performed. {{ContrastVolume}} ml of non-ionic iodinated contrast (Iohexol) was administered intravenously. Slice thickness: {{SliceThickness}} mm.</p>', '{{ContrastVolume}},{{SliceThickness}}', 1, 1, 'CT', 'Brain', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T127, 'Comparison', 3, 0, '<p>No prior imaging available for comparison.</p>', NULL, 1, 1, 'CT', 'Brain', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T127, 'Findings', 4, 1, '<p><strong>Brain parenchyma:</strong> No evidence of intra-axial or extra-axial hemorrhage. No abnormal enhancing lesion on post-contrast images. Grey-white matter differentiation is preserved.</p><p><strong>Ventricles:</strong> Ventricular system is normal in size and configuration. No midline shift.</p><p><strong>Basal cisterns:</strong> Basal cisterns are patent.</p><p><strong>Meninges:</strong> No abnormal meningeal enhancement.</p><p><strong>Calvarium:</strong> No fracture. Paranasal sinuses appear clear.</p><p><strong>DLP:</strong> {{DLP}} mGy.cm | <strong>CTDIvol:</strong> {{CTDIvol}} mGy</p>', '{{DLP}},{{CTDIvol}}', 1, 1, 'CT', 'Brain', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T127, 'Impression', 5, 1, '<p>Normal contrast-enhanced CT scan of the brain.</p>', NULL, 1, 1, 'CT', 'Brain', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T127, 'Recommendation', 6, 0, '<p>MRI brain may be considered for further evaluation if clinically indicated.</p>', NULL, 1, 1, 'CT', 'Brain', 'N/A', 1, 'Iohexol', GETDATE());
END
GO

-- ===== CT Chest HRCT (Test_ID = 128) =====
DECLARE @T128 INT = 128;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T128)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T128, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'CT', 'Chest', 'N/A', 0, GETDATE()),
    (@T128, 'Technique', 2, 1, '<p>High-resolution CT (HRCT) of the chest was performed without contrast in supine position with thin sections (1-1.25 mm). Slice thickness: {{SliceThickness}} mm.</p>', '{{SliceThickness}}', 1, 1, 'CT', 'Chest', 'N/A', 0, GETDATE()),
    (@T128, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'CT', 'Chest', 'N/A', 0, GETDATE()),
    (@T128, 'Findings', 4, 1, '<p><strong>Lung parenchyma:</strong> Both lungs show normal parenchymal attenuation. No ground-glass opacity, consolidation, or nodule. No honeycombing or traction bronchiectasis.</p><p><strong>Airways:</strong> Trachea and main bronchi are normal in calibre. No bronchial wall thickening or bronchiectasis.</p><p><strong>Pleura:</strong> No pleural effusion or pleural thickening.</p><p><strong>Mediastinum:</strong> No lymphadenopathy. Heart and great vessels are normal.</p><p><strong>Bony thorax:</strong> No lytic or sclerotic lesion.</p><p><strong>DLP:</strong> {{DLP}} mGy.cm | <strong>CTDIvol:</strong> {{CTDIvol}} mGy</p>', '{{DLP}},{{CTDIvol}}', 1, 1, 'CT', 'Chest', 'N/A', 0, GETDATE()),
    (@T128, 'Impression', 5, 1, '<p>Normal HRCT of the chest.</p>', NULL, 1, 1, 'CT', 'Chest', 'N/A', 0, GETDATE()),
    (@T128, 'Recommendation', 6, 0, '<p>Clinical correlation advised. Pulmonary function tests may be correlated.</p>', NULL, 1, 1, 'CT', 'Chest', 'N/A', 0, GETDATE());
END
GO

-- ===== CT Abdomen & Pelvis Contrast (Test_ID = 129) =====
DECLARE @T129 INT = 129;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T129)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, Contrast_Agent, CreatedDate) VALUES
    (@T129, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'CT', 'Abdomen', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T129, 'Technique', 2, 1, '<p>Contrast-enhanced CT of the abdomen and pelvis was performed. {{ContrastVolume}} ml of non-ionic iodinated contrast was administered intravenously. Arterial and portal venous phase images were obtained. {{ContrastPhase}}.</p>', '{{ContrastVolume}},{{ContrastPhase}}', 1, 1, 'CT', 'Abdomen', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T129, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'CT', 'Abdomen', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T129, 'Findings', 4, 1, '<p><strong>Liver:</strong> Normal size, shape and enhancement pattern. No focal lesion. Hepatic vasculature is normal. No biliary dilatation.</p><p><strong>Gallbladder & CBD:</strong> Normal. No calculus. CBD is not dilated.</p><p><strong>Pancreas:</strong> Normal in size, morphology and enhancement. No focal lesion or peripancreatic fluid.</p><p><strong>Spleen:</strong> Normal in size and enhancement. No focal lesion.</p><p><strong>Adrenals:</strong> Both adrenal glands are normal.</p><p><strong>Kidneys & ureters:</strong> Both kidneys show normal size, cortical thickness and enhancement. No calculus, hydronephrosis or focal lesion. Ureters are not dilated.</p><p><strong>Urinary bladder:</strong> Normal wall thickness. No mass or calculus.</p><p><strong>Bowel:</strong> No bowel wall thickening, obstruction or free air.</p><p><strong>Lymph nodes:</strong> No significant lymphadenopathy.</p><p><strong>Peritoneum:</strong> No ascites or peritoneal thickening.</p><p><strong>Vasculature:</strong> Aorta and IVC are normal in calibre.</p><p><strong>Bony structures:</strong> No suspicious lytic or sclerotic lesion.</p><p><strong>DLP:</strong> {{DLP}} mGy.cm | <strong>CTDIvol:</strong> {{CTDIvol}} mGy</p>', '{{DLP}},{{CTDIvol}}', 1, 1, 'CT', 'Abdomen', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T129, 'Impression', 5, 1, '<p>Normal contrast-enhanced CT of the abdomen and pelvis.</p>', NULL, 1, 1, 'CT', 'Abdomen', 'N/A', 1, 'Iohexol', GETDATE()),
    (@T129, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'CT', 'Abdomen', 'N/A', 1, 'Iohexol', GETDATE());
END
GO

-- ===== CT PNS Plain (Test_ID = 130) =====
DECLARE @T130 INT = 130;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T130)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T130, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'CT', 'PNS', 'N/A', 0, GETDATE()),
    (@T130, 'Technique', 2, 1, '<p>Non-contrast CT of the paranasal sinuses was performed with axial and coronal reconstructions.</p>', NULL, 1, 1, 'CT', 'PNS', 'N/A', 0, GETDATE()),
    (@T130, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'CT', 'PNS', 'N/A', 0, GETDATE()),
    (@T130, 'Findings', 4, 1, '<p><strong>Maxillary sinuses:</strong> Both maxillary sinuses are well pneumatised and clear. No mucosal thickening or fluid level.</p><p><strong>Frontal sinuses:</strong> Both frontal sinuses are clear.</p><p><strong>Ethmoid sinuses:</strong> Anterior and posterior ethmoid air cells are clear bilaterally.</p><p><strong>Sphenoid sinuses:</strong> Both sphenoid sinuses are clear.</p><p><strong>Nasal cavity:</strong> Nasal septum is midline / shows mild deviation to the right/left. Inferior turbinates are normal. No nasal polyp.</p><p><strong>Ostiomeatal complex (OMC):</strong> OMC is patent bilaterally.</p><p><strong>Orbits:</strong> Orbital walls are intact. Retro-orbital fat is normal.</p>', NULL, 1, 1, 'CT', 'PNS', 'N/A', 0, GETDATE()),
    (@T130, 'Impression', 5, 1, '<p>Normal CT of the paranasal sinuses.</p>', NULL, 1, 1, 'CT', 'PNS', 'N/A', 0, GETDATE()),
    (@T130, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'CT', 'PNS', 'N/A', 0, GETDATE());
END
GO

-- ===== MRI Brain Contrast (Test_ID = 132) =====
DECLARE @T132 INT = 132;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T132)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, Contrast_Agent, CreatedDate) VALUES
    (@T132, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'MRI', 'Brain', 'N/A', 1, 'Gadolinium', GETDATE()),
    (@T132, 'Technique', 2, 1, '<p>MRI of the brain was performed on {{FieldStrength}}T scanner. Pre- and post-contrast sequences obtained: {{Sequences}}. Gadolinium-based contrast agent was administered intravenously.</p>', '{{FieldStrength}},{{Sequences}}', 1, 1, 'MRI', 'Brain', 'N/A', 1, 'Gadolinium', GETDATE()),
    (@T132, 'Comparison', 3, 0, '<p>No prior imaging available for comparison.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 1, 'Gadolinium', GETDATE()),
    (@T132, 'Findings', 4, 1, '<p><strong>Brain parenchyma:</strong> Normal signal intensity on all sequences. No abnormal signal or enhancing lesion on post-contrast images. Grey-white matter differentiation is maintained.</p><p><strong>Ventricles:</strong> Normal in size and configuration. No midline shift.</p><p><strong>Posterior fossa:</strong> Cerebellum and brainstem are normal.</p><p><strong>Sella & parasellar region:</strong> Pituitary gland shows normal enhancement. Optic chiasm is normal.</p><p><strong>Meninges:</strong> No abnormal meningeal enhancement.</p><p><strong>IAMs & CPAs:</strong> Internal auditory meati and cerebellopontine angles are normal.</p><p><strong>Orbits & sinuses:</strong> Appear normal.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 1, 'Gadolinium', GETDATE()),
    (@T132, 'Impression', 5, 1, '<p>Normal contrast-enhanced MRI of the brain.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 1, 'Gadolinium', GETDATE()),
    (@T132, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'MRI', 'Brain', 'N/A', 1, 'Gadolinium', GETDATE());
END
GO

-- ===== MRI Knee (Test_ID = 134) =====
DECLARE @T134 INT = 134;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T134)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T134, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'MRI', 'Knee', 'Right', 0, GETDATE()),
    (@T134, 'Technique', 2, 1, '<p>MRI of the knee was performed on {{FieldStrength}}T scanner. Sequences: PD FS, T1W, T2W in sagittal, coronal and axial planes.</p>', '{{FieldStrength}}', 1, 1, 'MRI', 'Knee', 'Right', 0, GETDATE()),
    (@T134, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'MRI', 'Knee', 'Right', 0, GETDATE()),
    (@T134, 'Findings', 4, 1, '<p><strong>Menisci:</strong></p><ul><li><strong>Medial meniscus:</strong> Normal morphology and signal intensity. No tear.</li><li><strong>Lateral meniscus:</strong> Normal morphology and signal intensity. No tear.</li></ul><p><strong>Cruciate ligaments:</strong></p><ul><li><strong>ACL:</strong> Intact with normal signal and course.</li><li><strong>PCL:</strong> Intact with normal signal and course.</li></ul><p><strong>Collateral ligaments:</strong> MCL and LCL are intact.</p><p><strong>Articular cartilage:</strong> Normal articular cartilage thickness. No chondral defect.</p><p><strong>Bone:</strong> Normal marrow signal. No bone contusion, fracture or osteochondral lesion.</p><p><strong>Patellofemoral joint:</strong> Normal patellar tracking. Retropatellar cartilage is intact.</p><p><strong>Joint effusion:</strong> No significant joint effusion.</p><p><strong>Popliteal fossa:</strong> No Baker''s cyst or popliteal mass.</p>', NULL, 1, 1, 'MRI', 'Knee', 'Right', 0, GETDATE()),
    (@T134, 'Impression', 5, 1, '<p>Normal MRI of the knee.</p>', NULL, 1, 1, 'MRI', 'Knee', 'Right', 0, GETDATE()),
    (@T134, 'Recommendation', 6, 0, '<p>Clinical correlation advised.</p>', NULL, 1, 1, 'MRI', 'Knee', 'Right', 0, GETDATE());
END
GO

-- ===== USG Pelvis (Test_ID = 136) =====
DECLARE @T136 INT = 136;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T136)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T136, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T136, 'Technique', 2, 1, '<p>Transabdominal ultrasonographic evaluation of the pelvis was performed using {{Transducer}} MHz transducer with adequate bladder filling.</p>', '{{Transducer}}', 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T136, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T136, 'Findings', 4, 1, '<p><strong>Uterus:</strong> Normal in size, shape and echotexture. Anteverted/retroverted. Endometrial thickness is normal. No focal myometrial lesion.</p><p><strong>Cervix:</strong> Normal in appearance. No nabothian cyst or mass.</p><p><strong>Right ovary:</strong> Normal in size and echotexture. Follicular pattern is normal. No cyst or mass.</p><p><strong>Left ovary:</strong> Normal in size and echotexture. Follicular pattern is normal. No cyst or mass.</p><p><strong>Pouch of Douglas:</strong> No free fluid.</p><p><strong>Urinary bladder:</strong> Adequately distended. Normal wall thickness. No calculus or mass.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T136, 'Impression', 5, 1, '<p>Normal pelvic ultrasound.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T136, 'Recommendation', 6, 0, '<p>Transvaginal ultrasound may be considered for better evaluation if clinically indicated.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE());
END
GO

-- ===== USG Obstetric Anomaly Scan (Test_ID = 137) =====
DECLARE @T137 INT = 137;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T137)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T137, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/F, G_P_A_, referred for anomaly scan at {{GestationalAge}} weeks of gestation. LMP: ____.</p>', '{{PatientName}},{{PatientAge}},{{GestationalAge}}', 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T137, 'Technique', 2, 1, '<p>Transabdominal obstetric ultrasound was performed using {{Transducer}} MHz curvilinear transducer.</p>', '{{Transducer}}', 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T137, 'Comparison', 3, 0, '<p>Comparison with previous scan dated ____ if available.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T137, 'Findings', 4, 1, '<p><strong>Fetal number:</strong> Single live intrauterine fetus.</p><p><strong>Presentation:</strong> Cephalic / Breech / Transverse.</p><p><strong>Fetal biometry:</strong></p><ul><li>BPD: ___ mm (corresponding to ___ weeks)</li><li>HC: ___ mm</li><li>AC: ___ mm</li><li>FL: ___ mm</li><li>EFW: ___ grams (___th percentile)</li></ul><p><strong>Fetal anatomy:</strong></p><ul><li><strong>Head:</strong> Calvarium intact. Cerebral ventricles normal. Cerebellum and cisterna magna normal. Nuchal fold normal.</li><li><strong>Face:</strong> Normal profile. Both orbits seen. Nasal bone present. Lips and palate appear intact.</li><li><strong>Spine:</strong> Normal vertebral alignment. Overlying skin intact.</li><li><strong>Heart:</strong> Four-chamber view normal. Outflow tracts appear normal. Regular cardiac activity.</li><li><strong>Chest:</strong> Both lungs echogenic. No pleural effusion.</li><li><strong>Abdomen:</strong> Stomach bubble seen. Bowel echogenicity normal. Both kidneys seen. Bladder visualised.</li><li><strong>Extremities:</strong> All four limbs visualised with normal long bones.</li></ul><p><strong>Placenta:</strong> Anterior / Posterior / Fundal. Grade ___. Not low-lying.</p><p><strong>Amniotic fluid:</strong> AFI: ___ cm (Normal).</p><p><strong>Umbilical cord:</strong> Three-vessel cord.</p><p><strong>Cervix:</strong> Cervical length: ___ mm (Normal >25 mm).</p><p><strong>Fetal heart rate:</strong> ___ bpm (Normal).</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T137, 'Impression', 5, 1, '<p>Single live intrauterine pregnancy at approximately ___ weeks of gestation. No gross structural anomaly detected. Fetal growth parameters are appropriate for gestational age.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE()),
    (@T137, 'Recommendation', 6, 0, '<p>Follow-up growth scan at 32-34 weeks recommended. Anomaly scan does not rule out all structural abnormalities.</p>', NULL, 1, 1, 'USG', 'Pelvis', 'N/A', 0, GETDATE());
END
GO

-- ===== USG Thyroid (Test_ID = 138) =====
DECLARE @T138 INT = 138;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T138)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T138, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'USG', 'Thyroid', 'Bilateral', 0, GETDATE()),
    (@T138, 'Technique', 2, 1, '<p>High-resolution ultrasonographic evaluation of the thyroid gland was performed using {{Transducer}} MHz linear transducer.</p>', '{{Transducer}}', 1, 1, 'USG', 'Thyroid', 'Bilateral', 0, GETDATE()),
    (@T138, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'USG', 'Thyroid', 'Bilateral', 0, GETDATE()),
    (@T138, 'Findings', 4, 1, '<p><strong>Right lobe:</strong> Measures ___ x ___ x ___ cm (Vol: ___ ml). Normal echotexture. No focal nodule or cystic lesion.</p><p><strong>Left lobe:</strong> Measures ___ x ___ x ___ cm (Vol: ___ ml). Normal echotexture. No focal nodule or cystic lesion.</p><p><strong>Isthmus:</strong> Measures ___ mm in thickness. Normal.</p><p><strong>Total thyroid volume:</strong> ___ ml (Normal).</p><p><strong>Vascularity:</strong> Normal parenchymal vascularity on colour Doppler.</p><p><strong>Cervical lymph nodes:</strong> No suspicious cervical lymphadenopathy. Few reactive nodes seen, if any.</p>', NULL, 1, 1, 'USG', 'Thyroid', 'Bilateral', 0, GETDATE()),
    (@T138, 'Impression', 5, 1, '<p>Normal thyroid gland on ultrasound.</p>', NULL, 1, 1, 'USG', 'Thyroid', 'Bilateral', 0, GETDATE()),
    (@T138, 'Recommendation', 6, 0, '<p>Thyroid function tests may be correlated. Clinical correlation advised.</p>', NULL, 1, 1, 'USG', 'Thyroid', 'Bilateral', 0, GETDATE());
END
GO

-- ===== USG KUB (Test_ID = 139) =====
DECLARE @T139 INT = 139;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T139)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T139, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'USG', 'KUB', 'Bilateral', 0, GETDATE()),
    (@T139, 'Technique', 2, 1, '<p>Ultrasonographic evaluation of both kidneys, ureters and urinary bladder was performed using {{Transducer}} MHz curvilinear transducer.</p>', '{{Transducer}}', 1, 1, 'USG', 'KUB', 'Bilateral', 0, GETDATE()),
    (@T139, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'USG', 'KUB', 'Bilateral', 0, GETDATE()),
    (@T139, 'Findings', 4, 1, '<p><strong>Right kidney:</strong> Measures ___ x ___ cm. Normal size, shape and cortical echotexture. Corticomedullary differentiation is maintained. No calculus, hydronephrosis or focal lesion. Cortical thickness: ___ mm.</p><p><strong>Left kidney:</strong> Measures ___ x ___ cm. Normal size, shape and cortical echotexture. Corticomedullary differentiation is maintained. No calculus, hydronephrosis or focal lesion. Cortical thickness: ___ mm.</p><p><strong>Ureters:</strong> Not dilated. No ureteric calculus seen.</p><p><strong>Urinary bladder:</strong> Adequately distended. Normal wall thickness (___ mm). No calculus, mass or diverticulum.</p><p><strong>Post-void residual:</strong> ___ ml (Normal < 50 ml).</p><p><strong>Prostate (if male):</strong> Normal in size (___ x ___ x ___ cm, Volume: ___ ml). Homogeneous echotexture. No focal lesion.</p>', NULL, 1, 1, 'USG', 'KUB', 'Bilateral', 0, GETDATE()),
    (@T139, 'Impression', 5, 1, '<p>Normal ultrasonographic study of the kidneys, ureters and urinary bladder.</p>', NULL, 1, 1, 'USG', 'KUB', 'Bilateral', 0, GETDATE()),
    (@T139, 'Recommendation', 6, 0, '<p>Clinical correlation advised. Renal function tests may be correlated.</p>', NULL, 1, 1, 'USG', 'KUB', 'Bilateral', 0, GETDATE());
END
GO

-- ===== Mammography Bilateral (Test_ID = 140) =====
DECLARE @T140 INT = 140;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T140)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T140, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/F, referred for {{ClinicalIndication}}. Menopausal status: Pre/Post-menopausal.</p>', '{{PatientName}},{{PatientAge}},{{ClinicalIndication}}', 1, 1, 'Mammography', 'Breast', 'Bilateral', 0, GETDATE()),
    (@T140, 'Technique', 2, 1, '<p>Standard bilateral mammography was performed in CC (craniocaudal) and MLO (mediolateral oblique) views.</p>', NULL, 1, 1, 'Mammography', 'Breast', 'Bilateral', 0, GETDATE()),
    (@T140, 'Comparison', 3, 0, '<p>No prior mammogram available for comparison.</p>', NULL, 1, 1, 'Mammography', 'Breast', 'Bilateral', 0, GETDATE()),
    (@T140, 'Findings', 4, 1, '<p><strong>Breast composition:</strong> ACR Density Category: __ (a: almost entirely fatty / b: scattered fibroglandular / c: heterogeneously dense / d: extremely dense).</p><p><strong>Right breast:</strong> No suspicious mass, architectural distortion, or suspicious calcifications. No skin thickening or retraction.</p><p><strong>Left breast:</strong> No suspicious mass, architectural distortion, or suspicious calcifications. No skin thickening or retraction.</p><p><strong>Axillary lymph nodes:</strong> Normal bilateral axillary lymph nodes. No suspicious lymphadenopathy.</p>', NULL, 1, 1, 'Mammography', 'Breast', 'Bilateral', 0, GETDATE()),
    (@T140, 'Impression', 5, 1, '<p>Normal bilateral mammogram. BI-RADS Category 1 (Negative).</p>', NULL, 1, 1, 'Mammography', 'Breast', 'Bilateral', 0, GETDATE()),
    (@T140, 'Recommendation', 6, 0, '<p>Routine screening mammogram in 1 year recommended. Breast self-examination monthly.</p>', NULL, 1, 1, 'Mammography', 'Breast', 'Bilateral', 0, GETDATE());
END
GO

-- ===== Doppler Carotid Bilateral (Test_ID = 141) =====
DECLARE @T141 INT = 141;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T141)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T141, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'Doppler', 'Neck', 'Bilateral', 0, GETDATE()),
    (@T141, 'Technique', 2, 1, '<p>Duplex and colour Doppler evaluation of the bilateral carotid and vertebral arteries was performed using {{Transducer}} MHz linear transducer.</p>', '{{Transducer}}', 1, 1, 'Doppler', 'Neck', 'Bilateral', 0, GETDATE()),
    (@T141, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'Doppler', 'Neck', 'Bilateral', 0, GETDATE()),
    (@T141, 'Findings', 4, 1, '<p><strong>Right side:</strong></p><ul><li><strong>CCA:</strong> Normal calibre and wall thickness. IMT: ___ mm (Normal <1.0 mm). No plaque.</li><li><strong>ICA:</strong> Normal calibre. PSV: ___ cm/s. No stenosis.</li><li><strong>ECA:</strong> Normal flow pattern.</li><li><strong>Vertebral artery:</strong> Normal calibre and antegrade flow. PSV: ___ cm/s.</li></ul><p><strong>Left side:</strong></p><ul><li><strong>CCA:</strong> Normal calibre and wall thickness. IMT: ___ mm (Normal <1.0 mm). No plaque.</li><li><strong>ICA:</strong> Normal calibre. PSV: ___ cm/s. No stenosis.</li><li><strong>ECA:</strong> Normal flow pattern.</li><li><strong>Vertebral artery:</strong> Normal calibre and antegrade flow. PSV: ___ cm/s.</li></ul><p><strong>ICA/CCA ratio:</strong> Right: ___ | Left: ___ (Normal < 0.8)</p>', NULL, 1, 1, 'Doppler', 'Neck', 'Bilateral', 0, GETDATE()),
    (@T141, 'Impression', 5, 1, '<p>Normal bilateral carotid and vertebral artery Doppler study. No haemodynamically significant stenosis.</p>', NULL, 1, 1, 'Doppler', 'Neck', 'Bilateral', 0, GETDATE()),
    (@T141, 'Recommendation', 6, 0, '<p>Clinical correlation advised. Lipid profile and risk factor assessment recommended.</p>', NULL, 1, 1, 'Doppler', 'Neck', 'Bilateral', 0, GETDATE());
END
GO

-- ===== Doppler Lower Limb Venous (Test_ID = 142) =====
DECLARE @T142 INT = 142;
IF NOT EXISTS (SELECT 1 FROM LabDescriptiveTestTemplate WHERE Test_ID = @T142)
BEGIN
    INSERT INTO LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId, Modality, Body_Part, Laterality, Contrast_Required, CreatedDate) VALUES
    (@T142, 'Clinical History', 1, 1, '<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}. ?DVT.</p>', '{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}', 1, 1, 'Doppler', 'Lower Limb', 'Bilateral', 0, GETDATE()),
    (@T142, 'Technique', 2, 1, '<p>Colour Doppler and compression ultrasound evaluation of the bilateral lower limb deep and superficial venous system was performed using {{Transducer}} MHz linear transducer.</p>', '{{Transducer}}', 1, 1, 'Doppler', 'Lower Limb', 'Bilateral', 0, GETDATE()),
    (@T142, 'Comparison', 3, 0, '<p>No prior study available for comparison.</p>', NULL, 1, 1, 'Doppler', 'Lower Limb', 'Bilateral', 0, GETDATE()),
    (@T142, 'Findings', 4, 1, '<p><strong>Right lower limb:</strong></p><ul><li><strong>CFV (Common Femoral Vein):</strong> Compressible. Normal flow with respiratory phasicity. No thrombus.</li><li><strong>SFV (Superficial Femoral Vein):</strong> Compressible throughout. Normal augmentation. No thrombus.</li><li><strong>Popliteal vein:</strong> Compressible. Normal flow. No thrombus.</li><li><strong>Posterior tibial & peroneal veins:</strong> Compressible. No thrombus.</li><li><strong>GSV (Great Saphenous Vein):</strong> Normal calibre. Competent SFJ. No reflux on Valsalva.</li></ul><p><strong>Left lower limb:</strong></p><ul><li><strong>CFV:</strong> Compressible. Normal flow with respiratory phasicity. No thrombus.</li><li><strong>SFV:</strong> Compressible throughout. Normal augmentation. No thrombus.</li><li><strong>Popliteal vein:</strong> Compressible. Normal flow. No thrombus.</li><li><strong>Posterior tibial & peroneal veins:</strong> Compressible. No thrombus.</li><li><strong>GSV:</strong> Normal calibre. Competent SFJ. No reflux on Valsalva.</li></ul>', NULL, 1, 1, 'Doppler', 'Lower Limb', 'Bilateral', 0, GETDATE()),
    (@T142, 'Impression', 5, 1, '<p>No evidence of deep vein thrombosis (DVT) in bilateral lower limbs. Normal venous Doppler study.</p>', NULL, 1, 1, 'Doppler', 'Lower Limb', 'Bilateral', 0, GETDATE()),
    (@T142, 'Recommendation', 6, 0, '<p>Clinical correlation advised. D-Dimer levels may be correlated if clinically suspected DVT.</p>', NULL, 1, 1, 'Doppler', 'Lower Limb', 'Bilateral', 0, GETDATE());
END
GO
