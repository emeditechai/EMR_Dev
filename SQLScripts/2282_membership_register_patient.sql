-- ============================================================================================================
-- Migration: 2282_membership_register_patient.sql
-- Master > Membership Cards > Issue: "Register new patient" - a new patient is saved in the common Patient Master
-- (as LAB registration does: usp_PatientMaster_Insert, patient code of the branch, no OPD / LAB bill), with relation
-- Self, and selected as the head of family for the card.
-- Permission: control REGISTER_PATIENT on page MASTER.MEMBERSHIPCARDS, with its endpoints. No role or user grant is
-- seeded - set it in Settings > Security > Role Permissions. Safe to re-run.
-- ============================================================================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @page INT, @ctl INT;
DECLARE pg CURSOR LOCAL FAST_FORWARD FOR SELECT Page_ID FROM dbo.PageMaster WHERE Page_Code = N'MASTER.MEMBERSHIPCARDS';
OPEN pg; FETCH NEXT FROM pg INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @ctl = NULL;
    EXEC dbo.usp_Auth_PageControlMaster_Upsert @Page_ID = @page, @Control_Code = 'REGISTER_PATIENT', @Title = N'Register a new patient (Issue Card)', @Sort_Order = 25, @Control_ID = @ctl OUTPUT;
    SELECT @ctl = Control_ID FROM dbo.PageControlMaster WHERE Page_ID = @page AND Control_Code = 'REGISTER_PATIENT';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'MembershipCards', @Action = N'NewPatientLookups', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'MembershipCards', @Action = N'NewPatientGeo', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'POST', @Controller = N'MembershipCards', @Action = N'RegisterPatient', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'MembershipCards', @Action = N'NewPatientPhoneSearch', @Source = 'SEED';
    EXEC dbo.usp_Auth_PageEndpointMap_Upsert @Page_ID = @page, @Control_ID = @ctl, @App = 'WEB', @Http_Method = 'GET',  @Controller = N'MembershipCards', @Action = N'NewPatientExisting', @Source = 'SEED';
    FETCH NEXT FROM pg INTO @page;
END
CLOSE pg; DEALLOCATE pg;
GO
UPDATE dbo.Users SET Permission_Version = Permission_Version + 1;
GO
PRINT 'Script 2282 applied: Membership Cards - register a new patient.';
GO
