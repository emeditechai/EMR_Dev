-- ============================================================================
-- Migration: 2532_lab_rate_card_govt_scheme_code.sql
-- Description: Government scheme rate lists (e.g. WBHS - West Bengal Health Scheme).
--   * LabRateCardMaster.Is_Govt_Scheme / Scheme_Name: a rate list (Corporate rate list) marked as a government
--     scheme, with the scheme's name (e.g. WBHS).
--   * LabRateCardDetail.Scheme_Code: the scheme's own code for the test / profile / package on that rate list
--     (e.g. 01003044), printed against each test on the scheme's bill and claim annexure.
--   * usp_Api_LabRateCard_SaveScheme: saves the flag, name and codes after usp_Api_LabRateCardMaster_Save
--     (the save procedure and udt_LabRateCardDetail are unchanged).
--   * usp_Api_LabRateCard_GetScheme: the flag, name and codes of a rate list.
--   * Bulk upload (module corporate-rate): control IMPORT on MASTER.LABRATELISTCORPORATE.
--   Re-runnable.
-- ============================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('dbo.LabRateCardMaster', 'Is_Govt_Scheme') IS NULL
    ALTER TABLE dbo.LabRateCardMaster ADD Is_Govt_Scheme BIT NOT NULL CONSTRAINT DF_LabRateCardMaster_Is_Govt_Scheme DEFAULT 0;
GO
IF COL_LENGTH('dbo.LabRateCardMaster', 'Scheme_Name') IS NULL
    ALTER TABLE dbo.LabRateCardMaster ADD Scheme_Name NVARCHAR(100) NULL;
GO
IF COL_LENGTH('dbo.LabRateCardDetail', 'Scheme_Code') IS NULL
    ALTER TABLE dbo.LabRateCardDetail ADD Scheme_Code NVARCHAR(30) NULL;
GO

-- @CodesJson: [{"Item_Type":"Test","Item_ID":12,"Scheme_Code":"01003044"}, ...]
CREATE OR ALTER PROCEDURE dbo.usp_Api_LabRateCard_SaveScheme
    @RateCard_ID    INT,
    @Is_Govt_Scheme BIT,
    @Scheme_Name    NVARCHAR(100) = NULL,
    @CodesJson      NVARCHAR(MAX) = NULL,
    @UserId         INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.LabRateCardMaster
    SET Is_Govt_Scheme = ISNULL(@Is_Govt_Scheme, 0),
        Scheme_Name = CASE WHEN @Is_Govt_Scheme = 1 THEN NULLIF(LTRIM(RTRIM(@Scheme_Name)), '') END
    WHERE RateCard_ID = @RateCard_ID;

    IF ISNULL(@Is_Govt_Scheme, 0) = 0 OR ISJSON(@CodesJson) <> 1 RETURN;

    UPDATE d
    SET Scheme_Code = NULLIF(LTRIM(RTRIM(j.Scheme_Code)), '')
    FROM dbo.LabRateCardDetail d
    JOIN OPENJSON(@CodesJson) WITH (Item_Type VARCHAR(20), Item_ID INT, Scheme_Code NVARCHAR(30)) j
      ON j.Item_Type = d.Item_Type AND j.Item_ID = d.Item_ID
    WHERE d.RateCard_ID = @RateCard_ID AND ISNULL(d.IsDeleted, 0) = 0
      AND ISNULL(d.Scheme_Code, N'') <> ISNULL(NULLIF(LTRIM(RTRIM(j.Scheme_Code)), ''), N'');
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Api_LabRateCard_GetScheme
    @RateCard_ID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Is_Govt_Scheme, Scheme_Name FROM dbo.LabRateCardMaster WHERE RateCard_ID = @RateCard_ID;
    SELECT Item_Type, Item_ID, Scheme_Code FROM dbo.LabRateCardDetail
    WHERE RateCard_ID = @RateCard_ID AND ISNULL(IsDeleted, 0) = 0 AND Scheme_Code IS NOT NULL;
END
GO

-- Bulk upload on Rate List (Corporate): control IMPORT and the upload endpoints (module 'corporate-rate').
DECLARE @page INT, @ctl INT;
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = 'MASTER.LABRATELISTCORPORATE';
OPEN pc; FETCH NEXT FROM pc INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'IMPORT', @Title = N'Bulk upload (Excel)', @Sort_Order = 60, @Control_ID = @ctl OUTPUT;
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
         @Controller = N'LabBulkUpload', @Action = N'Template', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST',
         @Controller = N'LabBulkUpload', @Action = N'Import', @Source = 'SEED';
    FETCH NEXT FROM pc INTO @page;
END
CLOSE pc; DEALLOCATE pc;
GO
