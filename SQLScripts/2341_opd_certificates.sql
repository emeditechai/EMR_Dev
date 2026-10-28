-- ============================================================================
-- 2341: OPD > Certificates (plan: "OPD Medical Certificates - Plan", 2026-10-27).
-- Medical Fitness, Sick Leave, Fitness to Resume Duty, Vaccination / Immunization, Disability Assessment,
-- OPD Attendance and Medical (Treatment) certificates: drafted from an OPD visit or a patient search, issued by any
-- signing doctor of the branch, numbered per branch / type / financial year, verified publicly by QR.
-- Birth and Death records come later. Additive only: no existing table, procedure or OPD flow is changed.
-- ============================================================================
SET NOCOUNT ON;
GO

-- ── masters (company-wise; Disability Type is statutory and shared) ──────────────────────────────────────
IF OBJECT_ID('dbo.CertificateTypeMaster') IS NULL
CREATE TABLE dbo.CertificateTypeMaster (
    CertificateTypeId  INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId          INT NOT NULL,
    TypeCode           VARCHAR(10) NOT NULL,          -- FIT / SICK / RESUME / VACC / DIS / ATTEND / TREAT
    TypeName           NVARCHAR(100) NOT NULL,
    PrintTitle         NVARCHAR(150) NOT NULL,
    NumberPrefix       VARCHAR(10) NOT NULL,
    DefaultValidityDays INT NULL,                     -- fitness: how long it stays valid
    FeeServiceId       INT NULL,                      -- the OPD service to bill when it is charged (ServiceMaster)
    LegalNote          NVARCHAR(400) NULL,            -- printed under the body (rule it follows)
    SortOrder          INT NOT NULL DEFAULT 0,
    IsActive           BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL,
    CONSTRAINT UQ_CertificateType UNIQUE (CompanyId, TypeCode)
);
GO
IF OBJECT_ID('dbo.CertificatePurposeMaster') IS NULL
CREATE TABLE dbo.CertificatePurposeMaster (
    PurposeId   INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId   INT NOT NULL,
    TypeCode    VARCHAR(10) NOT NULL,
    PurposeName NVARCHAR(150) NOT NULL,
    SortOrder   INT NOT NULL DEFAULT 0,
    IsActive    BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.VaccineMaster') IS NULL
CREATE TABLE dbo.VaccineMaster (
    VaccineId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId     INT NOT NULL,
    VaccineName   NVARCHAR(150) NOT NULL,
    ShortCode     VARCHAR(20) NULL,
    Diseases      NVARCHAR(200) NULL,
    DefaultRoute  VARCHAR(30) NULL,                   -- IM / SC / ID / Oral
    DefaultSite   NVARCHAR(60) NULL,
    DosesInSeries INT NOT NULL DEFAULT 1,
    DoseGapDays   INT NULL,                           -- next dose due after these many days
    ScheduleAge   NVARCHAR(100) NULL,                 -- as in the National Immunization Schedule
    IsUIP         BIT NOT NULL DEFAULT 0,             -- in the Universal Immunization Programme
    SortOrder     INT NOT NULL DEFAULT 0,
    IsActive      BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF OBJECT_ID('dbo.DisabilityTypeMaster') IS NULL
CREATE TABLE dbo.DisabilityTypeMaster (
    DisabilityTypeId INT IDENTITY(1,1) PRIMARY KEY,
    Name             NVARCHAR(150) NOT NULL,
    Category         NVARCHAR(100) NOT NULL,          -- RPwD Act 2016 schedule group
    AssessmentForm   VARCHAR(10) NOT NULL,            -- RPwD Rules 2017: V (amputation / complete), VI (multiple), VII (other)
    SortOrder        INT NOT NULL DEFAULT 0,
    IsActive         BIT NOT NULL DEFAULT 1
);
GO
-- signing doctors: credentials printed on certificates (kept beside DoctorMaster, which is not changed)
IF OBJECT_ID('dbo.CertificateDoctorProfile') IS NULL
CREATE TABLE dbo.CertificateDoctorProfile (
    DoctorId             INT NOT NULL PRIMARY KEY,
    CanSign              BIT NOT NULL DEFAULT 0,
    Qualification        NVARCHAR(200) NULL,
    RegistrationCouncil  NVARCHAR(150) NULL,          -- National Medical Commission / <State> Medical Council
    RegistrationNo       NVARCHAR(50) NULL,           -- empty = DoctorMaster.MedicalLicenseNo
    RegistrationYear     INT NULL,
    SignaturePath        NVARCHAR(300) NULL,
    StampPath            NVARCHAR(300) NULL,
    ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO

-- ── transactions ────────────────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.PatientCertificate') IS NULL
CREATE TABLE dbo.PatientCertificate (
    CertificateId     INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId         INT NOT NULL,
    BranchId          INT NOT NULL,
    TypeCode          VARCHAR(10) NOT NULL,
    CertificateNo     VARCHAR(40) NULL,               -- given on Issue only
    PatientId         INT NOT NULL,
    OPDServiceId      INT NULL,                       -- the visit it was written from (optional)
    DoctorId          INT NULL,                       -- signing doctor
    PurposeId         INT NULL,
    PurposeText       NVARCHAR(200) NULL,
    IssueDate         DATE NULL,
    ValidFrom         DATE NULL,
    ValidTo           DATE NULL,
    Diagnosis         NVARCHAR(500) NULL,
    Remarks           NVARCHAR(1000) NULL,
    BodyJson          NVARCHAR(MAX) NULL,             -- the type's own fields
    FeeMode           CHAR(1) NOT NULL DEFAULT 'F',   -- F = free, B = charged on an OPD bill
    FeeOPDServiceId   INT NULL,                       -- the OPD bill that charged it
    Status            CHAR(1) NOT NULL DEFAULT 'D',   -- D draft / I issued / C cancelled
    VerifyToken       VARCHAR(40) NULL,
    ReissueOfId       INT NULL,
    IssuedBy INT NULL, IssuedOn DATETIME NULL,
    CancelledBy INT NULL, CancelledOn DATETIME NULL, CancelReason NVARCHAR(300) NULL,
    PrintCount        INT NOT NULL DEFAULT 0,
    LastPrintedOn     DATETIME NULL,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE(), ModifiedBy INT NULL, ModifiedDate DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PatientCertificate_Branch')
    CREATE INDEX IX_PatientCertificate_Branch ON dbo.PatientCertificate (BranchId, CreatedDate) INCLUDE (TypeCode, Status, PatientId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PatientCertificate_Token')
    CREATE UNIQUE INDEX UX_PatientCertificate_Token ON dbo.PatientCertificate (VerifyToken) WHERE VerifyToken IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PatientCertificate_Patient')
    CREATE INDEX IX_PatientCertificate_Patient ON dbo.PatientCertificate (PatientId);
GO
IF OBJECT_ID('dbo.PatientVaccination') IS NULL
CREATE TABLE dbo.PatientVaccination (
    VaccinationId  INT IDENTITY(1,1) PRIMARY KEY,
    CompanyId      INT NOT NULL,
    BranchId       INT NOT NULL,
    PatientId      INT NOT NULL,
    VaccineId      INT NOT NULL,
    DoseNo         INT NOT NULL DEFAULT 1,
    GivenOn        DATE NOT NULL,
    BatchNo        NVARCHAR(50) NULL,
    Manufacturer   NVARCHAR(100) NULL,
    ExpiryDate     DATE NULL,
    Route          VARCHAR(30) NULL,
    Site           NVARCHAR(60) NULL,
    GivenBy        NVARCHAR(150) NULL,
    NextDueDate    DATE NULL,
    CertificateId  INT NULL,                          -- the certificate it was recorded on
    IsActive       BIT NOT NULL DEFAULT 1,
    CreatedBy INT NULL, CreatedDate DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PatientVaccination_Patient')
    CREATE INDEX IX_PatientVaccination_Patient ON dbo.PatientVaccination (PatientId, GivenOn);
GO
IF OBJECT_ID('dbo.CertificateSequence') IS NULL
CREATE TABLE dbo.CertificateSequence (
    BranchId INT NOT NULL, TypeCode VARCHAR(10) NOT NULL, FinYear VARCHAR(4) NOT NULL, LastNo INT NOT NULL,
    CONSTRAINT PK_CertificateSequence PRIMARY KEY (BranchId, TypeCode, FinYear)
);
GO

-- ── disability types: the 21 specified disabilities (RPwD Act 2016, Schedule) ──────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.DisabilityTypeMaster)
INSERT dbo.DisabilityTypeMaster (Name, Category, AssessmentForm, SortOrder) VALUES
 (N'Locomotor Disability', N'Physical disability', 'VII', 10),
 (N'Leprosy Cured Person', N'Physical disability', 'VII', 20),
 (N'Cerebral Palsy', N'Physical disability', 'VII', 30),
 (N'Dwarfism', N'Physical disability', 'VII', 40),
 (N'Muscular Dystrophy', N'Physical disability', 'VII', 50),
 (N'Acid Attack Victim', N'Physical disability', 'VII', 60),
 (N'Blindness', N'Visual impairment', 'VII', 70),
 (N'Low Vision', N'Visual impairment', 'VII', 80),
 (N'Deaf', N'Hearing impairment', 'VII', 90),
 (N'Hard of Hearing', N'Hearing impairment', 'VII', 100),
 (N'Speech and Language Disability', N'Speech and language', 'VII', 110),
 (N'Intellectual Disability', N'Intellectual disability', 'VII', 120),
 (N'Specific Learning Disabilities', N'Intellectual disability', 'VII', 130),
 (N'Autism Spectrum Disorder', N'Intellectual disability', 'VII', 140),
 (N'Mental Illness', N'Mental behaviour', 'VII', 150),
 (N'Multiple Sclerosis', N'Chronic neurological condition', 'VII', 160),
 (N'Parkinson''s Disease', N'Chronic neurological condition', 'VII', 170),
 (N'Haemophilia', N'Blood disorder', 'VII', 180),
 (N'Thalassemia', N'Blood disorder', 'VII', 190),
 (N'Sickle Cell Disease', N'Blood disorder', 'VII', 200),
 (N'Multiple Disabilities (incl. Deaf Blindness)', N'Multiple disabilities', 'VI', 210);
GO

-- ── default masters for a company (called for every company now, and by the screens for a new company) ──
CREATE OR ALTER PROCEDURE dbo.usp_Certificate_EnsureMasters
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @CompanyId IS NULL OR @CompanyId <= 0 RETURN;

    INSERT dbo.CertificateTypeMaster (CompanyId, TypeCode, TypeName, PrintTitle, NumberPrefix, DefaultValidityDays, LegalNote, SortOrder)
    SELECT @CompanyId, t.Code, t.Name, t.Title, t.Prefix, t.Validity, t.Note, t.Sort
      FROM (VALUES
        ('FIT',    N'Medical Fitness Certificate',      N'MEDICAL FITNESS CERTIFICATE',          'FIT', 180,
                   N'Issued by a registered medical practitioner after personal examination (NMC Regulations, 2002).', 10),
        ('SICK',   N'Medical / Sick Leave Certificate', N'MEDICAL CERTIFICATE FOR LEAVE',        'MCL', NULL,
                   N'Format as per Form 3, Central Civil Services (Leave) Rules, 1972.', 20),
        ('RESUME', N'Fitness to Resume Duty',           N'CERTIFICATE OF FITNESS TO RESUME DUTY','FRD', NULL,
                   N'Format as per Form 4, Central Civil Services (Leave) Rules, 1972.', 30),
        ('VACC',   N'Vaccination / Immunization Certificate', N'VACCINATION / IMMUNIZATION CERTIFICATE', 'VAC', NULL,
                   N'Vaccines as per the National Immunization Schedule / Universal Immunization Programme.', 40),
        ('DIS',    N'Disability Assessment Report',     N'DISABILITY ASSESSMENT REPORT',         'DAR', NULL,
                   N'Assessment for the Rights of Persons with Disabilities Act, 2016. The disability certificate (Form V / VI / VII) is issued by the medical authority notified by the State Government.', 50),
        ('ATTEND', N'OPD Attendance Certificate',       N'CERTIFICATE OF ATTENDANCE',            'ATT', NULL,
                   N'Certifies attendance at the out-patient department on the date(s) stated.', 60),
        ('TREAT',  N'Medical (Treatment) Certificate',  N'MEDICAL CERTIFICATE',                  'MED', NULL,
                   N'Issued by a registered medical practitioner on the basis of examination and records of this hospital.', 70)
      ) t (Code, Name, Title, Prefix, Validity, Note, Sort)
     WHERE NOT EXISTS (SELECT 1 FROM dbo.CertificateTypeMaster x WHERE x.CompanyId = @CompanyId AND x.TypeCode = t.Code);

    IF NOT EXISTS (SELECT 1 FROM dbo.CertificatePurposeMaster WHERE CompanyId = @CompanyId)
    INSERT dbo.CertificatePurposeMaster (CompanyId, TypeCode, PurposeName, SortOrder)
    SELECT @CompanyId, p.Code, p.Name, p.Sort FROM (VALUES
        ('FIT', N'Employment / joining duty', 10), ('FIT', N'Driving licence (Form 1-A)', 20), ('FIT', N'School / college admission', 30),
        ('FIT', N'Sports / gym participation', 40), ('FIT', N'Travel / fit to fly', 50), ('FIT', N'Insurance', 60),
        ('FIT', N'Food handler', 70), ('FIT', N'General purpose', 80),
        ('SICK', N'Office / employer', 10), ('SICK', N'School / college', 20), ('SICK', N'Examination', 30),
        ('RESUME', N'Office / employer', 10), ('RESUME', N'School / college', 20),
        ('VACC', N'Travel', 10), ('VACC', N'School admission', 20), ('VACC', N'Employment', 30), ('VACC', N'Personal record', 40),
        ('DIS', N'Disability certificate / UDID application', 10), ('DIS', N'Employment reservation', 20), ('DIS', N'Education concession', 30),
        ('ATTEND', N'Office / employer', 10), ('ATTEND', N'School / college', 20), ('ATTEND', N'Court / legal', 30),
        ('TREAT', N'Insurance claim', 10), ('TREAT', N'Office / employer', 20), ('TREAT', N'Legal', 30), ('TREAT', N'General purpose', 40)
    ) p (Code, Name, Sort);

    IF NOT EXISTS (SELECT 1 FROM dbo.VaccineMaster WHERE CompanyId = @CompanyId)
    INSERT dbo.VaccineMaster (CompanyId, VaccineName, ShortCode, Diseases, DefaultRoute, DefaultSite, DosesInSeries, DoseGapDays, ScheduleAge, IsUIP, SortOrder)
    SELECT @CompanyId, v.Name, v.Code, v.Dis, v.Route, v.Site, v.Doses, v.Gap, v.Age, v.Uip, v.Sort FROM (VALUES
        (N'BCG', 'BCG', N'Tuberculosis', 'ID', N'Left upper arm', 1, NULL, N'At birth', 1, 10),
        (N'Hepatitis B (birth dose)', 'HEPB-0', N'Hepatitis B', 'IM', N'Anterolateral thigh', 1, NULL, N'At birth', 1, 20),
        (N'Oral Polio Vaccine', 'OPV', N'Poliomyelitis', 'Oral', N'Mouth', 4, 28, N'Birth, 6, 10, 14 weeks', 1, 30),
        (N'Pentavalent (DPT-HepB-Hib)', 'PENTA', N'Diphtheria, pertussis, tetanus, hepatitis B, Hib', 'IM', N'Anterolateral thigh', 3, 28, N'6, 10, 14 weeks', 1, 40),
        (N'Rotavirus Vaccine', 'RVV', N'Rotavirus diarrhoea', 'Oral', N'Mouth', 3, 28, N'6, 10, 14 weeks', 1, 50),
        (N'Pneumococcal Conjugate Vaccine', 'PCV', N'Pneumococcal disease', 'IM', N'Anterolateral thigh', 3, 28, N'6, 14 weeks, 9 months booster', 1, 60),
        (N'Fractional IPV', 'fIPV', N'Poliomyelitis', 'ID', N'Right upper arm', 3, 56, N'6, 14 weeks, 9 months', 1, 70),
        (N'Measles-Rubella', 'MR', N'Measles, rubella', 'SC', N'Right upper arm', 2, 180, N'9-12 months, 16-24 months', 1, 80),
        (N'Japanese Encephalitis', 'JE', N'Japanese encephalitis', 'SC', N'Left upper arm', 2, 180, N'9-12 months, 16-24 months (endemic districts)', 1, 90),
        (N'DPT Booster', 'DPT-B', N'Diphtheria, pertussis, tetanus', 'IM', N'Anterolateral thigh', 2, 1095, N'16-24 months, 5-6 years', 1, 100),
        (N'Tetanus and adult Diphtheria', 'Td', N'Tetanus, diphtheria', 'IM', N'Upper arm', 2, 28, N'10 and 16 years; pregnant women', 1, 110),
        (N'Vitamin A', 'VIT-A', N'Vitamin A deficiency', 'Oral', N'Mouth', 9, 180, N'9 months to 5 years', 1, 120),
        (N'Typhoid Conjugate Vaccine', 'TCV', N'Typhoid', 'IM', N'Deltoid / thigh', 1, NULL, N'From 6 months', 0, 130),
        (N'Hepatitis A', 'HEPA', N'Hepatitis A', 'IM', N'Deltoid / thigh', 2, 180, N'From 12 months', 0, 140),
        (N'Varicella', 'VAR', N'Chickenpox', 'SC', N'Upper arm', 2, 90, N'15 months, 4-6 years', 0, 150),
        (N'MMR', 'MMR', N'Measles, mumps, rubella', 'SC', N'Upper arm', 2, 180, N'9 months, 15 months', 0, 160),
        (N'HPV', 'HPV', N'Human papillomavirus', 'IM', N'Deltoid', 2, 180, N'9-14 years', 0, 170),
        (N'Influenza', 'FLU', N'Influenza', 'IM', N'Deltoid', 1, 365, N'Yearly, from 6 months', 0, 180),
        (N'Rabies (post-exposure)', 'RAB', N'Rabies', 'IM', N'Deltoid', 4, 7, N'Days 0, 3, 7, 28', 0, 190),
        (N'Tetanus Toxoid', 'TT', N'Tetanus', 'IM', N'Deltoid', 1, NULL, N'After injury / as advised', 0, 200),
        (N'Hepatitis B (adult)', 'HEPB', N'Hepatitis B', 'IM', N'Deltoid', 3, 30, N'0, 1, 6 months', 0, 210),
        (N'COVID-19', 'COVID', N'COVID-19', 'IM', N'Deltoid', 2, 28, N'As per national guidelines', 0, 220)
    ) v (Name, Code, Dis, Route, Site, Doses, Gap, Age, Uip, Sort);
END;
GO

DECLARE @co INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Certificate_EnsureMasters @co; FETCH NEXT FROM cc INTO @co; END
CLOSE cc; DEALLOCATE cc;
GO

-- ── issue: number from the branch / type / financial-year counter, a verify token, locked ───────────────
CREATE OR ALTER PROCEDURE dbo.usp_Certificate_Issue
    @CertificateId INT,
    @BranchId      INT,
    @UserId        INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DECLARE @type VARCHAR(10), @status CHAR(1), @company INT, @doctor INT, @issue DATE;
    SELECT @type = TypeCode, @status = Status, @company = CompanyId, @doctor = DoctorId, @issue = ISNULL(IssueDate, CAST(GETDATE() AS DATE))
      FROM dbo.PatientCertificate WITH (UPDLOCK, HOLDLOCK)
     WHERE CertificateId = @CertificateId AND BranchId = @BranchId;
    IF @type IS NULL BEGIN ROLLBACK; THROW 50040, 'Certificate not found in this branch.', 1; END
    IF @status <> 'D' BEGIN ROLLBACK; THROW 50041, 'Only a draft can be issued.', 1; END
    IF NOT EXISTS (SELECT 1 FROM dbo.CertificateDoctorProfile WHERE DoctorId = @doctor AND CanSign = 1)
        BEGIN ROLLBACK; THROW 50042, 'Choose a signing doctor (Certificate Masters > Signing Doctors).', 1; END

    -- Indian financial year of the issue date: Apr 2026 - Mar 2027 = 2627
    DECLARE @fyStart INT = CASE WHEN MONTH(@issue) >= 4 THEN YEAR(@issue) ELSE YEAR(@issue) - 1 END;
    DECLARE @fy VARCHAR(4) = RIGHT(CAST(@fyStart AS VARCHAR(4)), 2) + RIGHT(CAST(@fyStart + 1 AS VARCHAR(4)), 2);
    DECLARE @no INT;
    UPDATE dbo.CertificateSequence WITH (UPDLOCK, HOLDLOCK) SET @no = LastNo = LastNo + 1
     WHERE BranchId = @BranchId AND TypeCode = @type AND FinYear = @fy;
    IF @no IS NULL BEGIN SET @no = 1; INSERT dbo.CertificateSequence (BranchId, TypeCode, FinYear, LastNo) VALUES (@BranchId, @type, @fy, 1); END

    DECLARE @prefix VARCHAR(10) = ISNULL((SELECT NumberPrefix FROM dbo.CertificateTypeMaster WHERE CompanyId = @company AND TypeCode = @type), @type);
    DECLARE @branchCode VARCHAR(20) = ISNULL((SELECT BranchCode FROM dbo.BranchMaster WHERE BranchID = @BranchId), CAST(@BranchId AS VARCHAR(10)));

    UPDATE dbo.PatientCertificate
       SET CertificateNo = @prefix + '/' + @branchCode + '/' + @fy + '/' + RIGHT('000000' + CAST(@no AS VARCHAR(10)), 6),
           Status = 'I', IssueDate = @issue, IssuedBy = @UserId, IssuedOn = GETDATE(),
           VerifyToken = LOWER(REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', '')),
           ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE CertificateId = @CertificateId;
    COMMIT;
    SELECT CertificateNo, VerifyToken FROM dbo.PatientCertificate WHERE CertificateId = @CertificateId;
END;
GO

-- ── menu pages and their controls (OPD > Certificates, Master > OPD Master > Certificate Masters) ───────
DECLARE @co INT, @menu INT, @page INT, @view INT, @ctl INT;
SELECT TOP 1 @menu = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'OPD' ORDER BY Menu_ID;
IF @menu IS NOT NULL
BEGIN
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'OPD.CERTIFICATES',
         @Title = N'Certificates', @Controller = N'Certificates', @Action = N'Index',
         @Show_In_Menu = 1, @Sort_Order = 60, @Icon = N'bi bi-patch-check me-2',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Certificates', @Action = N'Index', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Certificates', @Action = N'Print', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Certificates', @Action = N'SearchPatients', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Certificates', @Action = N'PatientContext', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'Certificates', @Action = N'FeeBills', @Source = 'SEED';

    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'DRAFT', @Title = N'Write / edit a draft certificate', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Certificates', @Action = N'Create', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Certificates', @Action = N'Edit', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Certificates', @Action = N'Save', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'ISSUE', @Title = N'Issue (sign) a certificate', @Sort_Order = 30, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Certificates', @Action = N'Issue', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'CANCEL', @Title = N'Cancel an issued certificate', @Sort_Order = 40, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Certificates', @Action = N'Cancel', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'REISSUE', @Title = N'Reissue a cancelled certificate', @Sort_Order = 50, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Certificates', @Action = N'Reissue', @Source = 'SEED';
END

SET @menu = NULL;
SELECT TOP 1 @menu = Menu_ID, @co = CompanyId FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.OPD_MASTER' ORDER BY Menu_ID;
IF @menu IS NOT NULL
BEGIN
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.CERTIFICATEMASTERS',
         @Title = N'Certificate Masters', @Controller = N'CertificateMasters', @Action = N'Index',
         @Show_In_Menu = 1, @Sort_Order = 80, @Icon = N'bi bi-patch-check me-2',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SET @view = NULL; SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'CertificateMasters', @Action = N'Index', @Source = 'SEED';
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'EDIT', @Title = N'Change certificate masters and signing doctors', @Sort_Order = 20, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'CertificateMasters', @Action = N'SaveType', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'CertificateMasters', @Action = N'SavePurpose', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'CertificateMasters', @Action = N'SaveVaccine', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'CertificateMasters', @Action = N'SaveDoctor', @Source = 'SEED';
END

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2341 applied: OPD > Certificates (tables, masters, numbering, pages).';
GO
