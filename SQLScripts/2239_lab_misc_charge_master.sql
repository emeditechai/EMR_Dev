-- ====================================================================================================
-- Script: 2239_lab_misc_charge_master.sql
-- Description: Misc Charges Master (Masters > Lab Master): extra items billed along with investigations on a LAB bill,
--              e.g. Home Collection charges, container / kit charges.
-- Fields:
--   Misc_Charge_ID   INT IDENTITY PK
--   Charge_Name      NVARCHAR(150) mandatory, unique per company and type (among non-deleted rows)
--   Charge_Type      'Home Collection' / 'Misc'
--   Amount           DECIMAL(10,2) >= 0
--   Is_Discountable  BIT (a bill discount may apply to it)
--   Is_GST_Required  BIT; GST_Percentage mandatory (> 0, <= 28) when Yes, NULL when No
--   Display_Order, Description, Status, IsDeleted (soft delete: bills keep their reference)
-- Page: MASTER.LABMISCCHARGES under Master > Lab Master, controls VIEW / ADD / DETAILS / EDIT / STATUS / DELETE.
--       No role is granted here: give it from Settings > Security (Super Admin sees it without a grant).
-- Safe to re-run.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Table
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LabMiscChargeMaster' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    CREATE TABLE dbo.LabMiscChargeMaster
    (
        Misc_Charge_ID   INT IDENTITY(1,1) CONSTRAINT PK_LabMiscChargeMaster PRIMARY KEY,
        CompanyId        INT NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Company DEFAULT 1,
        Charge_Name      NVARCHAR(150) NOT NULL,
        Charge_Type      VARCHAR(20) NOT NULL,
        Amount           DECIMAL(10,2) NOT NULL,
        Is_Discountable  BIT NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Disc DEFAULT 0,
        Is_GST_Required  BIT NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Gst DEFAULT 0,
        GST_Percentage   DECIMAL(5,2) NULL,
        Description      NVARCHAR(500) NULL,
        Display_Order    INT NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Order DEFAULT 1,
        Status           BIT NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Status DEFAULT 1,
        IsDeleted        BIT NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Deleted DEFAULT 0,
        CreatedBy        INT NULL,
        CreatedDate      DATETIME2 NOT NULL CONSTRAINT DF_LabMiscChargeMaster_Created DEFAULT GETDATE(),
        ModifiedBy       INT NULL,
        ModifiedDate     DATETIME2 NULL,
        CONSTRAINT CK_LabMiscChargeMaster_Type   CHECK (Charge_Type IN ('Home Collection', 'Misc')),
        CONSTRAINT CK_LabMiscChargeMaster_Amount CHECK (Amount >= 0),
        CONSTRAINT CK_LabMiscChargeMaster_Gst    CHECK ((Is_GST_Required = 1 AND GST_Percentage > 0 AND GST_Percentage <= 28)
                                                     OR (Is_GST_Required = 0 AND GST_Percentage IS NULL))
    );
    CREATE INDEX IX_LabMiscChargeMaster_Type ON dbo.LabMiscChargeMaster(CompanyId, Charge_Type, Status) WHERE IsDeleted = 0;
    PRINT 'Created table dbo.LabMiscChargeMaster';
END
GO

-- 2. List
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabMiscChargeMaster_GetList
    @Status      BIT = NULL,
    @Charge_Type VARCHAR(20) = NULL,
    @Search      NVARCHAR(100) = NULL,
    @CompanyId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Search = NULLIF(LTRIM(RTRIM(@Search)), '');
    SET @Charge_Type = NULLIF(LTRIM(RTRIM(@Charge_Type)), '');

    SELECT m.Misc_Charge_ID, m.CompanyId, m.Charge_Name, m.Charge_Type, m.Amount, m.Is_Discountable, m.Is_GST_Required,
           m.GST_Percentage, m.Description, m.Display_Order, m.Status, m.CreatedBy, m.CreatedDate, m.ModifiedBy, m.ModifiedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), ''), cu.Username) AS CreatedByName,
           ISNULL(NULLIF(LTRIM(RTRIM(mu.FullName)), ''), mu.Username) AS ModifiedByName
    FROM dbo.LabMiscChargeMaster m
    LEFT JOIN dbo.Users cu ON cu.Id = m.CreatedBy
    LEFT JOIN dbo.Users mu ON mu.Id = m.ModifiedBy
    WHERE m.IsDeleted = 0
      AND (@Status IS NULL OR m.Status = @Status)
      AND (@CompanyId IS NULL OR m.CompanyId = @CompanyId)
      AND (@Charge_Type IS NULL OR m.Charge_Type = @Charge_Type)
      AND (@Search IS NULL OR m.Charge_Name LIKE '%' + @Search + '%' OR m.Description LIKE '%' + @Search + '%')
    ORDER BY m.Charge_Type, m.Display_Order, m.Charge_Name;
END
GO

-- 3. One record
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabMiscChargeMaster_GetById
    @Misc_Charge_ID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.Misc_Charge_ID, m.CompanyId, m.Charge_Name, m.Charge_Type, m.Amount, m.Is_Discountable, m.Is_GST_Required,
           m.GST_Percentage, m.Description, m.Display_Order, m.Status, m.CreatedBy, m.CreatedDate, m.ModifiedBy, m.ModifiedDate,
           ISNULL(NULLIF(LTRIM(RTRIM(cu.FullName)), ''), cu.Username) AS CreatedByName,
           ISNULL(NULLIF(LTRIM(RTRIM(mu.FullName)), ''), mu.Username) AS ModifiedByName
    FROM dbo.LabMiscChargeMaster m
    LEFT JOIN dbo.Users cu ON cu.Id = m.CreatedBy
    LEFT JOIN dbo.Users mu ON mu.Id = m.ModifiedBy
    WHERE m.Misc_Charge_ID = @Misc_Charge_ID AND m.IsDeleted = 0;
END
GO

-- 4. Shared validation (Create / Update): normalises the values and throws a readable message
CREATE OR ALTER PROCEDURE dbo.usp_LabMiscChargeMaster_Validate
    @Misc_Charge_ID  INT = NULL,
    @CompanyId       INT,
    @Charge_Name     NVARCHAR(150) OUTPUT,
    @Charge_Type     VARCHAR(20) OUTPUT,
    @Amount          DECIMAL(10,2),
    @Is_GST_Required BIT,
    @GST_Percentage  DECIMAL(5,2) OUTPUT,
    @Description     NVARCHAR(500) OUTPUT,
    @Display_Order   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Charge_Name = NULLIF(LTRIM(RTRIM(@Charge_Name)), '');
    SET @Charge_Type = NULLIF(LTRIM(RTRIM(@Charge_Type)), '');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), '');
    SET @Display_Order = ISNULL(@Display_Order, 1);

    IF @Charge_Name IS NULL THROW 52001, 'Charge Name is required.', 1;
    IF LEN(@Charge_Name) > 150 THROW 52002, 'Charge Name cannot exceed 150 characters.', 1;
    IF @Charge_Type IS NULL OR @Charge_Type NOT IN ('Home Collection', 'Misc') THROW 52003, 'Choose the Charge Type: Home Collection or Misc.', 1;
    IF @Amount IS NULL THROW 52004, 'Amount is required.', 1;
    IF @Amount < 0 THROW 52005, 'Amount cannot be negative.', 1;
    IF @Amount > 99999999.99 THROW 52006, 'Amount is too large.', 1;
    IF ISNULL(@Is_GST_Required, 0) = 1
    BEGIN
        IF @GST_Percentage IS NULL OR @GST_Percentage <= 0 THROW 52007, 'GST percentage is required when GST is applicable.', 1;
        IF @GST_Percentage > 28 THROW 52008, 'GST percentage cannot be more than 28.', 1;
    END
    ELSE SET @GST_Percentage = NULL;
    IF @Display_Order < 1 OR @Display_Order > 99999 THROW 52009, 'Display Order must be between 1 and 99999.', 1;

    IF EXISTS (SELECT 1 FROM dbo.LabMiscChargeMaster
               WHERE CompanyId = @CompanyId AND IsDeleted = 0 AND Charge_Type = @Charge_Type
                 AND LOWER(Charge_Name) = LOWER(@Charge_Name)
                 AND (@Misc_Charge_ID IS NULL OR Misc_Charge_ID <> @Misc_Charge_ID))
        THROW 52010, 'A charge with this name already exists for this Charge Type.', 1;
END
GO

-- 5. Create
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabMiscChargeMaster_Create
    @Charge_Name     NVARCHAR(150),
    @Charge_Type     VARCHAR(20),
    @Amount          DECIMAL(10,2),
    @Is_Discountable BIT = 0,
    @Is_GST_Required BIT = 0,
    @GST_Percentage  DECIMAL(5,2) = NULL,
    @Description     NVARCHAR(500) = NULL,
    @Display_Order   INT = 1,
    @Status          BIT = 1,
    @CompanyId       INT = 1,
    @UserId          INT = NULL,
    @NewId           INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_LabMiscChargeMaster_Validate @Misc_Charge_ID = NULL, @CompanyId = @CompanyId, @Charge_Name = @Charge_Name OUTPUT,
         @Charge_Type = @Charge_Type OUTPUT, @Amount = @Amount, @Is_GST_Required = @Is_GST_Required,
         @GST_Percentage = @GST_Percentage OUTPUT, @Description = @Description OUTPUT, @Display_Order = @Display_Order OUTPUT;

    INSERT INTO dbo.LabMiscChargeMaster (CompanyId, Charge_Name, Charge_Type, Amount, Is_Discountable, Is_GST_Required, GST_Percentage,
                                         Description, Display_Order, Status, CreatedBy, CreatedDate)
    VALUES (@CompanyId, @Charge_Name, @Charge_Type, @Amount, ISNULL(@Is_Discountable, 0), ISNULL(@Is_GST_Required, 0), @GST_Percentage,
            @Description, @Display_Order, ISNULL(@Status, 1), @UserId, GETDATE());
    SET @NewId = SCOPE_IDENTITY();
END
GO

-- 6. Update
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabMiscChargeMaster_Update
    @Misc_Charge_ID  INT,
    @Charge_Name     NVARCHAR(150),
    @Charge_Type     VARCHAR(20),
    @Amount          DECIMAL(10,2),
    @Is_Discountable BIT = 0,
    @Is_GST_Required BIT = 0,
    @GST_Percentage  DECIMAL(5,2) = NULL,
    @Description     NVARCHAR(500) = NULL,
    @Display_Order   INT = 1,
    @Status          BIT = 1,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CompanyId INT = (SELECT CompanyId FROM dbo.LabMiscChargeMaster WHERE Misc_Charge_ID = @Misc_Charge_ID AND IsDeleted = 0);
    IF @CompanyId IS NULL THROW 52011, 'Misc charge not found.', 1;
    EXEC dbo.usp_LabMiscChargeMaster_Validate @Misc_Charge_ID = @Misc_Charge_ID, @CompanyId = @CompanyId, @Charge_Name = @Charge_Name OUTPUT,
         @Charge_Type = @Charge_Type OUTPUT, @Amount = @Amount, @Is_GST_Required = @Is_GST_Required,
         @GST_Percentage = @GST_Percentage OUTPUT, @Description = @Description OUTPUT, @Display_Order = @Display_Order OUTPUT;

    UPDATE dbo.LabMiscChargeMaster
    SET Charge_Name = @Charge_Name, Charge_Type = @Charge_Type, Amount = @Amount, Is_Discountable = ISNULL(@Is_Discountable, 0),
        Is_GST_Required = ISNULL(@Is_GST_Required, 0), GST_Percentage = @GST_Percentage, Description = @Description,
        Display_Order = @Display_Order, Status = ISNULL(@Status, 1), ModifiedBy = @UserId, ModifiedDate = GETDATE()
    WHERE Misc_Charge_ID = @Misc_Charge_ID;
END
GO

-- 7. Activate / deactivate
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabMiscChargeMaster_ToggleStatus
    @Misc_Charge_ID INT,
    @Status         BIT,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabMiscChargeMaster WHERE Misc_Charge_ID = @Misc_Charge_ID AND IsDeleted = 0)
        THROW 52011, 'Misc charge not found.', 1;
    UPDATE dbo.LabMiscChargeMaster SET Status = @Status, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Misc_Charge_ID = @Misc_Charge_ID;
END
GO

-- 8. Delete (soft: a bill that used the charge keeps its reference)
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabMiscChargeMaster_Delete
    @Misc_Charge_ID INT,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabMiscChargeMaster WHERE Misc_Charge_ID = @Misc_Charge_ID AND IsDeleted = 0)
        THROW 52011, 'Misc charge not found or already deleted.', 1;
    UPDATE dbo.LabMiscChargeMaster SET IsDeleted = 1, Status = 0, ModifiedBy = @UserId, ModifiedDate = GETDATE() WHERE Misc_Charge_ID = @Misc_Charge_ID;
END
GO

-- 9. Page, controls and endpoints under Master > Lab Master
DECLARE @Controls TABLE (Code VARCHAR(30), Title NVARCHAR(150), Sort INT);
INSERT INTO @Controls VALUES ('ADD', N'Add New Misc Charge', 20), ('DETAILS', N'View details', 30), ('EDIT', N'Edit', 40),
                             ('STATUS', N'Activate / Deactivate', 50), ('DELETE', N'Delete', 60);
DECLARE @Endpoints TABLE (Method VARCHAR(10), Action NVARCHAR(100), Code VARCHAR(30));
INSERT INTO @Endpoints VALUES ('GET', N'Index', 'VIEW'), ('GET', N'Create', 'ADD'), ('POST', N'Create', 'ADD'),
                              ('GET', N'Details', 'DETAILS'), ('GET', N'Edit', 'EDIT'), ('POST', N'Edit', 'EDIT'),
                              ('POST', N'ToggleStatus', 'STATUS'), ('POST', N'Delete', 'DELETE');

DECLARE @co INT, @menu INT, @page INT, @ctl INT, @code VARCHAR(30), @title NVARCHAR(150), @sort INT, @method VARCHAR(10), @action NVARCHAR(100);
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @menu = NULL;
    SELECT @menu = Menu_ID FROM dbo.MenuMaster WHERE Menu_Code = 'MASTER.LAB_MASTER' AND CompanyId = @co;
    IF @menu IS NOT NULL
    BEGIN
        SET @page = NULL;
        EXEC dbo.usp_Auth_PageMaster_Upsert @CompanyId = @co, @Menu_ID = @menu, @Page_Code = N'MASTER.LABMISCCHARGES',
             @Title = N'Misc Charges Master', @Controller = N'LabMiscCharges', @Action = N'Index',
             @Show_In_Menu = 1, @Sort_Order = 135, @Icon = N'bi bi-cash-coin me-2', @Page_ID = @page OUTPUT;

        DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT Code, Title, Sort FROM @Controls;
        OPEN c1; FETCH NEXT FROM c1 INTO @code, @title, @sort;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = @code, @Title = @title, @Sort_Order = @sort, @Control_ID = @ctl OUTPUT;
            FETCH NEXT FROM c1 INTO @code, @title, @sort;
        END
        CLOSE c1; DEALLOCATE c1;

        DECLARE e1 CURSOR LOCAL FAST_FORWARD FOR SELECT Method, Action, Code FROM @Endpoints;
        OPEN e1; FETCH NEXT FROM e1 INTO @method, @action, @code;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ctl = NULL;
            SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = @code;
            EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = @method,
                 @Controller = N'LabMiscCharges', @Action = @action, @Source = 'SEED';
            FETCH NEXT FROM e1 INTO @method, @action, @code;
        END
        CLOSE e1; DEALLOCATE e1;
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2239 applied: Misc Charges Master (table, procedures, page under Master > Lab Master).';
GO
