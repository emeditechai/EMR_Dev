-- ============================================================================================================
-- 2550: Investigation Master - standard test catalogue (275 tests).
--   Adds the standard laboratory, imaging and cardiac tests that the master does not have yet, with a typical Indian
--   price, sample type, unit, method, TAT and standard adult reference ranges (by gender where they differ).
--   Areas: Clinical Biochemistry (diabetes, cardiac, lipids, iron, electrolytes, pancreas, drug levels, urine chemistry),
--   Haematology & coagulation, blood bank, clinical pathology, microbiology & infectious serology, hormones & tumour
--   markers, clinical immunology (autoimmune, allergy), histopathology & cytology (with IHC), molecular (PCR / viral
--   load), cardiac diagnostics (ECG / Echo / TMT / Holter) and radiology (X-ray, USG, Doppler, CT, MRI, DEXA).
--   New lab departments where none existed: Clinical Immunology, Histopathology & Cytology, Molecular Biology,
--   Cardiology Diagnostics (the existing Histopathology and Molecular categories move under the new departments).
--   Departments are global (one list for all companies, as the app reads them): each is created once and found by
--   name whatever the company; categories, sub-categories, units, methods, samples and tests are per company.
--   Missing sub-categories, units and sample types are created; a method is created in the department of the test's
--   category when that department does not have it (Investigation Master lists methods by department). Select-type tests get their result options
--   (Positive / Negative, Reactive / Non-Reactive, blood groups ...); imaging, cardiac and descriptive tests get a
--   standard report template (Clinical History / Technique / Findings / Impression / Recommendation).
--   A test whose name already exists in the company is skipped, so the script is safe to re-run.
--   Reference ranges are standard adult textbook values: have the pathologist review them before going live.
--   One database, many companies: the script runs once per active company of CompanyMaster (a company with an empty
--   master gets the full catalogue too); every lookup and every row it adds is that company's own.
--   Settings at the top of the run:
--     @OnlyCompanyId  NULL = every active company; a CompanyId = only that company.
--     @PreviewOnly    1 = change nothing, only list per company what would be found, created, added and skipped,
--                     and existing tests with a similar name (possible duplicates); 0 = apply.
-- Needs 2549. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- ════════ SETTINGS ════════
DECLARE @OnlyCompanyId INT = NULL;   -- NULL = every active company; e.g. 3 = only company 3
DECLARE @PreviewOnly   BIT = 0;      -- 1 = preview only (nothing is changed); 0 = apply
-- ══════════════════════════

DECLARE @T TABLE (Seq INT IDENTITY PRIMARY KEY, Name NVARCHAR(200), CatKey VARCHAR(5), Sub NVARCHAR(150), Sample NVARCHAR(100), Unit NVARCHAR(30), Method NVARCHAR(150), RType VARCHAR(20), Tat INT, Mrp DECIMAL(18,2), Gender VARCHAR(10));
INSERT @T (Name, CatKey, Sub, Sample, Unit, Method, RType, Tat, Mrp, Gender) VALUES
 (N'Random Blood Sugar (RBS)', 'BIO', N'Diabetic Profile & HbA1c', N'Fluoride Plasma', N'mg/dL', N'Photometric / Spectrophotometry', 'Numeric', 4, 100, 'All'),
 (N'Oral Glucose Tolerance Test (OGTT, 75 g)', 'BIO', N'Diabetic Profile & HbA1c', N'Fluoride Plasma', N'mg/dL', N'Photometric / Spectrophotometry', 'Text', 6, 350, 'All'),
 (N'Glucose Challenge Test (GCT, 50 g)', 'BIO', N'Diabetic Profile & HbA1c', N'Fluoride Plasma', N'mg/dL', N'Photometric / Spectrophotometry', 'Numeric', 4, 200, 'Female'),
 (N'Fructosamine', 'BIO', N'Diabetic Profile & HbA1c', N'Serum', N'µmol/L', N'Photometric / Spectrophotometry', 'Numeric', 24, 600, 'All'),
 (N'Average Blood Glucose (eAG)', 'BIO', N'Diabetic Profile & HbA1c', N'Whole Blood (EDTA)', N'mg/dL', N'Calculated Ratio / Formula', 'Numeric', 24, 100, 'All'),
 (N'Gamma Glutamyl Transferase (GGT)', 'BIO', N'Liver Function Test (LFT)', N'Serum', N'U/L', N'Photometric / Spectrophotometry', 'Numeric', 6, 250, 'All'),
 (N'Lactate Dehydrogenase (LDH)', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'U/L', N'Photometric / Spectrophotometry', 'Numeric', 6, 350, 'All'),
 (N'Creatine Phosphokinase (CPK) Total', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'U/L', N'Photometric / Spectrophotometry', 'Numeric', 6, 400, 'All'),
 (N'Troponin I (Quantitative)', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 2, 900, 'All'),
 (N'Troponin T (High Sensitive)', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'ng/L', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 2, 1200, 'All'),
 (N'NT-proBNP', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'pg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 6, 2500, 'All'),
 (N'Homocysteine', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'µmol/L', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1200, 'All'),
 (N'C-Reactive Protein (CRP, Quantitative)', 'BIO', N'Cardiac Markers & Enzymes', N'Serum', N'mg/L', N'Immunoturbidimetry', 'Numeric', 4, 400, 'All'),
 (N'Procalcitonin (PCT)', 'BIO', N'Special Biochemistry', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 4, 2500, 'All'),
 (N'Lipoprotein (a)', 'BIO', N'Lipid Profile', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 24, 900, 'All'),
 (N'Apolipoprotein A1', 'BIO', N'Lipid Profile', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 24, 700, 'All'),
 (N'Apolipoprotein B', 'BIO', N'Lipid Profile', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 24, 700, 'All'),
 (N'Non-HDL Cholesterol', 'BIO', N'Lipid Profile', N'Serum', N'mg/dL', N'Calculated Ratio / Formula', 'Numeric', 6, 100, 'All'),
 (N'Serum Iron', 'BIO', N'Iron & Anaemia Studies', N'Serum', N'µg/dL', N'Photometric / Spectrophotometry', 'Numeric', 6, 300, 'All'),
 (N'Total Iron Binding Capacity (TIBC)', 'BIO', N'Iron & Anaemia Studies', N'Serum', N'µg/dL', N'Photometric / Spectrophotometry', 'Numeric', 6, 350, 'All'),
 (N'Transferrin Saturation', 'BIO', N'Iron & Anaemia Studies', N'Serum', N'%', N'Calculated Ratio / Formula', 'Numeric', 6, 200, 'All'),
 (N'Serum Ferritin', 'BIO', N'Iron & Anaemia Studies', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 600, 'All'),
 (N'Serum Transferrin', 'BIO', N'Iron & Anaemia Studies', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 24, 700, 'All'),
 (N'Serum Magnesium', 'BIO', N'Electrolytes & Minerals', N'Serum', N'mg/dL', N'Photometric / Spectrophotometry', 'Numeric', 6, 300, 'All'),
 (N'Ionized Calcium', 'BIO', N'Electrolytes & Minerals', N'Heparinized Whole Blood', N'mmol/L', N'Ion Selective Electrode (ISE)', 'Numeric', 4, 400, 'All'),
 (N'Serum Bicarbonate', 'BIO', N'Electrolytes & Minerals', N'Serum', N'mEq/L', N'Photometric / Spectrophotometry', 'Numeric', 4, 250, 'All'),
 (N'Serum Osmolality', 'BIO', N'Electrolytes & Minerals', N'Serum', N'mOsm/kg', N'Calculated Ratio / Formula', 'Numeric', 6, 500, 'All'),
 (N'Serum Zinc', 'BIO', N'Electrolytes & Minerals', N'Serum', N'µg/dL', N'Photometric / Spectrophotometry', 'Numeric', 48, 1200, 'All'),
 (N'Arterial Blood Gas (ABG)', 'BIO', N'Electrolytes & Minerals', N'Heparinized Whole Blood', NULL, N'Ion Selective Electrode (ISE)', 'Text', 1, 1200, 'All'),
 (N'Plasma Ammonia', 'BIO', N'Special Biochemistry', N'Whole Blood (EDTA)', N'µmol/L', N'Photometric / Spectrophotometry', 'Numeric', 2, 900, 'All'),
 (N'Plasma Lactate', 'BIO', N'Special Biochemistry', N'Fluoride Plasma', N'mmol/L', N'Photometric / Spectrophotometry', 'Numeric', 2, 600, 'All'),
 (N'Serum Amylase', 'BIO', N'Pancreatic & GI Enzymes', N'Serum', N'U/L', N'Photometric / Spectrophotometry', 'Numeric', 6, 400, 'All'),
 (N'Serum Lipase', 'BIO', N'Pancreatic & GI Enzymes', N'Serum', N'U/L', N'Photometric / Spectrophotometry', 'Numeric', 6, 500, 'All'),
 (N'Cystatin C', 'BIO', N'Renal Function Test (RFT / KFT)', N'Serum', N'mg/L', N'Immunoturbidimetry', 'Numeric', 24, 1500, 'All'),
 (N'Serum Protein Electrophoresis', 'BIO', N'Special Biochemistry', N'Serum', NULL, N'Electrophoresis', 'Descriptive', 72, 1200, 'All'),
 (N'Serum Ceruloplasmin', 'BIO', N'Special Biochemistry', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 48, 1200, 'All'),
 (N'Serum Lithium', 'BIO', N'Therapeutic Drug Monitoring', N'Serum', N'mEq/L', N'Photometric / Spectrophotometry', 'Numeric', 24, 600, 'All'),
 (N'Serum Valproic Acid', 'BIO', N'Therapeutic Drug Monitoring', N'Serum', N'µg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1200, 'All'),
 (N'Serum Phenytoin', 'BIO', N'Therapeutic Drug Monitoring', N'Serum', N'µg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1200, 'All'),
 (N'Serum Carbamazepine', 'BIO', N'Therapeutic Drug Monitoring', N'Serum', N'µg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1200, 'All'),
 (N'Urine Microalbumin', 'BIO', N'Urine Biochemistry', N'Random Urine Sample', N'mg/L', N'Immunoturbidimetry', 'Numeric', 24, 500, 'All'),
 (N'Urine Albumin Creatinine Ratio (ACR)', 'BIO', N'Urine Biochemistry', N'Random Urine Sample', N'mg/g', N'Calculated Ratio / Formula', 'Numeric', 24, 600, 'All'),
 (N'Urine Protein Creatinine Ratio (PCR)', 'BIO', N'Urine Biochemistry', N'Random Urine Sample', N'mg/g', N'Calculated Ratio / Formula', 'Numeric', 24, 500, 'All'),
 (N'24 Hour Urine Protein', 'BIO', N'Urine Biochemistry', N'24 Hour Urine', N'mg/24hr', N'Photometric / Spectrophotometry', 'Numeric', 24, 400, 'All'),
 (N'Creatinine Clearance (24 Hour Urine)', 'BIO', N'Urine Biochemistry', N'24 Hour Urine', N'mL/min', N'Calculated Ratio / Formula', 'Numeric', 24, 600, 'All'),
 (N'24 Hour Urine Calcium', 'BIO', N'Urine Biochemistry', N'24 Hour Urine', N'mg/24hr', N'Photometric / Spectrophotometry', 'Numeric', 24, 400, 'All'),
 (N'Urine Sodium (Spot)', 'BIO', N'Urine Biochemistry', N'Random Urine Sample', N'mEq/L', N'Ion Selective Electrode (ISE)', 'Numeric', 6, 300, 'All'),
 (N'Urine Potassium (Spot)', 'BIO', N'Urine Biochemistry', N'Random Urine Sample', N'mEq/L', N'Ion Selective Electrode (ISE)', 'Numeric', 6, 300, 'All'),
 (N'Urine Creatinine (Spot)', 'BIO', N'Urine Biochemistry', N'Random Urine Sample', N'mg/dL', N'Photometric / Spectrophotometry', 'Numeric', 6, 200, 'All'),
 (N'Absolute Eosinophil Count (AEC)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', N'cells/cu.mm', N'Automated Electrical Impedance & Flow Cytometry', 'Numeric', 6, 150, 'All');
INSERT @T (Name, CatKey, Sub, Sample, Unit, Method, RType, Tat, Mrp, Gender) VALUES
 (N'Absolute Neutrophil Count (ANC)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', N'10^3/µL', N'Automated Electrical Impedance & Flow Cytometry', 'Numeric', 6, 150, 'All'),
 (N'Absolute Lymphocyte Count (ALC)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', N'10^3/µL', N'Automated Electrical Impedance & Flow Cytometry', 'Numeric', 6, 150, 'All'),
 (N'Red Cell Distribution Width (RDW-CV)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', N'%', N'Automated Electrical Impedance & Flow Cytometry', 'Numeric', 6, 80, 'All'),
 (N'Mean Platelet Volume (MPV)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', N'fL', N'Automated Electrical Impedance & Flow Cytometry', 'Numeric', 6, 80, 'All'),
 (N'Reticulocyte Count', 'HAE', N'Iron & Anaemia Studies', N'Whole Blood (EDTA)', N'%', N'Light Microscopy', 'Numeric', 24, 200, 'All'),
 (N'Peripheral Smear Examination', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', NULL, N'Light Microscopy', 'Descriptive', 24, 200, 'All'),
 (N'Malaria Parasite (Smear)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', NULL, N'Light Microscopy', 'Select', 4, 150, 'All'),
 (N'Malaria Antigen (Pf / Pv, Rapid)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', NULL, N'Immunochromatography (Rapid Card)', 'Select', 2, 400, 'All'),
 (N'Microfilaria (Smear)', 'HAE', N'Complete Blood Count (CBC) & ESR', N'Whole Blood (EDTA)', NULL, N'Light Microscopy', 'Select', 24, 200, 'All'),
 (N'Sickling Test', 'HAE', N'Iron & Anaemia Studies', N'Whole Blood (EDTA)', NULL, N'Light Microscopy', 'Select', 24, 250, 'All'),
 (N'Haemoglobin Electrophoresis (HPLC)', 'HAE', N'Iron & Anaemia Studies', N'Whole Blood (EDTA)', NULL, N'High Performance Liquid Chromatography (HPLC)', 'Descriptive', 72, 1000, 'All'),
 (N'G6PD (Quantitative)', 'HAE', N'Iron & Anaemia Studies', N'Whole Blood (EDTA)', N'U/g Hb', N'Photometric / Spectrophotometry', 'Numeric', 24, 600, 'All'),
 (N'Osmotic Fragility Test', 'HAE', N'Iron & Anaemia Studies', N'Heparinized Whole Blood', NULL, N'Photometric / Spectrophotometry', 'Descriptive', 48, 500, 'All'),
 (N'Bleeding Time (BT)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Whole Blood (EDTA)', N'min', N'Light Microscopy', 'Numeric', 1, 100, 'All'),
 (N'Clotting Time (CT)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Whole Blood (EDTA)', N'min', N'Light Microscopy', 'Numeric', 1, 100, 'All'),
 (N'Prothrombin Time (PT)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'sec', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 4, 250, 'All'),
 (N'International Normalized Ratio (INR)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'Ratio', N'Calculated Ratio / Formula', 'Numeric', 4, 100, 'All'),
 (N'Activated Partial Thromboplastin Time (APTT)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'sec', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 4, 350, 'All'),
 (N'Thrombin Time (TT)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'sec', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 24, 500, 'All'),
 (N'Plasma Fibrinogen', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'mg/dL', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 24, 600, 'All'),
 (N'D-Dimer', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'ng/mL', N'Immunoturbidimetry', 'Numeric', 4, 1000, 'All'),
 (N'Fibrin Degradation Products (FDP)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'µg/mL', N'Agglutination', 'Numeric', 24, 900, 'All'),
 (N'Factor VIII Assay', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'%', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 72, 2500, 'All'),
 (N'Factor IX Assay', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'%', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 72, 2500, 'All'),
 (N'Lupus Anticoagulant (dRVVT)', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', NULL, N'Coagulometry / Turbidimetric Clot Detection', 'Select', 72, 1800, 'All'),
 (N'Protein C Activity', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'%', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 72, 2500, 'All'),
 (N'Protein S Activity', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'%', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 72, 2500, 'All'),
 (N'Antithrombin III Activity', 'HAE', N'Coagulation Profile (PT/INR, APTT)', N'Citrated Plasma', N'%', N'Coagulometry / Turbidimetric Clot Detection', 'Numeric', 72, 2500, 'All'),
 (N'Blood Group & Rh Typing', 'HAE', N'Blood Group & Transfusion', N'Whole Blood (EDTA)', NULL, N'Agglutination', 'Select', 2, 150, 'All'),
 (N'Direct Coombs Test (DCT)', 'HAE', N'Blood Group & Transfusion', N'Whole Blood (EDTA)', NULL, N'Agglutination', 'Select', 6, 400, 'All'),
 (N'Indirect Coombs Test (ICT)', 'HAE', N'Blood Group & Transfusion', N'Serum', NULL, N'Agglutination', 'Select', 6, 500, 'All'),
 (N'Cross Match (Compatibility Test)', 'HAE', N'Blood Group & Transfusion', N'Whole Blood (EDTA)', NULL, N'Agglutination', 'Select', 2, 500, 'All'),
 (N'Urine Pregnancy Test (UPT)', 'CLP', N'Routine Urine & Microscopic Examination', N'Random Urine Sample', NULL, N'Immunochromatography (Rapid Card)', 'Select', 1, 150, 'Female'),
 (N'Urine Bence Jones Protein', 'CLP', N'Routine Urine & Microscopic Examination', N'Random Urine Sample', NULL, N'Photometric / Spectrophotometry', 'Select', 24, 500, 'All'),
 (N'Urine Ketone (Rothera)', 'CLP', N'Routine Urine & Microscopic Examination', N'Random Urine Sample', NULL, N'Photometric / Spectrophotometry', 'Select', 2, 100, 'All'),
 (N'Stool for Occult Blood', 'CLP', N'Stool Routine & Occult Blood', N'Stool Sample', NULL, N'Immunochromatography (Rapid Card)', 'Select', 6, 200, 'All'),
 (N'Stool for Ova & Cyst', 'CLP', N'Stool Routine & Occult Blood', N'Stool Sample', NULL, N'Light Microscopy', 'Descriptive', 6, 150, 'All'),
 (N'Stool Reducing Substances', 'CLP', N'Stool Routine & Occult Blood', N'Stool Sample', NULL, N'Photometric / Spectrophotometry', 'Select', 6, 200, 'All'),
 (N'Synovial Fluid Analysis', 'CLP', N'Body Fluid & CSF Analysis', N'Body Fluid (Pleural/Ascitic)', NULL, N'Light Microscopy', 'Descriptive', 24, 700, 'All'),
 (N'Body Fluid ADA (Adenosine Deaminase)', 'CLP', N'Body Fluid & CSF Analysis', N'Body Fluid (Pleural/Ascitic)', N'U/L', N'Photometric / Spectrophotometry', 'Numeric', 24, 700, 'All'),
 (N'Widal Test (Slide)', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Agglutination', 'Text', 6, 200, 'All'),
 (N'Typhidot IgM', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Immunochromatography (Rapid Card)', 'Select', 4, 500, 'All'),
 (N'Dengue NS1 Antigen', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Immunochromatography (Rapid Card)', 'Select', 4, 600, 'All'),
 (N'Dengue IgM Antibody', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 500, 'All'),
 (N'Dengue IgG Antibody', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 500, 'All'),
 (N'Chikungunya IgM', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 700, 'All'),
 (N'Leptospira IgM', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 900, 'All'),
 (N'Scrub Typhus IgM', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 900, 'All'),
 (N'Weil-Felix Test', 'MIC', N'Typhoid & Dengue Serology (Widal, NS1, IgM)', N'Serum', NULL, N'Agglutination', 'Text', 24, 300, 'All'),
 (N'HBsAg (Hepatitis B Surface Antigen)', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 6, 300, 'All');
INSERT @T (Name, CatKey, Sub, Sample, Unit, Method, RType, Tat, Mrp, Gender) VALUES
 (N'Anti-HCV Antibody', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 6, 500, 'All'),
 (N'HIV 1 & 2 Antibody', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 6, 400, 'All'),
 (N'VDRL / RPR', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Agglutination', 'Select', 6, 200, 'All'),
 (N'TPHA (Treponema pallidum)', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Agglutination', 'Select', 24, 500, 'All'),
 (N'Anti-HBs Antibody (Quantitative)', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', N'mIU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 800, 'All'),
 (N'HBeAg', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 24, 900, 'All'),
 (N'Anti-HBc Total', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 24, 900, 'All'),
 (N'Anti-HBc IgM', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 24, 1000, 'All'),
 (N'Hepatitis A Virus (HAV) IgM', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 900, 'All'),
 (N'Hepatitis E Virus (HEV) IgM', 'MIC', N'Viral Markers (HBsAg, HCV, HIV, VDRL)', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 24, 900, 'All'),
 (N'ASO Titre (Anti-Streptolysin O)', 'MIC', N'Infectious Serology', N'Serum', N'IU/mL', N'Immunoturbidimetry', 'Numeric', 24, 400, 'All'),
 (N'Toxoplasma IgG', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 48, 700, 'All'),
 (N'Toxoplasma IgM', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 48, 700, 'All'),
 (N'Rubella IgG', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 48, 700, 'All'),
 (N'Rubella IgM', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 48, 700, 'All'),
 (N'Cytomegalovirus (CMV) IgG', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 48, 800, 'All'),
 (N'Cytomegalovirus (CMV) IgM', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Chemiluminescence Immunoassay (CLIA)', 'Select', 48, 800, 'All'),
 (N'Herpes Simplex Virus (HSV 1 & 2) IgG', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 48, 900, 'All'),
 (N'Herpes Simplex Virus (HSV 1 & 2) IgM', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 48, 900, 'All'),
 (N'H. pylori Antibody IgG', 'MIC', N'Infectious Serology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 48, 900, 'All'),
 (N'H. pylori Stool Antigen', 'MIC', N'Infectious Serology', N'Stool Sample', NULL, N'Immunochromatography (Rapid Card)', 'Select', 24, 1200, 'All'),
 (N'Rotavirus Stool Antigen', 'MIC', N'Infectious Serology', N'Stool Sample', NULL, N'Immunochromatography (Rapid Card)', 'Select', 24, 800, 'All'),
 (N'Mantoux Test (Tuberculin Skin Test)', 'MIC', N'Infectious Serology', NULL, N'mm', N'Light Microscopy', 'Numeric', 72, 250, 'All'),
 (N'Stool Hanging Drop (Vibrio)', 'MIC', N'Microscopy & Special Stains', N'Stool Sample', NULL, N'Light Microscopy', 'Select', 6, 200, 'All'),
 (N'AFB Culture (Liquid / LJ)', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Sputum Sample', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 1008, 1500, 'All'),
 (N'Fungal Culture', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Pus / Wound Swab', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 504, 900, 'All'),
 (N'Throat Swab Culture & Sensitivity', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Throat / Nasopharyngeal Swab', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 72, 700, 'All'),
 (N'High Vaginal Swab Culture & Sensitivity', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Pus / Wound Swab', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 72, 700, 'Female'),
 (N'Ear Swab Culture & Sensitivity', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Pus / Wound Swab', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 72, 700, 'All'),
 (N'Eye Swab Culture & Sensitivity', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Pus / Wound Swab', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 72, 700, 'All'),
 (N'Semen Culture & Sensitivity', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Semen Sample', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 72, 700, 'Male'),
 (N'Catheter / ET Tip Culture & Sensitivity', 'MIC', N'Culture & Sensitivity - Other Specimens', N'Pus / Wound Swab', NULL, N'Automated Blood Culture & VITEK Antimicrobial Susceptibility Testing', 'Culture', 72, 700, 'All'),
 (N'Free T3 (FT3)', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'pg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 300, 'All'),
 (N'Free T4 (FT4)', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'ng/dL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 300, 'All'),
 (N'Anti-TPO Antibody', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'IU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 900, 'All'),
 (N'Anti-Thyroglobulin Antibody', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'IU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 1000, 'All'),
 (N'Thyroglobulin', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 1200, 'All'),
 (N'Calcitonin', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'pg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 72, 2000, 'All'),
 (N'TSH Receptor Antibody (TRAb)', 'END', N'Thyroid Profile (T3, T4, TSH)', N'Serum', N'IU/L', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 72, 2500, 'All'),
 (N'Luteinizing Hormone (LH)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'mIU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 450, 'All'),
 (N'Follicle Stimulating Hormone (FSH)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'mIU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 450, 'All'),
 (N'Prolactin', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 450, 'All'),
 (N'Estradiol (E2)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'pg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 600, 'All'),
 (N'Progesterone', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 600, 'All'),
 (N'Testosterone (Total)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'ng/dL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 600, 'All'),
 (N'Testosterone (Free)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'pg/mL', N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Numeric', 72, 1200, 'All'),
 (N'Anti-Mullerian Hormone (AMH)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 2000, 'Female'),
 (N'DHEA-S (Dehydroepiandrosterone Sulphate)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'µg/dL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 900, 'All'),
 (N'Sex Hormone Binding Globulin (SHBG)', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'nmol/L', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 1200, 'All'),
 (N'17-Hydroxy Progesterone', 'END', N'Reproductive Hormones (Beta HCG, LH, FSH, Prolactin)', N'Serum', N'ng/mL', N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Numeric', 72, 1200, 'All');
INSERT @T (Name, CatKey, Sub, Sample, Unit, Method, RType, Tat, Mrp, Gender) VALUES
 (N'Cortisol (Morning, 8 AM)', 'END', N'Adrenal & Pituitary', N'Serum', N'µg/dL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 500, 'All'),
 (N'Cortisol (Evening, 4 PM)', 'END', N'Adrenal & Pituitary', N'Serum', N'µg/dL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 500, 'All'),
 (N'ACTH (Adrenocorticotropic Hormone)', 'END', N'Adrenal & Pituitary', N'Whole Blood (EDTA)', N'pg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 1500, 'All'),
 (N'Growth Hormone (GH)', 'END', N'Adrenal & Pituitary', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 900, 'All'),
 (N'IGF-1 (Insulin-like Growth Factor 1)', 'END', N'Adrenal & Pituitary', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 72, 2200, 'All'),
 (N'Aldosterone', 'END', N'Adrenal & Pituitary', N'Serum', N'ng/dL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 72, 2000, 'All'),
 (N'Parathyroid Hormone (PTH, Intact)', 'END', N'Vitamin & Bone Markers (Vit D3, Vit B12)', N'Serum', N'pg/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1100, 'All'),
 (N'Folic Acid (Serum Folate)', 'END', N'Vitamin & Bone Markers (Vit D3, Vit B12)', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 900, 'All'),
 (N'Fasting Insulin', 'END', N'Diabetes & Metabolic Hormones', N'Serum', N'µIU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 700, 'All'),
 (N'Post Prandial Insulin', 'END', N'Diabetes & Metabolic Hormones', N'Serum', N'µIU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 700, 'All'),
 (N'C-Peptide (Fasting)', 'END', N'Diabetes & Metabolic Hormones', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 900, 'All'),
 (N'PSA (Prostate Specific Antigen, Total)', 'END', N'Tumour Markers', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 600, 'Male'),
 (N'PSA (Free)', 'END', N'Tumour Markers', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 900, 'Male'),
 (N'CEA (Carcinoembryonic Antigen)', 'END', N'Tumour Markers', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 700, 'All'),
 (N'AFP (Alpha Fetoprotein)', 'END', N'Tumour Markers', N'Serum', N'ng/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 700, 'All'),
 (N'CA-125', 'END', N'Tumour Markers', N'Serum', N'U/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1000, 'Female'),
 (N'CA 19-9', 'END', N'Tumour Markers', N'Serum', N'U/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1100, 'All'),
 (N'CA 15-3', 'END', N'Tumour Markers', N'Serum', N'U/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 1200, 'Female'),
 (N'Beta-2 Microglobulin', 'END', N'Tumour Markers', N'Serum', N'mg/L', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 1200, 'All'),
 (N'Rheumatoid Factor (RA, Quantitative)', 'IMM', N'Autoimmune & Rheumatology', N'Serum', N'IU/mL', N'Immunoturbidimetry', 'Numeric', 24, 400, 'All'),
 (N'Anti-CCP Antibody', 'IMM', N'Autoimmune & Rheumatology', N'Serum', N'U/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 48, 1500, 'All'),
 (N'ANA (Antinuclear Antibody) by IFA', 'IMM', N'Autoimmune & Rheumatology', N'Serum', NULL, N'Indirect Immunofluorescence (IFA)', 'Descriptive', 72, 1200, 'All'),
 (N'ANA (Antinuclear Antibody) by ELISA', 'IMM', N'Autoimmune & Rheumatology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 48, 900, 'All'),
 (N'Anti-dsDNA Antibody', 'IMM', N'Autoimmune & Rheumatology', N'Serum', N'IU/mL', N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Numeric', 72, 1200, 'All'),
 (N'ENA Profile (Extractable Nuclear Antigens)', 'IMM', N'Autoimmune & Rheumatology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Descriptive', 120, 3500, 'All'),
 (N'ANCA (p-ANCA / c-ANCA)', 'IMM', N'Autoimmune & Rheumatology', N'Serum', NULL, N'Indirect Immunofluorescence (IFA)', 'Descriptive', 120, 2500, 'All'),
 (N'HLA-B27', 'IMM', N'Autoimmune & Rheumatology', N'Whole Blood (EDTA)', NULL, N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Select', 72, 2000, 'All'),
 (N'Complement C3', 'IMM', N'Autoimmune & Rheumatology', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 48, 700, 'All'),
 (N'Complement C4', 'IMM', N'Autoimmune & Rheumatology', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 48, 700, 'All'),
 (N'Anti-tTG IgA (Celiac)', 'IMM', N'Autoimmune & Rheumatology', N'Serum', N'U/mL', N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Numeric', 72, 1500, 'All'),
 (N'Anti-Phospholipid Antibody IgG', 'IMM', N'Autoimmune & Rheumatology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 72, 1500, 'All'),
 (N'Anti-Phospholipid Antibody IgM', 'IMM', N'Autoimmune & Rheumatology', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Select', 72, 1500, 'All'),
 (N'Total IgE', 'IMM', N'Allergy & Immunoglobulins', N'Serum', N'IU/mL', N'Chemiluminescence Immunoassay (CLIA)', 'Numeric', 24, 700, 'All'),
 (N'Immunoglobulin G (IgG)', 'IMM', N'Allergy & Immunoglobulins', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 48, 700, 'All'),
 (N'Immunoglobulin A (IgA)', 'IMM', N'Allergy & Immunoglobulins', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 48, 700, 'All'),
 (N'Immunoglobulin M (IgM)', 'IMM', N'Allergy & Immunoglobulins', N'Serum', N'mg/dL', N'Immunoturbidimetry', 'Numeric', 48, 700, 'All'),
 (N'Allergy Panel - Food', 'IMM', N'Allergy & Immunoglobulins', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Descriptive', 120, 4500, 'All'),
 (N'Allergy Panel - Inhalant', 'IMM', N'Allergy & Immunoglobulins', N'Serum', NULL, N'Enzyme-Linked Immunosorbent Assay (ELISA)', 'Descriptive', 120, 4500, 'All'),
 (N'Histopathology - Small Biopsy', 'HIS', N'Histopathology', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 120, 1500, 'All'),
 (N'Histopathology - Medium Specimen', 'HIS', N'Histopathology', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 120, 2500, 'All'),
 (N'Histopathology - Large / Radical Specimen', 'HIS', N'Histopathology', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 168, 4500, 'All'),
 (N'Frozen Section', 'HIS', N'Histopathology', N'Fresh Tissue', NULL, N'Histopathology (H&E)', 'Descriptive', 1, 4000, 'All'),
 (N'Special Stain (PAS / AFB / Reticulin)', 'HIS', N'Histopathology', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 72, 800, 'All'),
 (N'Pap Smear (Conventional)', 'HIS', N'Cytology', N'Cytology Smear / Fluid', NULL, N'Light Microscopy', 'Descriptive', 72, 500, 'Female'),
 (N'Liquid Based Cytology (LBC Pap)', 'HIS', N'Cytology', N'Cytology Smear / Fluid', NULL, N'Light Microscopy', 'Descriptive', 72, 1500, 'Female'),
 (N'FNAC (Fine Needle Aspiration Cytology)', 'HIS', N'Cytology', N'Cytology Smear / Fluid', NULL, N'Light Microscopy', 'Descriptive', 48, 1200, 'All'),
 (N'FNAC (USG / CT Guided)', 'HIS', N'Cytology', N'Cytology Smear / Fluid', NULL, N'Light Microscopy', 'Descriptive', 48, 2000, 'All'),
 (N'Body Fluid Cytology (Malignant Cells)', 'HIS', N'Cytology', N'Body Fluid (Pleural/Ascitic)', NULL, N'Light Microscopy', 'Descriptive', 48, 800, 'All'),
 (N'Urine Cytology (Malignant Cells)', 'HIS', N'Cytology', N'Random Urine Sample', NULL, N'Light Microscopy', 'Descriptive', 48, 700, 'All'),
 (N'Sputum Cytology (Malignant Cells)', 'HIS', N'Cytology', N'Sputum Sample', NULL, N'Light Microscopy', 'Descriptive', 48, 600, 'All');
INSERT @T (Name, CatKey, Sub, Sample, Unit, Method, RType, Tat, Mrp, Gender) VALUES
 (N'Bone Marrow Aspiration', 'HIS', N'Cytology', N'Bone Marrow', NULL, N'Light Microscopy', 'Descriptive', 72, 2500, 'All'),
 (N'Bone Marrow Biopsy (Trephine)', 'HIS', N'Histopathology', N'Bone Marrow', NULL, N'Histopathology (H&E)', 'Descriptive', 168, 4000, 'All'),
 (N'IHC - Single Marker', 'HIS', N'Immunohistochemistry', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 120, 2500, 'All'),
 (N'IHC - ER / PR / HER2 (Breast)', 'HIS', N'Immunohistochemistry', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 120, 6500, 'All'),
 (N'IHC - Ki-67 Proliferation Index', 'HIS', N'Immunohistochemistry', N'Tissue in 10% Formalin', NULL, N'Histopathology (H&E)', 'Descriptive', 120, 2500, 'All'),
 (N'HBV DNA (Quantitative, Viral Load)', 'MOL', N'RT-PCR Viral Panel', N'Whole Blood (EDTA)', N'IU/mL', N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Text', 96, 4000, 'All'),
 (N'HCV RNA (Quantitative, Viral Load)', 'MOL', N'RT-PCR Viral Panel', N'Whole Blood (EDTA)', N'IU/mL', N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Text', 96, 4500, 'All'),
 (N'HIV-1 RNA (Quantitative, Viral Load)', 'MOL', N'RT-PCR Viral Panel', N'Whole Blood (EDTA)', N'copies/mL', N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Text', 96, 5000, 'All'),
 (N'Dengue RNA PCR', 'MOL', N'RT-PCR Viral Panel', N'Whole Blood (EDTA)', NULL, N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Select', 24, 2500, 'All'),
 (N'Influenza A (H1N1) & B PCR', 'MOL', N'RT-PCR Viral Panel', N'Throat / Nasopharyngeal Swab', NULL, N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Select', 24, 3500, 'All'),
 (N'HPV DNA (High Risk)', 'MOL', N'RT-PCR Viral Panel', N'Cytology Smear / Fluid', NULL, N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Select', 96, 3500, 'Female'),
 (N'CBNAAT / GeneXpert MTB / RIF', 'MOL', N'TB & Bacterial PCR', N'Sputum Sample', NULL, N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Text', 24, 2500, 'All'),
 (N'TB PCR (Mycobacterium tuberculosis)', 'MOL', N'TB & Bacterial PCR', N'Sputum Sample', NULL, N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Select', 48, 2000, 'All'),
 (N'BCR-ABL (Quantitative)', 'MOL', N'Genetic & Oncology Tests', N'Whole Blood (EDTA)', N'%', N'Real-Time Polymerase Chain Reaction (RT-PCR)', 'Text', 168, 6500, 'All'),
 (N'ECG (12-Lead Electrocardiogram)', 'CAR', N'ECG', NULL, NULL, N'Imaging', 'Image', 1, 250, 'All'),
 (N'2D Echo with Colour Doppler', 'CAR', N'Echocardiography', NULL, NULL, N'Imaging', 'Image', 2, 2000, 'All'),
 (N'Fetal Echocardiography', 'CAR', N'Echocardiography', NULL, NULL, N'Imaging', 'Image', 2, 3000, 'Female'),
 (N'TMT (Treadmill Stress Test)', 'CAR', N'Stress & Holter', NULL, NULL, N'Imaging', 'Image', 2, 1800, 'All'),
 (N'Holter Monitoring (24 Hour)', 'CAR', N'Stress & Holter', NULL, NULL, N'Imaging', 'Image', 48, 2500, 'All'),
 (N'Ambulatory BP Monitoring (24 Hour)', 'CAR', N'Stress & Holter', NULL, NULL, N'Imaging', 'Image', 48, 2000, 'All'),
 (N'X-Ray Chest AP', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 300, 'All'),
 (N'X-Ray Chest Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 300, 'All'),
 (N'X-Ray PNS (Waters View)', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Skull AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 400, 'All'),
 (N'X-Ray Dorsal Spine AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 400, 'All'),
 (N'X-Ray Pelvis AP', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 400, 'All'),
 (N'X-Ray Hip AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 450, 'All'),
 (N'X-Ray Shoulder AP', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Elbow AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Wrist AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Hand AP / Oblique', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Forearm AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Femur AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 400, 'All'),
 (N'X-Ray Leg (Tibia-Fibula) AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 400, 'All'),
 (N'X-Ray Ankle AP / Lateral', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Foot AP / Oblique', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray KUB', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'X-Ray Abdomen Erect', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 2, 350, 'All'),
 (N'Barium Swallow', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 24, 1500, 'All'),
 (N'Intravenous Pyelography (IVP)', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 24, 2500, 'All'),
 (N'Hysterosalpingography (HSG)', 'RAD', N'X-Ray', NULL, NULL, N'Imaging', 'Image', 24, 3000, 'Female'),
 (N'USG Upper Abdomen', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 900, 'All'),
 (N'USG Scrotum', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 1000, 'Male'),
 (N'USG Breast (Bilateral)', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 1200, 'All'),
 (N'USG Neck / Soft Tissue', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 900, 'All'),
 (N'USG Chest', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 900, 'All'),
 (N'USG Obstetric - Early Pregnancy / Dating', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 900, 'Female'),
 (N'USG Obstetric - Growth Scan', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 1200, 'Female'),
 (N'USG NT Scan (11 - 14 Weeks)', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 1800, 'Female'),
 (N'USG Follicular Monitoring (per visit)', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 1, 500, 'Female');
INSERT @T (Name, CatKey, Sub, Sample, Unit, Method, RType, Tat, Mrp, Gender) VALUES
 (N'USG Transvaginal (TVS)', 'RAD', N'USG', NULL, NULL, N'Imaging', 'Image', 2, 1200, 'Female'),
 (N'Doppler Lower Limb Arterial', 'RAD', N'Doppler', NULL, NULL, N'Imaging', 'Image', 2, 2500, 'All'),
 (N'Doppler Upper Limb Venous', 'RAD', N'Doppler', NULL, NULL, N'Imaging', 'Image', 2, 2500, 'All'),
 (N'Doppler Renal Artery', 'RAD', N'Doppler', NULL, NULL, N'Imaging', 'Image', 2, 2500, 'All'),
 (N'Doppler Obstetric', 'RAD', N'Doppler', NULL, NULL, N'Imaging', 'Image', 2, 2000, 'Female'),
 (N'CT Neck (Contrast)', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 5000, 'All'),
 (N'CT Thorax (Contrast)', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 5500, 'All'),
 (N'CT KUB (Plain)', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 3500, 'All'),
 (N'CT Abdomen (Plain)', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 4500, 'All'),
 (N'CT Cervical Spine', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 4000, 'All'),
 (N'CT Temporal Bone', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 4000, 'All'),
 (N'CT Angiography Brain', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 8000, 'All'),
 (N'CT Coronary Angiography', 'RAD', N'CT Scan', NULL, NULL, N'Imaging', 'Image', 24, 12000, 'All'),
 (N'MRI Cervical Spine', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 6500, 'All'),
 (N'MRI Dorsal Spine', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 6500, 'All'),
 (N'MRI Whole Spine Screening', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 9000, 'All'),
 (N'MRI Shoulder', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 6500, 'All'),
 (N'MRI Ankle', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 6500, 'All'),
 (N'MRI Abdomen', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 8000, 'All'),
 (N'MRI Pelvis', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 8000, 'All'),
 (N'MRCP', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 7000, 'All'),
 (N'MRI Breast', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 9000, 'Female'),
 (N'MRI Brain with MR Angiography', 'RAD', N'MRI', NULL, NULL, N'Imaging', 'Image', 24, 9500, 'All'),
 (N'Mammography (Unilateral)', 'RAD', N'Mammography', NULL, NULL, N'Imaging', 'Image', 24, 1500, 'Female'),
 (N'DEXA Scan (Bone Densitometry)', 'RAD', N'Bone Densitometry', NULL, NULL, N'Imaging', 'Image', 24, 2000, 'All');
DECLARE @R TABLE (Name NVARCHAR(200), Gender VARCHAR(10), Lo DECIMAL(18,4) NULL, Hi DECIMAL(18,4) NULL, Remark NVARCHAR(500));
INSERT @R VALUES
 (N'Random Blood Sugar (RBS)', 'All', 70, 140, N'Random: below 140 mg/dL normal; 200 and above with symptoms suggests diabetes.'),
 (N'Glucose Challenge Test (GCT, 50 g)', 'Female', 0, 140, N'1 hour after 50 g glucose; 140 and above needs a full OGTT.'),
 (N'Fructosamine', 'All', 205, 285, NULL),
 (N'Average Blood Glucose (eAG)', 'All', 70, 126, NULL),
 (N'Gamma Glutamyl Transferase (GGT)', 'Male', 10, 71, NULL),
 (N'Gamma Glutamyl Transferase (GGT)', 'Female', 6, 42, NULL),
 (N'Lactate Dehydrogenase (LDH)', 'All', 140, 280, NULL),
 (N'Creatine Phosphokinase (CPK) Total', 'Male', 39, 308, NULL),
 (N'Creatine Phosphokinase (CPK) Total', 'Female', 26, 192, NULL),
 (N'Troponin I (Quantitative)', 'All', 0, 0.04, N'Above 0.04 ng/mL suggests myocardial injury; correlate clinically.'),
 (N'Troponin T (High Sensitive)', 'All', 0, 14, NULL),
 (N'NT-proBNP', 'All', 0, 125, N'Below 125 pg/mL (under 75 years); below 450 pg/mL (75 years and above).'),
 (N'Homocysteine', 'All', 5, 15, NULL),
 (N'C-Reactive Protein (CRP, Quantitative)', 'All', 0, 6, NULL),
 (N'Procalcitonin (PCT)', 'All', 0, 0.5, N'Below 0.5 ng/mL: systemic bacterial infection unlikely; 2 and above: likely sepsis.'),
 (N'Lipoprotein (a)', 'All', 0, 30, NULL),
 (N'Apolipoprotein A1', 'Male', 104, 202, NULL),
 (N'Apolipoprotein A1', 'Female', 108, 225, NULL),
 (N'Apolipoprotein B', 'Male', 66, 133, NULL),
 (N'Apolipoprotein B', 'Female', 60, 117, NULL),
 (N'Non-HDL Cholesterol', 'All', 0, 130, NULL),
 (N'Serum Iron', 'Male', 65, 175, NULL),
 (N'Serum Iron', 'Female', 50, 170, NULL),
 (N'Total Iron Binding Capacity (TIBC)', 'All', 250, 450, NULL),
 (N'Transferrin Saturation', 'All', 20, 50, NULL),
 (N'Serum Ferritin', 'Male', 30, 400, NULL),
 (N'Serum Ferritin', 'Female', 13, 150, NULL),
 (N'Serum Transferrin', 'All', 200, 360, NULL),
 (N'Serum Magnesium', 'All', 1.7, 2.4, NULL),
 (N'Ionized Calcium', 'All', 1.12, 1.32, NULL),
 (N'Serum Bicarbonate', 'All', 22, 29, NULL),
 (N'Serum Osmolality', 'All', 275, 295, NULL),
 (N'Serum Zinc', 'All', 60, 120, NULL),
 (N'Plasma Ammonia', 'All', 11, 32, NULL),
 (N'Plasma Lactate', 'All', 0.5, 2.2, NULL),
 (N'Serum Amylase', 'All', 28, 100, NULL),
 (N'Serum Lipase', 'All', 13, 60, NULL),
 (N'Cystatin C', 'All', 0.6, 1.0, NULL),
 (N'Serum Ceruloplasmin', 'All', 20, 60, NULL),
 (N'Serum Lithium', 'All', 0.6, 1.2, N'Therapeutic range; above 1.5 mEq/L toxic.'),
 (N'Serum Valproic Acid', 'All', 50, 100, N'Therapeutic range.'),
 (N'Serum Phenytoin', 'All', 10, 20, N'Therapeutic range.'),
 (N'Serum Carbamazepine', 'All', 4, 12, N'Therapeutic range.'),
 (N'Urine Microalbumin', 'All', 0, 30, NULL),
 (N'Urine Albumin Creatinine Ratio (ACR)', 'All', 0, 30, N'30 - 300 mg/g: moderately increased; above 300: severely increased.'),
 (N'Urine Protein Creatinine Ratio (PCR)', 'All', 0, 150, NULL),
 (N'24 Hour Urine Protein', 'All', 0, 150, NULL),
 (N'Creatinine Clearance (24 Hour Urine)', 'Male', 97, 137, NULL),
 (N'Creatinine Clearance (24 Hour Urine)', 'Female', 88, 128, NULL),
 (N'24 Hour Urine Calcium', 'All', 100, 300, NULL);
INSERT @R VALUES
 (N'Urine Sodium (Spot)', 'All', 40, 220, NULL),
 (N'Urine Potassium (Spot)', 'All', 25, 125, NULL),
 (N'Urine Creatinine (Spot)', 'Male', 39, 259, NULL),
 (N'Urine Creatinine (Spot)', 'Female', 28, 217, NULL),
 (N'Absolute Eosinophil Count (AEC)', 'All', 40, 440, NULL),
 (N'Absolute Neutrophil Count (ANC)', 'All', 2.0, 7.0, NULL),
 (N'Absolute Lymphocyte Count (ALC)', 'All', 1.0, 3.0, NULL),
 (N'Red Cell Distribution Width (RDW-CV)', 'All', 11.6, 14.0, NULL),
 (N'Mean Platelet Volume (MPV)', 'All', 7.5, 11.5, NULL),
 (N'Reticulocyte Count', 'All', 0.5, 2.5, NULL),
 (N'G6PD (Quantitative)', 'All', 6.97, 20.5, NULL),
 (N'Bleeding Time (BT)', 'All', 1, 6, NULL),
 (N'Clotting Time (CT)', 'All', 4, 10, NULL),
 (N'Prothrombin Time (PT)', 'All', 11, 13.5, NULL),
 (N'International Normalized Ratio (INR)', 'All', 0.8, 1.1, N'On oral anticoagulants the target is usually 2.0 - 3.0.'),
 (N'Activated Partial Thromboplastin Time (APTT)', 'All', 25, 35, NULL),
 (N'Thrombin Time (TT)', 'All', 14, 19, NULL),
 (N'Plasma Fibrinogen', 'All', 200, 400, NULL),
 (N'D-Dimer', 'All', 0, 500, N'FEU; below 500 ng/mL makes DVT / PE unlikely.'),
 (N'Fibrin Degradation Products (FDP)', 'All', 0, 5, NULL),
 (N'Factor VIII Assay', 'All', 50, 150, NULL),
 (N'Factor IX Assay', 'All', 50, 150, NULL),
 (N'Protein C Activity', 'All', 70, 140, NULL),
 (N'Protein S Activity', 'All', 65, 140, NULL),
 (N'Antithrombin III Activity', 'All', 80, 120, NULL),
 (N'Body Fluid ADA (Adenosine Deaminase)', 'All', 0, 40, N'Pleural fluid: 40 U/L and above supports tuberculosis.'),
 (N'Anti-HBs Antibody (Quantitative)', 'All', 10, NULL, N'10 mIU/mL and above: protective (immune).'),
 (N'ASO Titre (Anti-Streptolysin O)', 'All', 0, 200, NULL),
 (N'Mantoux Test (Tuberculin Skin Test)', 'All', 0, 10, N'Induration below 10 mm: negative (below 5 mm in immunocompromised).'),
 (N'Free T3 (FT3)', 'All', 2.0, 4.4, NULL),
 (N'Free T4 (FT4)', 'All', 0.93, 1.7, NULL),
 (N'Anti-TPO Antibody', 'All', 0, 34, NULL),
 (N'Anti-Thyroglobulin Antibody', 'All', 0, 115, NULL),
 (N'Thyroglobulin', 'All', 3.5, 77, NULL),
 (N'Calcitonin', 'Male', 0, 8.4, NULL),
 (N'Calcitonin', 'Female', 0, 5, NULL),
 (N'TSH Receptor Antibody (TRAb)', 'All', 0, 1.75, NULL),
 (N'Luteinizing Hormone (LH)', 'Male', 1.7, 8.6, N'Female: follicular phase 2.4 - 12.6; mid-cycle 14 - 96; luteal 1.0 - 11.4; post-menopause 7.7 - 59.'),
 (N'Luteinizing Hormone (LH)', 'Female', 2.4, 12.6, N'Female: follicular phase 2.4 - 12.6; mid-cycle 14 - 96; luteal 1.0 - 11.4; post-menopause 7.7 - 59.'),
 (N'Follicle Stimulating Hormone (FSH)', 'Male', 1.5, 12.4, N'Female: follicular 3.5 - 12.5; mid-cycle 4.7 - 21.5; luteal 1.7 - 7.7; post-menopause 25.8 - 134.8.'),
 (N'Follicle Stimulating Hormone (FSH)', 'Female', 3.5, 12.5, N'Female: follicular 3.5 - 12.5; mid-cycle 4.7 - 21.5; luteal 1.7 - 7.7; post-menopause 25.8 - 134.8.'),
 (N'Prolactin', 'Male', 4.0, 15.2, NULL),
 (N'Prolactin', 'Female', 4.8, 23.3, NULL),
 (N'Estradiol (E2)', 'Male', 11, 44, N'Female: follicular 12.5 - 166; ovulation 85.8 - 498; luteal 43.8 - 211; post-menopause below 54.7.'),
 (N'Estradiol (E2)', 'Female', 12.5, 166, N'Female: follicular 12.5 - 166; ovulation 85.8 - 498; luteal 43.8 - 211; post-menopause below 54.7.'),
 (N'Progesterone', 'Male', 0.2, 1.4, N'Female: follicular 0.2 - 1.5; luteal 1.7 - 27.0; post-menopause below 0.8.'),
 (N'Progesterone', 'Female', 0.2, 1.5, N'Female: follicular 0.2 - 1.5; luteal 1.7 - 27.0; post-menopause below 0.8.'),
 (N'Testosterone (Total)', 'Male', 249, 836, NULL),
 (N'Testosterone (Total)', 'Female', 8, 48, NULL),
 (N'Testosterone (Free)', 'Male', 46, 224, NULL);
INSERT @R VALUES
 (N'Testosterone (Free)', 'Female', 0.3, 1.9, NULL),
 (N'Anti-Mullerian Hormone (AMH)', 'Female', 1.0, 3.5, N'Below 1.0: low ovarian reserve; above 3.5: high (consider PCOS).'),
 (N'DHEA-S (Dehydroepiandrosterone Sulphate)', 'Male', 80, 560, NULL),
 (N'DHEA-S (Dehydroepiandrosterone Sulphate)', 'Female', 35, 430, NULL),
 (N'Sex Hormone Binding Globulin (SHBG)', 'Male', 18, 54, NULL),
 (N'Sex Hormone Binding Globulin (SHBG)', 'Female', 18, 144, NULL),
 (N'17-Hydroxy Progesterone', 'All', 0, 2, NULL),
 (N'Cortisol (Morning, 8 AM)', 'All', 6.2, 19.4, NULL),
 (N'Cortisol (Evening, 4 PM)', 'All', 2.3, 11.9, NULL),
 (N'ACTH (Adrenocorticotropic Hormone)', 'All', 7.2, 63.3, NULL),
 (N'Growth Hormone (GH)', 'Male', 0, 3, NULL),
 (N'Growth Hormone (GH)', 'Female', 0, 8, NULL),
 (N'IGF-1 (Insulin-like Growth Factor 1)', 'All', 115, 307, N'Adult 21 - 50 years; varies with age.'),
 (N'Aldosterone', 'All', 3, 16, N'Upright position.'),
 (N'Parathyroid Hormone (PTH, Intact)', 'All', 15, 65, NULL),
 (N'Folic Acid (Serum Folate)', 'All', 3.1, 17.5, NULL),
 (N'Fasting Insulin', 'All', 2.6, 24.9, NULL),
 (N'Post Prandial Insulin', 'All', 0, 60, NULL),
 (N'C-Peptide (Fasting)', 'All', 1.1, 4.4, NULL),
 (N'PSA (Prostate Specific Antigen, Total)', 'Male', 0, 4, NULL),
 (N'PSA (Free)', 'Male', 0, 0.93, N'Free / total PSA ratio above 25% favours a benign cause.'),
 (N'CEA (Carcinoembryonic Antigen)', 'All', 0, 5, N'Non-smokers below 5; smokers may be up to 10.'),
 (N'AFP (Alpha Fetoprotein)', 'All', 0, 10, NULL),
 (N'CA-125', 'Female', 0, 35, NULL),
 (N'CA 19-9', 'All', 0, 37, NULL),
 (N'CA 15-3', 'Female', 0, 25, NULL),
 (N'Beta-2 Microglobulin', 'All', 0.8, 2.2, NULL),
 (N'Rheumatoid Factor (RA, Quantitative)', 'All', 0, 14, NULL),
 (N'Anti-CCP Antibody', 'All', 0, 17, NULL),
 (N'Anti-dsDNA Antibody', 'All', 0, 100, NULL),
 (N'Complement C3', 'All', 90, 180, NULL),
 (N'Complement C4', 'All', 10, 40, NULL),
 (N'Anti-tTG IgA (Celiac)', 'All', 0, 20, NULL),
 (N'Total IgE', 'All', 0, 100, NULL),
 (N'Immunoglobulin G (IgG)', 'All', 700, 1600, NULL),
 (N'Immunoglobulin A (IgA)', 'All', 70, 400, NULL),
 (N'Immunoglobulin M (IgM)', 'All', 40, 230, NULL);
DECLARE @OP TABLE (Name NVARCHAR(200), Txt NVARCHAR(100), Ord INT, Abn BIT, Dflt BIT);
INSERT @OP VALUES
 (N'Malaria Parasite (Smear)', N'Not Seen', 1, 0, 1),
 (N'Malaria Parasite (Smear)', N'Plasmodium vivax Seen', 2, 1, 0),
 (N'Malaria Parasite (Smear)', N'Plasmodium falciparum Seen', 3, 1, 0),
 (N'Malaria Parasite (Smear)', N'Mixed Infection (Pv + Pf)', 4, 1, 0),
 (N'Malaria Antigen (Pf / Pv, Rapid)', N'Not Seen', 1, 0, 1),
 (N'Malaria Antigen (Pf / Pv, Rapid)', N'Plasmodium vivax Seen', 2, 1, 0),
 (N'Malaria Antigen (Pf / Pv, Rapid)', N'Plasmodium falciparum Seen', 3, 1, 0),
 (N'Malaria Antigen (Pf / Pv, Rapid)', N'Mixed Infection (Pv + Pf)', 4, 1, 0),
 (N'Microfilaria (Smear)', N'Not Seen', 1, 0, 1),
 (N'Microfilaria (Smear)', N'Seen', 2, 1, 0),
 (N'Sickling Test', N'Negative', 1, 0, 1),
 (N'Sickling Test', N'Positive', 2, 1, 0),
 (N'Lupus Anticoagulant (dRVVT)', N'Not Detected', 1, 0, 1),
 (N'Lupus Anticoagulant (dRVVT)', N'Detected', 2, 1, 0),
 (N'Blood Group & Rh Typing', N'A Positive', 1, 0, 0),
 (N'Blood Group & Rh Typing', N'A Negative', 2, 0, 0),
 (N'Blood Group & Rh Typing', N'B Positive', 3, 0, 0),
 (N'Blood Group & Rh Typing', N'B Negative', 4, 0, 0),
 (N'Blood Group & Rh Typing', N'AB Positive', 5, 0, 0),
 (N'Blood Group & Rh Typing', N'AB Negative', 6, 0, 0),
 (N'Blood Group & Rh Typing', N'O Positive', 7, 0, 1),
 (N'Blood Group & Rh Typing', N'O Negative', 8, 0, 0),
 (N'Direct Coombs Test (DCT)', N'Negative', 1, 0, 1),
 (N'Direct Coombs Test (DCT)', N'Positive', 2, 1, 0),
 (N'Indirect Coombs Test (ICT)', N'Negative', 1, 0, 1),
 (N'Indirect Coombs Test (ICT)', N'Positive', 2, 1, 0),
 (N'Cross Match (Compatibility Test)', N'Compatible', 1, 0, 1),
 (N'Cross Match (Compatibility Test)', N'Incompatible', 2, 1, 0),
 (N'Urine Pregnancy Test (UPT)', N'Negative', 1, 0, 1),
 (N'Urine Pregnancy Test (UPT)', N'Positive', 2, 1, 0),
 (N'Urine Bence Jones Protein', N'Absent', 1, 0, 1),
 (N'Urine Bence Jones Protein', N'Present', 2, 1, 0),
 (N'Urine Bence Jones Protein', N'Trace', 3, 1, 0),
 (N'Urine Ketone (Rothera)', N'Absent', 1, 0, 1),
 (N'Urine Ketone (Rothera)', N'Present', 2, 1, 0),
 (N'Urine Ketone (Rothera)', N'Trace', 3, 1, 0),
 (N'Stool for Occult Blood', N'Negative', 1, 0, 1),
 (N'Stool for Occult Blood', N'Positive', 2, 1, 0),
 (N'Stool Reducing Substances', N'Absent', 1, 0, 1),
 (N'Stool Reducing Substances', N'Present', 2, 1, 0),
 (N'Stool Reducing Substances', N'Trace', 3, 1, 0),
 (N'Typhidot IgM', N'Negative', 1, 0, 1),
 (N'Typhidot IgM', N'Positive', 2, 1, 0),
 (N'Dengue NS1 Antigen', N'Negative', 1, 0, 1),
 (N'Dengue NS1 Antigen', N'Positive', 2, 1, 0),
 (N'Dengue IgM Antibody', N'Negative', 1, 0, 1),
 (N'Dengue IgM Antibody', N'Positive', 2, 1, 0),
 (N'Dengue IgG Antibody', N'Negative', 1, 0, 1),
 (N'Dengue IgG Antibody', N'Positive', 2, 1, 0),
 (N'Chikungunya IgM', N'Negative', 1, 0, 1),
 (N'Chikungunya IgM', N'Positive', 2, 1, 0),
 (N'Leptospira IgM', N'Negative', 1, 0, 1),
 (N'Leptospira IgM', N'Positive', 2, 1, 0),
 (N'Scrub Typhus IgM', N'Negative', 1, 0, 1),
 (N'Scrub Typhus IgM', N'Positive', 2, 1, 0),
 (N'HBsAg (Hepatitis B Surface Antigen)', N'Non-Reactive', 1, 0, 1),
 (N'HBsAg (Hepatitis B Surface Antigen)', N'Reactive', 2, 1, 0),
 (N'HBsAg (Hepatitis B Surface Antigen)', N'Weakly Reactive', 3, 1, 0),
 (N'Anti-HCV Antibody', N'Non-Reactive', 1, 0, 1),
 (N'Anti-HCV Antibody', N'Reactive', 2, 1, 0),
 (N'Anti-HCV Antibody', N'Weakly Reactive', 3, 1, 0),
 (N'HIV 1 & 2 Antibody', N'Non-Reactive', 1, 0, 1),
 (N'HIV 1 & 2 Antibody', N'Reactive', 2, 1, 0),
 (N'HIV 1 & 2 Antibody', N'Weakly Reactive', 3, 1, 0),
 (N'VDRL / RPR', N'Non-Reactive', 1, 0, 1),
 (N'VDRL / RPR', N'Reactive', 2, 1, 0),
 (N'VDRL / RPR', N'Weakly Reactive', 3, 1, 0),
 (N'TPHA (Treponema pallidum)', N'Non-Reactive', 1, 0, 1),
 (N'TPHA (Treponema pallidum)', N'Reactive', 2, 1, 0),
 (N'TPHA (Treponema pallidum)', N'Weakly Reactive', 3, 1, 0),
 (N'HBeAg', N'Non-Reactive', 1, 0, 1),
 (N'HBeAg', N'Reactive', 2, 1, 0),
 (N'HBeAg', N'Weakly Reactive', 3, 1, 0),
 (N'Anti-HBc Total', N'Non-Reactive', 1, 0, 1),
 (N'Anti-HBc Total', N'Reactive', 2, 1, 0),
 (N'Anti-HBc Total', N'Weakly Reactive', 3, 1, 0),
 (N'Anti-HBc IgM', N'Non-Reactive', 1, 0, 1),
 (N'Anti-HBc IgM', N'Reactive', 2, 1, 0),
 (N'Anti-HBc IgM', N'Weakly Reactive', 3, 1, 0),
 (N'Hepatitis A Virus (HAV) IgM', N'Non-Reactive', 1, 0, 1);
INSERT @OP VALUES
 (N'Hepatitis A Virus (HAV) IgM', N'Reactive', 2, 1, 0),
 (N'Hepatitis A Virus (HAV) IgM', N'Weakly Reactive', 3, 1, 0),
 (N'Hepatitis E Virus (HEV) IgM', N'Non-Reactive', 1, 0, 1),
 (N'Hepatitis E Virus (HEV) IgM', N'Reactive', 2, 1, 0),
 (N'Hepatitis E Virus (HEV) IgM', N'Weakly Reactive', 3, 1, 0),
 (N'Toxoplasma IgG', N'Negative', 1, 0, 1),
 (N'Toxoplasma IgG', N'Positive', 2, 1, 0),
 (N'Toxoplasma IgM', N'Negative', 1, 0, 1),
 (N'Toxoplasma IgM', N'Positive', 2, 1, 0),
 (N'Rubella IgG', N'Negative', 1, 0, 1),
 (N'Rubella IgG', N'Positive', 2, 1, 0),
 (N'Rubella IgM', N'Negative', 1, 0, 1),
 (N'Rubella IgM', N'Positive', 2, 1, 0),
 (N'Cytomegalovirus (CMV) IgG', N'Negative', 1, 0, 1),
 (N'Cytomegalovirus (CMV) IgG', N'Positive', 2, 1, 0),
 (N'Cytomegalovirus (CMV) IgM', N'Negative', 1, 0, 1),
 (N'Cytomegalovirus (CMV) IgM', N'Positive', 2, 1, 0),
 (N'Herpes Simplex Virus (HSV 1 & 2) IgG', N'Negative', 1, 0, 1),
 (N'Herpes Simplex Virus (HSV 1 & 2) IgG', N'Positive', 2, 1, 0),
 (N'Herpes Simplex Virus (HSV 1 & 2) IgM', N'Negative', 1, 0, 1),
 (N'Herpes Simplex Virus (HSV 1 & 2) IgM', N'Positive', 2, 1, 0),
 (N'H. pylori Antibody IgG', N'Negative', 1, 0, 1),
 (N'H. pylori Antibody IgG', N'Positive', 2, 1, 0),
 (N'H. pylori Stool Antigen', N'Negative', 1, 0, 1),
 (N'H. pylori Stool Antigen', N'Positive', 2, 1, 0),
 (N'Rotavirus Stool Antigen', N'Negative', 1, 0, 1),
 (N'Rotavirus Stool Antigen', N'Positive', 2, 1, 0),
 (N'Stool Hanging Drop (Vibrio)', N'Not Seen', 1, 0, 1),
 (N'Stool Hanging Drop (Vibrio)', N'Seen', 2, 1, 0),
 (N'ANA (Antinuclear Antibody) by ELISA', N'Negative', 1, 0, 1),
 (N'ANA (Antinuclear Antibody) by ELISA', N'Positive', 2, 1, 0),
 (N'HLA-B27', N'Not Detected', 1, 0, 1),
 (N'HLA-B27', N'Detected', 2, 1, 0),
 (N'Anti-Phospholipid Antibody IgG', N'Negative', 1, 0, 1),
 (N'Anti-Phospholipid Antibody IgG', N'Positive', 2, 1, 0),
 (N'Anti-Phospholipid Antibody IgM', N'Negative', 1, 0, 1),
 (N'Anti-Phospholipid Antibody IgM', N'Positive', 2, 1, 0),
 (N'Dengue RNA PCR', N'Not Detected', 1, 0, 1),
 (N'Dengue RNA PCR', N'Detected', 2, 1, 0),
 (N'Influenza A (H1N1) & B PCR', N'Not Detected', 1, 0, 1),
 (N'Influenza A (H1N1) & B PCR', N'Detected', 2, 1, 0),
 (N'HPV DNA (High Risk)', N'Not Detected', 1, 0, 1),
 (N'HPV DNA (High Risk)', N'Detected', 2, 1, 0),
 (N'TB PCR (Mycobacterium tuberculosis)', N'Not Detected', 1, 0, 1),
 (N'TB PCR (Mycobacterium tuberculosis)', N'Detected', 2, 1, 0);
DECLARE @TP TABLE (Name NVARCHAR(200), Modality NVARCHAR(50), BodyPart NVARCHAR(100));
INSERT @TP VALUES
 (N'Serum Protein Electrophoresis', N'Electrophoresis', N'Serum'),
 (N'Peripheral Smear Examination', N'Microscopy', N'Peripheral blood smear'),
 (N'Haemoglobin Electrophoresis (HPLC)', N'HPLC', N'Whole blood'),
 (N'Osmotic Fragility Test', N'Laboratory', N'Whole blood'),
 (N'Stool for Ova & Cyst', N'Microscopy', N'Stool'),
 (N'Synovial Fluid Analysis', N'Microscopy', N'Synovial fluid'),
 (N'ANA (Antinuclear Antibody) by IFA', N'IFA', N'Serum'),
 (N'ENA Profile (Extractable Nuclear Antigens)', N'Immunoblot', N'Serum'),
 (N'ANCA (p-ANCA / c-ANCA)', N'IFA', N'Serum'),
 (N'Allergy Panel - Food', N'Immunoblot', N'Serum'),
 (N'Allergy Panel - Inhalant', N'Immunoblot', N'Serum'),
 (N'Histopathology - Small Biopsy', N'Histopathology', N'Tissue'),
 (N'Histopathology - Medium Specimen', N'Histopathology', N'Tissue'),
 (N'Histopathology - Large / Radical Specimen', N'Histopathology', N'Tissue'),
 (N'Frozen Section', N'Histopathology', N'Tissue'),
 (N'Special Stain (PAS / AFB / Reticulin)', N'Histopathology', N'Tissue'),
 (N'Pap Smear (Conventional)', N'Cytology', N'Cervix'),
 (N'Liquid Based Cytology (LBC Pap)', N'Cytology', N'Cervix'),
 (N'FNAC (Fine Needle Aspiration Cytology)', N'Cytology', N'Lesion'),
 (N'FNAC (USG / CT Guided)', N'Cytology', N'Lesion'),
 (N'Body Fluid Cytology (Malignant Cells)', N'Cytology', N'Body fluid'),
 (N'Urine Cytology (Malignant Cells)', N'Cytology', N'Urine'),
 (N'Sputum Cytology (Malignant Cells)', N'Cytology', N'Sputum'),
 (N'Bone Marrow Aspiration', N'Cytology', N'Bone marrow'),
 (N'Bone Marrow Biopsy (Trephine)', N'Histopathology', N'Bone marrow'),
 (N'IHC - Single Marker', N'IHC', N'Tissue'),
 (N'IHC - ER / PR / HER2 (Breast)', N'IHC', N'Breast'),
 (N'IHC - Ki-67 Proliferation Index', N'IHC', N'Tissue'),
 (N'ECG (12-Lead Electrocardiogram)', N'ECG', N'Heart'),
 (N'2D Echo with Colour Doppler', N'Echo', N'Heart'),
 (N'Fetal Echocardiography', N'Echo', N'Fetal heart'),
 (N'TMT (Treadmill Stress Test)', N'TMT', N'Heart'),
 (N'Holter Monitoring (24 Hour)', N'Holter', N'Heart'),
 (N'Ambulatory BP Monitoring (24 Hour)', N'ABPM', N'Heart'),
 (N'X-Ray Chest AP', N'X-Ray', N'Chest'),
 (N'X-Ray Chest Lateral', N'X-Ray', N'Chest'),
 (N'X-Ray PNS (Waters View)', N'X-Ray', N'Paranasal sinuses'),
 (N'X-Ray Skull AP / Lateral', N'X-Ray', N'Skull'),
 (N'X-Ray Dorsal Spine AP / Lateral', N'X-Ray', N'Dorsal spine'),
 (N'X-Ray Pelvis AP', N'X-Ray', N'Pelvis'),
 (N'X-Ray Hip AP / Lateral', N'X-Ray', N'Hip'),
 (N'X-Ray Shoulder AP', N'X-Ray', N'Shoulder'),
 (N'X-Ray Elbow AP / Lateral', N'X-Ray', N'Elbow'),
 (N'X-Ray Wrist AP / Lateral', N'X-Ray', N'Wrist'),
 (N'X-Ray Hand AP / Oblique', N'X-Ray', N'Hand'),
 (N'X-Ray Forearm AP / Lateral', N'X-Ray', N'Forearm'),
 (N'X-Ray Femur AP / Lateral', N'X-Ray', N'Femur'),
 (N'X-Ray Leg (Tibia-Fibula) AP / Lateral', N'X-Ray', N'Leg'),
 (N'X-Ray Ankle AP / Lateral', N'X-Ray', N'Ankle'),
 (N'X-Ray Foot AP / Oblique', N'X-Ray', N'Foot'),
 (N'X-Ray KUB', N'X-Ray', N'KUB'),
 (N'X-Ray Abdomen Erect', N'X-Ray', N'Abdomen'),
 (N'Barium Swallow', N'Fluoroscopy', N'Oesophagus'),
 (N'Intravenous Pyelography (IVP)', N'Fluoroscopy', N'Urinary tract'),
 (N'Hysterosalpingography (HSG)', N'Fluoroscopy', N'Uterus and tubes'),
 (N'USG Upper Abdomen', N'USG', N'Upper abdomen'),
 (N'USG Scrotum', N'USG', N'Scrotum'),
 (N'USG Breast (Bilateral)', N'USG', N'Breast'),
 (N'USG Neck / Soft Tissue', N'USG', N'Neck'),
 (N'USG Chest', N'USG', N'Chest'),
 (N'USG Obstetric - Early Pregnancy / Dating', N'USG', N'Obstetric'),
 (N'USG Obstetric - Growth Scan', N'USG', N'Obstetric'),
 (N'USG NT Scan (11 - 14 Weeks)', N'USG', N'Obstetric'),
 (N'USG Follicular Monitoring (per visit)', N'USG', N'Ovaries'),
 (N'USG Transvaginal (TVS)', N'USG', N'Pelvis'),
 (N'Doppler Lower Limb Arterial', N'Doppler', N'Lower limb arteries'),
 (N'Doppler Upper Limb Venous', N'Doppler', N'Upper limb veins'),
 (N'Doppler Renal Artery', N'Doppler', N'Renal arteries'),
 (N'Doppler Obstetric', N'Doppler', N'Obstetric'),
 (N'CT Neck (Contrast)', N'CT', N'Neck'),
 (N'CT Thorax (Contrast)', N'CT', N'Thorax'),
 (N'CT KUB (Plain)', N'CT', N'KUB'),
 (N'CT Abdomen (Plain)', N'CT', N'Abdomen'),
 (N'CT Cervical Spine', N'CT', N'Cervical spine'),
 (N'CT Temporal Bone', N'CT', N'Temporal bone'),
 (N'CT Angiography Brain', N'CT', N'Brain vessels'),
 (N'CT Coronary Angiography', N'CT', N'Coronary arteries'),
 (N'MRI Cervical Spine', N'MRI', N'Cervical spine'),
 (N'MRI Dorsal Spine', N'MRI', N'Dorsal spine'),
 (N'MRI Whole Spine Screening', N'MRI', N'Whole spine'),
 (N'MRI Shoulder', N'MRI', N'Shoulder'),
 (N'MRI Ankle', N'MRI', N'Ankle'),
 (N'MRI Abdomen', N'MRI', N'Abdomen'),
 (N'MRI Pelvis', N'MRI', N'Pelvis'),
 (N'MRCP', N'MRI', N'Biliary tree'),
 (N'MRI Breast', N'MRI', N'Breast'),
 (N'MRI Brain with MR Angiography', N'MRI', N'Brain'),
 (N'Mammography (Unilateral)', N'Mammography', N'Breast'),
 (N'DEXA Scan (Bone Densitometry)', N'DEXA', N'Spine and hip');
DECLARE @CAT TABLE (CatKey VARCHAR(5), CatName NVARCHAR(150), NewDept NVARCHAR(100), NewDeptCode VARCHAR(20), FallbackDept NVARCHAR(100));
INSERT @CAT VALUES
 ('BIO', N'Clinical Biochemistry', NULL, NULL, N'Biochemistry'),
 ('HAE', N'Hematology & Hemostasis', NULL, NULL, N'Pathology'),
 ('CLP', N'Clinical Pathology & Urinalysis', NULL, NULL, N'Pathology'),
 ('MIC', N'Microbiology & Serology', NULL, NULL, N'Microbiology'),
 ('END', N'Endocrinology & Immunology', NULL, NULL, N'Biochemistry'),
 ('IMM', N'Clinical Immunology', N'Clinical Immunology', N'LAB-IMMU', NULL),
 ('HIS', N'Histopathology & Cytopathology', N'Histopathology & Cytology', N'LAB-HIST', NULL),
 ('MOL', N'Molecular Diagnostics & RT-PCR', N'Molecular Biology', N'LAB-MOLB', NULL),
 ('CAR', N'Cardiac Diagnostics', N'Cardiology Diagnostics', N'LAB-CARD', NULL),
 ('RAD', N'Radiology', NULL, NULL, N'Radiology');
DECLARE @U TABLE (Sym NVARCHAR(30), UName NVARCHAR(100));
INSERT @U VALUES
 (N'ng/dL', N'Nanograms per Deciliter'),
 (N'IU/mL', N'International Units per Milliliter'),
 (N'U/mL', N'Units per Milliliter'),
 (N'mg/L', N'Milligrams per Liter'),
 (N'ng/L', N'Nanograms per Liter'),
 (N'nmol/L', N'Nanomoles per Liter'),
 (N'mOsm/kg', N'Milliosmoles per Kilogram'),
 (N'mg/24hr', N'Milligrams per 24 Hours'),
 (N'mL/min', N'Milliliters per Minute'),
 (N'mg/g', N'Milligrams per Gram Creatinine'),
 (N'min', N'Minutes'),
 (N'copies/mL', N'Copies per Milliliter'),
 (N'mm', N'Millimeters'),
 (N'U/g Hb', N'Units per Gram Haemoglobin'),
 (N'IU/L', N'International Units per Liter'),
 (N'mIU/mL', N'Milli-international Units per Milliliter');
DECLARE @SM TABLE (SName NVARCHAR(100), Cont NVARCHAR(100), Vol DECIMAL(10,2), VUnit NVARCHAR(20), VReq NVARCHAR(100), Store NVARCHAR(50), Rej NVARCHAR(300));
INSERT @SM VALUES
 (N'24 Hour Urine', N'24 Hour Urine Container', 2000, N'mL', N'Complete 24 hour collection', N'2 to 8', N'Incomplete collection or no preservative when needed.'),
 (N'Tissue in 10% Formalin', N'Formalin Container', 1, N'Piece', N'Whole specimen, 10x formalin volume', N'Room Temp', N'Specimen not in formalin, unlabelled or autolysed.'),
 (N'Fresh Tissue', N'Sterile Dry Container', 1, N'Piece', N'Whole specimen, sent immediately', N'2 to 8', N'Specimen in formalin or delayed beyond 30 minutes.'),
 (N'Cytology Smear / Fluid', N'Slides / Cytology Vial', 1, N'Set', N'Fixed smears or fluid vial', N'Room Temp', N'Unfixed or broken slides, unlabelled vial.'),
 (N'Bone Marrow', N'EDTA Tube + Slides', 2, N'mL', N'1 - 2 mL aspirate and smears', N'Room Temp', N'Clotted aspirate or unlabelled slides.');

DECLARE @co INT, @added INT, @skipped INT;

-- ── new lab departments: departments are global (one list for every company), created once ──
IF @PreviewOnly = 0
    INSERT dbo.DepartmentMaster (DeptCode, DeptName, DeptType, IsActive, CreatedDate, CompanyId)
    SELECT x.NewDeptCode, x.NewDept, 'Lab', 1, GETDATE(), ISNULL(@OnlyCompanyId, 1)
    FROM (SELECT DISTINCT NewDept, NewDeptCode FROM @CAT WHERE NewDept IS NOT NULL) x
    WHERE NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster d WHERE d.DeptName = x.NewDept)
      AND NOT EXISTS (SELECT 1 FROM dbo.DepartmentMaster d WHERE d.DeptCode = x.NewDeptCode);

CREATE TABLE #Preview (CompanyId INT, Company NVARCHAR(200), Area VARCHAR(30), Item NVARCHAR(300), Result NVARCHAR(400));
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR
    SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1 AND (@OnlyCompanyId IS NULL OR CompanyId = @OnlyCompanyId) ORDER BY CompanyId;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @PreviewOnly = 1
    BEGIN
        DECLARE @cname NVARCHAR(200) = (SELECT TOP 1 CompanyName FROM dbo.CompanyMaster WHERE CompanyId = @co);
        -- departments
        INSERT #Preview SELECT DISTINCT @co, @cname, '1 Department (global)', x.NewDept,
               CASE WHEN EXISTS (SELECT 1 FROM dbo.DepartmentMaster d WHERE d.DeptName = x.NewDept) THEN N'exists' ELSE N'will be created' END
        FROM @CAT x WHERE x.NewDept IS NOT NULL;
        -- categories
        INSERT #Preview SELECT @co, @cname, '2 Category', x.CatName,
               CASE WHEN c.Category_ID IS NOT NULL THEN N'found (Category_ID ' + CAST(c.Category_ID AS NVARCHAR(10)) + N')'
                         + CASE WHEN x.NewDept IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.LabTestCategoryMaster c2 INNER JOIN dbo.DepartmentMaster d2 ON d2.DeptId = c2.Department_ID
                                                                          WHERE c2.Category_ID = c.Category_ID AND d2.DeptName = x.NewDept)
                                THEN N', moves to department ' + x.NewDept ELSE N'' END
                    WHEN x.NewDept IS NOT NULL THEN N'will be created under new department ' + x.NewDept
                    WHEN EXISTS (SELECT 1 FROM dbo.DepartmentMaster d WHERE d.DeptName = x.FallbackDept)
                         THEN N'will be created under department ' + x.FallbackDept
                    ELSE N'NOT PLACED: no category of this name and no department named ' + x.FallbackDept + N' - its tests will be skipped' END
        FROM @CAT x
        OUTER APPLY (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE CompanyId = @co AND IsDeleted = 0 AND Category_Name = x.CatName ORDER BY Category_ID) c;
        -- tests per area: to add / already there
        INSERT #Preview SELECT @co, @cname, '3 Tests', x.CatName,
               CAST(SUM(CASE WHEN e.Test_ID IS NULL THEN 1 ELSE 0 END) AS NVARCHAR(10)) + N' to add, '
               + CAST(SUM(CASE WHEN e.Test_ID IS NOT NULL THEN 1 ELSE 0 END) AS NVARCHAR(10)) + N' already there (same name)'
        FROM @T t INNER JOIN @CAT x ON x.CatKey = t.CatKey
        OUTER APPLY (SELECT TOP 1 Test_ID FROM dbo.LabInvestigationMaster i WHERE i.CompanyId = @co AND i.IsDeleted = 0 AND LTRIM(RTRIM(i.Test_Name)) = LTRIM(RTRIM(t.Name))) e
        GROUP BY x.CatKey, x.CatName;
        -- possible duplicates: an existing test whose name looks like a new one (but is not the same)
        ;WITH n AS (SELECT t.Name,
                           LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(t.Name, ' ', ''), '-', ''), '(', ''), ')', ''), '/', ''), '.', '')) AS NN,
                           LOWER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(CASE WHEN CHARINDEX('(', t.Name) > 1 THEN LEFT(t.Name, CHARINDEX('(', t.Name) - 1) ELSE t.Name END)), ' ', ''), '-', ''), '/', '')) AS NC
                    FROM @T t
                    WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster i WHERE i.CompanyId = @co AND i.IsDeleted = 0 AND LTRIM(RTRIM(i.Test_Name)) = LTRIM(RTRIM(t.Name)))),
              e AS (SELECT i.Test_ID, i.Test_Name,
                           LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(i.Test_Name, ' ', ''), '-', ''), '(', ''), ')', ''), '/', ''), '.', '')) AS EN
                    FROM dbo.LabInvestigationMaster i WHERE i.CompanyId = @co AND i.IsDeleted = 0)
        INSERT #Preview SELECT @co, @cname, '4 Possible duplicate', n.Name, N'similar existing test: ' + e.Test_Name + N' (Test_ID ' + CAST(e.Test_ID AS NVARCHAR(10)) + N')'
        FROM n INNER JOIN e ON (LEN(e.EN) >= 5 AND n.NN LIKE '%' + e.EN + '%') OR (LEN(n.NC) >= 5 AND e.EN LIKE '%' + n.NC + '%');
        GOTO next_company;
    END

    -- ── categories: existing by name (moved to its new department), else created ──
    DECLARE @C TABLE (CatKey VARCHAR(5), Category_ID INT, Department_ID INT);
    DELETE @C;
    DECLARE @ck VARCHAR(5), @cn NVARCHAR(150), @nd NVARCHAR(100), @fd NVARCHAR(100), @cid INT, @did INT;
    DECLARE ct CURSOR LOCAL FAST_FORWARD FOR SELECT CatKey, CatName, NewDept, FallbackDept FROM @CAT;
    OPEN ct; FETCH NEXT FROM ct INTO @ck, @cn, @nd, @fd;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @did = (SELECT TOP 1 DeptId FROM dbo.DepartmentMaster WHERE DeptName = ISNULL(@nd, @fd) ORDER BY DeptId);
        SET @cid = (SELECT TOP 1 Category_ID FROM dbo.LabTestCategoryMaster WHERE CompanyId = @co AND IsDeleted = 0 AND Category_Name = @cn ORDER BY Category_ID);
        IF @cid IS NOT NULL AND @nd IS NOT NULL AND @did IS NOT NULL
            UPDATE dbo.LabTestCategoryMaster SET Department_ID = @did, ModifiedDate = GETDATE() WHERE Category_ID = @cid AND Department_ID <> @did;
        IF @cid IS NULL AND @did IS NOT NULL
        BEGIN
            INSERT dbo.LabTestCategoryMaster (CompanyId, Department_ID, Category_Name, Category_Code, Display_Order, Status, CreatedDate, IsDeleted,
                   Is_Barcode_Required, Is_Sample_Collection_Required)
            VALUES (@co, @did, @cn,
                    'LCAT' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Category_Code, 5, 10) AS INT)) FROM dbo.LabTestCategoryMaster WHERE Category_Code LIKE 'LCAT%'), 0) + 1 AS VARCHAR(10)), 4),
                    ISNULL((SELECT MAX(Display_Order) FROM dbo.LabTestCategoryMaster WHERE CompanyId = @co), 0) + 1, 1, GETDATE(), 0,
                    CASE WHEN @ck = 'CAR' THEN 0 ELSE 1 END, CASE WHEN @ck = 'CAR' THEN 0 ELSE 1 END);
            SET @cid = SCOPE_IDENTITY();
        END
        IF @cid IS NOT NULL
            INSERT @C SELECT @ck, @cid, Department_ID FROM dbo.LabTestCategoryMaster WHERE Category_ID = @cid;
        FETCH NEXT FROM ct INTO @ck, @cn, @nd, @fd;
    END
    CLOSE ct; DEALLOCATE ct;

    -- ── sub-categories ───────────────────────────────────────────────────────
    INSERT dbo.LabTestSubCategoryMaster (CompanyId, Category_ID, SubCategory_Name, SubCategory_Code, Display_Order, Status, CreatedDate, IsDeleted)
    SELECT @co, s.Category_ID, s.Sub,
           'LSUBCAT' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(SubCategory_Code, 8, 10) AS INT)) FROM dbo.LabTestSubCategoryMaster WHERE SubCategory_Code LIKE 'LSUBCAT%'), 0)
                                      + ROW_NUMBER() OVER (ORDER BY s.Category_ID, s.Sub) AS VARCHAR(10)), 4),
           ROW_NUMBER() OVER (PARTITION BY s.Category_ID ORDER BY s.Sub) + 50, 1, GETDATE(), 0
    FROM (SELECT DISTINCT c.Category_ID, t.Sub FROM @T t INNER JOIN @C c ON c.CatKey = t.CatKey) s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.LabTestSubCategoryMaster x WHERE x.CompanyId = @co AND x.IsDeleted = 0 AND x.Category_ID = s.Category_ID AND x.SubCategory_Name = s.Sub);

    -- ── units, methods, sample types ─────────────────────────────────────────
    INSERT dbo.LabUnitMaster (CompanyId, Unit_Name, Unit_Code, Unit_Symbol, Conversion_Factor, Display_Order, Status, CreatedDate, IsDeleted)
    SELECT @co, u.UName,
           'UNT' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Unit_Code, 4, 10) AS INT)) FROM dbo.LabUnitMaster WHERE Unit_Code LIKE 'UNT%'), 0) + ROW_NUMBER() OVER (ORDER BY u.Sym) AS VARCHAR(10)), 4),
           u.Sym, 1, ISNULL((SELECT MAX(Display_Order) FROM dbo.LabUnitMaster WHERE CompanyId = @co), 0) + ROW_NUMBER() OVER (ORDER BY u.Sym), 1, GETDATE(), 0
    FROM @U u
    WHERE NOT EXISTS (SELECT 1 FROM dbo.LabUnitMaster x WHERE x.CompanyId = @co AND x.IsDeleted = 0 AND x.Unit_Symbol = u.Sym);

    -- methods belong to a department: each test's method is created in the department of its category when missing
    INSERT dbo.LabTestMethodMaster (CompanyId, Department_ID, Method_Name, Method_Code, Display_Order, Status, CreatedDate, IsDeleted)
    SELECT @co, x.Department_ID, x.Method,
           'MTH' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Method_Code, 4, 10) AS INT)) FROM dbo.LabTestMethodMaster WHERE Method_Code LIKE 'MTH%'), 0) + ROW_NUMBER() OVER (ORDER BY x.Department_ID, x.Method) AS VARCHAR(10)), 4),
           ROW_NUMBER() OVER (PARTITION BY x.Department_ID ORDER BY x.Method) + 50, 1, GETDATE(), 0
    FROM (SELECT DISTINCT c.Department_ID, t.Method FROM @T t INNER JOIN @C c ON c.CatKey = t.CatKey) x
    WHERE NOT EXISTS (SELECT 1 FROM dbo.LabTestMethodMaster m WHERE m.CompanyId = @co AND m.IsDeleted = 0 AND m.Department_ID = x.Department_ID AND m.Method_Name = x.Method);

    INSERT dbo.LabSampleTypeMaster (CompanyId, Sample_Name, Sample_Code, Container_Type, Volume_Value, Volume_Unit, Volume_Required, Storage_Temperature,
           Rejection_Criteria, Display_Order, Status, CreatedDate, IsDeleted)
    SELECT @co, s.SName,
           'SMP' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Sample_Code, 4, 10) AS INT)) FROM dbo.LabSampleTypeMaster WHERE Sample_Code LIKE 'SMP%'), 0) + ROW_NUMBER() OVER (ORDER BY s.SName) AS VARCHAR(10)), 4),
           s.Cont, s.Vol, s.VUnit, s.VReq, s.Store, s.Rej, 20 + ROW_NUMBER() OVER (ORDER BY s.SName), 1, GETDATE(), 0
    FROM @SM s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.LabSampleTypeMaster x WHERE x.CompanyId = @co AND x.IsDeleted = 0 AND x.Sample_Name = s.SName);

    -- ── the tests (skipped when the name already exists in the company) ──────
    DECLARE @New TABLE (Seq INT, Test_ID INT);
    DELETE @New;
    DECLARE @seq INT, @tid INT, @base INT = ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Test_Code, 4, 10) AS INT)) FROM dbo.LabInvestigationMaster WHERE Test_Code LIKE 'TST%'), 0), @n INT = 0;
    DECLARE tt CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.Seq FROM @T t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.LabInvestigationMaster x WHERE x.CompanyId = @co AND x.IsDeleted = 0
                            AND LTRIM(RTRIM(x.Test_Name)) = LTRIM(RTRIM(t.Name)))
          AND EXISTS (SELECT 1 FROM @C c WHERE c.CatKey = t.CatKey)
        ORDER BY t.Seq;
    OPEN tt; FETCH NEXT FROM tt INTO @seq;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @n = @n + 1;
        INSERT dbo.LabInvestigationMaster (CompanyId, Test_Code, Test_Name, Department_ID, Category_ID, SubCategory_ID, Sample_Type_ID, Method_ID, Unit_ID,
               Reporting_Type, TAT_Hours, NABL_Accredited, Is_Outsourced, MRP, Status, CreatedDate, IsDeleted, Is_Profile_Test,
               Applicable_Gender, Is_Billable, Is_Fasting_Required, Is_Consent_Required, OVD_Document, Prescription_Required, Reporting_Name,
               Has_External_Document, Is_LMP_Date_Required)
        SELECT @co, 'TST' + RIGHT('0000' + CAST(@base + @n AS VARCHAR(10)), 4), t.Name, c.Department_ID, c.Category_ID,
               (SELECT TOP 1 SubCategory_ID FROM dbo.LabTestSubCategoryMaster s WHERE s.CompanyId = @co AND s.IsDeleted = 0 AND s.Category_ID = c.Category_ID AND s.SubCategory_Name = t.Sub ORDER BY s.SubCategory_ID),
               (SELECT TOP 1 Sample_Type_ID FROM dbo.LabSampleTypeMaster s WHERE s.CompanyId = @co AND s.IsDeleted = 0 AND s.Sample_Name = t.Sample ORDER BY s.Sample_Type_ID),
               (SELECT TOP 1 Method_ID FROM dbo.LabTestMethodMaster m WHERE m.CompanyId = @co AND m.IsDeleted = 0 AND m.Department_ID = c.Department_ID AND m.Method_Name = t.Method ORDER BY m.Method_ID),
               (SELECT TOP 1 Unit_ID FROM dbo.LabUnitMaster u WHERE u.CompanyId = @co AND u.IsDeleted = 0 AND u.Unit_Symbol = t.Unit ORDER BY u.Unit_ID),
               t.RType, t.Tat, 0, 0, t.Mrp, 1, GETDATE(), 0, 0,
               t.Gender, 1,
               CASE WHEN t.Name IN (N'Fasting Insulin', N'C-Peptide (Fasting)', N'Lipoprotein (a)', N'Apolipoprotein A1', N'Apolipoprotein B', N'Non-HDL Cholesterol',
                                    N'Oral Glucose Tolerance Test (OGTT, 75 g)', N'Serum Iron', N'Homocysteine') THEN 1 ELSE 0 END,
               CASE WHEN t.CatKey IN ('HIS', 'MOL') OR t.Name LIKE N'HIV%' OR t.Name LIKE N'CT %' OR t.Name LIKE N'MRI%' OR t.Name IN (N'TMT (Treadmill Stress Test)', N'Intravenous Pyelography (IVP)', N'Hysterosalpingography (HSG)') THEN 1 ELSE 0 END,
               0, 0, t.Name, 0,
               CASE WHEN t.Name LIKE N'USG Obstetric%' OR t.Name LIKE N'USG NT%' OR t.Name IN (N'Doppler Obstetric', N'Fetal Echocardiography', N'Urine Pregnancy Test (UPT)') THEN 1 ELSE 0 END
        FROM @T t INNER JOIN @C c ON c.CatKey = t.CatKey
        WHERE t.Seq = @seq;
        SET @tid = SCOPE_IDENTITY();
        INSERT @New VALUES (@seq, @tid);
        FETCH NEXT FROM tt INTO @seq;
    END
    CLOSE tt; DEALLOCATE tt;

    -- reference ranges
    INSERT dbo.LabReferenceRangeMaster (CompanyId, Test_ID, Unit_ID, Age_From, Age_To, Age_Unit, Gender, Pregnancy_Trimester, Low_Value, High_Value,
           Range_Source, Effective_From, Status, IsDeleted, CreatedDate, Special_Remarks, Is_Common_For_All, Notification_Required, Acknowledgement_Required)
    SELECT @co, n.Test_ID, i.Unit_ID, 0, 100, 'Years', r.Gender, 'Not Applicable', r.Lo, r.Hi, N'Standard adult reference', '2020-01-01', 1, 0, GETDATE(),
           r.Remark, CASE WHEN r.Gender = 'All' THEN 1 ELSE 0 END, 0, 0
    FROM @New n
    INNER JOIN @T t ON t.Seq = n.Seq
    INNER JOIN @R r ON r.Name = t.Name
    INNER JOIN dbo.LabInvestigationMaster i ON i.Test_ID = n.Test_ID
    WHERE i.Unit_ID IS NOT NULL;

    -- result options for Select tests
    INSERT dbo.LabParameterOptionMaster (CompanyId, Option_Code, Test_ID, Option_Text, Display_Order, Is_Abnormal, Is_Default, Status, IsDeleted, CreatedDate)
    SELECT @co,
           'OPT' + RIGHT('0000' + CAST(ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(Option_Code, 4, 10) AS INT)) FROM dbo.LabParameterOptionMaster WHERE Option_Code LIKE 'OPT%'), 0)
                                  + ROW_NUMBER() OVER (ORDER BY n.Test_ID, o.Ord) AS VARCHAR(10)), 4),
           n.Test_ID, o.Txt, o.Ord, o.Abn, o.Dflt, 1, 0, GETDATE()
    FROM @New n INNER JOIN @T t ON t.Seq = n.Seq INNER JOIN @OP o ON o.Name = t.Name;

    -- report templates for imaging / cardiac / descriptive tests
    INSERT dbo.LabDescriptiveTestTemplate (Test_ID, Section_Name, Section_Sequence, Is_Mandatory, Default_Content_Html, Placeholder_Tags, IsActive, CompanyId,
           CreatedDate, Modality, Body_Part, Laterality, Contrast_Required)
    SELECT n.Test_ID, s.Section_Name, s.Seq, s.Mand, s.Html, s.Tags, 1, @co, GETDATE(), tp.Modality, tp.BodyPart, 'N/A',
           CASE WHEN t.Name LIKE N'%(Contrast)%' OR t.Name LIKE N'%Angiography%' OR t.Name IN (N'Intravenous Pyelography (IVP)', N'Hysterosalpingography (HSG)', N'Barium Swallow') THEN 1 ELSE 0 END
    FROM @New n
    INNER JOIN @T t ON t.Seq = n.Seq
    INNER JOIN @TP tp ON tp.Name = t.Name
    CROSS APPLY (VALUES
        (1, N'Clinical History', 1, N'<p>{{PatientName}}, {{PatientAge}}/{{PatientGender}}, referred for {{ClinicalIndication}}.</p>', N'{{PatientName}},{{PatientAge}},{{PatientGender}},{{ClinicalIndication}}'),
        (2, CASE WHEN t.RType = 'Image' THEN N'Technique' ELSE N'Specimen' END, 1,
            CASE WHEN t.RType = 'Image' THEN N'<p>' + t.Name + N' was performed as per standard protocol.</p>' ELSE N'<p><strong>Specimen:</strong> Received as labelled.</p>' END, NULL),
        (3, N'Findings', 1, N'<p>No significant abnormality detected.</p>', NULL),
        (4, N'Impression', 1, CASE WHEN t.RType = 'Image' THEN N'<p>Normal study.</p>' ELSE N'<p>&nbsp;</p>' END, NULL),
        (5, N'Recommendation', 0, N'<p>Clinical correlation advised.</p>', NULL)
    ) s (Seq, Section_Name, Mand, Html, Tags);

    SET @added = (SELECT COUNT(1) FROM @New);
    SET @skipped = (SELECT COUNT(1) FROM @T) - @added;
    PRINT CONCAT('Company ', @co, ': ', @added, ' tests added, ', @skipped, ' already present or not placed.');
    INSERT #Preview SELECT @co, (SELECT TOP 1 CompanyName FROM dbo.CompanyMaster WHERE CompanyId = @co), '0 Applied', N'Tests',
           CAST(@added AS NVARCHAR(10)) + N' added, ' + CAST(@skipped AS NVARCHAR(10)) + N' already present or not placed';
next_company:
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;

SELECT CompanyId, Company, Area, Item, Result FROM #Preview ORDER BY CompanyId, Area, Item;
DROP TABLE #Preview;

GO

PRINT 'Script 2550 applied: Investigation Master - standard test catalogue.';
GO

