-- ============================================================================================================
-- 2389  User Master > Clinical & Status, for a phlebotomist:
--   1. Assigned Zones: a phlebotomist can cover several areas, also across branches and cities (UserPhleboArea).
--      Users.AssignedZoneId stays as the main area, so usp_Phlebo_Guard and older screens keep working.
--   2. Phones: the office approves or blocks the phones the user signs in from, on the user's own page. Same rules
--      as LAB > Phlebotomist Phones (2388), but scoped to the company, because User Master edits users of every
--      branch. Approving can block the user's other phones, so one phone stays in use.
-- Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID(N'dbo.UserPhleboArea', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.UserPhleboArea
    (
        UserId      INT      NOT NULL CONSTRAINT FK_UserPhleboArea_Users REFERENCES dbo.Users (Id),
        AreaId      INT      NOT NULL CONSTRAINT FK_UserPhleboArea_Area REFERENCES dbo.AreaMaster (AreaId),
        CreatedDate DATETIME NOT NULL CONSTRAINT DF_UserPhleboArea_CreatedDate DEFAULT (GETDATE()),
        CONSTRAINT PK_UserPhleboArea PRIMARY KEY (UserId, AreaId)
    );
END
GO

-- the main area of today's phlebotomists becomes their first assigned area
INSERT dbo.UserPhleboArea (UserId, AreaId)
SELECT u.Id, u.AssignedZoneId
  FROM dbo.Users u
 WHERE u.IsPhlebotomist = 1 AND u.AssignedZoneId IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.UserPhleboArea a WHERE a.UserId = u.Id AND a.AreaId = u.AssignedZoneId);
GO

-- description (picked up by the data dictionary)
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.UserPhleboArea') AND minor_id = 0 AND name = 'MS_Description')
    EXEC sys.sp_addextendedproperty @name = N'MS_Description',
         @value = N'Areas a phlebotomist covers, across branches. Users.AssignedZoneId is the main one of these.',
         @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'UserPhleboArea';
GO

-- Phones of one user, waiting ones first.
CREATE OR ALTER PROCEDURE dbo.usp_User_PhleboDevice_List
    @OwnerUserId INT,
    @CompanyId   INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.PhleboDeviceId, d.DeviceName, d.Platform, d.AppVersion, RIGHT(d.DeviceId, 8) AS DeviceTail, d.Status,
           d.CreatedDate, d.LastSeen, d.ApprovedDate, COALESCE(a.FullName, a.Username) AS ApprovedByName
      FROM dbo.PhleboDevice d
      JOIN dbo.Users u ON u.Id = d.UserId AND ISNULL(u.CompanyId, 1) = @CompanyId
      LEFT JOIN dbo.Users a ON a.Id = d.ApprovedBy
     WHERE d.UserId = @OwnerUserId
     ORDER BY CASE d.Status WHEN 'PENDING' THEN 0 WHEN 'APPROVED' THEN 1 ELSE 2 END, d.LastSeen DESC;
END
GO

-- @Action APPROVE (a waiting or blocked phone) or BLOCK (a waiting or approved one).
CREATE OR ALTER PROCEDURE dbo.usp_User_PhleboDevice_Decide
    @PhleboDeviceId INT,
    @OwnerUserId    INT,
    @CompanyId      INT,
    @UserId         INT,
    @Action         VARCHAR(10),
    @BlockOthers    BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status VARCHAR(10);
    SELECT @Status = d.Status
      FROM dbo.PhleboDevice d WITH (UPDLOCK)
      JOIN dbo.Users u ON u.Id = d.UserId AND ISNULL(u.CompanyId, 1) = @CompanyId
     WHERE d.PhleboDeviceId = @PhleboDeviceId AND d.UserId = @OwnerUserId;

    IF @Status IS NULL BEGIN RAISERROR('This phone is not of this user.', 16, 1); RETURN; END
    IF @Action NOT IN ('APPROVE', 'BLOCK') BEGIN RAISERROR('Choose approve or block.', 16, 1); RETURN; END
    IF @Action = 'APPROVE' AND @Status = 'APPROVED' BEGIN RAISERROR('This phone is already approved.', 16, 1); RETURN; END
    IF @Action = 'BLOCK' AND @Status = 'REVOKED' BEGIN RAISERROR('This phone is already blocked.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        IF @Action = 'APPROVE'
        BEGIN
            UPDATE dbo.PhleboDevice SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE() WHERE PhleboDeviceId = @PhleboDeviceId;
            IF @BlockOthers = 1
                UPDATE dbo.PhleboDevice SET Status = 'REVOKED' WHERE UserId = @OwnerUserId AND PhleboDeviceId <> @PhleboDeviceId AND Status <> 'REVOKED';
        END
        ELSE
            UPDATE dbo.PhleboDevice SET Status = 'REVOKED' WHERE PhleboDeviceId = @PhleboDeviceId;
    COMMIT;

    SELECT Status FROM dbo.PhleboDevice WHERE PhleboDeviceId = @PhleboDeviceId;
END
GO

-- User Master endpoints for the phones
DECLARE @page INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'SETTINGS.USERS';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'Users', @Action = N'PhleboDevices', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'Users', @Action = N'PhleboDeviceDecide', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
PRINT 'Script 2389 applied: phlebotomist areas and phones in User Master.';
GO
