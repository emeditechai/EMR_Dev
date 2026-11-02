-- ============================================================================================================
-- 2388  LAB > Phlebotomist Phones: the office approves or blocks the phones phlebotomists sign in from.
--   The app sends a random id it keeps in its own storage (X-Device-Id), so a reinstall or cleared app data is a
--   new phone. The first phone of a phlebotomist is approved by itself (PhleboSettings.AutoApproveFirstDevice);
--   every later one waits here. Approving can block the user's other phones, so one phone stays in use.
--   Blocked phones keep Status 'REVOKED', which usp_Phlebo_Guard already refuses. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- Phones of the phlebotomists who work in this branch, waiting ones first.
CREATE OR ALTER PROCEDURE dbo.usp_Lab_PhleboDevice_List
    @BranchId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.PhleboDeviceId, d.UserId, COALESCE(u.FullName, u.Username) AS UserName, u.Username, d.DeviceName, d.Platform, d.AppVersion,
           RIGHT(d.DeviceId, 8) AS DeviceTail, d.Status, d.CreatedDate, d.LastSeen, d.ApprovedDate,
           COALESCE(a.FullName, a.Username) AS ApprovedByName,
           (SELECT COUNT(*) FROM dbo.PhleboDevice o WHERE o.UserId = d.UserId AND o.Status = 'APPROVED' AND o.PhleboDeviceId <> d.PhleboDeviceId) AS OtherApproved
      FROM dbo.PhleboDevice d
      JOIN dbo.Users u ON u.Id = d.UserId
      LEFT JOIN dbo.Users a ON a.Id = d.ApprovedBy
     WHERE EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = d.UserId AND ub.BranchID = @BranchId AND ub.IsActive = 1)
     ORDER BY CASE d.Status WHEN 'PENDING' THEN 0 WHEN 'APPROVED' THEN 1 ELSE 2 END, d.LastSeen DESC;
END
GO

-- @Action APPROVE (a waiting or blocked phone) or BLOCK (a waiting or approved one).
CREATE OR ALTER PROCEDURE dbo.usp_Lab_PhleboDevice_Decide
    @PhleboDeviceId INT,
    @BranchId       INT,
    @UserId         INT,
    @Action         VARCHAR(10),
    @BlockOthers    BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Owner INT, @Status VARCHAR(10);
    SELECT @Owner = d.UserId, @Status = d.Status
      FROM dbo.PhleboDevice d WITH (UPDLOCK)
     WHERE d.PhleboDeviceId = @PhleboDeviceId
       AND EXISTS (SELECT 1 FROM dbo.UserBranches ub WHERE ub.UserId = d.UserId AND ub.BranchID = @BranchId AND ub.IsActive = 1);

    IF @Owner IS NULL BEGIN RAISERROR('This phone is not of a phlebotomist in your branch.', 16, 1); RETURN; END
    IF @Action NOT IN ('APPROVE', 'BLOCK') BEGIN RAISERROR('Choose approve or block.', 16, 1); RETURN; END
    IF @Action = 'APPROVE' AND @Status = 'APPROVED' BEGIN RAISERROR('This phone is already approved.', 16, 1); RETURN; END
    IF @Action = 'BLOCK' AND @Status = 'REVOKED' BEGIN RAISERROR('This phone is already blocked.', 16, 1); RETURN; END

    BEGIN TRANSACTION;
        IF @Action = 'APPROVE'
        BEGIN
            UPDATE dbo.PhleboDevice SET Status = 'APPROVED', ApprovedBy = @UserId, ApprovedDate = GETDATE() WHERE PhleboDeviceId = @PhleboDeviceId;
            IF @BlockOthers = 1
                UPDATE dbo.PhleboDevice SET Status = 'REVOKED' WHERE UserId = @Owner AND PhleboDeviceId <> @PhleboDeviceId AND Status <> 'REVOKED';
        END
        ELSE
            UPDATE dbo.PhleboDevice SET Status = 'REVOKED' WHERE PhleboDeviceId = @PhleboDeviceId;
    COMMIT;

    SELECT Status FROM dbo.PhleboDevice WHERE PhleboDeviceId = @PhleboDeviceId;
END
GO

-- ── page and endpoints ─────────────────────────────────────────────────────────────────────────────
DECLARE @co INT, @lab INT, @page INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @lab = NULL;
    SELECT @lab = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'LAB' AND CompanyId = @co;
    IF @lab IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @lab, @Page_Code = N'LAB.PHLEBODEVICES', @Title = N'Phlebotomist Phones',
             @Controller = N'LabPhleboDevices', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 37, @Icon = N'bi bi-phone me-2 text-primary',
             @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboDevices', @Action = N'Index',   @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'LabPhleboDevices', @Action = N'Devices', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabPhleboDevices', @Action = N'Approve', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = NULL, @App = 'WEB', @Http_Method = 'POST', @Controller = N'LabPhleboDevices', @Action = N'Block',   @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO
PRINT 'Script 2388 applied: LAB > Phlebotomist Phones.';
GO
