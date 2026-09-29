-- ============================================================================
-- Migration: 2170_authorization_page_control_catalog.sql
-- Description:
--   Server-Side Authorization - every action a screen offers is a control of that page
--   (Doctor Master: Add Doctor, View details, Edit, Consulting Charges, Configure Scheduler ...),
--   and controls follow their page by default.
--     * usp_Auth_GetEffectivePermissions (2165, re-applied): a control with no row of its own
--       takes the page's answer - allowed with the page unless denied on the control.
--     * Page-specific control codes are allowed (A-Z, 0-9, _), not only the standard list;
--       the standard list gains ADD, DETAILS, STATUS, IMPORT, SAVE, COLLECT_PAYMENT.
--     * usp_Auth_Admin_ApplyControlCatalog: writes the catalogue built by
--       Tools/Authorization/page_controls.py (controls per page, and which control each
--       endpoint of the page belongs to). A control no screen offers is kept inactive, so its
--       endpoints are closed to everyone but a super admin.
--   Run after 2169, then: python3 Tools/Authorization/page_controls.py --apply
-- ============================================================================
USE [Dev_EMR];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

MERGE dbo.PermissionControlVocabulary AS t
USING (VALUES
    ('ADD',             'Add',              'Add a new record',                        20, 0),
    ('DETAILS',         'View details',     'Open a record read-only',                 30, 0),
    ('STATUS',          'Activate / Deactivate', 'Switch a record active or inactive', 50, 0),
    ('IMPORT',          'Bulk upload',      'Upload records from a file',              85, 0),
    ('SAVE',            'Save',             'Save the screen''s work (booking, registration)', 25, 0),
    ('COLLECT_PAYMENT', 'Collect payment',  'Take a payment against a bill',           26, 0)
) AS s (Control_Code, Title, Description, Sort_Order, Is_Sensitive)
ON t.Control_Code = s.Control_Code
WHEN NOT MATCHED THEN INSERT (Control_Code, Title, Description, Sort_Order, Is_Sensitive)
     VALUES (s.Control_Code, s.Title, s.Description, s.Sort_Order, s.Is_Sensitive);
GO

-- Page-specific controls: a standard code, or the screen's own (e.g. CONSULTING_CHARGES) with a title.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_SaveControl
    @Control_ID   INT = NULL,
    @Page_ID      INT,
    @CompanyId    INT,
    @Control_Code VARCHAR(30),
    @Title        NVARCHAR(150) = NULL,
    @Sort_Order   INT = NULL,
    @UserId       INT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Control_Code = UPPER(LTRIM(RTRIM(@Control_Code)));
    SET @Title = NULLIF(LTRIM(RTRIM(@Title)), '');
    IF @Control_ID = 0 SET @Control_ID = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.PageMaster WHERE Page_ID = @Page_ID AND CompanyId = @CompanyId)
    BEGIN RAISERROR('That page belongs to another company.', 16, 1); RETURN; END
    IF @Control_Code IS NULL OR @Control_Code LIKE '%[^A-Z0-9_]%' OR LEFT(@Control_Code, 1) NOT LIKE '[A-Z]'
    BEGIN RAISERROR('Use a code of capital letters, digits and _ (e.g. CONSULTING_CHARGES).', 16, 1); RETURN; END
    IF @Title IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.PermissionControlVocabulary WHERE Control_Code = @Control_Code)
    BEGIN RAISERROR('Give the control a title - the name of the button on the screen.', 16, 1); RETURN; END
    IF @Control_ID IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Control_ID = @Control_ID AND Control_Code = 'VIEW' AND @Control_Code <> 'VIEW')
    BEGIN RAISERROR('VIEW cannot be removed - it is how the screen is opened.', 16, 1); RETURN; END

    SELECT @Title = ISNULL(@Title, Title), @Sort_Order = ISNULL(@Sort_Order, Sort_Order)
    FROM dbo.PermissionControlVocabulary WHERE Control_Code = @Control_Code;
    SET @Sort_Order = ISNULL(@Sort_Order, 75);

    IF @Control_ID IS NULL
        EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @Page_ID, @Control_Code = @Control_Code, @Title = @Title,
             @Sort_Order = @Sort_Order, @UserId = @UserId, @Control_ID = @Control_ID OUTPUT;
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.PageControlMaster WHERE Page_ID = @Page_ID AND Control_Code = @Control_Code AND Control_ID <> @Control_ID)
        BEGIN RAISERROR('This page already has %s.', 16, 1, @Control_Code); RETURN; END
        UPDATE dbo.PageControlMaster SET Control_Code = @Control_Code, Title = @Title, Sort_Order = @Sort_Order, IsActive = 1,
               ModifiedBy = @UserId, ModifiedDate = GETDATE()
        WHERE Control_ID = @Control_ID AND Page_ID = @Page_ID;
    END
    UPDATE dbo.PageControlMaster SET IsActive = 1 WHERE Control_ID = @Control_ID;
    SELECT @Control_ID AS Control_ID;
END;
GO

-- @Json = { "pages": ["MASTER.DOCTORS", ...],
--           "controls": [ {"p":"MASTER.DOCTORS","c":"CONSULTING_CHARGES","t":"Consulting Charges","s":75,"a":1}, ... ],
--           "placements": [ {"pc":"MASTER.DOCTORS","m":"POST","ctl":"Doctors","act":"AddConsultingFee","c":"CONSULTING_CHARGES"}, ... ] }
-- Applied to every company's page with that code. Controls created by hand on the Menus & Pages screen are left alone.
CREATE OR ALTER PROCEDURE dbo.usp_Auth_Admin_ApplyControlCatalog
    @Json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;

    DECLARE @added INT, @updated INT, @retired INT, @remapped INT;

    SELECT pg.Page_ID, j.c AS Control_Code, j.t AS Title, j.s AS Sort_Order, j.a AS IsActive
    INTO #C
    FROM OPENJSON(@Json, '$.controls') WITH (p NVARCHAR(150), c VARCHAR(30), t NVARCHAR(150), s INT, a BIT) j
    INNER JOIN dbo.PageMaster pg ON pg.Page_Code = j.p;

    UPDATE pc SET pc.Title = c.Title, pc.Sort_Order = c.Sort_Order, pc.IsActive = c.IsActive, pc.ModifiedDate = GETDATE()
    FROM dbo.PageControlMaster pc INNER JOIN #C c ON c.Page_ID = pc.Page_ID AND c.Control_Code = pc.Control_Code;
    SET @updated = @@ROWCOUNT;

    INSERT INTO dbo.PageControlMaster (Page_ID, Control_Code, Title, Sort_Order, IsActive, CreatedDate)
    SELECT c.Page_ID, c.Control_Code, c.Title, c.Sort_Order, c.IsActive, GETDATE()
    FROM #C c
    WHERE NOT EXISTS (SELECT 1 FROM dbo.PageControlMaster pc WHERE pc.Page_ID = c.Page_ID AND pc.Control_Code = c.Control_Code);
    SET @added = @@ROWCOUNT;

    -- Generic controls of these pages that the catalogue no longer has (system-made only; VIEW always stays).
    UPDATE pc SET pc.IsActive = 0, pc.ModifiedDate = GETDATE()
    FROM dbo.PageControlMaster pc
    INNER JOIN dbo.PageMaster pg ON pg.Page_ID = pc.Page_ID
    INNER JOIN OPENJSON(@Json, '$.pages') WITH (p NVARCHAR(150) '$') j ON j.p = pg.Page_Code
    WHERE pc.IsActive = 1 AND pc.Control_Code <> 'VIEW' AND pc.CreatedBy IS NULL
      AND NOT EXISTS (SELECT 1 FROM #C c WHERE c.Page_ID = pc.Page_ID AND c.Control_Code = pc.Control_Code);
    SET @retired = @@ROWCOUNT;

    UPDATE m SET m.Control_ID = pc.Control_ID
    FROM OPENJSON(@Json, '$.placements') WITH (pc NVARCHAR(150), m VARCHAR(10), ctl NVARCHAR(150), act NVARCHAR(150), c VARCHAR(30)) j
    INNER JOIN dbo.PageMaster pg ON pg.Page_Code = j.pc
    INNER JOIN dbo.PageEndpointMap m ON m.App = 'WEB' AND m.Page_ID = pg.Page_ID AND m.Http_Method = j.m AND m.Controller = j.ctl AND m.Action = j.act
    INNER JOIN dbo.PageControlMaster pc ON pc.Page_ID = pg.Page_ID AND pc.Control_Code = j.c
    WHERE ISNULL(m.Control_ID, 0) <> pc.Control_ID;
    SET @remapped = @@ROWCOUNT;

    -- Everyone's permission set changes shape: make every session re-read it.
    UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
    COMMIT;

    DROP TABLE #C;
    SELECT @added AS Added, @updated AS Updated, @retired AS Retired, @remapped AS Remapped;
END;
GO
PRINT 'Script 2170 applied: page-specific controls ready. Now run Tools/Authorization/page_controls.py --apply.';
GO
