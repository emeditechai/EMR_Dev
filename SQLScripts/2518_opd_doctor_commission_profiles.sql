-- ============================================================================================================
-- Migration: 2518_opd_doctor_commission_profiles.sql   (application database; needs 2517)
-- OPD > Doctor Commission Configuration as PROFILES: one scope (doctor / speciality / branch, dates, overrides, approval,
-- status) with a table of share lines - e.g. Consultation 70 % + Service (Dressing, Injection) Rs 50 + Service (all
-- other services) 30 %. Each line stays one dbo.DoctorCommissionConfig row (the share calculation, accrual and
-- settlement are unchanged); the lines of a profile share DoctorCommissionConfig.ProfileId. A rule saved before this
-- script is a profile of its own (ProfileId NULL = its own CommissionConfigId).
--   usp_Api_DoctorCommissionProfile_List   : one row per profile, its lines summarised
--   usp_Api_DoctorCommissionProfile_Get    : the profile (result 1) and its lines (result 2, services as JSON)
--   usp_Api_DoctorCommissionProfile_Save   : the whole profile at once (lines as JSON), validated:
--       a line per revenue type (Consultation / Consultant count as one), Service lines any number but a service in one
--       line only and one "all services" line at most, 'All Services' not mixed with Consultation / Service lines,
--       share > 0 and a percentage up to 100. Removed lines are deleted (as the existing Delete does).
--   usp_Api_DoctorCommissionProfile_Delete : all lines of the profile
-- Safe to re-run.
-- ============================================================================================================
SET NOCOUNT ON;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF OBJECT_ID(N'dbo.DoctorCommissionConfigService', N'U') IS NULL
BEGIN
    RAISERROR('Script 2518 needs script 2517 first. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO
IF COL_LENGTH(N'dbo.DoctorCommissionConfig', N'ProfileId') IS NULL
    ALTER TABLE dbo.DoctorCommissionConfig ADD ProfileId INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DoctorCommissionConfig_Profile' AND object_id = OBJECT_ID(N'dbo.DoctorCommissionConfig'))
    CREATE INDEX IX_DoctorCommissionConfig_Profile ON dbo.DoctorCommissionConfig (ProfileId);
GO

-- one line's text: "Consultation 70% of Net Collected", "Service (Dressing, Injection) Rs 50 flat"
CREATE OR ALTER FUNCTION dbo.ufn_DoctorCommission_LineText (@CommissionConfigId INT)
RETURNS NVARCHAR(600)
AS
BEGIN
    DECLARE @t NVARCHAR(600);
    SELECT @t = c.RevenueType
              + CASE WHEN c.RevenueType = 'Service'
                     THEN N' (' + ISNULL((SELECT STRING_AGG(sm.ItemName, N', ') WITHIN GROUP (ORDER BY sm.ItemName)
                                           FROM dbo.DoctorCommissionConfigService x JOIN dbo.ServiceMaster sm ON sm.ServiceId = x.ServiceId
                                          WHERE x.CommissionConfigId = c.CommissionConfigId), N'all services') + N')'
                     ELSE N'' END
              + CASE WHEN c.CalculationType = 'Fixed Amount' THEN N' ₹' + FORMAT(c.DoctorShare, '0.##') + N' flat'
                     ELSE N' ' + FORMAT(c.DoctorShare, '0.##') + N'% of ' + c.CommissionBasis END
      FROM dbo.DoctorCommissionConfig c WHERE c.CommissionConfigId = @CommissionConfigId;
    RETURN @t;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionProfile_List
    @CompanyId    INT,
    @BranchId     INT = NULL,
    @DoctorId     INT = NULL,
    @SpecialityId INT = NULL,
    @IsActive     BIT = NULL,
    @Search       NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
    WITH g AS (
        SELECT ISNULL(c.ProfileId, c.CommissionConfigId) AS Pid, c.CommissionConfigId, c.RevenueType, c.IsActive
          FROM dbo.DoctorCommissionConfig c
         WHERE c.CompanyId = @CompanyId
    ), p AS (
        -- the profile's scope is the same on every line: read it from its first line
        SELECT g.Pid AS ProfileId, MIN(g.CommissionConfigId) AS FirstLineId, COUNT(*) AS LineCount,
               STRING_AGG(dbo.ufn_DoctorCommission_LineText(g.CommissionConfigId), N' · ')
                   WITHIN GROUP (ORDER BY CASE WHEN g.RevenueType = 'Service' THEN 1 ELSE 0 END, g.CommissionConfigId) AS LinesText,
               MAX(CAST(g.IsActive AS INT)) AS AnyActive
          FROM g GROUP BY g.Pid
    )
    SELECT p.ProfileId, p.LineCount, p.LinesText,
           f.BranchId, b.BranchName, f.DoctorId, d.FullName AS DoctorName, f.SpecialityId, s.SpecialityName,
           f.ProcedureId, f.ServiceId, f.CorporateId, f.InsuranceTPAId,
           f.EffectiveFrom, f.EffectiveTo, f.ApprovalRequired, CAST(p.AnyActive AS BIT) AS IsActive, f.CreatedDate, f.ModifiedDate
      FROM p
      JOIN dbo.DoctorCommissionConfig f ON f.CommissionConfigId = p.FirstLineId
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = f.BranchId
      LEFT JOIN dbo.DoctorMaster d ON d.DoctorId = f.DoctorId
      LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = f.SpecialityId
     WHERE (@BranchId IS NULL OR f.BranchId IS NULL OR f.BranchId = @BranchId)
       AND (@DoctorId IS NULL OR f.DoctorId = @DoctorId)
       AND (@SpecialityId IS NULL OR f.SpecialityId = @SpecialityId)
       AND (@IsActive IS NULL OR CAST(p.AnyActive AS BIT) = @IsActive)
       AND (@Search IS NULL OR d.FullName LIKE N'%' + @Search + N'%' OR s.SpecialityName LIKE N'%' + @Search + N'%'
            OR b.BranchName LIKE N'%' + @Search + N'%' OR p.LinesText LIKE N'%' + @Search + N'%')
     ORDER BY CAST(p.AnyActive AS BIT) DESC, ISNULL(f.ModifiedDate, f.CreatedDate) DESC, p.ProfileId DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionProfile_Get
    @ProfileId INT,
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    -- a link may carry one line's id (an older screen): it opens that line's profile
    SET @ProfileId = ISNULL((SELECT ISNULL(ProfileId, CommissionConfigId) FROM dbo.DoctorCommissionConfig
                              WHERE CommissionConfigId = @ProfileId AND CompanyId = @CompanyId), @ProfileId);
    DECLARE @first INT = (SELECT MIN(CommissionConfigId) FROM dbo.DoctorCommissionConfig
                           WHERE ISNULL(ProfileId, CommissionConfigId) = @ProfileId AND CompanyId = @CompanyId);
    SELECT @ProfileId AS ProfileId, f.CompanyId, f.BranchId, f.DoctorId, f.SpecialityId, f.ProcedureId, f.ServiceId, f.CorporateId, f.InsuranceTPAId,
           f.EffectiveFrom, f.EffectiveTo, f.ApprovalRequired, f.IsActive
      FROM dbo.DoctorCommissionConfig f WHERE f.CommissionConfigId = @first;
    SELECT c.CommissionConfigId, c.RevenueType, c.CalculationType, c.CommissionBasis, c.DoctorShare,
           (SELECT N'[' + STRING_AGG(CAST(x.ServiceId AS NVARCHAR(12)), N',') + N']' FROM dbo.DoctorCommissionConfigService x
             WHERE x.CommissionConfigId = c.CommissionConfigId) AS ServiceIdsJson
      FROM dbo.DoctorCommissionConfig c
     WHERE @first IS NOT NULL AND ISNULL(c.ProfileId, c.CommissionConfigId) = @ProfileId AND c.CompanyId = @CompanyId
     ORDER BY CASE WHEN c.RevenueType = 'Service' THEN 1 ELSE 0 END, c.CommissionConfigId;
END
GO

-- @Lines: [{"CommissionConfigId":12|null,"RevenueType":"Consultation","CalculationType":"Percentage","CommissionBasis":"Net Collected",
--           "DoctorShare":70,"ServiceIds":[2,7]}, ...]   Result: ProfileId. A rule broken -> THROW 51000 + the reason.
CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionProfile_Save
    @ProfileId        INT = NULL,
    @CompanyId        INT,
    @BranchId         INT = NULL,
    @DoctorId         INT = NULL,
    @SpecialityId     INT = NULL,
    @ProcedureId      INT = NULL,
    @ServiceId        INT = NULL,
    @CorporateId      INT = NULL,
    @InsuranceTPAId   INT = NULL,
    @EffectiveFrom    DATE,
    @EffectiveTo      DATE = NULL,
    @ApprovalRequired BIT = 1,
    @IsActive         BIT = 1,
    @Lines            NVARCHAR(MAX),
    @UserId           INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @BranchId = NULLIF(@BranchId, 0), @DoctorId = NULLIF(@DoctorId, 0), @SpecialityId = NULLIF(@SpecialityId, 0),
           @ProcedureId = NULLIF(@ProcedureId, 0), @ServiceId = NULLIF(@ServiceId, 0), @CorporateId = NULLIF(@CorporateId, 0),
           @InsuranceTPAId = NULLIF(@InsuranceTPAId, 0), @ProfileId = NULLIF(@ProfileId, 0);

    IF @EffectiveFrom IS NULL THROW 51000, 'Enter the Effective From date.', 1;
    IF @EffectiveTo IS NOT NULL AND @EffectiveTo < @EffectiveFrom THROW 51000, 'Effective To cannot be before Effective From.', 1;
    IF ISJSON(@Lines) <> 1 THROW 51000, 'Add at least one share line.', 1;

    CREATE TABLE #L (Seq INT IDENTITY PRIMARY KEY, Id INT NULL, Rev NVARCHAR(50), Calc NVARCHAR(50), Basis NVARCHAR(100), Share DECIMAL(18, 2), Svc NVARCHAR(MAX));
    INSERT #L (Id, Rev, Calc, Basis, Share, Svc)
    SELECT NULLIF(TRY_CAST(JSON_VALUE(j.value, '$.CommissionConfigId') AS INT), 0),
           LTRIM(RTRIM(JSON_VALUE(j.value, '$.RevenueType'))), LTRIM(RTRIM(JSON_VALUE(j.value, '$.CalculationType'))),
           LTRIM(RTRIM(JSON_VALUE(j.value, '$.CommissionBasis'))), TRY_CAST(JSON_VALUE(j.value, '$.DoctorShare') AS DECIMAL(18, 2)),
           JSON_QUERY(j.value, '$.ServiceIds')
      FROM OPENJSON(@Lines) j;
    IF NOT EXISTS (SELECT 1 FROM #L) THROW 51000, 'Add at least one share line.', 1;

    -- the services of each Service line (only real services: Service Type 'Service', not registration)
    CREATE TABLE #S (Seq INT, ServiceId INT, PRIMARY KEY (Seq, ServiceId));
    INSERT #S SELECT DISTINCT l.Seq, sm.ServiceId
      FROM #L l CROSS APPLY OPENJSON(ISNULL(l.Svc, N'[]')) j
      JOIN dbo.ServiceMaster sm ON sm.ServiceId = TRY_CAST(j.value AS INT) AND sm.ServiceType = 'Service' AND ISNULL(sm.IsRegistration, 0) = 0
     WHERE l.Rev = 'Service';

    DECLARE @msg NVARCHAR(400);
    IF EXISTS (SELECT 1 FROM #L WHERE Rev NOT IN ('Consultant', 'Consultation', 'Service', 'Procedure', 'Investigation', 'Package', 'Emergency', 'Telemedicine', 'All Services'))
        THROW 51000, 'Choose what each share line applies to.', 1;
    IF EXISTS (SELECT 1 FROM #L WHERE Calc NOT IN ('Percentage', 'Fixed Amount', 'Tiered') OR ISNULL(Calc, '') = '')
        THROW 51000, 'Choose the calculation of each share line.', 1;
    IF EXISTS (SELECT 1 FROM #L WHERE Calc <> 'Fixed Amount' AND Basis NOT IN ('Net Collected', 'Gross Bill', 'Net Bill (After Discount)', 'Base Tariff'))
        THROW 51000, 'Choose the commission basis of each percentage line.', 1;
    IF EXISTS (SELECT 1 FROM #L WHERE ISNULL(Share, 0) <= 0) THROW 51000, 'Each share line needs a share above 0.', 1;
    IF EXISTS (SELECT 1 FROM #L WHERE Calc <> 'Fixed Amount' AND Share > 100) THROW 51000, 'A percentage share cannot be above 100.', 1;
    IF EXISTS (SELECT 1 FROM #L WHERE Rev <> 'Service' GROUP BY CASE WHEN Rev = 'Consultant' THEN 'Consultation' ELSE Rev END HAVING COUNT(*) > 1)
    BEGIN
        SET @msg = (SELECT TOP 1 N'Only one ' + CASE WHEN MIN(Rev) IN ('Consultant', 'Consultation') THEN 'Consultation' ELSE MIN(Rev) END + N' line per profile.' FROM #L WHERE Rev <> 'Service'
                     GROUP BY CASE WHEN Rev = 'Consultant' THEN 'Consultation' ELSE Rev END HAVING COUNT(*) > 1);
        THROW 51000, @msg, 1;
    END
    IF EXISTS (SELECT 1 FROM #L WHERE Rev = 'All Services') AND EXISTS (SELECT 1 FROM #L WHERE Rev IN ('Consultant', 'Consultation', 'Service'))
        THROW 51000, 'An "All Services" line already shares the whole bill - remove it, or remove the Consultation / Service lines.', 1;
    IF (SELECT COUNT(*) FROM #L l WHERE l.Rev = 'Service' AND NOT EXISTS (SELECT 1 FROM #S s WHERE s.Seq = l.Seq)) > 1
        THROW 51000, 'Only one Service line can be for all services - pick the services of the others.', 1;
    IF EXISTS (SELECT 1 FROM #S GROUP BY ServiceId HAVING COUNT(*) > 1)
    BEGIN
        SET @msg = (SELECT TOP 1 N'The service ' + sm.ItemName + N' is in two Service lines - keep it in one.'
                      FROM #S s JOIN dbo.ServiceMaster sm ON sm.ServiceId = s.ServiceId GROUP BY sm.ItemName HAVING COUNT(*) > 1);
        THROW 51000, @msg, 1;
    END
    IF @ProfileId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfig WHERE ISNULL(ProfileId, CommissionConfigId) = @ProfileId AND CompanyId = @CompanyId)
        THROW 51000, 'The commission profile was not found.', 1;

    BEGIN TRANSACTION;
    -- a line id that is not of this profile is a new line
    UPDATE l SET Id = NULL FROM #L l
     WHERE l.Id IS NOT NULL AND (@ProfileId IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfig c
                                   WHERE c.CommissionConfigId = l.Id AND ISNULL(c.ProfileId, c.CommissionConfigId) = @ProfileId AND c.CompanyId = @CompanyId));

    -- removed lines go (their services cascade), as the existing Delete does
    IF @ProfileId IS NOT NULL
        DELETE c FROM dbo.DoctorCommissionConfig c
         WHERE ISNULL(c.ProfileId, c.CommissionConfigId) = @ProfileId AND c.CompanyId = @CompanyId
           AND c.CommissionConfigId NOT IN (SELECT Id FROM #L WHERE Id IS NOT NULL);

    UPDATE c SET BranchId = @BranchId, DoctorId = @DoctorId, SpecialityId = @SpecialityId, RevenueType = l.Rev, CalculationType = l.Calc,
                 CommissionBasis = ISNULL(NULLIF(l.Basis, ''), 'Net Collected'), DoctorShare = l.Share, ProcedureId = @ProcedureId, ServiceId = @ServiceId,
                 CorporateId = @CorporateId, InsuranceTPAId = @InsuranceTPAId, ApprovalRequired = @ApprovalRequired, EffectiveFrom = @EffectiveFrom,
                 EffectiveTo = @EffectiveTo, IsActive = @IsActive, ModifiedDate = GETDATE(), ModifiedBy = @UserId
      FROM dbo.DoctorCommissionConfig c JOIN #L l ON l.Id = c.CommissionConfigId;

    DECLARE @seq INT, @newId INT;
    DECLARE lc CURSOR LOCAL FAST_FORWARD FOR SELECT Seq FROM #L WHERE Id IS NULL ORDER BY Seq;
    OPEN lc; FETCH NEXT FROM lc INTO @seq;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT dbo.DoctorCommissionConfig (CompanyId, BranchId, DoctorId, SpecialityId, RevenueType, CalculationType, CommissionBasis, DoctorShare,
                                           ProcedureId, ServiceId, CorporateId, InsuranceTPAId, ApprovalRequired, EffectiveFrom, EffectiveTo, IsActive,
                                           CreatedDate, CreatedBy, ProfileId)
        SELECT @CompanyId, @BranchId, @DoctorId, @SpecialityId, l.Rev, l.Calc, ISNULL(NULLIF(l.Basis, ''), 'Net Collected'), l.Share,
               @ProcedureId, @ServiceId, @CorporateId, @InsuranceTPAId, @ApprovalRequired, @EffectiveFrom, @EffectiveTo, @IsActive,
               GETDATE(), @UserId, @ProfileId
          FROM #L l WHERE l.Seq = @seq;
        SET @newId = CAST(SCOPE_IDENTITY() AS INT);
        UPDATE #L SET Id = @newId WHERE Seq = @seq;
        IF @ProfileId IS NULL SET @ProfileId = @newId;      -- a new profile is known by its first line
        FETCH NEXT FROM lc INTO @seq;
    END
    CLOSE lc; DEALLOCATE lc;

    -- every line carries the profile (an old single rule becomes a profile of its own id)
    UPDATE c SET ProfileId = @ProfileId FROM dbo.DoctorCommissionConfig c JOIN #L l ON l.Id = c.CommissionConfigId
     WHERE ISNULL(c.ProfileId, -1) <> @ProfileId;

    -- the services of the Service lines (none = all services); other lines have none
    DELETE x FROM dbo.DoctorCommissionConfigService x JOIN #L l ON l.Id = x.CommissionConfigId
     WHERE NOT EXISTS (SELECT 1 FROM #S s WHERE s.Seq = l.Seq AND s.ServiceId = x.ServiceId);
    INSERT dbo.DoctorCommissionConfigService (CommissionConfigId, ServiceId)
    SELECT l.Id, s.ServiceId FROM #S s JOIN #L l ON l.Seq = s.Seq
     WHERE NOT EXISTS (SELECT 1 FROM dbo.DoctorCommissionConfigService x WHERE x.CommissionConfigId = l.Id AND x.ServiceId = s.ServiceId);
    COMMIT;

    SELECT @ProfileId AS ProfileId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_DoctorCommissionProfile_Delete
    @ProfileId INT,
    @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    DELETE dbo.DoctorCommissionConfig WHERE ISNULL(ProfileId, CommissionConfigId) = @ProfileId AND CompanyId = @CompanyId;
    SELECT @@ROWCOUNT AS Deleted;
END
GO

-- the new API endpoints (api/doctor-commission-profiles), catalogued like the configs controller's
DECLARE @a TABLE (M VARCHAR(10), A NVARCHAR(100), R NVARCHAR(200));
INSERT @a VALUES ('GET', N'GetList', N'api/doctor-commission-profiles'), ('GET', N'GetById', N'api/doctor-commission-profiles/{id}'),
                 ('POST', N'Save', N'api/doctor-commission-profiles'), ('DELETE', N'Delete', N'api/doctor-commission-profiles/{id}');
INSERT dbo.PageEndpointMap (Page_ID, Control_ID, App, Http_Method, Controller, Action, Route, IsActive, CreatedDate, Source, Discovered_On, Last_Seen_On, Is_Orphaned, Is_Public)
SELECT t.Page_ID, t.Control_ID, 'API', a.M, N'DoctorCommissionProfiles', a.A, a.R, t.IsActive, GETDATE(), t.Source, GETDATE(), GETDATE(), 0, t.Is_Public
  FROM @a a
 CROSS APPLY (SELECT TOP 1 * FROM dbo.PageEndpointMap WHERE App = 'API' AND Controller = N'DoctorCommissionConfigs' AND Action = N'GetList') t
 WHERE NOT EXISTS (SELECT 1 FROM dbo.PageEndpointMap x WHERE x.App = 'API' AND x.Controller = N'DoctorCommissionProfiles' AND x.Action = a.A AND x.Http_Method = a.M);
GO

PRINT 'Script 2518 applied: OPD Doctor Commission profiles (share table).';
GO
SET NOEXEC OFF;
GO
