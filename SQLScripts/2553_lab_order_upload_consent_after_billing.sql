-- ============================================================================================================
-- 2553: LAB > B2C Order List / B2B Registration - "Upload Consent" after billing.
--   A bill with a test whose Investigation Master has Consent Required = Yes (directly, or inside a profile / package,
--   resolved as usp_Lab_GetInvestigationDocFlags does at booking) shows "Upload Consent" in the row's actions; the file
--   (PDF / JPG / JPEG / PNG) goes to wwwroot/uploads/lab-compliance/consent like the one taken at billing, and its path
--   is stored on LabOrder.ConsentFilePath (the same column "View Uploaded Documents" reads).
--     usp_LabOrder_ConsentStatus  the rows of a list page: consent needed? file / remark already there? which tests
--     usp_LabOrder_SaveConsent    stores the uploaded file's path (replaces an earlier one)
--   Permission: new control UPLOAD_CONSENT on both list pages (no grant seeded: give it in Role Permissions);
--   the status read is part of VIEW. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- the consent-required tests of some orders (direct tests, profile tests and package members, one nested level)
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_ConsentStatus
    @LabOrderIds NVARCHAR(MAX),
    @BranchId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Ids TABLE (LabOrderId INT PRIMARY KEY);
    INSERT @Ids SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
    FROM STRING_SPLIT(ISNULL(@LabOrderIds, ''), ',')
    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;

    -- the tests of each order: a test line is itself; a package line is its members
    DECLARE @T TABLE (LabOrderId INT, TestId INT);
    INSERT @T
    SELECT li.LabOrderId, li.InvestigationId
    FROM dbo.LabOrderItem li INNER JOIN @Ids i ON i.LabOrderId = li.LabOrderId
    WHERE li.IsActive = 1 AND ISNULL(li.[Type], 'I') <> 'P';

    INSERT @T
    SELECT li.LabOrderId, d.Test_ID
    FROM dbo.LabOrderItem li INNER JOIN @Ids i ON i.LabOrderId = li.LabOrderId
    INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = li.InvestigationId AND d.IsDeleted = 0
    WHERE li.IsActive = 1 AND li.[Type] = 'P';

    -- a profile test (e.g. a panel billed as one test) brings its member tests, one level
    INSERT @T
    SELECT t.LabOrderId, d.Test_ID
    FROM @T t
    INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId AND ISNULL(m.Is_Profile_Test, 0) = 1
    INNER JOIN dbo.LabInvestigationProfileHeader h ON (h.Test_ID = m.Test_ID OR h.Profile_Name = m.Test_Name) AND h.IsDeleted = 0
    INNER JOIN dbo.LabInvestigationProfileDetail d ON d.Profile_ID = h.Profile_ID AND d.IsDeleted = 0;

    SELECT o.LabOrderId,
           CAST(CASE WHEN c.Tests IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS ConsentRequired,
           c.Tests AS ConsentTests,
           o.ConsentFilePath, o.ConsentRemarks
    FROM dbo.LabOrder o
    INNER JOIN @Ids i ON i.LabOrderId = o.LabOrderId
    OUTER APPLY (SELECT STRING_AGG(x.Test_Name, ', ') AS Tests
                 FROM (SELECT DISTINCT m.Test_Name FROM @T t
                       INNER JOIN dbo.LabInvestigationMaster m ON m.Test_ID = t.TestId AND ISNULL(m.Is_Consent_Required, 0) = 1
                       WHERE t.LabOrderId = o.LabOrderId) x) c
    WHERE @BranchId IS NULL OR o.BranchId = @BranchId;
END;
GO

-- store the consent uploaded after billing (the latest file replaces an earlier one; the bypass remark is kept)
CREATE OR ALTER PROCEDURE dbo.usp_LabOrder_SaveConsent
    @LabOrderId      INT,
    @ConsentFilePath NVARCHAR(300),
    @BranchId        INT = NULL,
    @UserId          INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@LabOrderId, 0) <= 0 OR NULLIF(LTRIM(RTRIM(@ConsentFilePath)), '') IS NULL
        THROW 56530, 'A bill and a consent file are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.LabOrder WHERE LabOrderId = @LabOrderId AND (@BranchId IS NULL OR BranchId = @BranchId))
        THROW 56531, 'The bill was not found in this branch.', 1;

    UPDATE dbo.LabOrder
       SET ConsentFilePath = @ConsentFilePath, ModifiedBy = @UserId, ModifiedDate = GETDATE()
     WHERE LabOrderId = @LabOrderId;
END;
GO

-- ── permission: UPLOAD_CONSENT on both list pages; the status read is part of VIEW ──
DECLARE @page INT, @view INT, @up INT, @code NVARCHAR(100);
DECLARE pp CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID, Page_Code FROM dbo.PageMaster WHERE Page_Code IN ('LAB.LABORDERBOOKING.B2CORDERLIST', 'LAB.LABORDERBOOKING.B2BREGISTRATION');
OPEN pp; FETCH NEXT FROM pp INTO @page, @code;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @view = (SELECT TOP 1 Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'VIEW');
    SET @up = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'UPLOAD_CONSENT', @Title = N'Upload consent', @Sort_Order = 60, @Control_ID = @up OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @view, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabOrderBooking', @Action = N'GetOrderConsentStatus', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @up, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabOrderBooking', @Action = N'UploadOrderConsent', @Source = 'SEED';
    FETCH NEXT FROM pp INTO @page, @code;
END
CLOSE pp; DEALLOCATE pp;

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2553 applied: LAB order lists - Upload Consent after billing.';
GO
