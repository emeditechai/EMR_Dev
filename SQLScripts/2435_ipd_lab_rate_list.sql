-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
-- 2435  IPD Phase 4 (LAB integration), step 1: IPD LAB Rate List, branch-wise
--   Master > IPD Master > IPD LAB Rate List (page MASTER.IPD_LABRATELIST, controller LabRateListIpd): the LAB rates of
--   tests, profiles and packages for admitted patients. Same tables, API and procedures as Rate List (B2C), with
--   Rate_Type = 'IPD' in LabRateCardMaster.
--   usp_Api_LabRateCardMaster_Save: an IPD list must have a branch, one list of a branch in force on any date
--   (no overlapping dates), every rate above zero.
--   fn_Ipd_LabRate: rate of a LAB item for an admitted patient (IPD LAB orders charge from it).
-- Needs 2011 / 2015 (LAB rate cards) and 2434. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════════════
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ── 1. save rules for IPD rate lists (added to the existing procedure) ──────────────────────────────────────
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_Api_LabRateCardMaster_Save'));
IF @def NOT LIKE '%IPD LAB rate list%'
BEGIN
    DECLARE @anchor NVARCHAR(200) = N'IF @RateCard_ID IS NULL OR @RateCard_ID = 0';
    IF CHARINDEX(@anchor, @def) = 0 THROW 51300, 'usp_Api_LabRateCardMaster_Save has changed: add the IPD rules by hand.', 1;
    DECLARE @rules NVARCHAR(MAX) = N'-- IPD LAB rate list (SQLScripts/2435): a branch, no overlapping dates, rates above zero
        IF @Rate_Type = ''IPD''
        BEGIN
            IF @Branch_ID IS NULL RAISERROR(''Choose the branch of the IPD LAB rate list.'', 16, 1);
            IF @Effective_To < @Effective_From RAISERROR(''Effective To cannot be before Effective From.'', 16, 1);
            IF EXISTS (SELECT 1 FROM [dbo].[LabRateCardMaster]
                       WHERE [Rate_Type] = ''IPD'' AND [Branch_ID] = @Branch_ID AND [IsDeleted] = 0 AND [Status] = 1 AND @Status = 1
                         AND (@RateCard_ID IS NULL OR @RateCard_ID = 0 OR [RateCard_ID] <> @RateCard_ID)
                         AND [Effective_From] <= @Effective_To AND [Effective_To] >= @Effective_From)
                RAISERROR(''This branch already has an active IPD LAB rate list over these dates. Edit it, or end it before the new one starts.'', 16, 1);
            IF EXISTS (SELECT 1 FROM @Details WHERE ISNULL([Rate], 0) <= 0)
                RAISERROR(''Every test, profile and package of the IPD LAB rate list needs a rate above zero.'', 16, 1);
        END

        ';
    SET @def = STUFF(@def, CHARINDEX(@anchor, @def), 0, @rules);
    SET @def = REPLACE(@def, 'CREATE   PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    SET @def = REPLACE(@def, 'CREATE PROCEDURE', 'CREATE OR ALTER PROCEDURE');
    EXEC (@def);
END
GO

-- ── 2. rate of a LAB item for an admitted patient ─────────────────────────────────────────────────────────────
-- @ItemType as in LabRateCardDetail (test / profile / package); the active IPD list of the branch in force on @OnDate.
CREATE OR ALTER FUNCTION dbo.fn_Ipd_LabRate (@BranchId INT, @ItemType VARCHAR(50), @ItemId INT, @OnDate DATE)
RETURNS TABLE
AS RETURN
(
    SELECT TOP (1) CAST(d.Rate AS DECIMAL(18,2)) AS Rate, d.Is_Discount_Allowed, m.RateCard_ID
    FROM dbo.LabRateCardMaster m
    JOIN dbo.LabRateCardDetail d ON d.RateCard_ID = m.RateCard_ID AND d.IsDeleted = 0 AND d.Status = 1
    WHERE m.Rate_Type = 'IPD' AND m.Branch_ID = @BranchId AND m.Status = 1 AND m.IsDeleted = 0
      AND @OnDate BETWEEN m.Effective_From AND m.Effective_To
      AND d.Item_Type = @ItemType AND d.Item_ID = @ItemId AND d.Rate > 0
    ORDER BY m.Effective_From DESC, m.RateCard_ID DESC
);
GO

-- ── 3. page: Master > IPD Master > IPD LAB Rate List ─────────────────────────────────────────────────────────
SET NOCOUNT ON;
DECLARE @co INT = 1, @menu INT, @page INT, @view INT, @ctl INT;
SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.IPD_MASTER';
IF @menu IS NULL THROW 51301, 'Menu MASTER.IPD_MASTER is missing.', 1;
EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.IPD_LABRATELIST', @Title = N'IPD LAB Rate List',
     @Controller = N'LabRateListIpd', @Action = N'Index', @Show_In_Menu = 1, @Sort_Order = 245, @Icon = N'bi bi-droplet-half me-2',
     @Route_Values = NULL, @Link_Target = NULL, @UserId = NULL, @Page_ID = @page OUTPUT;
SELECT @view = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW';
IF @view IS NULL EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'VIEW', @Title = N'Open page', @Sort_Order = 10, @Control_ID = @view OUTPUT;
DECLARE @a NVARCHAR(60);
DECLARE v CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'Index,LoadData,GetAllItems,GetCategories,GetSubCategories,GetDetailsForBranch', ',');
OPEN v; FETCH NEXT FROM v INTO @a;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET', @Controller = N'LabRateListIpd', @Action = @a, @Source = 'SEED'; FETCH NEXT FROM v INTO @a; END
CLOSE v; DEALLOCATE v;
DECLARE @c TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT, Method VARCHAR(10), Act NVARCHAR(60));
INSERT @c VALUES ('ADD', N'Create an IPD LAB rate list', 20, 'GET', N'Create'), ('EDIT', N'Edit an IPD LAB rate list', 30, 'GET', N'Edit'),
                 ('EDIT', N'Edit an IPD LAB rate list', 30, 'POST', N'Save'), ('STATUS', N'Activate / deactivate', 40, 'POST', N'ToggleStatus'),
                 ('DELETE', N'Delete an IPD LAB rate list', 50, 'DELETE', N'Delete');
DECLARE @cc VARCHAR(30), @ct NVARCHAR(150), @cs INT, @cm VARCHAR(10), @ca NVARCHAR(60);
DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort, Method, Act FROM @c;
OPEN k; FETCH NEXT FROM k INTO @cc, @ct, @cs, @cm, @ca;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @cc, @Title = @ct, @Sort_Order = @cs, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @cm, @Controller = N'LabRateListIpd', @Action = @ca, @Source = 'SEED';
    FETCH NEXT FROM k INTO @cc, @ct, @cs, @cm, @ca;
END
CLOSE k; DEALLOCATE k;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT '2435 IPD LAB rate list - done.';
GO
