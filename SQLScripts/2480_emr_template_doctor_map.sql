-- ============================================================================================================
-- Migration: 2480_emr_template_doctor_map.sql   (application database)
-- Utility > EMR Templates: a template is mapped to ONE speciality (mandatory) and, optionally, to DOCTORS of that speciality.
-- Create can start from an existing template (Copy From: by speciality, and the template a doctor uses).
--   no doctor chosen   = the speciality's DEFAULT template (one active default per speciality, as before)
--   doctors chosen     = a DOCTOR-SPECIFIC template: only those doctors get it (one active doctor-specific template per
--                        doctor); it is never the default of the speciality's other doctors
-- Doctor Dashboard (EMR of a visit), usp_Emr_ResolveTemplate:
--   1. the visit's consultation is already saved -> the template it was saved with (its data belongs to that template)
--   2. the doctor's own active template (of the doctor's current primary speciality)
--   3. the active default template of the doctor's primary speciality (as before)
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.EmrTemplateDoctorMap', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.EmrTemplateDoctorMap
    (
        TemplateId  INT      NOT NULL CONSTRAINT FK_EmrTemplateDoctorMap_Template REFERENCES dbo.EmrTemplates (TemplateId),
        DoctorId    INT      NOT NULL CONSTRAINT FK_EmrTemplateDoctorMap_Doctor REFERENCES dbo.DoctorMaster (DoctorId),
        CompanyId   INT      NOT NULL CONSTRAINT DF_EmrTemplateDoctorMap_Company DEFAULT (1),
        IsActive    BIT      NOT NULL CONSTRAINT DF_EmrTemplateDoctorMap_Active DEFAULT (1),
        CreatedBy   INT      NULL,
        CreatedDate DATETIME NOT NULL CONSTRAINT DF_EmrTemplateDoctorMap_Created DEFAULT (GETDATE()),
        CONSTRAINT PK_EmrTemplateDoctorMap PRIMARY KEY (TemplateId, DoctorId)
    );
    CREATE INDEX IX_EmrTemplateDoctorMap_Doctor ON dbo.EmrTemplateDoctorMap (DoctorId) INCLUDE (TemplateId, IsActive);
END
GO

-- one speciality per template: at most one active speciality row per template (every template has one today)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_EmrTemplateSpecialityMap_OneSpeciality')
   AND NOT EXISTS (SELECT TemplateId FROM dbo.EmrTemplateSpecialityMap WHERE IsActive = 1 GROUP BY TemplateId HAVING COUNT(*) > 1)
    CREATE UNIQUE INDEX UX_EmrTemplateSpecialityMap_OneSpeciality ON dbo.EmrTemplateSpecialityMap (TemplateId) WHERE IsActive = 1;
GO
IF EXISTS (SELECT TemplateId FROM dbo.EmrTemplateSpecialityMap WHERE IsActive = 1 GROUP BY TemplateId HAVING COUNT(*) > 1)
    PRINT 'Note: some EMR templates still have more than one speciality - open and save each with one speciality, then re-run this script.';
GO

-- which template the EMR of a visit uses (Doctor Dashboard); Source = SAVED | DOCTOR | SPECIALITY
CREATE OR ALTER PROCEDURE dbo.usp_Emr_ResolveTemplate @OpdServiceId INT, @DoctorId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @co INT = (SELECT TOP 1 b.CompanyId FROM dbo.PatientOPDService s JOIN dbo.BranchMaster b ON b.BranchId = s.BranchId WHERE s.OPDServiceId = @OpdServiceId);

    -- 1. a saved consultation keeps its template (its values are keyed by that template's fields)
    DECLARE @saved INT = (SELECT TOP 1 c.TemplateId FROM dbo.EmrPatientConsultation c WHERE c.OPDServiceId = @OpdServiceId AND c.TemplateId IS NOT NULL);
    IF @saved IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.EmrTemplates WHERE TemplateId = @saved)
    BEGIN
        SELECT t.TemplateId, t.TemplateName, CAST('SAVED' AS VARCHAR(12)) AS Source FROM dbo.EmrTemplates t WHERE t.TemplateId = @saved;
        RETURN;
    END

    -- 2. the doctor's own template - only while it is of the doctor's (current) primary speciality
    DECLARE @spec INT = (SELECT PrimarySpecialityId FROM dbo.DoctorMaster WHERE DoctorId = @DoctorId AND IsActive = 1);
    IF EXISTS (SELECT 1 FROM dbo.EmrTemplateDoctorMap m JOIN dbo.EmrTemplates t ON t.TemplateId = m.TemplateId
               JOIN dbo.EmrTemplateSpecialityMap sm ON sm.TemplateId = t.TemplateId AND sm.IsActive = 1 AND sm.SpecialityId = @spec
               WHERE m.DoctorId = @DoctorId AND m.IsActive = 1 AND t.IsActive = 1 AND (@co IS NULL OR t.CompanyId = @co))
    BEGIN
        SELECT TOP 1 t.TemplateId, t.TemplateName, CAST('DOCTOR' AS VARCHAR(12)) AS Source
        FROM dbo.EmrTemplateDoctorMap m JOIN dbo.EmrTemplates t ON t.TemplateId = m.TemplateId
        JOIN dbo.EmrTemplateSpecialityMap sm ON sm.TemplateId = t.TemplateId AND sm.IsActive = 1 AND sm.SpecialityId = @spec
        WHERE m.DoctorId = @DoctorId AND m.IsActive = 1 AND t.IsActive = 1 AND (@co IS NULL OR t.CompanyId = @co)
        ORDER BY ISNULL(t.ModifiedDate, t.CreatedDate) DESC, t.TemplateId DESC;
        RETURN;
    END

    -- 3. the speciality's default template (a doctor-specific template is never the default)
    SELECT TOP 1 t.TemplateId, t.TemplateName, CAST('SPECIALITY' AS VARCHAR(12)) AS Source
    FROM dbo.EmrTemplateSpecialityMap m JOIN dbo.EmrTemplates t ON t.TemplateId = m.TemplateId
    WHERE m.SpecialityId = @spec AND m.IsActive = 1 AND t.IsActive = 1 AND (@co IS NULL OR t.CompanyId = @co)
      AND NOT EXISTS (SELECT 1 FROM dbo.EmrTemplateDoctorMap d WHERE d.TemplateId = t.TemplateId AND d.IsActive = 1)
    ORDER BY t.TemplateId;
END
GO

-- the template page's new actions: Doctors (doctors of the speciality) with the page's View; CopySources with Create (as Create)
DECLARE @page INT, @view INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.EMRTEMPLATES';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @view = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'EmrTemplates', @Action = N'Doctors', @Source = 'SEED';
    DECLARE @add INT = (SELECT TOP 1 Control_ID FROM dbo.PageEndpointMap WHERE Page_ID = @page AND Controller = N'EmrTemplates' AND Action = N'Create' AND Http_Method = 'GET');
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @add, @App = 'WEB', @Http_Method = 'GET', @Controller = N'EmrTemplates', @Action = N'CopySources', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2480 applied: EMR templates by doctor (optional) and template resolution.';
GO
