-- ============================================================================================================
-- Migration: 2299_campaigns.sql
-- Utility > Campaigns: bulk or individual emails to Patients, Users (staff) or Doctors, written in the email designer
-- or from a saved campaign template, sent now or at a scheduled time by a background sender (Email for now; the
-- Channel column is there for WhatsApp later). Patients can unsubscribe from campaign emails (CampaignOptOut).
-- Data goes EMR.Web -> EMR.Api (api/campaigns) -> the stored procedures below; the sender (EMR.Web) sends each email
-- with the mail settings of the campaign's "send from" branch. Adds the tables, the procedures, the Utility > Campaigns
-- page and its calls. No role grants change. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.CampaignTemplate', N'U') IS NULL
CREATE TABLE dbo.CampaignTemplate
(
    TemplateId    INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CampaignTemplate PRIMARY KEY,
    CompanyId     INT           NOT NULL,
    Name          NVARCHAR(150) NOT NULL,
    AudienceType  CHAR(1)       NOT NULL CONSTRAINT CK_CampaignTemplate_Audience CHECK (AudienceType IN ('P', 'U', 'D')),  -- Patient, User, Doctor
    Subject       NVARCHAR(255) NOT NULL,
    DesignJson    NVARCHAR(MAX) NOT NULL,
    IsActive      BIT           NOT NULL CONSTRAINT DF_CampaignTemplate_IsActive DEFAULT (1),
    CreatedBy     INT NULL,
    CreatedDate   DATETIME      NOT NULL CONSTRAINT DF_CampaignTemplate_CreatedDate DEFAULT (GETDATE()),
    ModifiedBy    INT NULL,
    ModifiedDate  DATETIME NULL
);
GO

IF OBJECT_ID(N'dbo.Campaign', N'U') IS NULL
CREATE TABLE dbo.Campaign
(
    CampaignId     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_Campaign PRIMARY KEY,
    CompanyId      INT           NOT NULL,
    BranchId       INT           NOT NULL,                 -- its mail settings are used
    Name           NVARCHAR(150) NOT NULL,
    AudienceType   CHAR(1)       NOT NULL CONSTRAINT CK_Campaign_Audience CHECK (AudienceType IN ('P', 'U', 'D')),
    Channel        VARCHAR(10)   NOT NULL CONSTRAINT DF_Campaign_Channel DEFAULT ('EMAIL'),
    TemplateId     INT NULL,
    Subject        NVARCHAR(255) NOT NULL,
    DesignJson     NVARCHAR(MAX) NOT NULL,
    HtmlBody       NVARCHAR(MAX) NOT NULL,                 -- built from the design when the campaign is sent
    SelectionMode  VARCHAR(10)   NOT NULL,                 -- ALL, FILTER, PICK
    FilterJson     NVARCHAR(MAX) NULL,
    BaseUrl        NVARCHAR(300) NULL,                     -- for the patients' unsubscribe link
    Status         VARCHAR(12)   NOT NULL CONSTRAINT CK_Campaign_Status CHECK (Status IN ('DRAFT', 'SCHEDULED', 'SENDING', 'COMPLETED', 'CANCELLED')),
    ScheduledAt    DATETIME NULL,
    StartedAt      DATETIME NULL,
    CompletedAt    DATETIME NULL,
    CreatedBy      INT NULL,
    CreatedDate    DATETIME      NOT NULL CONSTRAINT DF_Campaign_CreatedDate DEFAULT (GETDATE()),
    ModifiedBy     INT NULL,
    ModifiedDate   DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Campaign_Status' AND object_id = OBJECT_ID(N'dbo.Campaign'))
    CREATE INDEX IX_Campaign_Status ON dbo.Campaign (Status, ScheduledAt);
GO

IF OBJECT_ID(N'dbo.CampaignRecipient', N'U') IS NULL
CREATE TABLE dbo.CampaignRecipient
(
    RecipientId    BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CampaignRecipient PRIMARY KEY,
    CampaignId     INT           NOT NULL CONSTRAINT FK_CampaignRecipient_Campaign REFERENCES dbo.Campaign (CampaignId),
    RefId          INT           NOT NULL,                 -- PatientId / Users.Id / DoctorId
    Name           NVARCHAR(200) NULL,
    Email          NVARCHAR(256) NULL,
    FieldsJson     NVARCHAR(MAX) NULL,                     -- the merge field values of this person
    Status         CHAR(1)       NOT NULL CONSTRAINT DF_CampaignRecipient_Status DEFAULT ('P'),  -- P pending, S sent, F failed, X skipped
    Message        NVARCHAR(500) NULL,
    Attempts       INT           NOT NULL CONSTRAINT DF_CampaignRecipient_Attempts DEFAULT (0),
    SentAt         DATETIME NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_CampaignRecipient_Campaign' AND object_id = OBJECT_ID(N'dbo.CampaignRecipient'))
    CREATE INDEX IX_CampaignRecipient_Campaign ON dbo.CampaignRecipient (CampaignId, Status);
GO

IF OBJECT_ID(N'dbo.CampaignOptOut', N'U') IS NULL
CREATE TABLE dbo.CampaignOptOut
(
    OptOutId     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_CampaignOptOut PRIMARY KEY,
    CompanyId    INT           NOT NULL,
    Email        NVARCHAR(256) NOT NULL,
    CampaignId   INT NULL,
    OptedOutAt   DATETIME      NOT NULL CONSTRAINT DF_CampaignOptOut_At DEFAULT (GETDATE())
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_CampaignOptOut_Email' AND object_id = OBJECT_ID(N'dbo.CampaignOptOut'))
    CREATE UNIQUE INDEX UX_CampaignOptOut_Email ON dbo.CampaignOptOut (CompanyId, Email);
GO

-- ════════════════════════════════════ stored procedures (EMR.Api api/campaigns) ════════════════════════════════════

-- campaigns of the branch (all branches for Head Office) with their counts; RS2 the campaign templates
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_List @CompanyId INT, @BranchId INT, @AllBranches BIT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 300 c.CampaignId, c.Name, c.AudienceType, c.Channel, c.Status, c.Subject, c.CreatedDate, c.ScheduledAt, c.StartedAt, c.CompletedAt,
           c.BranchId, b.BranchName, COALESCE(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
           ISNULL(r.Total, 0) AS Total, ISNULL(r.Sent, 0) AS Sent, ISNULL(r.Failed, 0) AS Failed, ISNULL(r.Skipped, 0) AS Skipped, ISNULL(r.Pending, 0) AS Pending
      FROM dbo.Campaign c
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
      LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
     OUTER APPLY (SELECT COUNT(*) AS Total, SUM(CASE WHEN x.Status = 'S' THEN 1 ELSE 0 END) AS Sent, SUM(CASE WHEN x.Status = 'F' THEN 1 ELSE 0 END) AS Failed,
                         SUM(CASE WHEN x.Status = 'X' THEN 1 ELSE 0 END) AS Skipped, SUM(CASE WHEN x.Status = 'P' THEN 1 ELSE 0 END) AS Pending
                    FROM dbo.CampaignRecipient x WHERE x.CampaignId = c.CampaignId) r
     WHERE c.CompanyId = @CompanyId AND (@AllBranches = 1 OR c.BranchId = @BranchId)
     ORDER BY c.CampaignId DESC;

    SELECT t.TemplateId, t.Name, t.AudienceType, t.Subject, t.IsActive, t.CreatedDate, t.ModifiedDate,
           (SELECT COUNT(*) FROM dbo.Campaign c WHERE c.TemplateId = t.TemplateId) AS Used
      FROM dbo.CampaignTemplate t WHERE t.CompanyId = @CompanyId ORDER BY t.Name;
END
GO

-- one campaign (with its design, filter and counts) and the hospital name of its sending branch
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_Get @CampaignId INT, @CompanyId INT, @BranchId INT, @AllBranches BIT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CampaignId, c.Name, c.AudienceType, c.Channel, c.Status, c.Subject, c.DesignJson, c.HtmlBody, c.SelectionMode, c.FilterJson, c.TemplateId,
           c.CreatedDate, c.ScheduledAt, c.StartedAt, c.CompletedAt, c.BranchId, b.BranchName, COALESCE(NULLIF(u.FullName, ''), u.Username) AS CreatedByName,
           (SELECT TOP 1 h.HotelName FROM dbo.HospitalSettings h WHERE h.BranchId = c.BranchId) AS HospitalName,
           (SELECT TOP 1 s.SenderEmail FROM dbo.SmtpEmailConfiguration s WHERE s.BranchId = c.BranchId AND s.IsActive = 1 ORDER BY s.IsDefault DESC, s.Id) AS SenderEmail,
           ISNULL(r.Total, 0) AS Total, ISNULL(r.Sent, 0) AS Sent, ISNULL(r.Failed, 0) AS Failed, ISNULL(r.Skipped, 0) AS Skipped, ISNULL(r.Pending, 0) AS Pending
      FROM dbo.Campaign c
      LEFT JOIN dbo.Branchmaster b ON b.BranchID = c.BranchId
      LEFT JOIN dbo.Users u ON u.Id = c.CreatedBy
     OUTER APPLY (SELECT COUNT(*) AS Total, SUM(CASE WHEN x.Status = 'S' THEN 1 ELSE 0 END) AS Sent, SUM(CASE WHEN x.Status = 'F' THEN 1 ELSE 0 END) AS Failed,
                         SUM(CASE WHEN x.Status = 'X' THEN 1 ELSE 0 END) AS Skipped, SUM(CASE WHEN x.Status = 'P' THEN 1 ELSE 0 END) AS Pending
                    FROM dbo.CampaignRecipient x WHERE x.CampaignId = c.CampaignId) r
     WHERE c.CampaignId = @CampaignId AND c.CompanyId = @CompanyId AND (@AllBranches = 1 OR c.BranchId = @BranchId);
END
GO

-- the people an audience selection covers. @AudienceType P / U / D; @Mode ALL / FILTER / PICK (@Ids)
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_AudienceList
    @CompanyId INT, @AudienceType CHAR(1), @Mode VARCHAR(10), @Ids NVARCHAR(MAX) = NULL,
    @BranchId INT = NULL, @Gender NVARCHAR(10) = NULL, @AgeFrom INT = NULL, @AgeTo INT = NULL,
    @VisitFrom DATE = NULL, @VisitTo DATE = NULL, @RegisteredFrom DATE = NULL, @RegisteredTo DATE = NULL,
    @RoleId INT = NULL, @SpecialityId INT = NULL, @DoctorKind CHAR(1) = NULL, @Search NVARCHAR(100) = NULL, @Top INT = 100000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pick BIT = CASE WHEN @Mode = 'PICK' THEN 1 ELSE 0 END, @flt BIT = CASE WHEN @Mode = 'FILTER' THEN 1 ELSE 0 END;
    DECLARE @pickIds TABLE (Id INT PRIMARY KEY);
    IF @pick = 1 INSERT @pickIds SELECT DISTINCT TRY_CAST(value AS INT) FROM STRING_SPLIT(ISNULL(@Ids, ''), ',') WHERE TRY_CAST(value AS INT) IS NOT NULL;
    DECLARE @vTo DATE = DATEADD(DAY, 1, @VisitTo), @rTo DATE = DATEADD(DAY, 1, @RegisteredTo);

    IF @AudienceType = 'P'
        SELECT TOP (@Top) p.PatientId AS RefId,
               LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(p.Salutation)), '') + ' ', p.FirstName, ' ' + NULLIF(LTRIM(RTRIM(p.LastName)), '')))) AS Name,
               p.FirstName, p.EmailId AS Email, p.PatientCode AS Code, p.PhoneNumber AS Phone, CAST(NULL AS NVARCHAR(200)) AS Extra,
               CAST(CASE WHEN o.OptOutId IS NULL THEN 0 ELSE 1 END AS BIT) AS OptedOut
          FROM dbo.PatientMaster p
          LEFT JOIN dbo.CampaignOptOut o ON o.CompanyId = @CompanyId AND o.Email = LTRIM(RTRIM(p.EmailId))
         WHERE p.CompanyId = @CompanyId AND ISNULL(p.IsActive, 1) = 1
           AND (@pick = 0 OR p.PatientId IN (SELECT Id FROM @pickIds))
           AND (@flt = 0 OR (
                    (@BranchId IS NULL OR p.BranchId = @BranchId)
                AND (@Gender IS NULL OR p.Gender = @Gender)
                AND (@AgeFrom IS NULL OR (p.DateOfBirth IS NOT NULL AND DATEDIFF(DAY, p.DateOfBirth, GETDATE()) / 365.25 >= @AgeFrom))
                AND (@AgeTo IS NULL OR (p.DateOfBirth IS NOT NULL AND DATEDIFF(DAY, p.DateOfBirth, GETDATE()) / 365.25 < @AgeTo + 1))
                AND (@RegisteredFrom IS NULL OR p.CreatedDate >= @RegisteredFrom) AND (@rTo IS NULL OR p.CreatedDate < @rTo)
                AND (@VisitFrom IS NULL AND @VisitTo IS NULL
                     OR EXISTS (SELECT 1 FROM dbo.LabOrder lo WHERE lo.PatientId = p.PatientId AND ISNULL(lo.IsActive, 1) = 1
                                   AND (@VisitFrom IS NULL OR lo.OrderDate >= @VisitFrom) AND (@vTo IS NULL OR lo.OrderDate < @vTo))
                     OR EXISTS (SELECT 1 FROM dbo.PatientOPDService v WHERE v.PatientId = p.PatientId AND ISNULL(v.IsActive, 1) = 1
                                   AND (@VisitFrom IS NULL OR v.VisitDate >= @VisitFrom) AND (@vTo IS NULL OR v.VisitDate < @vTo)))))
           AND (@Search IS NULL OR p.FirstName + ' ' + ISNULL(p.LastName, '') LIKE '%' + @Search + '%' OR p.PatientCode LIKE '%' + @Search + '%'
                OR p.PhoneNumber LIKE '%' + @Search + '%' OR p.EmailId LIKE '%' + @Search + '%')
         ORDER BY p.FirstName, p.LastName, p.PatientId;
    ELSE IF @AudienceType = 'U'
        SELECT TOP (@Top) u.Id AS RefId,
               COALESCE(NULLIF(u.FullName, ''), NULLIF(LTRIM(RTRIM(CONCAT(u.FirstName, ' ', u.LastName))), ''), u.Username) AS Name,
               COALESCE(NULLIF(u.FirstName, ''), NULLIF(u.FullName, ''), u.Username) AS FirstName,
               u.Email, u.Username AS Code, COALESCE(u.PhoneNumber, u.Phone) AS Phone, CAST(NULL AS NVARCHAR(200)) AS Extra, CAST(0 AS BIT) AS OptedOut
          FROM dbo.Users u
         WHERE ISNULL(u.CompanyId, 1) = @CompanyId AND u.IsActive = 1 AND ISNULL(u.IsLockedOut, 0) = 0
           AND (@pick = 0 OR u.Id IN (SELECT Id FROM @pickIds))
           AND (@flt = 0 OR (
                    (@BranchId IS NULL OR EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = u.Id AND ub.BranchID = @BranchId AND ub.IsActive = 1))
                AND (@RoleId IS NULL OR EXISTS (SELECT 1 FROM dbo.Userroles ur WHERE ur.UserId = u.Id AND ur.RoleId = @RoleId AND ur.IsActive = 1))))
           AND (@Search IS NULL OR u.Username LIKE '%' + @Search + '%' OR u.FullName LIKE '%' + @Search + '%' OR u.Email LIKE '%' + @Search + '%')
         ORDER BY Name, u.Id;
    ELSE
        SELECT TOP (@Top) d.DoctorId AS RefId,
               LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(d.NamePrefix)), '') + ' ', d.FullName))) AS Name,
               d.FullName AS FirstName, d.EmailId AS Email, d.MedicalLicenseNo AS Code, d.PhoneNumber AS Phone, s.SpecialityName AS Extra, CAST(0 AS BIT) AS OptedOut
          FROM dbo.DoctorMaster d
          LEFT JOIN dbo.DoctorSpecialityMaster s ON s.SpecialityId = d.PrimarySpecialityId
         WHERE ISNULL(d.CompanyId, 1) = @CompanyId AND d.IsActive = 1
           AND (@pick = 0 OR d.DoctorId IN (SELECT Id FROM @pickIds))
           AND (@flt = 0 OR (
                    (@SpecialityId IS NULL OR d.PrimarySpecialityId = @SpecialityId OR d.SecondarySpecialityId = @SpecialityId)
                AND (@DoctorKind IS NULL OR (@DoctorKind = 'R' AND ISNULL(d.IsReferralDoctor, 0) = 1) OR (@DoctorKind = 'C' AND ISNULL(d.IsReferralDoctor, 0) = 0))))
           AND (@Search IS NULL OR d.FullName LIKE '%' + @Search + '%' OR d.EmailId LIKE '%' + @Search + '%' OR d.PhoneNumber LIKE '%' + @Search + '%')
         ORDER BY d.FullName, d.DoctorId;
END
GO

-- the lists of the wizard: branches (with the mail account each one sends from), roles, specialities
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_Options @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.BranchID AS Id, b.BranchName AS Name, CAST(ISNULL(b.IsHOBranch, 0) AS BIT) AS IsHo,
           (SELECT TOP 1 s.SenderEmail FROM dbo.SmtpEmailConfiguration s WHERE s.BranchId = b.BranchID AND s.IsActive = 1 ORDER BY s.IsDefault DESC, s.Id) AS SenderEmail,
           (SELECT TOP 1 h.HotelName FROM dbo.HospitalSettings h WHERE h.BranchId = b.BranchID) AS HospitalName
      FROM dbo.Branchmaster b WHERE b.CompanyId = @CompanyId AND b.IsActive = 1 ORDER BY b.IsHOBranch DESC, b.BranchName;
    SELECT Id, Name FROM dbo.roles WHERE ISNULL(CompanyId, @CompanyId) = @CompanyId ORDER BY Name;
    SELECT SpecialityId AS Id, SpecialityName AS Name FROM dbo.DoctorSpecialityMaster
     WHERE ISNULL(IsActive, 1) = 1 AND ISNULL(CompanyId, @CompanyId) = @CompanyId ORDER BY SpecialityName;
END
GO

-- saves a campaign (new or a draft); with recipients (JSON) the list is fixed and sending can start
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_Save
    @CampaignId INT, @CompanyId INT, @BranchId INT, @Name NVARCHAR(150), @AudienceType CHAR(1), @TemplateId INT = NULL,
    @Subject NVARCHAR(255), @DesignJson NVARCHAR(MAX), @HtmlBody NVARCHAR(MAX), @SelectionMode VARCHAR(10), @FilterJson NVARCHAR(MAX) = NULL,
    @BaseUrl NVARCHAR(300) = NULL, @Status VARCHAR(12), @ScheduledAt DATETIME = NULL, @UserId INT, @RecipientsJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @Status NOT IN ('DRAFT', 'SCHEDULED', 'SENDING') THROW 51001, 'Unknown campaign status.', 1;
    BEGIN TRAN;
    IF @CampaignId > 0
    BEGIN
        UPDATE dbo.Campaign
           SET BranchId = @BranchId, Name = @Name, AudienceType = @AudienceType, TemplateId = @TemplateId, Subject = @Subject, DesignJson = @DesignJson,
               HtmlBody = @HtmlBody, SelectionMode = @SelectionMode, FilterJson = @FilterJson, BaseUrl = @BaseUrl, Status = @Status,
               ScheduledAt = @ScheduledAt, StartedAt = CASE WHEN @Status = 'SENDING' THEN GETDATE() END, ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE CampaignId = @CampaignId AND CompanyId = @CompanyId AND Status = 'DRAFT';
        IF @@ROWCOUNT = 0 THROW 51002, 'This campaign is no longer a draft.', 1;
    END
    ELSE
    BEGIN
        INSERT dbo.Campaign (CompanyId, BranchId, Name, AudienceType, Channel, TemplateId, Subject, DesignJson, HtmlBody, SelectionMode, FilterJson,
                             BaseUrl, Status, ScheduledAt, StartedAt, CreatedBy)
        VALUES (@CompanyId, @BranchId, @Name, @AudienceType, 'EMAIL', @TemplateId, @Subject, @DesignJson, @HtmlBody, @SelectionMode, @FilterJson,
                @BaseUrl, @Status, @ScheduledAt, CASE WHEN @Status = 'SENDING' THEN GETDATE() END, @UserId);
        SET @CampaignId = CAST(SCOPE_IDENTITY() AS INT);
    END
    IF @RecipientsJson IS NOT NULL
        INSERT dbo.CampaignRecipient (CampaignId, RefId, Name, Email, FieldsJson, Status, Message)
        SELECT @CampaignId, j.RefId, j.Name, j.Email, j.FieldsJson, j.Status, j.Message
          FROM OPENJSON(@RecipientsJson) WITH (RefId INT '$.refId', Name NVARCHAR(200) '$.name', Email NVARCHAR(256) '$.email',
                                               FieldsJson NVARCHAR(MAX) '$.fieldsJson', Status CHAR(1) '$.status', Message NVARCHAR(500) '$.message') j;
    COMMIT;
    SELECT @CampaignId AS CampaignId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Campaign_Recipients @CampaignId INT, @CompanyId INT, @Status CHAR(1) = NULL, @Search NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 2000 r.Name, r.Email, r.Status, r.Message, r.SentAt, r.Attempts
      FROM dbo.CampaignRecipient r JOIN dbo.Campaign c ON c.CampaignId = r.CampaignId
     WHERE r.CampaignId = @CampaignId AND c.CompanyId = @CompanyId AND (@Status IS NULL OR r.Status = @Status)
       AND (@Search IS NULL OR r.Name LIKE '%' + @Search + '%' OR r.Email LIKE '%' + @Search + '%')
     ORDER BY CASE r.Status WHEN 'F' THEN 0 WHEN 'P' THEN 1 WHEN 'S' THEN 2 ELSE 3 END, r.Name;
END
GO

-- Cancel (scheduled / sending: what has not gone out yet is skipped), RETRY (failed ones go again), DELETE (drafts only)
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_Action @CampaignId INT, @CompanyId INT, @Action VARCHAR(10), @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT = 0;
    IF @Action = 'CANCEL'
    BEGIN
        UPDATE dbo.Campaign SET Status = 'CANCELLED', CompletedAt = GETDATE(), ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE CampaignId = @CampaignId AND CompanyId = @CompanyId AND Status IN ('SCHEDULED', 'SENDING');
        SET @n = @@ROWCOUNT;
        IF @n > 0 UPDATE dbo.CampaignRecipient SET Status = 'X', Message = N'Campaign cancelled' WHERE CampaignId = @CampaignId AND Status = 'P';
    END
    ELSE IF @Action = 'RETRY'
    BEGIN
        UPDATE r SET Status = 'P', Message = NULL
          FROM dbo.CampaignRecipient r JOIN dbo.Campaign c ON c.CampaignId = r.CampaignId
         WHERE r.CampaignId = @CampaignId AND c.CompanyId = @CompanyId AND r.Status = 'F' AND c.Status IN ('COMPLETED', 'SENDING');
        SET @n = @@ROWCOUNT;
        IF @n > 0 UPDATE dbo.Campaign SET Status = 'SENDING', CompletedAt = NULL WHERE CampaignId = @CampaignId AND Status = 'COMPLETED';
    END
    ELSE IF @Action = 'DELETE'
    BEGIN
        DELETE FROM dbo.Campaign WHERE CampaignId = @CampaignId AND CompanyId = @CompanyId AND Status = 'DRAFT';
        SET @n = @@ROWCOUNT;
    END
    SELECT @n AS Affected;
END
GO

-- ── campaign templates ──
CREATE OR ALTER PROCEDURE dbo.usp_CampaignTemplate_Get @TemplateId INT, @CompanyId INT
AS
    SELECT TemplateId, Name, AudienceType, Subject, DesignJson, IsActive FROM dbo.CampaignTemplate WHERE TemplateId = @TemplateId AND CompanyId = @CompanyId;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CampaignTemplate_List @CompanyId INT, @AudienceType CHAR(1)
AS
    SELECT TemplateId, Name, Subject FROM dbo.CampaignTemplate WHERE CompanyId = @CompanyId AND AudienceType = @AudienceType AND IsActive = 1 ORDER BY Name;
GO
CREATE OR ALTER PROCEDURE dbo.usp_CampaignTemplate_Save
    @TemplateId INT, @CompanyId INT, @Name NVARCHAR(150), @AudienceType CHAR(1), @Subject NVARCHAR(255), @DesignJson NVARCHAR(MAX), @IsActive BIT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.CampaignTemplate WHERE CompanyId = @CompanyId AND Name = @Name AND TemplateId <> @TemplateId)
        THROW 51011, 'Another template already has this name.', 1;
    IF @TemplateId > 0
        UPDATE dbo.CampaignTemplate SET Name = @Name, AudienceType = @AudienceType, Subject = @Subject, DesignJson = @DesignJson, IsActive = @IsActive,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
         WHERE TemplateId = @TemplateId AND CompanyId = @CompanyId;
    ELSE
    BEGIN
        INSERT dbo.CampaignTemplate (CompanyId, Name, AudienceType, Subject, DesignJson, IsActive, CreatedBy)
        VALUES (@CompanyId, @Name, @AudienceType, @Subject, @DesignJson, @IsActive, @UserId);
        SET @TemplateId = CAST(SCOPE_IDENTITY() AS INT);
    END
    SELECT @TemplateId AS TemplateId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_CampaignTemplate_Delete @TemplateId INT, @CompanyId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Campaign SET TemplateId = NULL WHERE TemplateId = @TemplateId AND CompanyId = @CompanyId;
    DELETE FROM dbo.CampaignTemplate WHERE TemplateId = @TemplateId AND CompanyId = @CompanyId;
    SELECT @@ROWCOUNT AS Affected;
END
GO

-- ── the sender (EMR.Web background service) ──
-- scheduled campaigns whose time has come start; returns the running ones with what is needed to send
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_SenderRunning
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Campaign SET Status = 'SENDING', StartedAt = ISNULL(StartedAt, GETDATE()) WHERE Status = 'SCHEDULED' AND ScheduledAt <= GETDATE();
    SELECT c.CampaignId, c.CompanyId, c.BranchId, c.AudienceType, c.Subject, c.HtmlBody, c.BaseUrl,
           ISNULL((SELECT TOP 1 h.HotelName FROM dbo.HospitalSettings h WHERE h.BranchId = c.BranchId), N'') AS HospitalName
      FROM dbo.Campaign c WHERE c.Status = 'SENDING' ORDER BY c.StartedAt;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_SenderNext @CampaignId INT, @Batch INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Batch) r.RecipientId, r.Email, r.FieldsJson
      FROM dbo.CampaignRecipient r JOIN dbo.Campaign c ON c.CampaignId = r.CampaignId
     WHERE r.CampaignId = @CampaignId AND r.Status = 'P' AND c.Status = 'SENDING'
     ORDER BY r.RecipientId;
END
GO
-- one recipient's result; returns whether the campaign is still sending (it may have been cancelled meanwhile)
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_SenderMark @RecipientId BIGINT, @Status CHAR(1), @Message NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.CampaignRecipient
       SET Status = @Status, Message = @Message, Attempts = Attempts + 1, SentAt = CASE WHEN @Status = 'S' THEN GETDATE() ELSE SentAt END
     WHERE RecipientId = @RecipientId AND Status = 'P';
    SELECT CAST(CASE WHEN c.Status = 'SENDING' THEN 1 ELSE 0 END AS BIT)
      FROM dbo.CampaignRecipient r JOIN dbo.Campaign c ON c.CampaignId = r.CampaignId WHERE r.RecipientId = @RecipientId;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_SenderFinish @CampaignId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Campaign SET Status = 'COMPLETED', CompletedAt = GETDATE()
     WHERE CampaignId = @CampaignId AND Status = 'SENDING'
       AND NOT EXISTS (SELECT 1 FROM dbo.CampaignRecipient WHERE CampaignId = @CampaignId AND Status = 'P');
END
GO

-- a patient unsubscribes from campaign emails (the link in the email)
CREATE OR ALTER PROCEDURE dbo.usp_Campaign_OptOut @CompanyId INT, @Email NVARCHAR(256), @CampaignId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.CampaignOptOut WHERE CompanyId = @CompanyId AND Email = LTRIM(RTRIM(@Email)))
        INSERT dbo.CampaignOptOut (CompanyId, Email, CampaignId) VALUES (@CompanyId, LTRIM(RTRIM(@Email)), @CampaignId);
END
GO

-- ── Utility > Campaigns ──
DECLARE @co INT, @menu INT, @page INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT CompanyId FROM dbo.MenuMaster WHERE Menu_Code = N'UTILITY';
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = (SELECT TOP 1 Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = N'UTILITY' AND CompanyId = @co);
    SET @page = NULL;
    EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'UTILITY.CAMPAIGNS', @Title = N'Campaigns',
         @Controller = N'Campaign', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 35, @Icon = N'bi bi-megaphone me-2',
         @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
    SELECT @page = Page_ID FROM dbo.PageMaster WHERE Page_Code = N'UTILITY.CAMPAIGNS' AND Menu_ID = @menu;

    DECLARE @a TABLE (Method VARCHAR(6), Action NVARCHAR(60));
    DELETE @a;
    INSERT @a VALUES ('GET', N'Index'), ('GET', N'Create'), ('GET', N'Details'), ('GET', N'Progress'), ('GET', N'Recipients'),
                     ('GET', N'AudienceOptions'), ('POST', N'AudienceCount'), ('GET', N'AudienceSearch'), ('POST', N'Preview'),
                     ('POST', N'SendTest'), ('POST', N'Save'), ('POST', N'Cancel'), ('POST', N'RetryFailed'), ('POST', N'Delete'),
                     ('GET', N'TemplateEdit'), ('POST', N'TemplateEdit'), ('POST', N'TemplateDelete'), ('GET', N'TemplateGet'), ('GET', N'TemplateList');
    DECLARE @m VARCHAR(6), @act NVARCHAR(60);
    DECLARE ac CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action FROM @a;
    OPEN ac; FETCH NEXT FROM ac INTO @m, @act;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = @m,
             @Controller = N'Campaign', @Action = @act, @Source = 'SEED';
        FETCH NEXT FROM ac INTO @m, @act;
    END
    CLOSE ac; DEALLOCATE ac;
    -- EMR.Api api/campaigns (called by the page)
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'List',        @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'Get',         @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'Campaigns', @Action = N'Audience',    @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'Options',     @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'AudienceSearch', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'Campaigns', @Action = N'Save',        @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'Recipients',  @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'Campaigns', @Action = N'Action',      @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'TemplateGet', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'GET',  @Controller = N'Campaigns', @Action = N'TemplateList',@Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'Campaigns', @Action = N'TemplateSave',@Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'API', @Http_Method = 'POST', @Controller = N'Campaigns', @Action = N'TemplateDelete', @Source = 'SEED';
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
PRINT 'Script 2299 applied: Utility > Campaigns.';
GO
