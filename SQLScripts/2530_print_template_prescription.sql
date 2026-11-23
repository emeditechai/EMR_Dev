-- ============================================================================================================
-- Migration: 2530_print_template_prescription.sql   (application database; needs 2324 and 2527)
-- Utility > Print Templates: a third kind, RX = "Dr. Prescription" - the header and footer of the doctor's prescription
-- pad (OPD > Print Dr. Prescription, 2527), designed, published and assigned per branch like Bills and Lab Reports.
--   * A branch with no prescription template prints the pad as before: with its Bill template's header, else the
--     Classic hospital name / address header (and blank space on pre-printed letterhead).
--   * PrintTemplate.Kind / PrintTemplateAssignment.Kind: 'RX' allowed (constraint CK_PrintTemplate_Kind).
--   * usp_PrintTpl_Save / usp_PrintTpl_Assign accept RX; usp_PrintTpl_Assignments returns RxTemplateId.
--   * usp_PrintTpl_LatestRxVisit @BranchId: the newest OPD visit of the branch with a consulting doctor - the
--     designer's "Preview on a real prescription" (api/print-templates/preview-visit, WEB PrintTemplates/PreviewPrescription).
-- No role is granted anything. Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'dbo.PrintTemplate', N'U') IS NULL
BEGIN
    RAISERROR('Script 2530 needs script 2324 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ── kind RX ────────────────────────────────────────────────────────────────────────────────────────────────
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PrintTemplate_Kind' AND parent_object_id = OBJECT_ID(N'dbo.PrintTemplate')
           AND definition NOT LIKE N'%''RX''%')
    ALTER TABLE dbo.PrintTemplate DROP CONSTRAINT CK_PrintTemplate_Kind;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PrintTemplate_Kind' AND parent_object_id = OBJECT_ID(N'dbo.PrintTemplate'))
    ALTER TABLE dbo.PrintTemplate ADD CONSTRAINT CK_PrintTemplate_Kind CHECK (Kind IN ('BILL', 'REPORT', 'RX'));
GO

-- create (@TemplateId 0) or save the draft of a template; returns its id
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Save
    @CompanyId INT, @TemplateId INT, @Kind VARCHAR(10), @Name NVARCHAR(100), @DraftJson NVARCHAR(MAX), @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Name = LTRIM(RTRIM(@Name));
    IF NULLIF(@Name, N'') IS NULL THROW 54001, 'Enter the template name.', 1;
    IF @Kind NOT IN ('BILL', 'REPORT', 'RX') THROW 54002, 'Choose Bill, Lab Report or Dr. Prescription.', 1;
    IF ISJSON(@DraftJson) = 0 THROW 54003, 'The layout could not be read.', 1;
    IF EXISTS (SELECT 1 FROM dbo.PrintTemplate WHERE CompanyId = @CompanyId AND Kind = @Kind AND Name = @Name AND IsActive = 1 AND TemplateId <> ISNULL(@TemplateId, 0))
        THROW 54004, 'Another template of this kind already has this name.', 1;

    IF ISNULL(@TemplateId, 0) = 0
    BEGIN
        INSERT dbo.PrintTemplate (CompanyId, Kind, Name, DraftJson, CreatedBy, ModifiedBy)
        VALUES (@CompanyId, @Kind, @Name, @DraftJson, @UserId, @UserId);
        SELECT CAST(SCOPE_IDENTITY() AS INT) AS TemplateId;
        RETURN;
    END

    UPDATE dbo.PrintTemplate SET Name = @Name, DraftJson = @DraftJson, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId AND IsActive = 1;
    IF @@ROWCOUNT = 0 THROW 54005, 'Template not found.', 1;
    SELECT @TemplateId AS TemplateId;
END
GO

-- every active branch with the template it prints its bills, reports and prescriptions with (NULL = Classic)
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Assignments @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BranchID AS BranchId, b.BranchName, CAST(b.IsHOBranch AS BIT) AS IsHOBranch,
           (SELECT a.TemplateId FROM dbo.PrintTemplateAssignment a WHERE a.CompanyId = @CompanyId AND a.BranchId = b.BranchID AND a.Kind = 'BILL') AS BillTemplateId,
           (SELECT a.TemplateId FROM dbo.PrintTemplateAssignment a WHERE a.CompanyId = @CompanyId AND a.BranchId = b.BranchID AND a.Kind = 'REPORT') AS ReportTemplateId,
           (SELECT a.TemplateId FROM dbo.PrintTemplateAssignment a WHERE a.CompanyId = @CompanyId AND a.BranchId = b.BranchID AND a.Kind = 'RX') AS RxTemplateId
    FROM dbo.Branchmaster b
    WHERE b.IsActive = 1 AND ISNULL(b.CompanyId, 1) = @CompanyId
    ORDER BY CASE WHEN b.IsHOBranch = 1 THEN 0 ELSE 1 END, b.BranchName;
END
GO

-- set the template of a branch for a kind (@TemplateId NULL = Classic / as before); only a published template
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_Assign @CompanyId INT, @BranchId INT, @Kind VARCHAR(10), @TemplateId INT = NULL, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind NOT IN ('BILL', 'REPORT', 'RX') THROW 54002, 'Choose Bill, Lab Report or Dr. Prescription.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.Branchmaster WHERE BranchID = @BranchId AND ISNULL(CompanyId, 1) = @CompanyId)
        THROW 54008, 'Branch not found.', 1;
    IF @TemplateId IS NULL
    BEGIN
        DELETE dbo.PrintTemplateAssignment WHERE CompanyId = @CompanyId AND BranchId = @BranchId AND Kind = @Kind;
        RETURN;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.PrintTemplate WHERE CompanyId = @CompanyId AND TemplateId = @TemplateId AND Kind = @Kind AND IsActive = 1 AND LayoutJson IS NOT NULL)
        THROW 54009, 'Only a published template of the same kind can be assigned.', 1;
    MERGE dbo.PrintTemplateAssignment AS a
    USING (SELECT @CompanyId AS CompanyId, @BranchId AS BranchId, @Kind AS Kind) s
       ON a.CompanyId = s.CompanyId AND a.BranchId = s.BranchId AND a.Kind = s.Kind
    WHEN MATCHED THEN UPDATE SET TemplateId = @TemplateId, ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHEN NOT MATCHED THEN INSERT (CompanyId, BranchId, Kind, TemplateId, ModifiedBy) VALUES (@CompanyId, @BranchId, @Kind, @TemplateId, @UserId);
END
GO

-- the designer's prescription preview: the newest OPD visit of the branch with a consulting doctor (none = NULL)
CREATE OR ALTER PROCEDURE dbo.usp_PrintTpl_LatestRxVisit @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1 s.OPDServiceId
      FROM dbo.PatientOPDService s
     WHERE s.BranchId = @BranchId AND s.IsActive = 1 AND s.ConsultingDoctorId IS NOT NULL
     ORDER BY CASE WHEN EXISTS (SELECT 1 FROM dbo.PatientOPDServiceItem i WHERE i.OPDServiceId = s.OPDServiceId AND i.IsActive = 1 AND i.ServiceType = 'Consulting')
                   THEN 0 ELSE 1 END, s.OPDServiceId DESC;
END
GO

-- ── endpoints: the preview (VIEW) on page UTILITY.PRINTTEMPLATES ──────────────────────────────────────────
DECLARE @co INT, @page INT, @ctl INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @page = (SELECT TOP 1 Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.PRINTTEMPLATES' AND CompanyId = @co);
    IF @page IS NOT NULL
    BEGIN
        SET @ctl = (SELECT Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'PrintTemplates', @Action = N'PreviewPrescription', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'API', @Http_Method = 'GET',
             @Controller = N'PrintTemplates', @Action = N'PreviewVisit', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2530 applied: Print Templates - Dr. Prescription (RX) header and footer.';
GO
