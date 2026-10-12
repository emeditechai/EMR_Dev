-- ====================================================================================================
-- Script: 2257_b2b_billing_patient_search_endpoints.sql
-- The B2B billing page finds an existing patient by phone / name / UHID and loads the chosen patient through
-- OPD/SearchPatientByPhone, SearchPatientByName, SearchPatientByCode and GetPatientDetails. Those calls were
-- registered only under the OPD pages, so a login that has B2B Lab Billing but no OPD page (the Franchise role,
-- 2251) got nothing back when typing an existing patient's phone number.
-- Registers the four calls under LAB.LABORDERBOOKING.B2BBOOKING (VIEW) as well. No role grants change.
-- Safe to re-run. Run after 2256.
-- ====================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @p INT, @ctl INT, @co INT;
DECLARE cc CURSOR LOCAL FAST_FORWARD FOR SELECT CompanyId FROM dbo.CompanyMaster WHERE IsActive = 1;
OPEN cc; FETCH NEXT FROM cc INTO @co;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @p = NULL; SET @ctl = NULL;
    SELECT @p = Page_ID FROM dbo.PageMaster WHERE CompanyId = @co AND Page_Code = N'LAB.LABORDERBOOKING.B2BBOOKING';
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @p AND Control_Code = 'VIEW';
    IF @p IS NOT NULL
    BEGIN
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'OPD', @Action = N'SearchPatientByPhone', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'OPD', @Action = N'SearchPatientByName', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'OPD', @Action = N'SearchPatientByCode', @Source = 'SEED';
        EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @p, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',
             @Controller = N'OPD', @Action = N'GetPatientDetails', @Source = 'SEED';
    END
    FETCH NEXT FROM cc INTO @co;
END
CLOSE cc; DEALLOCATE cc;
GO

UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO

PRINT 'Script 2257 applied: B2B billing patient search endpoints.';
GO
