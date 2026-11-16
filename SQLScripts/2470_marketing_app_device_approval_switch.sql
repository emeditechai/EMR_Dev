-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2470  Marketing Executive App: phone approval can be switched off (and is off for now).
--   The app shares the phlebotomist phone approval (PhleboDevice): the first phone of a login is approved by itself and
--   any other phone waits for LAB > Phlebotomist Phones. MarketingSettings.RequireDeviceApproval (default 0 = off) decides
--   it for the marketing app only:
--     0 - a new phone is still registered (the office keeps seeing it, with LastSeen), but a PENDING phone is let in;
--         a phone the office REVOKED stays blocked.
--     1 - as before: a PENDING phone waits for approval.
--   The phlebotomist app is not affected. Turn approval back on per company:
--     UPDATE dbo.MarketingSettings SET RequireDeviceApproval = 1 WHERE CompanyId = <company>;
--   Needs 2446. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
IF COL_LENGTH('dbo.MarketingSettings', 'RequireDeviceApproval') IS NULL
    ALTER TABLE dbo.MarketingSettings ADD RequireDeviceApproval BIT NOT NULL CONSTRAINT DF_MarketingSettings_RequireDeviceApproval DEFAULT (0);
GO
IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.MarketingSettings')
             AND minor_id = COLUMNPROPERTY(OBJECT_ID('dbo.MarketingSettings'), 'RequireDeviceApproval', 'ColumnId') AND name = 'MS_Description')
    EXEC sys.sp_updateextendedproperty 'MS_Description', N'1 = a marketing executive''s second phone waits for approval (LAB > Phlebotomist Phones); 0 = any phone not revoked is let in.', 'SCHEMA', 'dbo', 'TABLE', 'MarketingSettings', 'COLUMN', 'RequireDeviceApproval';
ELSE
    EXEC sys.sp_addextendedproperty 'MS_Description', N'1 = a marketing executive''s second phone waits for approval (LAB > Phlebotomist Phones); 0 = any phone not revoked is let in.', 'SCHEMA', 'dbo', 'TABLE', 'MarketingSettings', 'COLUMN', 'RequireDeviceApproval';
GO

-- the marketing app's gate on every call (2446) with the switch
CREATE OR ALTER PROCEDURE dbo.usp_Mkt_Guard
    @UserId   INT,
    @DeviceId NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Code VARCHAR(20) = 'OK', @IsMkt BIT, @Exec INT, @Company INT, @Status VARCHAR(10), @Require BIT;
    SELECT @IsMkt = u.Is_MarketingExecutive & u.IsActive, @Company = u.CompanyId FROM dbo.Users u WHERE u.Id = @UserId;
    SELECT @Exec = e.ExecutiveId FROM dbo.MarketingExecutive e WHERE e.LoginUserId = @UserId AND e.IsActive = 1 AND e.IsDeleted = 0;
    SELECT @Status = Status FROM dbo.PhleboDevice WHERE UserId = @UserId AND DeviceId = @DeviceId;
    SELECT @Require = RequireDeviceApproval FROM dbo.MarketingSettings WHERE CompanyId = ISNULL(@Company, 1);   -- 2470

    IF ISNULL(@IsMkt, 0) = 0 SET @Code = 'NOT_MARKETING';
    ELSE IF @Exec IS NULL SET @Code = 'NO_EXECUTIVE';
    ELSE IF @Status IS NULL SET @Code = 'DEVICE_NEW';                                   -- the app registers it and asks again
    ELSE IF @Status = 'REVOKED' SET @Code = 'DEVICE_REVOKED';                           -- an office block always holds
    ELSE IF @Status = 'PENDING' AND ISNULL(@Require, 0) = 1 SET @Code = 'DEVICE_PENDING';

    IF @Status IS NOT NULL UPDATE dbo.PhleboDevice SET LastSeen = GETDATE() WHERE UserId = @UserId AND DeviceId = @DeviceId;
    SELECT @Code AS Code;
END
GO
PRINT 'Script 2470 applied: marketing app phone approval switch (MarketingSettings.RequireDeviceApproval, off by default).';
GO
